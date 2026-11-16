import XCTest
@testable import UchidenLinkCore

final class VoipPushTests: XCTestCase {
    func testParseIncoming() {
        let p: [AnyHashable: Any] = ["uchidenlink": 1, "type": "incoming", "callId": "c-1", "from": "2101", "display": "居間"]
        XCTAssertEqual(VoipPush.parse(p), .init(callId: "c-1", from: "2101", display: "居間"))
        // 同じ callId からは常に同じ CallKit UUID (WSS の incoming / hello.call と一致し、二重 report が潰れる)
        XCTAssertEqual(CallUUID.derive(callId: "c-1"), CallUUID.derive(callId: "c-1"))
    }

    func testParseRejectsOtherPayloads() {
        XCTAssertNil(VoipPush.parse([:]))
        XCTAssertNil(VoipPush.parse(["uchidenlink": 1, "type": "incoming"])) // callId 無し
        XCTAssertNil(VoipPush.parse(["uchidenlink": 1, "type": "other", "callId": "x"]))
        XCTAssertNil(VoipPush.parse(["uchidenlink": "1", "callId": "x"]))
        XCTAssertEqual(VoipPush.parse(["uchidenlink": 1, "callId": "x"])?.from, "") // 省略項目は空
    }

    func testHexAndMask() {
        let hex = VoipPush.hexToken(Data([0x00, 0xab, 0xff, 0x10]))
        XCTAssertEqual(hex, "00abff10")
        XCTAssertEqual(VoipPush.masked(String(repeating: "a", count: 64)), "aaaa…aaaa")
        XCTAssertEqual(VoipPush.masked("abc"), "***")
    }

    private func fakeProfile(aps: String?) -> Data {
        let ent = aps.map { "<key>aps-environment</key><string>\($0)</string>" } ?? ""
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Name</key><string>x</string><key>Entitlements</key><dict>\(ent)</dict></dict></plist>
        """
        // CMS の前後のバイナリを模す
        return Data([0x30, 0x82, 0x01, 0x00, 0xff]) + Data(plist.utf8) + Data([0xa0, 0x00, 0x31])
    }

    func testApsEnvironment() {
        XCTAssertEqual(ApsEnvironment.from(provisioningProfile: fakeProfile(aps: "development")), "development")
        XCTAssertEqual(ApsEnvironment.from(provisioningProfile: fakeProfile(aps: "production")), "production")
        XCTAssertEqual(ApsEnvironment.from(provisioningProfile: fakeProfile(aps: nil)), "production")
        XCTAssertEqual(ApsEnvironment.from(provisioningProfile: nil), "production") // App Store / TestFlight
        XCTAssertEqual(ApsEnvironment.from(provisioningProfile: Data("garbage".utf8)), "production")
    }

    func testRegisterPushCommand() throws {
        let s = RelayCommand.registerPush(provider: "apns-voip", token: "abcd", env: "development")
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: String])
        XCTAssertEqual(o, ["t": "register_push", "provider": "apns-voip", "token": "abcd", "env": "development"])
    }
}
