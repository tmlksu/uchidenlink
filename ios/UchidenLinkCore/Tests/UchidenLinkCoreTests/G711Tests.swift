import XCTest
@testable import UchidenLinkCore

final class G711Tests: XCTestCase {
    // Anchor values from the ITU-T G.711 conversion tables.
    func testUlawDecodeAnchors() {
        XCTAssertEqual(G711.ulawToLinear(0x00), -32124)
        XCTAssertEqual(G711.ulawToLinear(0x01), -31100)
        XCTAssertEqual(G711.ulawToLinear(0x80), 32124)
        XCTAssertEqual(G711.ulawToLinear(0x81), 31100)
        XCTAssertEqual(G711.ulawToLinear(0xFF), 0)
        XCTAssertEqual(G711.ulawToLinear(0x7F), 0)
        XCTAssertEqual(G711.ulawToLinear(0xAA), 5372)
        XCTAssertEqual(G711.ulawToLinear(0x2A), -5372)
        XCTAssertEqual(G711.ulawToLinear(0x55), -716)
    }

    func testAlawDecodeAnchors() {
        XCTAssertEqual(G711.alawToLinear(0xD5), 8)
        XCTAssertEqual(G711.alawToLinear(0x55), -8)
        XCTAssertEqual(G711.alawToLinear(0x00), -5504)
        XCTAssertEqual(G711.alawToLinear(0x80), 5504)
        XCTAssertEqual(G711.alawToLinear(0xAA), 32256)
        XCTAssertEqual(G711.alawToLinear(0x2A), -32256)
    }

    func testEncodeAnchors() {
        XCTAssertEqual(G711.linearToUlaw(0), 0xFF)
        XCTAssertEqual(G711.linearToUlaw(32124), 0x80)
        XCTAssertEqual(G711.linearToUlaw(-32124), 0x00)
        XCTAssertEqual(G711.linearToUlaw(32767), 0x80)
        XCTAssertEqual(G711.linearToUlaw(-32768), 0x00)
        XCTAssertEqual(G711.linearToAlaw(0), 0xD5)
        XCTAssertEqual(G711.linearToAlaw(8), 0xD5)
        XCTAssertEqual(G711.linearToAlaw(-8), 0x55)
    }

    /// Every code word must survive a decode -> encode round trip unchanged,
    /// except μ-law 0x7F: it is the "negative zero" code — it decodes to 0,
    /// and 0 encodes canonically to 0xFF (positive zero). Both decode to 0.
    func testRoundTripAll256() {
        for i in 0...255 {
            let u = UInt8(i)
            if u != 0x7F {
                XCTAssertEqual(G711.linearToUlaw(G711.ulawToLinear(u)), u, "ulaw round trip \(u)")
            }
            XCTAssertEqual(G711.linearToAlaw(G711.alawToLinear(u)), u, "alaw round trip \(u)")
        }
        XCTAssertEqual(G711.ulawToLinear(0x7F), 0)
        XCTAssertEqual(G711.ulawToLinear(0xFF), 0)
        XCTAssertEqual(G711.linearToUlaw(0), 0xFF)
    }

    func testDecodeMonotonicWithinSign() {
        // Positive μ-law: 0xFF decodes to 0 and values grow monotonically
        // as the code moves toward 0x80 (max positive).
        var prev = Int16.min
        for code: UInt8 in stride(from: 0xFF, through: 0x80, by: -1) {
            let v = G711.ulawToLinear(code)
            XCTAssertGreaterThanOrEqual(v, prev)
            prev = v
        }
        XCTAssertEqual(prev, 32124)
    }

    func testFrameHelpers() {
        let payload: [UInt8] = [0xFF, 0x7F, 0x00, 0x80]
        let samples = G711.decodeFrame(payload, law: .ulaw)
        XCTAssertEqual(samples, [0, 0, -32124, 32124])
        let floats = G711.decodeToFloat(payload, law: .ulaw)
        XCTAssertEqual(floats.count, 4)
        XCTAssertEqual(floats[3], Float(32124) / 32768.0, accuracy: 0.0001)
        let encoded = G711.encodeFromFloat([0, 0, -1, 1], law: .ulaw)
        XCTAssertEqual(encoded.count, 4)
    }

    // MARK: - A-law golden (全 256 コード) とエンコードのアンカー

