import Foundation

// 通話品質の計測 (docs/QUALITY_STATS.md, PROTOCOL v1.2 `call_stats`)。
// Android の CallStats.kt (RtpRxStats / RxStallMonitor / CallRtt / relayVersionAtLeast)
// と同じ意味論のポート。値は通話ごとに作り直す。
// 大原則 (QUALITY_STATS.md): パケットごとの処理は整数演算とロック 1 回だけ。アロケーションしない。

/// 下り RTP の受信統計 (RFC 3550 interarrival jitter を含む)。
///
/// - `gaps`: 期待 seq より先に進んだ分 (欠けた数)。16bit ラップ対応。
/// - `reorder`: 期待 seq より前 (逆行・重複)。Android と同じく重複も含む。
/// - `duplicates`: `reorder` のうち、既に受けた seq と同じもの (iOS のログ用の内訳。
///   `call_stats` には載せない = Android と同じ形式を保つ)。
/// - `jitterMs`: RFC 3550 §6.4.1 の J (RTP ts 単位で保持、ms で返す)。
/// - `maxGapMs` / `stall*`: 連続する 2 パケットの到着間隔の最大値と、100/200/500 ms 超えの回数。
/// - SSRC が変わった、または seq が `resyncSeq` 以上飛んだときはストリームの取り直しとみなし、
///   欠け・逆行・jitter を数えずに基準を取り直す。
///
/// スレッド: `onPacket` は受信スレッドから、`snapshot` は任意のスレッドから呼んでよい (内部ロック)。
public final class RtpRxStats: @unchecked Sendable {
    public static let resyncSeq = 3000
    public static let stall100Ns: UInt64 = 100_000_000
    public static let stall200Ns: UInt64 = 200_000_000
    public static let stall500Ns: UInt64 = 500_000_000

    public struct Snapshot: Equatable, Sendable {
        public var pkts: Int64 = 0
        public var gaps: Int64 = 0
        public var reorder: Int64 = 0
        public var duplicates: Int64 = 0

        public init() {}
        public var jitterMs: Int = 0
        public var maxGapMs: Int64 = 0
        public var stall100: Int64 = 0
        public var stall200: Int64 = 0
        public var stall500: Int64 = 0
    }

    private let clockRate: Double
    private let lock = NSLock()
    private var s = Snapshot()
    private var jitterTs: Double = 0
    private var maxGapNs: UInt64 = 0
    private var started = false
    private var expectedSeq: UInt16 = 0
    private var lastSsrc: UInt32 = 0
    private var lastTs: UInt32 = 0
    private var lastArrivalNs: UInt64 = 0
    /// 重複判定用: 直近 64 個の seq を受けたかどうかのビットマップ (bit0 = expectedSeq-1)。
    private var recentMask: UInt64 = 0

    public init(clockRate: Int = 8000) {
        self.clockRate = Double(clockRate)
    }

