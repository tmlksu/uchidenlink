import AVFoundation
import Foundation
import UchidenLinkCore

/// 音声の調整項目。既定値は実測で決める (ios/docs/AUDIO-QUALITY.md)。
/// DEBUG ビルドでは環境変数で切り替えられる (1 回のインストールで A/B 比較するため):
/// - `UCHIDENLINK_JB=fixed|adaptive`
/// - `UCHIDENLINK_FEEDER=timer|level`
/// - `UCHIDENLINK_RING_TARGET=<サンプル数>` (level フィーダーがリングに保つ量。8 kHz)
struct AudioTuning: CustomStringConvertible {
    enum Feeder: String {
        /// 20 ms タイマーごとに 1 フレーム (Phase 0a)。タイマーとオーディオのクロックがずれると
        /// リングが痩せる (アンダーラン) か太る (遅延) 。
        case timer
        /// 5 ms ごとにリングの残量を見て、目標量を下回った分だけジッタバッファから取り出す
        /// (取り出しの速さがオーディオのクロックに従う)。
        case level
    }

    var jitter: JitterBuffer.Config
    var feeder: Feeder
    var ringTargetSamples: Int

    // 既定は実機の実測で決めた (AUDIO-QUALITY.md「既定の決定」): ジッタバッファは adaptive。
    // WSS ではほぼ毎秒 100 ms 超の到着の空白があり、fixed (60 ms 先読み) は受信の 8〜11% を捨てた。
    // フィーダーは比較していないので Phase 0a の timer のまま。
    static let `default` = AudioTuning(jitter: .adaptive, feeder: .timer, ringTargetSamples: 320)
    static let phase0a = AudioTuning(jitter: .fixed, feeder: .timer, ringTargetSamples: 320)

    static func fromEnvironment() -> AudioTuning {
        var t = AudioTuning.default
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let jb = env["UCHIDENLINK_JB"] {
            switch jb {
            case "fixed": t.jitter = .fixed
            case "adaptive": t.jitter = .adaptive
            default: break
            }
        }
        if let f = env["UCHIDENLINK_FEEDER"], let feeder = Feeder(rawValue: f) {
            t.feeder = feeder
        }
        if let r = env["UCHIDENLINK_RING_TARGET"], let n = Int(r), n >= 160, n <= 4000 {
            t.ringTargetSamples = n
        }
        #endif
        return t
    }

    var description: String {
        "jb=\(jitter.mode.rawValue)(prefetch=\(jitter.prefetchFrames),max=\(jitter.maxFrames)) feeder=\(feeder.rawValue) ringTarget=\(ringTargetSamples)"
    }
}

/// 1 通話分の計測 (受信・送信・下り途絶)。通話ごとに作り直す。
final class CallMediaStats: Sendable {
    let rx = RtpRxStats()
    let tx = TxStats()
    let stall = RxStallMonitor()
}

/// 定期ログ・終話サマリ用のスナップショット。
struct AudioStatsSnapshot {
    var rx = RtpRxStats.Snapshot()
    var tx = TxStats.Snapshot()
    var jb = JitterBuffer.Stats()
    var reconnects = 0
    var playUnderrun = 0
    var playUnderrunMs = 0
    var ringMinMs = 0
    var ringMaxMs = 0
    var feederMaxLateMs = 0
    var tapFrames = 0
    var ioBufferMs = 0.0
    var hwRate = 0.0
    /// 窓内の最大振幅 (0〜32767)。エコー試験でミュート・DTMF が相手に届いたかを見る。
    var rxPeak = 0
    var txPeak = 0
}

