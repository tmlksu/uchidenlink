import XCTest
@testable import UchidenLinkCore

final class JitterBufferModeTests: XCTestCase {
    private func frame(_ value: Int16) -> [Int16] { [Int16](repeating: value, count: 160) }
    private let silence = [Int16](repeating: 0, count: 160)

    func testPlcAttenuatesThenGoesSilent() {
        let jb = JitterBuffer(config: .init(mode: .fixed, prefetchFrames: 1, plcRepeatFrames: 3))
        jb.push(sequenceNumber: 1, frame: frame(800))
        XCTAssertEqual(jb.popFrame(), frame(800))
        XCTAssertEqual(jb.popFrame(), frame(400))
        XCTAssertEqual(jb.popFrame(), frame(200))
        XCTAssertEqual(jb.popFrame(), frame(100))
        XCTAssertEqual(jb.popFrame(), silence) // 長い途絶でブザー音を出さない
        XCTAssertEqual(jb.snapshot().underrun, 4)
    }

    func testFixedModeDropsPacketsDelayedByStall() {
        // 固定モード: 途絶中も再生位置が進むので、遅れて全部届いた分は late で捨てられる
        let jb = JitterBuffer(config: .init(mode: .fixed, prefetchFrames: 2))
        jb.push(sequenceNumber: 0, frame: frame(1))
        jb.push(sequenceNumber: 1, frame: frame(2))
        _ = jb.popFrame(); _ = jb.popFrame()
        for _ in 0..<5 { _ = jb.popFrame() } // 100 ms 途絶
        for s in 2..<7 { jb.push(sequenceNumber: UInt16(s), frame: frame(Int16(s + 1))) }
        XCTAssertEqual(jb.snapshot().late, 5)
    }

    func testAdaptiveHoldsPositionDuringStall() {
        // 適応モード: 空なら再生位置を進めない → 遅れて届いた分も捨てずに再生する
        // (遅延を戻す間引きはここでは無効にして、位置の保持だけを見る)
        let jb = JitterBuffer(config: .init(mode: .adaptive, prefetchFrames: 2, maxFrames: 50, forceSkipMargin: 100, quietPeak: -1))
        jb.push(sequenceNumber: 0, frame: frame(1))
        jb.push(sequenceNumber: 1, frame: frame(2))
        XCTAssertEqual(jb.popFrame(), frame(1))
        XCTAssertEqual(jb.popFrame(), frame(2))
        for _ in 0..<5 { _ = jb.popFrame() }
        for s in 2..<7 { jb.push(sequenceNumber: UInt16(s), frame: frame(Int16(s + 1))) }
        XCTAssertEqual(jb.snapshot().late, 0)
        XCTAssertEqual(jb.popFrame(), frame(3))
        XCTAssertEqual(jb.snapshot().underrun, 5)
        XCTAssertEqual(jb.snapshot().skippedMissing, 0)
    }

    func testAdaptiveSkipsTrulyMissingFrame() {
        let jb = JitterBuffer(config: .init(mode: .adaptive, prefetchFrames: 2, maxFrames: 50))
        jb.push(sequenceNumber: 10, frame: frame(1))
        jb.push(sequenceNumber: 12, frame: frame(3)) // 11 が欠け
        XCTAssertEqual(jb.popFrame(), frame(1))
        _ = jb.popFrame() // 11: 後続 (12) があるので欠けとして進める
        XCTAssertEqual(jb.popFrame(), frame(3))
        XCTAssertEqual(jb.snapshot().skippedMissing, 1)
    }

    func testAdaptiveRaisesTargetOnLateAndShrinksLatency() {
        var cfg = JitterBuffer.Config.adaptive
        cfg.prefetchFrames = 2
        cfg.minTarget = 2
        cfg.decreaseAfterFrames = 10
        cfg.forceSkipMargin = 4
        let jb = JitterBuffer(config: cfg)
        // 深さ 10 まで溜まった (静かなフレーム)
        for s in 0..<10 { jb.push(sequenceNumber: UInt16(s), frame: frame(10)) }
        var played = 0
        for _ in 0..<6 {
            _ = jb.popFrame()
            played += 1
        }
        let st = jb.snapshot()
        XCTAssertGreaterThan(st.skippedForLatency, 0) // 遅延を戻した
        XCTAssertLessThanOrEqual(st.depth, 3)
        // late が来たら目標が上がる
        let before = jb.snapshot().target
        jb.push(sequenceNumber: 0, frame: frame(10))
        XCTAssertEqual(jb.snapshot().target, before + 1)
    }