    /// ITU-T G.711 の A-law 再構成値 (16 ビット = 13 ビット値 x 8)。
    /// 実装とは別に式から作った表: コード c を c ^ 0x55 として bit7 = 符号 (1 が正)、
    /// bit6-4 = セグメント s、bit3-0 = m。13 ビットの大きさは s == 0 で 2m+1、s >= 1 で (2m+33) << (s-1)。
    static let alawDecodeGolden: [Int16] = [
        -5504, -5248, -6016, -5760, -4480, -4224, -4992, -4736,
        -7552, -7296, -8064, -7808, -6528, -6272, -7040, -6784,
        -2752, -2624, -3008, -2880, -2240, -2112, -2496, -2368,
        -3776, -3648, -4032, -3904, -3264, -3136, -3520, -3392,
        -22016, -20992, -24064, -23040, -17920, -16896, -19968, -18944,
        -30208, -29184, -32256, -31232, -26112, -25088, -28160, -27136,
        -11008, -10496, -12032, -11520, -8960, -8448, -9984, -9472,
        -15104, -14592, -16128, -15616, -13056, -12544, -14080, -13568,
        -344, -328, -376, -360, -280, -264, -312, -296,
        -472, -456, -504, -488, -408, -392, -440, -424,
        -88, -72, -120, -104, -24, -8, -56, -40,
        -216, -200, -248, -232, -152, -136, -184, -168,
        -1376, -1312, -1504, -1440, -1120, -1056, -1248, -1184,
        -1888, -1824, -2016, -1952, -1632, -1568, -1760, -1696,
        -688, -656, -752, -720, -560, -528, -624, -592,
        -944, -912, -1008, -976, -816, -784, -880, -848,
        5504, 5248, 6016, 5760, 4480, 4224, 4992, 4736,
        7552, 7296, 8064, 7808, 6528, 6272, 7040, 6784,
        2752, 2624, 3008, 2880, 2240, 2112, 2496, 2368,
        3776, 3648, 4032, 3904, 3264, 3136, 3520, 3392,
        22016, 20992, 24064, 23040, 17920, 16896, 19968, 18944,
        30208, 29184, 32256, 31232, 26112, 25088, 28160, 27136,
        11008, 10496, 12032, 11520, 8960, 8448, 9984, 9472,
        15104, 14592, 16128, 15616, 13056, 12544, 14080, 13568,
        344, 328, 376, 360, 280, 264, 312, 296,
        472, 456, 504, 488, 408, 392, 440, 424,
        88, 72, 120, 104, 24, 8, 56, 40,
        216, 200, 248, 232, 152, 136, 184, 168,
        1376, 1312, 1504, 1440, 1120, 1056, 1248, 1184,
        1888, 1824, 2016, 1952, 1632, 1568, 1760, 1696,
        688, 656, 752, 720, 560, 528, 624, 592,
        944, 912, 1008, 976, 816, 784, 880, 848
    ]

    func testAlawDecodeGoldenAll256() {
        XCTAssertEqual(Self.alawDecodeGolden.count, 256)
        for c in 0...255 {
            XCTAssertEqual(G711.alawToLinear(UInt8(c)), Self.alawDecodeGolden[c], String(format: "alaw decode 0x%02X", c))
        }
    }

    /// エンコードのアンカー: 両端・0 付近 (-8〜-1 の負の小振幅を含む)・各セグメントの境界。
    /// -1〜-7 は 16 ビット版参照実装 (Sun g711.c) どおり -8 と同じ 0x55 (以前は UInt8() でトラップしていた)。
    func testAlawEncodeAnchors() {
        let anchors: [(Int16, UInt8)] = [
        (-32768, 0x2A), (-32767, 0x2A), (-32256, 0x2A), (-16384, 0x3A), (-264, 0x45), (-263, 0x5A),
        (-24, 0x54), (-23, 0x55), (-9, 0x55), (-8, 0x55), (-7, 0x55), (-1, 0x55),
        (0, 0xD5), (1, 0xD5), (7, 0xD5), (8, 0xD5), (15, 0xD5), (16, 0xD4),
        (255, 0xDA), (256, 0xC5), (511, 0xCA), (512, 0xF5), (1023, 0xFA), (1024, 0xE5),
        (2047, 0xEA), (2048, 0x95), (4095, 0x9A), (4096, 0x85), (8191, 0x8A), (8192, 0xB5),
        (16383, 0xBA), (16384, 0xA5), (32256, 0xAA), (32767, 0xAA),
        ]
        for (x, code) in anchors {
            XCTAssertEqual(G711.linearToAlaw(x), code, "alaw encode \(x)")
        }
    }

    func testUlawEncodeAnchors() {
        let anchors: [(Int16, UInt8)] = [
        (-32768, 0x00), (-32124, 0x00), (-8159, 0x1F), (-100, 0x72), (-1, 0x7F), (0, 0xFF),
        (1, 0xFF), (100, 0xF2), (8159, 0x9F), (32124, 0x80), (32767, 0x80),
        ]
        for (x, code) in anchors {
            XCTAssertEqual(G711.linearToUlaw(x), code, "ulaw encode \(x)")
        }
    }

    /// 全 65536 入力でトラップせず、復号値が入力と同じ符号側にあり、誤差がそのセグメントの
    /// 量子化幅以内に収まること。セグメントの幅は大きさの 1/16 以下 (最小 16) なので、
    /// 上限は max(16, 大きさ/16) + 8 (A-law 負側の参照実装の区切りのずれ 8 の分)。
    func testEncodeAllInputsNoTrapAndBoundedError() {
        for v in Int(Int16.min)...Int(Int16.max) {
            let x = Int16(v)
            let a = Int(G711.alawToLinear(G711.linearToAlaw(x)))
            let u = Int(G711.ulawToLinear(G711.linearToUlaw(x)))
            let mag = abs(v)
            XCTAssertLessThanOrEqual(abs(a - v), max(16, mag / 16) + 8, "alaw error at \(v)")
            XCTAssertLessThanOrEqual(abs(u - v), max(16, (mag + 132) / 16) + 8, "ulaw error at \(v)")
            if v > 0 { XCTAssertGreaterThan(a, 0, "alaw sign at \(v)") }
            if v < 0 { XCTAssertLessThan(a, 0, "alaw sign at \(v)") }
            if v > 0 { XCTAssertGreaterThanOrEqual(u, 0, "ulaw sign at \(v)") }
            if v < 0 { XCTAssertLessThanOrEqual(u, 0, "ulaw sign at \(v)") }
        }
    }

    /// 無音付近の負の小さな浮動小数 (PCMA 通話でマイクから普通に来る値) でトラップしないこと。
    func testAlawEncodeFromFloatNearZero() {
        let frame: [Float] = [-0.0001, -0.0002, -0.00015, 0, 0.0001] // x32767 = -3, -7, -5, 0, 3
        let out = G711.encodeFromFloat(frame, law: .alaw)
        XCTAssertEqual(out.count, frame.count)
        XCTAssertEqual(Array(out.prefix(4)), [0x55, 0x55, 0x55, 0xD5])
    }
}