/// 通話音声: AVAudioEngine + voice processing (設計 §3.1)。
///
/// TX: マイクのタップ -> AVAudioConverter (端末レート -> 8 kHz、160 サンプルに切り直し) ->
///     (DTMF 送出中はトーンに置換) -> ゲイン/ミュート -> G.711 -> RTP -> WebSocket。
/// RX: RTP (netQueue) -> 統計 -> G.711 デコード -> JitterBuffer -> フィーダー -> SPSC リング ->
///     AVAudioSourceNode (pull)。レンダーブロックはリングだけを読む。
/// AVAudioSession は通話中 CallKit が持つ。このクラスは didActivate / didDeactivate で
/// エンジンを開始/停止するだけ。
final class AudioEngine: @unchecked Sendable {
    let tuning: AudioTuning
    private let engine = AVAudioEngine()
    private let ring = SpscRingBuffer(capacity: 16384)
    private let jitter: JitterBuffer
    private var sourceNode: AVAudioSourceNode?
    private var resampler: StreamResampler?
    private var feeder: DispatchSourceTimer?
    private let feederQueue = DispatchQueue(label: "io.github.tmlksu.uchidenlink.audio-feeder", qos: .userInteractive)
    private let stateLock = NSLock()

    private var _running = false
    private var _muted = false
    private var _micGain: Float = 1.0
    private var _payloadType: UInt8 = 0
    private var _stats = CallMediaStats()
    private var _monitorStall = false
    private var rtpSeq: UInt16 = 0
    private var rtpTimestamp: UInt32 = 0
    private var rtpSsrc: UInt32 = 0
    private var dtmfFrames: [[Int16]] = []
    private var rxPeak = 0
    private var txPeak = 0

    // フィーダースレッドだけが触る (窓ごとの最小/最大)。snapshot はロック越しに読む。
    private var ringMin = Int.max
    private var ringMax = 0
    private var feederMaxLateNs: UInt64 = 0
    private var lastFeederNs: UInt64 = 0
    private var tapFrameLength = 0
    /// レンダーブロックが呼ばれた回数 (診断用。レンダースレッドだけが書く)。
    private let renderCalls = RenderCounter()
    private var configObserver: NSObjectProtocol?

    /// 送信する RTP (シリアライズ済み)。送れたら true (未接続なら false = tx.lost)。
    var onSendFrame: (@Sendable (Data, CallMediaStats) -> Bool)?
    /// 通話中に下り RTP が 3 秒途絶えたとき (フィーダースレッドから)。張り直しを要求できたら true。
    var onRxStall: (@Sendable () -> Bool)?
    /// DEBUG ループバック: 送るフレームをそのまま受信側に戻す。
    var loopback = false

    init(tuning: AudioTuning = .fromEnvironment()) {
        self.tuning = tuning
        self.jitter = JitterBuffer(config: tuning.jitter)
    }

    var isRunning: Bool { stateLock.withLock { _running } }
    var muted: Bool {
        get { stateLock.withLock { _muted } }
        set { stateLock.withLock { _muted = newValue } }
    }
    var micGain: Float {
        get { stateLock.withLock { _micGain } }
        set { stateLock.withLock { _micGain = max(0.5, min(4.5, newValue)) } }
    }
    var stats: CallMediaStats { stateLock.withLock { _stats } }

    func setPayloadType(_ pt: UInt8) {
        stateLock.withLock { _payloadType = pt }
    }

    /// 通話の計測を新しくする (呼が確立してメディアが始まるとき)。
    func beginCallStats() {
        stateLock.withLock {
            _stats = CallMediaStats()
            _monitorStall = true
        }
        jitter.reset()
    }

    func endCallStats() {
        stateLock.withLock { _monitorStall = false }
    }

    /// WS を張り直したとき (下り途絶監視の猶予の起点)。
    func onRelayConnected() {
        stats.stall.onConnected(nowNs: DispatchTime.now().uptimeNanoseconds)
    }

    /// in-band DTMF を 1 桁送る (120 ms トーン + 80 ms 無音。ミュートの影響を受けない)。
    func sendDtmf(_ digit: Character) {
        guard let frames = DtmfTone.frames(for: digit) else { return }
        stateLock.withLock {
            dtmfFrames.append(contentsOf: frames)
            if dtmfFrames.count > 100 { dtmfFrames.removeFirst(dtmfFrames.count - 100) }
        }
    }

    // MARK: - Lifecycle

