import Foundation

/// ジッタバッファ (8 kHz mono、20 ms = 160 サンプルのフレーム単位)。
///
/// 2 つのモードを持つ (どちらを使うかは実測で決める。docs は ios/docs/AUDIO-QUALITY.md):
///
/// - `.fixed` (Phase 0a 互換): `prefetchFrames` 溜めてから再生開始。欠けたフレームは PLC で埋めて
///   再生位置を進める (後から届いた分は late として捨てる)。上限 `maxFrames` を超えた到着は捨てる。
/// - `.adaptive`: WSS (TCP) 区間では「欠け」は実質起きず「遅れてまとめて届く」ため、
///   次のフレームが未着でバッファが空なら **再生位置を進めずに待つ** (PLC/無音を出して遅延を増やす)。
///   後続のフレームが既にある (= 本当に欠けた) ときだけ飛ばす。
///   待ち (空による underrun) が始まったとき、または遅れて捨てた (late) が出たら目標深さを 1 上げ、
///   しばらく安定していれば下げる。待ちは途絶 1 回につき 1 回だけ数える (途絶の長さで何段も上げない)。
///   (待つ方式では late は構造上ほぼ起きないため、late だけを契機にすると目標が下限に張り付く。
///   2026-11 実機で確認: AUDIO-QUALITY.md)
///   深さが目標を超えたら、振幅の小さいフレームを選んで 1 枚ずつ捨てて遅延を戻す
///   (深さが目標 + `forceSkipMargin` を超えたら振幅に関係なく捨てる)。
///
/// PLC はどちらのモードでも「直前フレームを減衰させながら最大 `plcRepeatFrames` 回繰り返し、
/// その後は無音」(長い途絶で 20 ms のフレームを延々繰り返すブザー音を出さない)。
///
/// スレッド: 内部ロックで保護。オーディオのレンダースレッドからは呼ばない
/// (フィーダーがここから SpscRingBuffer に移す)。
public final class JitterBuffer: @unchecked Sendable {
    public static let frameSamples = 160 // 20 ms at 8 kHz

    public enum Mode: String, Sendable {
        case fixed
        case adaptive
    }

    public struct Config: Equatable, Sendable {
        public var mode: Mode
        /// 再生開始前に溜めるフレーム数 (adaptive では目標深さの初期値)。
        public var prefetchFrames: Int
        /// 保持できる最大フレーム数。超えた到着は捨てる (overflow)。
        public var maxFrames: Int
        /// adaptive: 目標深さの下限・上限。
        public var minTarget: Int
        public var maxTarget: Int
        /// adaptive: late が出ずにこのフレーム数再生したら目標を 1 下げる。
        public var decreaseAfterFrames: Int
        /// adaptive: 深さが目標 + この値を超えたら振幅に関係なく 1 枚捨てる。
        public var forceSkipMargin: Int
        /// adaptive: 振幅の小さいフレーム (ピーク絶対値) とみなす閾値。
        public var quietPeak: Int16
        /// PLC で直前フレームを繰り返す最大回数。以降は無音。
        public var plcRepeatFrames: Int

        public init(mode: Mode = .fixed, prefetchFrames: Int = 3, maxFrames: Int = 10,
                    minTarget: Int = 2, maxTarget: Int = 15, decreaseAfterFrames: Int = 500,
                    forceSkipMargin: Int = 4, quietPeak: Int16 = 1200, plcRepeatFrames: Int = 3) {
            self.mode = mode
            self.prefetchFrames = prefetchFrames
            self.maxFrames = maxFrames
            self.minTarget = minTarget
            self.maxTarget = maxTarget
            self.decreaseAfterFrames = decreaseAfterFrames
            self.forceSkipMargin = forceSkipMargin
            self.quietPeak = quietPeak
            self.plcRepeatFrames = plcRepeatFrames
        }

        /// Phase 0a と同じ固定バッファ (60 ms 先読み、200 ms 上限)。
        public static let fixed = Config()
        /// 適応バッファ。上限は 1 秒 (TCP の滞留で一度に届く分を捨てないため)。
        public static let adaptive = Config(mode: .adaptive, prefetchFrames: 3, maxFrames: 50)
    }

    public struct Stats: Equatable, Sendable {
        /// push された数 (不正長も含む)。
        public var received: Int64 = 0
        /// 再生位置を過ぎてから届いて捨てた数。
        public var late: Int64 = 0
        /// 同じ seq の 2 回目以降。
        public var duplicate: Int64 = 0
        /// 上限超過で捨てた数 (call_stats の jb.overflow)。
        public var overflow: Int64 = 0
        /// 再生開始後に次のフレームが無く、PLC/無音を出した回数 (call_stats の jb.underrun)。
        public var underrun: Int64 = 0
        /// 欠けとして飛ばした seq の数。
        public var skippedMissing: Int64 = 0
        /// 遅延を戻すために捨てたフレーム数 (adaptive)。
        public var skippedForLatency: Int64 = 0
        /// 実データを再生した数。
        public var played: Int64 = 0
        /// 現在の深さ (フレーム数) と目標深さ。
        public var depth: Int = 0
        public var target: Int = 0
        /// 直近の `resetWindow()` 以降の深さの最大値。
        public var maxDepth: Int = 0
        /// seq の大きな飛びで取り直した回数。
        public var resyncs: Int64 = 0

        public init() {}
    }

    /// これ以上 seq が飛んだら取り直す (20 ms × 100 = 2 秒)。
    public static let resyncFrames = 100

