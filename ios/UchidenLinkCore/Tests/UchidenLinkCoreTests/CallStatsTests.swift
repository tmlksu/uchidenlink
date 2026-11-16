import XCTest
@testable import UchidenLinkCore

/// Android の CallStatsTest と同じ入力・期待値。
final class RtpRxStatsTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    private func feed(_ s: RtpRxStats, startSeq: Int, startTs: UInt32, startNs: UInt64, n: Int, ssrc: UInt32 = 1) {
        for i in 0..<n {
            s.onPacket(seq: UInt16((startSeq + i) & 0xFFFF), ts: startTs &+ UInt32(160 * i), ssrc: ssrc, arrivalNs: startNs + 20 * ms * UInt64(i))
        }
    }

    func testSteadyStream() {
        let s = RtpRxStats()
        feed(s, startSeq: 100, startTs: 1000, startNs: 0, n: 500)
        let r = s.snapshot()
        XCTAssertEqual(r.pkts, 500)
        XCTAssertEqual(r.gaps, 0)
        XCTAssertEqual(r.reorder, 0)
        XCTAssertEqual(r.jitterMs, 0)
        XCTAssertEqual(r.maxGapMs, 20)
        XCTAssertEqual(r.stall100, 0)
    }

    func testMissingSeqCountsGaps() {
        let s = RtpRxStats()
        s.onPacket(seq: 10, ts: 0, ssrc: 1, arrivalNs: 0)
        s.onPacket(seq: 11, ts: 160, ssrc: 1, arrivalNs: 20 * ms)
        s.onPacket(seq: 14, ts: 640, ssrc: 1, arrivalNs: 80 * ms)
        XCTAssertEqual(s.snapshot().gaps, 2)
        XCTAssertEqual(s.snapshot().reorder, 0)
    }

    func testSeqWrapIsNotAGap() {
        let s = RtpRxStats()
        feed(s, startSeq: 65530, startTs: 0, startNs: 0, n: 12)
        XCTAssertEqual(s.snapshot().gaps, 0)
        XCTAssertEqual(s.snapshot().reorder, 0)
        s.onPacket(seq: 7, ts: 160 * 13, ssrc: 1, arrivalNs: 20 * ms * 13)
        XCTAssertEqual(s.snapshot().gaps, 1)
    }

    func testGapAcrossWrap() {
        let s = RtpRxStats()
        s.onPacket(seq: 65534, ts: 0, ssrc: 1, arrivalNs: 0)
        s.onPacket(seq: 1, ts: 480, ssrc: 1, arrivalNs: 60 * ms)
        XCTAssertEqual(s.snapshot().gaps, 2)
    }

    func testLateAndDuplicateCountAsReorder() {
        let s = RtpRxStats()
        s.onPacket(seq: 1, ts: 0, ssrc: 1, arrivalNs: 0)
        s.onPacket(seq: 3, ts: 320, ssrc: 1, arrivalNs: 40 * ms)
        s.onPacket(seq: 2, ts: 160, ssrc: 1, arrivalNs: 41 * ms) // 遅れて到着
        s.onPacket(seq: 3, ts: 320, ssrc: 1, arrivalNs: 42 * ms) // 重複
        XCTAssertEqual(s.snapshot().gaps, 1)
        XCTAssertEqual(s.snapshot().reorder, 2)
        XCTAssertEqual(s.snapshot().duplicates, 1) // iOS の内訳: 3 の再送だけが重複
        s.onPacket(seq: 4, ts: 480, ssrc: 1, arrivalNs: 60 * ms)
        XCTAssertEqual(s.snapshot().gaps, 1)
    }

    func testLateThenDuplicateOfLate() {
        let s = RtpRxStats()
        s.onPacket(seq: 1, ts: 0, ssrc: 1, arrivalNs: 0)
        s.onPacket(seq: 4, ts: 480, ssrc: 1, arrivalNs: 60 * ms)
        s.onPacket(seq: 2, ts: 160, ssrc: 1, arrivalNs: 61 * ms)
        s.onPacket(seq: 2, ts: 160, ssrc: 1, arrivalNs: 62 * ms)
        XCTAssertEqual(s.snapshot().reorder, 2)
        XCTAssertEqual(s.snapshot().duplicates, 1)
    }

    func testLargeJumpOrSsrcChangeResyncs() {
        let s = RtpRxStats()
        feed(s, startSeq: 100, startTs: 0, startNs: 0, n: 10)
        s.onPacket(seq: 20000, ts: 5000, ssrc: 1, arrivalNs: 220 * ms)
        XCTAssertEqual(s.snapshot().gaps, 0)
        s.onPacket(seq: 20001, ts: 5160, ssrc: 1, arrivalNs: 240 * ms)
        XCTAssertEqual(s.snapshot().gaps, 0)
        s.onPacket(seq: 5, ts: 0, ssrc: 2, arrivalNs: 260 * ms)
        s.onPacket(seq: 6, ts: 160, ssrc: 2, arrivalNs: 280 * ms)
        XCTAssertEqual(s.snapshot().gaps, 0)
        XCTAssertEqual(s.snapshot().reorder, 0)
        XCTAssertEqual(s.snapshot().pkts, 14)
    }

    func testStallBucketsAreCumulative() {
        let s = RtpRxStats()
        var t: UInt64 = 0
        var seq = 0
        func pkt(_ afterMs: UInt64) {
            t += afterMs * ms
            s.onPacket(seq: UInt16(seq), ts: UInt32(160 * seq), ssrc: 1, arrivalNs: t)
            seq += 1
        }
        pkt(0); pkt(20); pkt(150); pkt(250); pkt(600); pkt(100)
        let r = s.snapshot()
        XCTAssertEqual(r.stall100, 3)
        XCTAssertEqual(r.stall200, 2)
        XCTAssertEqual(r.stall500, 1)
        XCTAssertEqual(r.maxGapMs, 600)
    }

    func testJitterFollowsRfc3550() {
        let s = RtpRxStats()
        for i in 0..<400 {
            let wobble: UInt64 = i % 2 == 0 ? 0 : 10 * ms
            s.onPacket(seq: UInt16(i), ts: UInt32(160 * i), ssrc: 1, arrivalNs: 20 * ms * UInt64(i) + wobble)
        }
        XCTAssertEqual(s.snapshot().jitterMs, 10)
    }

    func testTimestampWrapDoesNotExplodeJitter() {
        let s = RtpRxStats()
        feed(s, startSeq: 0, startTs: 0xFFFF_FFFF - 800, startNs: 0, n: 20)
        XCTAssertEqual(s.snapshot().jitterMs, 0)
    }
}