    func start() {
        stateLock.lock()
        guard !_running else { stateLock.unlock(); return }
        _running = true
        rtpSeq = UInt16.random(in: 0...UInt16.max)
        rtpTimestamp = UInt32.random(in: 0...UInt32.max)
        rtpSsrc = UInt32.random(in: 0...UInt32.max)
        dtmfFrames.removeAll()
        stateLock.unlock()

        ring.reset()
        feederQueue.sync {
            ringMin = Int.max
            ringMax = 0
            feederMaxLateNs = 0
            lastFeederNs = 0
        }

        let input = engine.inputNode
        // voice processing はエンジン停止中に有効化し、フォーマットはその後で読む (VPIO が変える)。
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            AppLog.audioEvent("setVoiceProcessingEnabled failed: \(error.localizedDescription)")
        }
        let inputFormat = input.outputFormat(forBus: 0)
        let session = AVAudioSession.sharedInstance()
        AppLog.audioEvent("audio start: input \(Int(inputFormat.sampleRate)) Hz ch=\(inputFormat.channelCount) session=\(Int(session.sampleRate)) Hz io=\(String(format: "%.1f", session.ioBufferDuration * 1000)) ms mic=\(Self.recordPermissionName) route=\(Self.routeDescription) tuning: \(tuning)")

