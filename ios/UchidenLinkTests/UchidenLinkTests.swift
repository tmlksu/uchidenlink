import XCTest
@testable import UchidenLink

final class UchidenLinkTests: XCTestCase {
    func testSessionURLFromHost() {
        var s = AppSettings()
        s.host = "relay.example.com"
        s.mockURL = ""
        XCTAssertEqual(RelayClient.sessionURL(settings: s)?.absoluteString, "wss://relay.example.com/v1/session")
    }

    func testSessionURLMockOverride() {
        var s = AppSettings()
        s.host = "relay.example.com"
        s.mockURL = "ws://192.0.2.10:8765/v1/session"
        XCTAssertEqual(RelayClient.sessionURL(settings: s)?.absoluteString, "ws://192.0.2.10:8765/v1/session")
    }

    func testClientVersionFormat() {
        // Android sends "UchidenLink/<version>-<flavor>"; iOS uses flavor "ios".
        XCTAssertTrue(RelayClient.clientVersion.hasPrefix("UchidenLink/"))
        XCTAssertTrue(RelayClient.clientVersion.hasSuffix("-ios"))
    }

    func testKeychainRoundTrip() {
        let key = "test-\(UUID().uuidString)"
        XCTAssertTrue(KeychainStore.set(key, "value-123"))
        XCTAssertEqual(KeychainStore.get(key), "value-123")
        XCTAssertTrue(KeychainStore.set(key, "value-456"))
        XCTAssertEqual(KeychainStore.get(key), "value-456")
        KeychainStore.delete(key)
        XCTAssertNil(KeychainStore.get(key))
    }

    func testDeviceIdGeneratedAndStable() {
        let first = AppSettings.load()
        XCTAssertFalse(first.deviceId.isEmpty)
        let second = AppSettings.load()
        XCTAssertEqual(first.deviceId, second.deviceId)
    }
}