    /// 受信 1 パケットごとに呼ぶ。`arrivalNs` は単調時計 (DispatchTime.uptimeNanoseconds など)。
    public func onPacket(seq: UInt16, ts: UInt32, ssrc: UInt32, arrivalNs: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        s.pkts += 1
        guard started else {
            started = true
            resync(seq: seq, ts: ts, ssrc: ssrc, arrivalNs: arrivalNs)
            return
        }
        // 到着間隔 (seq に関係なく到着順で見る)
        let gapNs = arrivalNs &- lastArrivalNs
        if arrivalNs >= lastArrivalNs {
            if gapNs > maxGapNs { maxGapNs = gapNs }
            if gapNs > Self.stall100Ns {
                s.stall100 += 1
                if gapNs > Self.stall200Ns {
                    s.stall200 += 1
                    if gapNs > Self.stall500Ns { s.stall500 += 1 }
                }
            }
        }

        let delta = Int(seq &- expectedSeq) // 0..65535
        let forward = delta < 0x8000
        let jump = forward ? delta : 0x10000 - delta
        if ssrc != lastSsrc || jump >= Self.resyncSeq {
            resync(seq: seq, ts: ts, ssrc: ssrc, arrivalNs: arrivalNs)
            return
        }
        if forward {
            s.gaps += Int64(delta)
            // ビットマップを (delta + 1) だけ進めて、今回の seq を bit0 に立てる
            let shift = delta + 1
            recentMask = shift >= 64 ? 1 : (recentMask << UInt64(shift)) | 1
            expectedSeq = seq &+ 1
        } else {
            s.reorder += 1
            // expectedSeq - 1 - seq = back (0 = 直前に受けた seq と同じ)
            let back = jump - 1
            if back < 64 {
                let bit: UInt64 = 1 << UInt64(back)
                if recentMask & bit != 0 {
                    s.duplicates += 1
                } else {
                    recentMask |= bit
                }
            }
        }

        // RFC 3550: D(i,j) = (Rj - Ri) - (Sj - Si)、J += (|D| - J) / 16
        let arrivalDiffTs = (Double(arrivalNs) - Double(lastArrivalNs)) * clockRate / 1_000_000_000.0
        let tsDiff = Double(Int32(bitPattern: ts &- lastTs)) // 32bit ラップを符号付き差分に
        let d = arrivalDiffTs - tsDiff
        jitterTs += (abs(d) - jitterTs) / 16.0
        lastTs = ts
        lastArrivalNs = arrivalNs
    }

    private func resync(seq: UInt16, ts: UInt32, ssrc: UInt32, arrivalNs: UInt64) {
        expectedSeq = seq &+ 1
        lastSsrc = ssrc
        lastTs = ts
        lastArrivalNs = arrivalNs
        recentMask = 1
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        var out = s
        out.jitterMs = Int((jitterTs * 1000.0 / clockRate).rounded())
        out.maxGapMs = Int64(maxGapNs / 1_000_000)
        return out
    }
}

/// 通話中の下り途絶監視 (QUALITY_STATS.md「付随: 通話中の下り途絶監視」)。Android の RxStallMonitor と同じ。
///
/// 下り RTP の最終到着から `thresholdNs` 経ったら 1 回だけ張り直しを要求する。
/// - まだ 1 パケットも受けていない間は発動しない。
/// - 途絶 1 回につき 1 回: 次の RTP 受信で最終到着時刻が変わるまで再発動しない。
/// - `onConnected` (接続し直し) からも `thresholdNs` の猶予を取る。
/// - `act` が false を返したら発動済みにしない。
public final class RxStallMonitor: @unchecked Sendable {
    public static let defaultThresholdNs: UInt64 = 3_000_000_000

    private let thresholdNs: UInt64
    private let lock = NSLock()
    private var lastRxNs: UInt64 = 0
    private var connectedNs: UInt64 = 0
    private var firedForRxNs: UInt64 = 0
    private var _reconnects = 0

    public init(thresholdNs: UInt64 = RxStallMonitor.defaultThresholdNs) {
        self.thresholdNs = thresholdNs
    }

    public var reconnects: Int { lock.withLock { _reconnects } }

    public func onRx(nowNs: UInt64) {
        lock.withLock { lastRxNs = nowNs == 0 ? 1 : nowNs }
    }

    public func onConnected(nowNs: UInt64) {
        lock.withLock { connectedNs = nowNs }
    }

    /// 張り直しを要求したら true。`act` はロックの外で呼ぶ。
    public func poll(nowNs: UInt64, act: () -> Bool) -> Bool {
        let (last, ref): (UInt64, UInt64) = lock.withLock {
            (lastRxNs, max(lastRxNs, connectedNs))
        }
        let alreadyFired = lock.withLock { last == firedForRxNs }
        if last == 0 || alreadyFired { return false }
        if nowNs < ref || nowNs - ref < thresholdNs { return false }
        if !act() { return false }
        lock.withLock {
            firedForRxNs = last
            _reconnects += 1
        }
        return true
    }
}