final class RxStallMonitorTests: XCTestCase {
    private let sec: UInt64 = 1_000_000_000

    func testDoesNotFireBeforeFirstRtp() {
        let m = RxStallMonitor()
        var calls = 0
        XCTAssertFalse(m.poll(nowNs: 10 * sec) { calls += 1; return true })
        XCTAssertFalse(m.poll(nowNs: 100 * sec) { calls += 1; return true })
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(m.reconnects, 0)
    }

    func testFiresOncePerStallAndResetsOnNextRtp() {
        let m = RxStallMonitor()
        var calls = 0
        let act: () -> Bool = { calls += 1; return true }
        m.onRx(nowNs: 1 * sec)
        XCTAssertFalse(m.poll(nowNs: 3 * sec, act: act))
        XCTAssertTrue(m.poll(nowNs: 4 * sec, act: act))
        XCTAssertFalse(m.poll(nowNs: 5 * sec, act: act))
        XCTAssertFalse(m.poll(nowNs: 60 * sec, act: act))
        XCTAssertEqual(calls, 1)
        m.onRx(nowNs: 61 * sec)
        XCTAssertFalse(m.poll(nowNs: 63 * sec, act: act))
        XCTAssertTrue(m.poll(nowNs: 64 * sec, act: act))
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(m.reconnects, 2)
    }

    func testSteadyRtpNeverFires() {
        let m = RxStallMonitor()
        var t: UInt64 = 0
        for _ in 0..<1000 {
            t += 20_000_000
            m.onRx(nowNs: t)
            XCTAssertFalse(m.poll(nowNs: t + 10_000_000) { true })
        }
        XCTAssertEqual(m.reconnects, 0)
    }

    func testRetriesWhenReconnectCouldNotBeIssued() {
        let m = RxStallMonitor()
        m.onRx(nowNs: 1 * sec)
        XCTAssertFalse(m.poll(nowNs: 5 * sec) { false })
        XCTAssertEqual(m.reconnects, 0)
        XCTAssertTrue(m.poll(nowNs: 5 * sec) { true })
        XCTAssertEqual(m.reconnects, 1)
    }

    func testFreshConnectionGetsGrace() {
        let m = RxStallMonitor()
        m.onRx(nowNs: 1 * sec)
        m.onConnected(nowNs: 8 * sec)
        XCTAssertFalse(m.poll(nowNs: 9 * sec) { true })
        XCTAssertFalse(m.poll(nowNs: 10_900_000_000) { true })
        XCTAssertTrue(m.poll(nowNs: 11 * sec) { true })
        XCTAssertFalse(m.poll(nowNs: 20 * sec) { true })
        XCTAssertEqual(m.reconnects, 1)
    }
}