    private let lock = NSLock()
    public let config: Config
    private var packets: [UInt16: [Int16]] = [:]
    private var expectedSeq: UInt16?
    /// 再生開始前に見た seq の循環最小値 (最初に届いたものが最古とは限らない)。
    private var startSeq: UInt16?
    private var started = false
    private var lastFrame: [Int16]
    private var plcCount = 0
    private var target: Int
    private var framesSinceLate = 0
    /// adaptive: いま待ち (空) の最中か。待ちの始まりで 1 回だけ目標を上げるため。
    private var waiting = false
    private var stats = Stats()
    private static let silence = [Int16](repeating: 0, count: frameSamples)

    public init(config: Config = .fixed) {
        self.config = config
        self.target = config.prefetchFrames
        self.lastFrame = Self.silence
    }

    /// Phase 0a 互換の初期化。
    public convenience init(prefetchFrames: Int, maxPackets: Int = 10) {
        self.init(config: Config(prefetchFrames: prefetchFrames, maxFrames: maxPackets))
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        packets.removeAll(keepingCapacity: true)
        expectedSeq = nil
        startSeq = nil
        started = false
        lastFrame = Self.silence
        plcCount = 0
        target = config.prefetchFrames
        framesSinceLate = 0
        waiting = false
        stats = Stats()
    }

    public func snapshot() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        var out = stats
        out.depth = packets.count
        out.target = target
        return out
    }

    /// 深さの最大値の集計窓をリセットする (定期ログ用)。
    public func resetWindow() {
        lock.withLock { stats.maxDepth = packets.count }
    }

    public func push(sequenceNumber seq: UInt16, frame: [Int16]) {
        lock.lock()
        defer { lock.unlock() }
        stats.received += 1
        guard frame.count == Self.frameSamples else { return }
        if packets[seq] != nil {
            stats.duplicate += 1
            return
        }
        if let expected = expectedSeq {
            // 再生位置からの符号付き距離。負 = 既に再生 (または PLC) 済み。
            let diff = Int16(bitPattern: seq &- expected)
            if abs(Int(diff)) >= Self.resyncFrames {
                // 2 秒以上の飛び = 相手側のストリームが変わった (再接続・SSRC 変更など)。
                // 1 つずつ追いかけると何秒も無音/全捨てになるので、ここから取り直す。
                stats.resyncs += 1
                packets.removeAll(keepingCapacity: true)
                expectedSeq = nil
                startSeq = seq
                started = false
                packets[seq] = frame
                return
            }
            if diff < 0 {
                stats.late += 1
                if config.mode == .adaptive {
                    target = min(config.maxTarget, target + 1)
                    framesSinceLate = 0
                }
                return
            }
        }
        if packets.count >= config.maxFrames {
            // 満杯: 次に再生するフレームを追い出さず、到着側を捨てる。
            stats.overflow += 1
            return
        }
        if expectedSeq == nil {
            if let current = startSeq {
                if Int16(bitPattern: seq &- current) < 0 { startSeq = seq }
            } else {
                startSeq = seq
            }
        }
        packets[seq] = frame
        if packets.count > stats.maxDepth { stats.maxDepth = packets.count }
    }

    /// 次に再生する 160 サンプル (再生開始前は無音)。
    public func popFrame() -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        if !started {
            guard packets.count >= target, let start = startSeq else { return Self.silence }
            started = true
            expectedSeq = start
        }
        guard var expected = expectedSeq else { return Self.silence }

        if config.mode == .adaptive {
            framesSinceLate += 1
            if framesSinceLate >= config.decreaseAfterFrames {
                framesSinceLate = 0
                if target > config.minTarget { target -= 1 }
            }
            // 遅延を戻す: 目標より深いとき、静かなフレーム (または深すぎるなら何でも) を 1 枚捨てる。
            let depth = packets.count
            if depth > target + 1, let next = packets[expected], packets[expected &+ 1] != nil {
                let force = depth > target + config.forceSkipMargin
                if force || Self.peak(next) <= config.quietPeak {
                    packets.removeValue(forKey: expected)
                    stats.skippedForLatency += 1
                    expected = expected &+ 1
                }
            }
        }

        if let frame = packets.removeValue(forKey: expected) {
            waiting = false
            lastFrame = frame
            plcCount = 0
            stats.played += 1
            expectedSeq = expected &+ 1
            return frame
        }

        // 次のフレームが無い。
        stats.underrun += 1
        if config.mode == .adaptive {
            if hasPacket(after: expected) {
                // 後続が既にある = 本当に欠けた。PLC 1 枚で欠けを埋め、再生位置を進める。
                stats.skippedMissing += 1
                expectedSeq = expected &+ 1
            } else {
                // 空 = 遅れているだけ (TCP)。再生位置は進めずに待つ。
                // 待ちの始まりで目標を 1 上げる (次の途絶をバッファで吸収できるように)。
                expectedSeq = expected
                if !waiting {
                    waiting = true
                    target = min(config.maxTarget, target + 1)
                    framesSinceLate = 0
                }
            }
        } else {
            stats.skippedMissing += 1
            expectedSeq = expected &+ 1
        }
        return concealment()
    }

    /// 直前フレームを 1 回ごとに半分に減衰させて最大 plcRepeatFrames 回、以降は無音。
    private func concealment() -> [Int16] {
        plcCount += 1
        guard plcCount <= config.plcRepeatFrames else { return Self.silence }
        let shift = plcCount // 1 回目 1/2、2 回目 1/4 …
        return lastFrame.map { $0 >> Int16(shift) }
    }

    private func hasPacket(after seq: UInt16) -> Bool {
        packets.keys.contains { Int16(bitPattern: $0 &- seq) > 0 }
    }

    private static func peak(_ frame: [Int16]) -> Int16 {
        var m: Int16 = 0
        for s in frame {
            let a = s == Int16.min ? Int16.max : abs(s)
            if a > m { m = a }
        }
        return m
    }
}