/// 通話中の RTT 計測 (JSON ping/pong を開始直後・終了直前に 1 回ずつ)。Android の CallRtt と同じ。
public final class CallRtt: @unchecked Sendable {
    private let lock = NSLock()
    private var startPingTs: Int64 = -1
    private var endPingTs: Int64 = -1
    private var _startMs: Int64 = -1
    private var _endMs: Int64 = -1

    public init() {}

    public var startMs: Int64 { lock.withLock { _startMs } }
    public var endMs: Int64 { lock.withLock { _endMs } }
    public var endPingSent: Bool { lock.withLock { endPingTs >= 0 } }

    public func markStartPing(ts: Int64) { lock.withLock { startPingTs = ts } }
    public func markEndPing(ts: Int64) { lock.withLock { endPingTs = ts } }

    /// pong を受けたら呼ぶ。この通話の ping への応答なら true。
    @discardableResult
    public func onPong(ts: Int64, nowMs: Int64) -> Bool {
        if ts < 0 { return false }
        let rtt = nowMs - ts
        if rtt < 0 || rtt > 60_000 { return false }
        return lock.withLock {
            if ts == startPingTs {
                if _startMs < 0 { _startMs = rtt }
                return true
            }
            if ts == endPingTs {
                if _endMs < 0 { _endMs = rtt }
                return true
            }
            return false
        }
    }
}

/// 通話終了時に送る `call_stats` の中身。キー構成は Android の RelayProtocol.buildCallStats と同一。
public struct CallStatsReport: Equatable, Sendable {
    public var callId: String
    public var durMs: Int64
    public var net: String
    public var rxPkts: Int64 = 0
    public var rxGaps: Int64 = 0
    public var rxReorder: Int64 = 0
    public var rxJitterMs: Int = 0
    public var rxMaxGapMs: Int64 = 0
    public var rxStall100: Int64 = 0
    public var rxStall200: Int64 = 0
    public var rxStall500: Int64 = 0
    public var rxReconnects: Int = 0
    public var jbUnderrun: Int64 = 0
    public var jbOverflow: Int64 = 0
    public var playUnderrun: Int64 = 0
    public var txPkts: Int64 = 0
    public var txDrop: Int64 = 0
    public var txLost: Int64 = 0
    public var txLateMs: Int64 = 0
    public var rttStartMs: Int64 = -1
    public var rttEndMs: Int64 = -1

    public init(callId: String, durMs: Int64, net: String) {
        self.callId = callId
        self.durMs = durMs
        self.net = net
    }

    /// 受信統計を取り込む。
    public mutating func apply(rx: RtpRxStats.Snapshot) {
        rxPkts = rx.pkts
        rxGaps = rx.gaps
        rxReorder = rx.reorder
        rxJitterMs = rx.jitterMs
        rxMaxGapMs = rx.maxGapMs
        rxStall100 = rx.stall100
        rxStall200 = rx.stall200
        rxStall500 = rx.stall500
    }

    /// PROTOCOL v1.2 の `call_stats` JSON。キーの順序は固定 (ログの比較・ゴールデンテストのため)。
    /// 番号・表示名などの PII は含めない。
    public func json() -> String {
        func esc(_ s: String) -> String {
            var out = ""
            for u in s.unicodeScalars {
                switch u {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:
                    if u.value < 0x20 {
                        out += String(format: "\\u%04x", u.value)
                    } else {
                        out.unicodeScalars.append(u)
                    }
                }
            }
            return out
        }
        return "{\"t\":\"call_stats\",\"callId\":\"\(esc(callId))\",\"dur\":\(durMs),\"net\":\"\(esc(net))\","
            + "\"rx\":{\"pkts\":\(rxPkts),\"gaps\":\(rxGaps),\"reorder\":\(rxReorder),\"jitterMs\":\(rxJitterMs),"
            + "\"maxGapMs\":\(rxMaxGapMs),\"stall100\":\(rxStall100),\"stall200\":\(rxStall200),"
            + "\"stall500\":\(rxStall500),\"reconnects\":\(rxReconnects)},"
            + "\"jb\":{\"underrun\":\(jbUnderrun),\"overflow\":\(jbOverflow)},\"playUnderrun\":\(playUnderrun),"
            + "\"tx\":{\"pkts\":\(txPkts),\"drop\":\(txDrop),\"lost\":\(txLost),\"lateMs\":\(txLateMs)},"
            + "\"rttMs\":[\(rttStartMs),\(rttEndMs)]}"
    }
}

