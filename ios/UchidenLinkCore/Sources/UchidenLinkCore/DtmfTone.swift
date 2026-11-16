import Foundation

/// in-band DTMF トーン生成。Android の DtmfTone.kt と同じ仕様 (UI-DESIGN §3.1):
/// 二重音 (低群 697/770/852/941 Hz × 高群 1209/1336/1477/1633 Hz) を 120 ms、続けて無音 80 ms。
/// 8 kHz で 960 + 640 = 1600 サンプル。各正弦波の振幅は約 -6 dBFS (16383)。
/// Asterisk 側は `dtmfmode=inband` なので、relay に `dtmf` メッセージは送らない (PROTOCOL.md)。
public enum DtmfTone {
    public static let sampleRate = 8000
    public static let toneSamples = sampleRate * 120 / 1000
    public static let silenceSamples = sampleRate * 80 / 1000
    public static let totalSamples = toneSamples + silenceSamples
    public static let frameSamples = sampleRate * 20 / 1000
    public static let amplitude = 16383.0

    private static let low: [Double] = [697, 770, 852, 941]
    private static let high: [Double] = [1209, 1336, 1477, 1633]

    /// 桁に対応する (低群, 高群) 周波数。未対応文字は nil。小文字 a〜d も受け付ける。
    public static func frequencies(for digit: Character) -> (low: Double, high: Double)? {
        let rc: (Int, Int)
        switch digit.uppercased() {
        case "1": rc = (0, 0)
        case "2": rc = (0, 1)
        case "3": rc = (0, 2)
        case "A": rc = (0, 3)
        case "4": rc = (1, 0)
        case "5": rc = (1, 1)
        case "6": rc = (1, 2)
        case "B": rc = (1, 3)
        case "7": rc = (2, 0)
        case "8": rc = (2, 1)
        case "9": rc = (2, 2)
        case "C": rc = (2, 3)
        case "*": rc = (3, 0)
        case "0": rc = (3, 1)
        case "#": rc = (3, 2)
        case "D": rc = (3, 3)
        default: return nil
        }
        return (low[rc.0], high[rc.1])
    }

    /// 1 桁分の PCM (16bit, 8 kHz mono, `totalSamples`)。未対応文字は nil。
    public static func tone(for digit: Character) -> [Int16]? {
        guard let f = frequencies(for: digit) else { return nil }
        var out = [Int16](repeating: 0, count: totalSamples)
        for i in 0..<toneSamples {
            let t = Double(i) / Double(sampleRate)
            let s = amplitude * sin(2 * .pi * f.low * t) + amplitude * sin(2 * .pi * f.high * t)
            out[i] = Int16(max(-32768, min(32767, Int(s))))
        }
        return out
    }

    /// `tone(for:)` を 20 ms フレームに分割したもの (10 フレーム)。
    public static func frames(for digit: Character) -> [[Int16]]? {
        guard let t = tone(for: digit) else { return nil }
        return stride(from: 0, to: t.count, by: frameSamples).map { Array(t[$0..<min($0 + frameSamples, t.count)]) }
    }
}