final class CallRttTests: XCTestCase {
    func testMatchesStartAndEndPings() {
        let r = CallRtt()
        r.markStartPing(ts: 1000)
        XCTAssertTrue(r.onPong(ts: 1000, nowMs: 1045))
        XCTAssertFalse(r.endPingSent)
        r.markEndPing(ts: 9000)
        XCTAssertTrue(r.endPingSent)
        XCTAssertFalse(r.onPong(ts: 1234, nowMs: 9100))
        XCTAssertTrue(r.onPong(ts: 9000, nowMs: 9080))
        XCTAssertEqual(r.startMs, 45)
        XCTAssertEqual(r.endMs, 80)
    }

    func testDefaultsToMinusOne() {
        let r = CallRtt()
        XCTAssertEqual(r.startMs, -1)
        XCTAssertEqual(r.endMs, -1)
        XCTAssertFalse(r.onPong(ts: -1, nowMs: 10))
    }
}

final class RelayVersionTests: XCTestCase {
    func testComparison() {
        XCTAssertTrue(relayVersionAtLeast("0.3.0", "0.3.0"))
        XCTAssertTrue(relayVersionAtLeast("0.3.1", "0.3.0"))
        XCTAssertTrue(relayVersionAtLeast("0.10.0", "0.3.0"))
        XCTAssertTrue(relayVersionAtLeast("1.0.0", "0.3.0"))
        XCTAssertTrue(relayVersionAtLeast("v0.3.0", "0.3.0"))
        XCTAssertTrue(relayVersionAtLeast("0.3.0+abc", "0.3.0"))
        XCTAssertTrue(relayVersionAtLeast("0.4.0-rc1", "0.3.0"))
        XCTAssertFalse(relayVersionAtLeast("0.3.0-rc1", "0.3.0"))
        XCTAssertFalse(relayVersionAtLeast("0.2.0", "0.3.0"))
        XCTAssertFalse(relayVersionAtLeast("0.2.99", "0.3.0"))
        XCTAssertFalse(relayVersionAtLeast("", "0.3.0"))
        XCTAssertFalse(relayVersionAtLeast("0.3", "0.3.0"))
        XCTAssertFalse(relayVersionAtLeast("x.y.z", "0.3.0"))
        XCTAssertFalse(relayVersionAtLeast("dev", "0.3.0"))
    }
}

final class CallStatsReportTests: XCTestCase {
    func testGoldenJson() throws {
        let fx = try XCTUnwrap(Fixtures.json("call_stats.json") as? [String: Any])
        let r = try XCTUnwrap(fx["report"] as? [String: Any])
        func i(_ k: String) -> Int64 { (r[k] as! NSNumber).int64Value }
        var rep = CallStatsReport(callId: r["callId"] as! String, durMs: i("durMs"), net: r["net"] as! String)
        rep.rxPkts = i("rxPkts"); rep.rxGaps = i("rxGaps"); rep.rxReorder = i("rxReorder")
        rep.rxJitterMs = Int(i("rxJitterMs")); rep.rxMaxGapMs = i("rxMaxGapMs")
        rep.rxStall100 = i("rxStall100"); rep.rxStall200 = i("rxStall200"); rep.rxStall500 = i("rxStall500")
        rep.rxReconnects = Int(i("rxReconnects"))
        rep.jbUnderrun = i("jbUnderrun"); rep.jbOverflow = i("jbOverflow"); rep.playUnderrun = i("playUnderrun")
        rep.txPkts = i("txPkts"); rep.txDrop = i("txDrop"); rep.txLost = i("txLost"); rep.txLateMs = i("txLateMs")
        rep.rttStartMs = i("rttStartMs"); rep.rttEndMs = i("rttEndMs")
        XCTAssertEqual(rep.json(), fx["expected"] as? String)
        // relay 側が解釈できる JSON であること
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rep.json().utf8)) as? [String: Any])
        XCTAssertEqual(parsed["t"] as? String, "call_stats")
        XCTAssertLessThan(rep.json().utf8.count, 4096)
    }

    func testCallIdIsEscaped() throws {
        let rep = CallStatsReport(callId: "a\"b\\c", durMs: 1, net: "wifi")
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rep.json().utf8)) as? [String: Any])
        XCTAssertEqual(parsed["callId"] as? String, "a\"b\\c")
    }
}

final class TxStatsTests: XCTestCase {
    func testLatenessAfterWarmup() {
        let s = TxStats()
        var t: UInt64 = 1_000_000_000
        for _ in 0..<60 { s.onFrame(nowNs: t, sent: true); t += 20_000_000 }
        XCTAssertEqual(s.snapshot().lateMs, 0)
        // 100 ms 分がまとめて届く (5 フレーム同時) → 最初のフレームが 80 ms 遅れ
        t += 80_000_000
        for _ in 0..<5 { s.onFrame(nowNs: t, sent: false) }
        let r = s.snapshot()
        XCTAssertEqual(r.lateMs, 80)
        XCTAssertEqual(r.pkts, 65)
        XCTAssertEqual(r.lost, 5)
    }
}