/// `call_stats` を送ってよい relay の最小版 (PROTOCOL v1.2)。
public let callStatsMinRelayVersion = "0.3.0"

/// `hello.relayVersion` が `min` 以上か (semver の MAJOR.MINOR.PATCH 比較)。Android と同じ規則:
/// 先頭の `v` は許し、`-pre` 付きは同じ番号の正式版より小さいとみなす。`+build` は無視。
/// パースできなければ false (送らない側に倒す)。
public func relayVersionAtLeast(_ version: String, _ min: String) -> Bool {
    guard let v = parseSemver(version), let m = parseSemver(min) else { return false }
    for i in 0..<3 where v.nums[i] != m.nums[i] {
        return v.nums[i] > m.nums[i]
    }
    return !(v.pre && !m.pre)
}

private func parseSemver(_ s: String) -> (nums: [Int], pre: Bool)? {
    var t = Substring(s.trimmingCharacters(in: .whitespaces))
    if t.hasPrefix("v") { t = t.dropFirst() }
    if let plus = t.firstIndex(of: "+") { t = t[..<plus] }
    let pre = t.contains("-")
    if let dash = t.firstIndex(of: "-") { t = t[..<dash] }
    let parts = t.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    var nums: [Int] = []
    for p in parts {
        guard !p.isEmpty, p.allSatisfy({ $0 >= "0" && $0 <= "9" }), let n = Int(p) else { return nil }
        nums.append(n)
    }
    return (nums, pre)
}

/// 送信側の統計 (上り)。`onFrameSent` は送信スレッド (マイクのタップ) から呼ぶ。
/// - `pkts`: 送ろうとした RTP 数。`lost`: WS 未接続で送れなかった数。`drop`: 送信エラー数。
/// - `lateMs`: 20 ms のサンプル時計に対する送出の最大遅れ (最初の 1 秒は数えない)。Android の tx.lateMs と同じ考え方。
public final class TxStats: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public var pkts: Int64 = 0
        public var lost: Int64 = 0
        public var drop: Int64 = 0
        public var lateMs: Int64 = 0

        public init() {}
    }

    private let lock = NSLock()
    private var s = Snapshot()
    private var nextNs: UInt64 = 0
    private var warmupFrames = 50
    private var maxLateNs: UInt64 = 0

    public init() {}

    public func onFrame(nowNs: UInt64, sent: Bool) {
        lock.lock()
        defer { lock.unlock() }
        s.pkts += 1
        if !sent { s.lost += 1 }
        if warmupFrames > 0 {
            warmupFrames -= 1
            nextNs = nowNs &+ 20_000_000
            return
        }
        // nextNs = このフレームの予定時刻
        if nowNs > nextNs {
            let late = nowNs - nextNs
            if late > maxLateNs { maxLateNs = late }
            nextNs = nowNs // 遅れは持ち越さない (Android の送信ループと同じ)
        }
        nextNs &+= 20_000_000
    }

    public func onSendError() {
        lock.withLock { s.drop += 1 }
    }

    public func snapshot() -> Snapshot {
        lock.withLock {
            var out = s
            out.lateMs = Int64(maxLateNs / 1_000_000)
            return out
        }
    }
}