        let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false)!
        let ring = self.ring
        let renderCalls = self.renderCalls
        renderCalls.reset()
        let source = AVAudioSourceNode(format: sourceFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            renderCalls.increment()
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in abl {
                guard let mData = buffer.mData else { continue }
                let frames = min(Int(frameCount), Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                let ptr = mData.assumingMemoryBound(to: Float.self)
                ring.read(into: UnsafeMutableBufferPointer(start: ptr, count: frames), count: frames)
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: sourceFormat)
        sourceNode = source

        resampler = StreamResampler(inputFormat: inputFormat)
        input.removeTap(onBus: 0)
        let tapSize = AVAudioFrameCount(max(160, inputFormat.sampleRate / 50))
        input.installTap(onBus: 0, bufferSize: tapSize, format: inputFormat) { [weak self] buffer, _ in
            self?.handleInputBuffer(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            AppLog.audioEvent("audio engine started")
        } catch {
            AppLog.audioEvent("audio engine start failed: \(error.localizedDescription)")
        }
        observeConfigurationChange()
        startFeeder()
        // 実機で「start は成功したが I/O が回らない」を見分けるための 1 回だけの確認。
        feederQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.isRunning else { return }
            AppLog.audioEvent("audio health: engineRunning=\(self.engine.isRunning) renderCalls=\(self.renderCalls.value) tapFrames=\(self.tapFrameLength) mic=\(Self.recordPermissionName) route=\(Self.routeDescription)")
        }
    }

    /// 経路・フォーマットの変化で AVAudioEngine は自分で止まる (AVAudioEngineConfigurationChange)。
    /// 通話中ならタップ/ソースを張り直して再開する。
    private func observeConfigurationChange() {
        if configObserver != nil { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let running = self.engine.isRunning
            AppLog.audioEvent("engine configuration change: engineRunning=\(running) route=\(Self.routeDescription)")
            guard self.isRunning else { return }
            DispatchQueue.main.async {
                guard self.isRunning else { return }
                self.stop()
                self.start()
            }
        }
    }

    static var recordPermissionName: String {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }

    static var routeDescription: String {
        let r = AVAudioSession.sharedInstance().currentRoute
        let ins = r.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outs = r.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        return "in[\(ins)] out[\(outs)]"
    }

    func stop() {
        stateLock.lock()
        guard _running else { stateLock.unlock(); return }
        _running = false
        stateLock.unlock()

        feeder?.cancel()
        feeder = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let source = sourceNode {
            engine.detach(source)
            sourceNode = nil
        }
        resampler = nil
        AppLog.audioEvent("audio engine stopped")
    }

    // MARK: - Stats

    /// 現在の値。`resetWindow` なら窓ごとの最小/最大を取り直す (5 秒ごとのログ用)。
    func snapshot(resetWindow: Bool) -> AudioStatsSnapshot {
        let st = stats
        var out = AudioStatsSnapshot()
        out.rx = st.rx.snapshot()
        out.tx = st.tx.snapshot()
        out.reconnects = st.stall.reconnects
        out.jb = jitter.snapshot()
        out.playUnderrun = ring.underruns
        out.playUnderrunMs = ring.underrunSamples / 8
        feederQueue.sync {
            out.ringMinMs = ringMin == Int.max ? 0 : ringMin / 8
            out.ringMaxMs = ringMax / 8
            out.feederMaxLateMs = Int(feederMaxLateNs / 1_000_000)
            out.tapFrames = tapFrameLength
            if resetWindow {
                ringMin = Int.max
                ringMax = 0
                feederMaxLateNs = 0
            }
        }
        stateLock.withLock {
            out.rxPeak = rxPeak
            out.txPeak = txPeak
            if resetWindow { rxPeak = 0; txPeak = 0 }
        }
        if resetWindow { jitter.resetWindow() }
        let session = AVAudioSession.sharedInstance()
        out.ioBufferMs = session.ioBufferDuration * 1000
        out.hwRate = session.sampleRate
        return out
    }

    // MARK: - RX (netQueue)

    func receivePacket(_ data: Data, arrivalNs: UInt64) {
        guard let packet = RtpPacket.parse([UInt8](data)) else { return }
        let st = stats
        st.rx.onPacket(seq: packet.sequenceNumber, ts: packet.timestamp, ssrc: packet.ssrc, arrivalNs: arrivalNs)
        st.stall.onRx(nowNs: arrivalNs)
        guard let law = G711.Law(payloadType: packet.payloadType) else { return } // 101/13 などは捨てる
        let samples = G711.decodeFrame(packet.payload, law: law)
        var peak = 0
        for v in samples { let a = abs(Int(v)); if a > peak { peak = a } }
        stateLock.withLock { if peak > rxPeak { rxPeak = peak } }
        jitter.push(sequenceNumber: packet.sequenceNumber, frame: samples)
    }

    private func startFeeder() {
        // timer は Phase 0a と同じ既定フラグ (比較の基準)。level は合体させない strict。
        let timer = DispatchSource.makeTimerSource(flags: tuning.feeder == .level ? .strict : [], queue: feederQueue)
        switch tuning.feeder {
        case .timer:
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        case .level:
            timer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5), leeway: .milliseconds(1))
        }
        let period: UInt64 = tuning.feeder == .timer ? 20_000_000 : 5_000_000
        let target = tuning.ringTargetSamples
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if self.lastFeederNs != 0, now > self.lastFeederNs + period {
                let late = now - self.lastFeederNs - period
                if late > self.feederMaxLateNs { self.feederMaxLateNs = late }
            }
            self.lastFeederNs = now
            let level = self.ring.availableToRead
            if level < self.ringMin { self.ringMin = level }
            if level > self.ringMax { self.ringMax = level }
            switch self.tuning.feeder {
            case .timer:
                self.writeToRing(self.jitter.popFrame())
            case .level:
                var guardCount = 0
                while self.ring.availableToRead < target, guardCount < 10 {
                    self.writeToRing(self.jitter.popFrame())
                    guardCount += 1
                }
            }
            let monitor = self.stateLock.withLock { self._monitorStall }
            if monitor, let act = self.onRxStall {
                _ = self.stats.stall.poll(nowNs: now, act: act)
            }
        }
        timer.resume()
        feeder = timer
    }

    private func writeToRing(_ frame: [Int16]) {
        var f = [Float](repeating: 0, count: frame.count)
        for i in 0..<frame.count { f[i] = Float(frame[i]) / 32768.0 }
        ring.write(f)
    }

    // MARK: - TX (マイクのタップスレッド)

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let resampler else { return }
        if tapFrameLength == 0 {
            tapFrameLength = Int(buffer.frameLength)
            AppLog.audioEvent("mic tap: \(buffer.frameLength) frames per buffer")
        }
        resampler.append(buffer)
        let frames = resampler.pullFrames()
        guard !frames.isEmpty else { return }
        let (isMuted, gain, pt, st) = stateLock.withLock { (_muted, _micGain, _payloadType, _stats) }
        guard let law = G711.Law(payloadType: pt) else { return }
        for frame in frames {
            let dtmf: [Int16]? = stateLock.withLock { dtmfFrames.isEmpty ? nil : dtmfFrames.removeFirst() }
            let payload: [UInt8]
            var peak = 0
            if let dtmf {
                for v in dtmf { let a = abs(Int(v)); if a > peak { peak = a } }
            } else if !isMuted {
                for v in frame { let a = Int(abs(v * gain) * 32767); if a > peak { peak = a } }
            }
            stateLock.withLock { if peak > txPeak { txPeak = min(peak, 32767) } }
            if let dtmf {
                payload = G711.encodeFrame(dtmf, law: law)
            } else if isMuted {
                payload = G711.encodeFromFloat([Float](repeating: 0, count: 160), law: law)
            } else if gain != 1.0 {
                payload = G711.encodeFromFloat(frame.map { max(-1, min(1, $0 * gain)) }, law: law)
            } else {
                payload = G711.encodeFromFloat(frame, law: law)
            }
            let packet: RtpPacket = stateLock.withLock {
                let p = RtpPacket(payloadType: pt, sequenceNumber: rtpSeq, timestamp: rtpTimestamp, ssrc: rtpSsrc, payload: payload)
                rtpSeq &+= 1
                rtpTimestamp &+= 160
                return p
            }
            let data = Data(packet.serialized())
            let now = DispatchTime.now().uptimeNanoseconds
            if loopback {
                receivePacket(data, arrivalNs: now)
                st.tx.onFrame(nowNs: now, sent: true)
            } else {
                let sent = onSendFrame?(data, st) ?? false
                st.tx.onFrame(nowNs: now, sent: sent)
            }
        }
    }
}

