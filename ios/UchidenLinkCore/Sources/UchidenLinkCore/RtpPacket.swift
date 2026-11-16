/// Minimal RTP (RFC 3550) packet: fixed 12-byte header + payload.
/// uchidenlink carries exactly one RTP packet per WebSocket binary frame
/// (docs/PROTOCOL.md). PT 0 = PCMU, PT 8 = PCMA, 8 kHz, 20 ms (160 bytes).
public struct RtpPacket: Equatable, Sendable {
    public var marker: Bool
    public var payloadType: UInt8
    public var sequenceNumber: UInt16
    public var timestamp: UInt32
    public var ssrc: UInt32
    public var payload: [UInt8]

    public init(payloadType: UInt8, sequenceNumber: UInt16, timestamp: UInt32, ssrc: UInt32, payload: [UInt8], marker: Bool = false) {
        self.marker = marker
        self.payloadType = payloadType
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.payload = payload
    }

    public func serialized() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 12 + payload.count)
        out[0] = 0x80 // V=2, no padding, no extension, CC=0
        out[1] = (marker ? 0x80 : 0x00) | (payloadType & 0x7F)
        out[2] = UInt8(sequenceNumber >> 8)
        out[3] = UInt8(sequenceNumber & 0xFF)
        out[4] = UInt8((timestamp >> 24) & 0xFF)
        out[5] = UInt8((timestamp >> 16) & 0xFF)
        out[6] = UInt8((timestamp >> 8) & 0xFF)
        out[7] = UInt8(timestamp & 0xFF)
        out[8] = UInt8((ssrc >> 24) & 0xFF)
        out[9] = UInt8((ssrc >> 16) & 0xFF)
        out[10] = UInt8((ssrc >> 8) & 0xFF)
        out[11] = UInt8(ssrc & 0xFF)
        out.replaceSubrange(12..., with: payload)
        return out
    }

    public static func parse(_ bytes: [UInt8]) -> RtpPacket? {
        guard bytes.count >= 12, bytes[0] >> 6 == 2 else { return nil }
        let cc = Int(bytes[0] & 0x0F)
        var offset = 12 + cc * 4
        guard bytes.count >= offset else { return nil }
        if bytes[0] & 0x10 != 0 { // extension present
            guard bytes.count >= offset + 4 else { return nil }
            let extWords = (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            offset += 4 + extWords * 4
            guard bytes.count >= offset else { return nil }
        }
        var end = bytes.count
        if bytes[0] & 0x20 != 0, end > offset { // padding present
            let pad = Int(bytes[end - 1])
            if pad > 0, pad <= end - offset { end -= pad }
        }
        let seq = (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
        let ts = (UInt32(bytes[4]) << 24) | (UInt32(bytes[5]) << 16) | (UInt32(bytes[6]) << 8) | UInt32(bytes[7])
        let ssrc = (UInt32(bytes[8]) << 24) | (UInt32(bytes[9]) << 16) | (UInt32(bytes[10]) << 8) | UInt32(bytes[11])
        return RtpPacket(
            payloadType: bytes[1] & 0x7F,
            sequenceNumber: seq,
            timestamp: ts,
            ssrc: ssrc,
            payload: Array(bytes[offset..<end]),
            marker: bytes[1] & 0x80 != 0
        )
    }
}