    func testAdaptiveDoesNotSkipLoudFramesUnlessFarBehind() {
        var cfg = JitterBuffer.Config.adaptive
        cfg.prefetchFrames = 2
        cfg.forceSkipMargin = 6
        let jb = JitterBuffer(config: cfg)
        for s in 0..<6 { jb.push(sequenceNumber: UInt16(s), frame: frame(5000)) } // 深さ 6 = 目標 + 4
        _ = jb.popFrame()
        XCTAssertEqual(jb.snapshot().skippedForLatency, 0)
    }

    func testResyncOnLargeSeqJump() {
        let jb = JitterBuffer(config: .init(mode: .adaptive, prefetchFrames: 1, maxFrames: 50))
        jb.push(sequenceNumber: 100, frame: frame(1))
        XCTAssertEqual(jb.popFrame(), frame(1))
        jb.push(sequenceNumber: 40000, frame: frame(9)) // 再接続で別ストリーム
        XCTAssertEqual(jb.popFrame(), frame(9))
        XCTAssertEqual(jb.snapshot().resyncs, 1)
        // 逆方向の大きな飛びも同様
        jb.push(sequenceNumber: 5, frame: frame(4))
        XCTAssertEqual(jb.popFrame(), frame(4))
        XCTAssertEqual(jb.snapshot().resyncs, 2)
    }

    func testOverflowCounted() {
        let jb = JitterBuffer(config: .init(mode: .fixed, prefetchFrames: 3, maxFrames: 4))
        for s in 0..<6 { jb.push(sequenceNumber: UInt16(s), frame: frame(1)) }
        XCTAssertEqual(jb.snapshot().overflow, 2)
        XCTAssertEqual(jb.snapshot().maxDepth, 4)
    }
}

final class DtmfToneTests: XCTestCase {
    func testLengthsAndFrames() throws {
        let t = try XCTUnwrap(DtmfTone.tone(for: "5"))
        XCTAssertEqual(t.count, 1600)
        XCTAssertTrue(t[960...].allSatisfy { $0 == 0 })
        XCTAssertEqual(DtmfTone.frames(for: "#")?.count, 10)
        XCTAssertNil(DtmfTone.tone(for: "x"))
        XCTAssertNotNil(DtmfTone.tone(for: "a"))
    }

    func testFrequencies() {
        XCTAssertEqual(DtmfTone.frequencies(for: "1")?.low, 697)
        XCTAssertEqual(DtmfTone.frequencies(for: "1")?.high, 1209)
        XCTAssertEqual(DtmfTone.frequencies(for: "0")?.low, 941)
        XCTAssertEqual(DtmfTone.frequencies(for: "0")?.high, 1336)
        XCTAssertEqual(DtmfTone.frequencies(for: "D")?.high, 1633)
    }

    func testToneEnergyAtExpectedFrequencies() throws {
        // Goertzel で 770 Hz / 1336 Hz ("5") に強い成分、697 Hz に弱い成分
        let t = try XCTUnwrap(DtmfTone.tone(for: "5")).prefix(960).map { Double($0) }
        func power(_ f: Double) -> Double {
            let k = 2 * cos(2 * .pi * f / 8000)
            var s1 = 0.0, s2 = 0.0
            for x in t { let s0 = x + k * s1 - s2; s2 = s1; s1 = s0 }
            return s1 * s1 + s2 * s2 - k * s1 * s2
        }
        XCTAssertGreaterThan(power(770), power(697) * 20)
        XCTAssertGreaterThan(power(1336), power(1209) * 20)
        XCTAssertLessThanOrEqual(t.map { abs($0) }.max()!, 32767)
    }
}

/// TCP 区間の典型 (欠けは無く、途絶後にまとめて届く) を決定的に再現して両モードを比べる。
/// 20 ms ごとに送信、3 秒ごとに 300 ms 滞留してから一括到着。再生は 20 ms ごと (理想クロック)。
final class JitterBufferSimulationTests: XCTestCase {
    struct Result { var lostFrames: Int64; var underrun: Int64; var avgDepth: Double }

    private func simulate(_ config: JitterBuffer.Config, seconds: Int = 15) -> Result {
        let jb = JitterBuffer(config: config)
        let frame = [Int16](repeating: 3000, count: 160)
        var arrivals: [(t: Int, seq: UInt16)] = []
        for i in 0..<(seconds * 50) {
            let sent = i * 20
            var t = sent + 5 // 片道遅延 5 ms
            let cycle = sent % 3000
            if sent >= 3000 && cycle < 300 { t = sent - cycle + 300 + 5 } // 滞留 → 一括到着
            arrivals.append((t, UInt16(i)))
        }
        arrivals.sort { $0.t < $1.t }
        var idx = 0
        var depthSum = 0
        var pops = 0
        for now in stride(from: 0, to: seconds * 1000 + 500, by: 20) {
            while idx < arrivals.count, arrivals[idx].t <= now {
                jb.push(sequenceNumber: arrivals[idx].seq, frame: frame)
                idx += 1
            }
            _ = jb.popFrame()
            depthSum += jb.snapshot().depth
            pops += 1
        }
        let st = jb.snapshot()
        return Result(lostFrames: st.late + st.overflow, underrun: st.underrun, avgDepth: Double(depthSum) / Double(pops))
    }