/// AVAudioConverter の convert(to:error:withInputFrom:) (リサンプルできる唯一の形) によるストリーム変換。
/// append() と pullFrames() はどちらもタップのスレッドから呼ぶ (単一スレッド)。
final class StreamResampler: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private var inputSamples: [Float] = []
    private var outputSamples: [Float] = []

    init?(inputFormat: AVAudioFormat) {
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inputFormat, to: outFormat)
        else { return nil }
        self.inputFormat = inputFormat
        self.outputFormat = outFormat
        self.converter = conv
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        inputSamples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: count))
    }

    /// 溜まった入力をすべて変換し、揃った 160 サンプル (20 ms) フレームを返す。
    /// 壁時計ではなくサンプル数で駆動する (設計 §3.1)。
    func pullFrames() -> [[Float]] {
        while !inputSamples.isEmpty {
            let chunk = Array(inputSamples.prefix(4096))
            inputSamples.removeFirst(chunk.count)
            guard let inBuffer = makeBuffer(from: chunk) else { break }
            let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 2048)!
            var error: NSError?
            var supplied = false
            let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return inBuffer
            }
            if status == .error {
                AppLog.audioEvent("resampler convert error: \(error?.localizedDescription ?? "unknown")")
                break
            }
            if outBuffer.frameLength > 0, let channel = outBuffer.floatChannelData {
                outputSamples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(outBuffer.frameLength)))
            }
        }
        var frames: [[Float]] = []
        while outputSamples.count >= 160 {
            frames.append(Array(outputSamples.prefix(160)))
            outputSamples.removeFirst(160)
        }
        return frames
    }

    private func makeBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData
        else { return nil }
        samples.withUnsafeBufferPointer { src in
            channel[0].update(from: src.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}

/// レンダースレッドから増やし、他スレッドから読む診断用カウンタ (多少の読み違いは許容)。
final class RenderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { if lock.try() { n += 1; lock.unlock() } }
    func reset() { lock.withLock { n = 0 } }
    var value: Int { lock.withLock { n } }
}
