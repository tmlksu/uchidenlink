import XCTest
@testable import UchidenLinkCore

final class RtpPacketTests: XCTestCase {
    func testSerializeParseRoundTrip() {
        let payload = [UInt8](repeating: 0xAB, count: 160)
        let packet = RtpPacket(payloadType: 8, sequenceNumber: 0x1234, timestamp: 0x01020304, ssrc: 0xA0B0C0D0, payload: payload, marker: true)
        let bytes = packet.serialized()
        XCTAssertEqual(bytes.count, 172)
        XCTAssertEqual(bytes[0], 0x80)
        XCTAssertEqual(bytes[1], 0x88)
        let parsed = RtpPacket.parse(bytes)
        XCTAssertEqual(parsed, packet)
    }

    func testParseRejectsShortAndWrongVersion() {
        XCTAssertNil(RtpPacket.parse([0x80, 0x00]))
        XCTAssertNil(RtpPacket.parse([UInt8](repeating: 0x40, count: 20))) // V=1
    }

    func testParseWithCsrcAndPadding() {
        var bytes = [UInt8](repeating: 0, count: 12 + 4 + 4 + 3)
        bytes[0] = 0xA1 // V=2, P=1, CC=1
        bytes[1] = 0x00
        bytes[bytes.count - 1] = 3 // 3 padding bytes
        bytes[16] = 0x11 // payload start (after 1 CSRC)
        bytes[17] = 0x22
        bytes[18] = 0x33
        bytes[19] = 0x44
        let parsed = RtpPacket.parse(bytes)
        XCTAssertEqual(parsed?.payload, [0x11, 0x22, 0x33, 0x44])
    }
}