    func testAdaptiveLosesNothingUnderTcpStalls() {
        let fixed = simulate(.fixed)
        let adaptive = simulate(.adaptive)
        print("[jb-sim] fixed: lost=\(fixed.lostFrames) underrun=\(fixed.underrun) avgDepth=\(String(format: "%.1f", fixed.avgDepth))")
        print("[jb-sim] adaptive: lost=\(adaptive.lostFrames) underrun=\(adaptive.underrun) avgDepth=\(String(format: "%.1f", adaptive.avgDepth))")
        XCTAssertGreaterThan(fixed.lostFrames, 40) // 途絶ごとに ~13 フレームを捨てる
        XCTAssertEqual(adaptive.lostFrames, 0)
        XCTAssertLessThan(adaptive.underrun, fixed.underrun)
        XCTAssertLessThan(adaptive.avgDepth, 12) // 遅延は上がりっぱなしにならない (≤ 240 ms)
    }
}

/// 2026-11 の実機 (iPad + 本番 relay、Wi-Fi、WSS) で見えた到着の仕方を決定的に再現する:
/// 欠けは無く、ほぼ毎秒 1 回 80〜140 ms 滞留してから一括到着 (実測: stall100 が 30 秒で 31〜38 回、
/// maxGap 119〜136 ms、jitter 22〜25 ms)。捨てた実データは late + overflow + 遅延を戻す間引きの合計。
final class JitterBufferRealPatternTests: XCTestCase {
    struct Result { var discarded: Int64; var underrun: Int64; var avgDepth: Double; var target: Int }

    static func simulate(_ config: JitterBuffer.Config, seconds: Int = 30) -> Result {
        let jb = JitterBuffer(config: config)
        let frame = [Int16](repeating: 600, count: 160) // 静かめ (間引きの対象になりうる)
        var arrivals: [(t: Int, seq: UInt16)] = []
        var rng: UInt32 = 12345
        func next() -> Int { rng = rng &* 1_103_515_245 &+ 12345; return Int((rng >> 16) & 0x7FFF) }
        var stallStart = 700, stallLen = 100
        for i in 0..<(seconds * 50) {
            let sent = i * 20
            if sent >= stallStart + stallLen {
                stallStart += 850 + next() % 300 // 次の滞留まで 0.85〜1.15 秒
                stallLen = 80 + next() % 61      // 80〜140 ms
            }
            var t = sent + 5
            if sent >= stallStart && sent < stallStart + stallLen { t = stallStart + stallLen + 5 }
            arrivals.append((t, UInt16(i)))
        }
        arrivals.sort { $0.t < $1.t }
        var idx = 0, depthSum = 0, pops = 0
        for now in stride(from: 0, to: seconds * 1000 + 500, by: 20) {
            while idx < arrivals.count, arrivals[idx].t <= now {
                jb.push(sequenceNumber: arrivals[idx].seq, frame: frame)
                idx += 1
            }
            _ = jb.popFrame()
            depthSum += jb.snapshot().depth
            pops += 1
        }
        let st = jb.snapshot()
        return Result(discarded: st.late + st.overflow + st.skippedForLatency, underrun: st.underrun,
                      avgDepth: Double(depthSum) / Double(pops), target: st.target)
    }

    func testAdaptiveLearnsFromWaitUnderruns() {
        let fixed = Self.simulate(.fixed)
        let adaptive = Self.simulate(.adaptive)
        for (name, r) in [("fixed", fixed), ("adaptive", adaptive)] {
            print("[jb-real] \(name): discarded=\(r.discarded) underrun=\(r.underrun) avgDepth=\(String(format: "%.1f", r.avgDepth)) target=\(r.target)")
        }
        // 待ちを契機に目標が上がり、滞留 (最大 140 ms = 7 フレーム) を吸収できる深さに落ち着く。
        XCTAssertGreaterThanOrEqual(adaptive.target, 6)
        XCTAssertLessThan(adaptive.underrun, fixed.underrun / 3) // 残りは目標が育つまでの学習期間の分
        XCTAssertLessThan(adaptive.discarded, fixed.discarded / 4)
        XCTAssertLessThan(adaptive.avgDepth, 12) // 240 ms 未満
    }
}
