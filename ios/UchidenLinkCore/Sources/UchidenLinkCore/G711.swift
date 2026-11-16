/// G.711 μ-law / A-law conversion.
/// Faithful port of the Android implementation (android/.../G711.kt),
/// which follows ITU-T G.711 segment companding.
public enum G711 {
    public enum Law: Sendable {
        case ulaw // PT 0 (PCMU)
        case alaw // PT 8 (PCMA)

        public init?(payloadType: UInt8) {
            switch payloadType {
            case 0: self = .ulaw
            case 8: self = .alaw
            default: return nil
            }
        }

        public var payloadType: UInt8 {
            switch self {
            case .ulaw: return 0
            case .alaw: return 8
            }
        }
    }

    private static let bias = 0x84
    private static let segEnd: [Int] = [0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF, 0x1FFF, 0x3FFF, 0x7FFF]

    private static func search(_ v: Int, _ table: [Int]) -> Int {
        for i in table.indices where v <= table[i] { return i }
        return table.count
    }

    // MARK: μ-law

    public static func linearToUlaw(_ pcm: Int16) -> UInt8 {
        var p = Int(pcm)
        let mask: Int
        if p < 0 {
            p = bias - p
            mask = 0x7F
        } else {
            p += bias
            mask = 0xFF
        }
        let seg = search(p, segEnd)
        if seg >= 8 { return UInt8(0x7F ^ mask) }
        let uval = (seg << 4) | ((p >> (seg + 3)) & 0xF)
        return UInt8(uval ^ mask)
    }

    public static func ulawToLinear(_ u: UInt8) -> Int16 {
        let uval = Int(u) ^ 0xFF
        var t = ((uval & 0x0F) << 3) + bias
        t <<= (uval & 0x70) >> 4
        return Int16((uval & 0x80) != 0 ? bias - t : t - bias)
    }

    // MARK: A-law

    public static func linearToAlaw(_ pcm: Int16) -> UInt8 {
        var p = Int(pcm)
        let mask: Int
        if p >= 0 {
            mask = 0xD5
        } else {
            mask = 0x55
            // 16 ビット版の参照実装は -p - 8 (13 ビット版の (pcm >> 3) の -x - 1 と同じ区切り)。
            // -1〜-7 ではこれが負になり、seg 0 の (p >> 4) ^ mask が負値になって UInt8() がトラップする。
            // 参照実装 (Sun g711.c) どおり -8 と同じ 0x55 に寄せる (0 に丸める)。他の入力の結果は変わらない。
            p = max(0, -p - 8)
        }
        let seg = search(p, segEnd)
        if seg >= 8 { return UInt8(0x7F ^ mask) }
        if seg == 0 { return UInt8((p >> 4) ^ mask) }
        return UInt8(((seg << 4) | ((p >> (seg + 3)) & 0xF)) ^ mask)
    }

    public static func alawToLinear(_ a: UInt8) -> Int16 {
        // ITU-T G.711 reference form: for seg >= 1 the (mantissa + 0x108)
        // sum is shifted, i.e. ((m << 4) + 0x108) << (seg - 1).
        // NOTE: the Android G711.kt decode adds (0x100 << (seg-1)) + 8
        // instead, which deviates from the ITU table for seg >= 2
        // (e.g. 0x00 -> -4184 there vs -5504 in the ITU table). The repo
        // has no Android G.711 test vectors, so this follows the ITU table;
        // the encode side is identical in both implementations.
        let aval = Int(a) ^ 0x55
        var t = (aval & 0x0F) << 4
        let seg = (aval & 0x70) >> 4
        if seg == 0 {
            t += 8
        } else if seg == 1 {
            t += 0x108
        } else {
            t += 0x108
            t <<= seg - 1
        }
        return Int16((aval & 0x80) != 0 ? t : -t)
    }

    // MARK: Frame helpers (20 ms = 160 samples at 8 kHz)

    public static func decodeFrame(_ payload: [UInt8], law: Law) -> [Int16] {
        switch law {
        case .ulaw: return payload.map(ulawToLinear)
        case .alaw: return payload.map(alawToLinear)
        }
    }

    public static func encodeFrame(_ samples: [Int16], law: Law) -> [UInt8] {
        switch law {
        case .ulaw: return samples.map(linearToUlaw)
        case .alaw: return samples.map(linearToAlaw)
        }
    }

    public static func decodeToFloat(_ payload: [UInt8], law: Law) -> [Float] {
        decodeFrame(payload, law: law).map { Float($0) / 32768.0 }
    }

    public static func encodeFromFloat(_ samples: [Float], law: Law) -> [UInt8] {
        encodeFrame(samples.map { s in
            let clamped = max(-1.0, min(1.0, s))
            return Int16((clamped * 32767.0).rounded())
        }, law: law)
    }
}
