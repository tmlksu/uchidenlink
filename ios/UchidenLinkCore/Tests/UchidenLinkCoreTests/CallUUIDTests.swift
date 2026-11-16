import XCTest
@testable import UchidenLinkCore

final class CallUUIDTests: XCTestCase {
    func testDeterministic() {
        XCTAssertEqual(CallUUID.derive(callId: "abc-123"), CallUUID.derive(callId: "abc-123"))
        XCTAssertNotEqual(CallUUID.derive(callId: "abc-123"), CallUUID.derive(callId: "abc-124"))
    }

    func testVersionAndVariant() {
        let uuid = CallUUID.derive(callId: "some-call-id")
        let s = uuid.uuidString
        // 15th character is the version nibble; 20th is the variant nibble.
        XCTAssertEqual(Array(s)[14], "5")
        XCTAssertTrue(["8", "9", "A", "B"].contains(Array(s)[19]))
    }

    /// Known UUIDv5 test vector (RFC 4122 style, DNS namespace) via the SHA-1 core:
    /// SHA-1("The quick brown fox jumps over the lazy dog") is a well-known digest.
    func testSHA1KnownVector() {
        let digest = SHA1.hash([UInt8]("The quick brown fox jumps over the lazy dog".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12")
        let empty = SHA1.hash([])
        XCTAssertEqual(empty.map { String(format: "%02x", $0) }.joined(),
                       "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }
}
