import XCTest
@testable import UchidenLinkCore

final class HistoryStoreTests: XCTestCase {
    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
    }

    func testAddOrderLimitAndDuration() {
        let store = HistoryStore(url: tempURL("history.json"))
        XCTAssertTrue(store.all().isEmpty)
        let a = store.add(direction: .OUT, number: "2101", name: "", startedAt: 1)
        store.add(direction: .MISSED, number: "110", name: "", startedAt: 2)
        XCTAssertEqual(store.all().map(\.number), ["110", "2101"])
        XCTAssertEqual(store.missedOnly().count, 1)
        XCTAssertTrue(store.updateDuration(id: a.id, durationSec: 42))
        XCTAssertEqual(store.all().last?.durationSec, 42)
        XCTAssertFalse(store.updateDuration(id: "nope", durationSec: 1))
        XCTAssertTrue(store.remove(id: a.id))
        XCTAssertFalse(store.remove(id: a.id))
        for i in 0..<(HistoryStore.maxEntries + 5) {
            store.add(direction: .IN, number: "\(i)", name: "", startedAt: Int64(i))
        }
        XCTAssertEqual(store.all().count, HistoryStore.maxEntries)
        XCTAssertEqual(store.all().first?.number, "\(HistoryStore.maxEntries + 4)")
        store.clear()
        XCTAssertTrue(store.all().isEmpty)
    }

    func testReadsAndroidFormatFixture() throws {
        let url = tempURL("history.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Fixtures.url("history.json"), to: url)
        let all = HistoryStore(url: url).all()
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(all[0].direction, .IN)
        XCTAssertEqual(all[0].durationSec, 68)
        XCTAssertEqual(all[0].displayName, "居間")
        XCTAssertEqual(all[1].displayName, "110")
        // 不正な direction は MISSED、負の通話時間は 0、id 無しは生成 (Android と同じ寛容さ)
        XCTAssertEqual(all[3].direction, .MISSED)
        XCTAssertEqual(all[3].durationSec, 0)
        XCTAssertFalse(all[3].id.isEmpty)
    }

    func testCorruptFileIsEmpty() throws {
        let url = tempURL("history.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        XCTAssertTrue(HistoryStore(url: url).all().isEmpty)
    }

    func testRoundTripKeepsAndroidKeys() throws {
        let url = tempURL("history.json")
        HistoryStore(url: url).add(direction: .IN, number: "2101", name: "居間", startedAt: 5, durationSec: 3)
        let arr = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertEqual(Set(arr[0].keys), ["id", "direction", "number", "name", "startedAt", "durationSec"])
        XCTAssertEqual(arr[0]["direction"] as? String, "IN")
    }
}

final class ContactStoreTests: XCTestCase {
    private func store(fromFixture: Bool) throws -> ContactStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("contacts.json")
        if fromFixture {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: Fixtures.url("contacts.json"), to: url)
        }
        return ContactStore(url: url)
    }

    func testNormalize() {
        XCTAssertEqual(normalizePhoneNumber(" 03－1234ー5678 "), "0312345678")
        XCTAssertEqual(normalizePhoneNumber("090‐1234–5678"), "09012345678")
    }

    func testFixtureLookupAndSearch() throws {
        let s = try store(fromFixture: true)
        XCTAssertEqual(s.all().count, 4)
        XCTAssertEqual(s.all()[3].group, .SOTO) // 不明なグループは SOTO
        XCTAssertEqual(s.lookup("2110"), "玄関インターホン")
        XCTAssertEqual(s.lookup("0312345678"), "区役所")
        XCTAssertNil(s.lookup("9999"))
        XCTAssertNil(s.lookup(""))
        XCTAssertEqual(s.search("21").map(\.name), ["母屋", "玄関インターホン", "不明グループ"])
        XCTAssertEqual(s.search("役所").map(\.name), ["区役所"])
        XCTAssertEqual(s.search(" ").count, 4)
    }

    func testCrud() throws {
        let s = try store(fromFixture: false)
        let c = s.add(name: " 台所 ", number: " 2106 ", group: .UCHI)
        XCTAssertEqual(c.name, "台所")
        XCTAssertEqual(c.number, "2106")
        XCTAssertTrue(s.update(id: c.id, name: "台所2", number: "2107", group: .SOTO))
        XCTAssertEqual(s.all().first?.group, .SOTO)
        XCTAssertTrue(s.remove(id: c.id))
        XCTAssertTrue(s.all().isEmpty)
    }
}

final class ProvisioningFixtureTests: XCTestCase {
    func testCases() throws {
        let fx = try XCTUnwrap(Fixtures.json("provisioning.json") as? [String: Any])
        let cases = try XCTUnwrap(fx["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 15)
        for c in cases {
            let name = c["name"] as! String
            let allow = c["allowLoopbackCleartext"] as? Bool ?? false
            let r = ProvisioningPayload.parse(c["input"] as! String, allowLoopbackCleartext: allow)
            if let ok = c["ok"] as? [String: Any] {
                guard case .ok(let p) = r else { XCTFail("\(name): expected ok, got \(r)"); continue }
                XCTAssertEqual(p.relayURL, ok["url"] as? String, name)
                XCTAssertEqual(p.accessClientId, ok["cid"] as? String, name)
                XCTAssertEqual(p.accessClientSecret, ok["cs"] as? String, name)
                XCTAssertEqual(p.devToken, ok["tok"] as? String, name)
                XCTAssertEqual(p.sipUser, ok["user"] as? String, name)
                XCTAssertEqual(p.sipPassword, ok["pw"] as? String, name)
                XCTAssertEqual(p.sipDisplay, ok["name"] as? String, name)
                XCTAssertEqual(p.mode, ok["mode"] as? String, name)
                if let host = ok["relayHost"] as? String { XCTAssertEqual(p.relayHost(), host, name) }
            } else {
                guard case .error(let msg) = r else { XCTFail("\(name): expected error, got \(r)"); continue }
                let want = c["error"] as? String ?? ""
                XCTAssertTrue(want.isEmpty || msg.contains(want), "\(name): \(msg)")
                if let bad = c["mustNotContain"] as? String { XCTAssertFalse(msg.contains(bad), name) }
            }
        }
    }

    func testTooLong() {
        let s = "{\"x\":\"" + String(repeating: "a", count: ProvisioningPayload.maxLength) + "\"}"
        guard case .error = ProvisioningPayload.parse(s, allowLoopbackCleartext: false) else { return XCTFail() }
    }

    func testRelayUrlTable() throws {
        let fx = try XCTUnwrap(Fixtures.json("provisioning.json") as? [String: Any])
        for c in try XCTUnwrap(fx["relayUrl"] as? [[String: Any]]) {
            let input = c["input"] as! String
            let r = checkRelayURL(input, allowLoopbackCleartext: c["allowLoopbackCleartext"] as? Bool ?? false)
            if let ok = c["ok"] as? String {
                XCTAssertEqual(r.normalizedURL, ok, input)
            } else {
                switch (c["error"] as! String, r) {
                case ("empty", .empty), ("cleartext", .cleartext), ("invalid", .invalid): break
                default: XCTFail("\(input): \(r)")
                }
            }
        }
    }
}

final class DisplayRulesTests: XCTestCase {
    func testKeypadCaption() {
        XCTAssertEqual(DisplayRules.keypadCaption(number: "", contactName: nil), .empty)
        XCTAssertEqual(DisplayRules.keypadCaption(number: "2101", contactName: "母屋"), .contact(name: "母屋"))
        XCTAssertEqual(DisplayRules.keypadCaption(number: "21", contactName: nil), .extensionNumber)
        XCTAssertEqual(DisplayRules.keypadCaption(number: "2", contactName: nil), .external)
        XCTAssertEqual(DisplayRules.keypadCaption(number: "21010", contactName: nil), .external)
        XCTAssertEqual(DisplayRules.keypadCaption(number: "*21", contactName: nil), .external)
    }

    func testHistoryTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 17, minute: 5))!
        func ms(_ d: DateComponents) -> Int64 { Int64(cal.date(from: d)!.timeIntervalSince1970 * 1000) }
        XCTAssertEqual(DisplayRules.historyTime(epochMs: ms(DateComponents(year: 2026, month: 11, day: 15, hour: 9, minute: 3)), now: now, calendar: cal), .today("09:03"))
        XCTAssertEqual(DisplayRules.historyTime(epochMs: ms(DateComponents(year: 2026, month: 11, day: 14, hour: 23, minute: 59)), now: now, calendar: cal), .yesterday)
        XCTAssertEqual(DisplayRules.historyTime(epochMs: ms(DateComponents(year: 2026, month: 1, day: 2, hour: 1)), now: now, calendar: cal), .date("1/2"))
    }

    func testDuration() {
        XCTAssertEqual(DisplayRules.duration(seconds: 68), "01:08")
        XCTAssertEqual(DisplayRules.duration(seconds: 0), "00:00")
        XCTAssertEqual(DisplayRules.duration(seconds: 3725), "1:02:05")
    }

    func testResolveName() {
        let lookup: (String) -> String? = { $0 == "2110" ? "玄関" : nil }
        XCTAssertEqual(DisplayRules.resolveName(display: "", number: "2110", lookup: lookup), "玄関")
        XCTAssertEqual(DisplayRules.resolveName(display: "2110", number: "2110", lookup: lookup), "玄関")
        XCTAssertEqual(DisplayRules.resolveName(display: "インターホン", number: "2110", lookup: lookup), "インターホン")
        XCTAssertEqual(DisplayRules.resolveName(display: "", number: "9999", lookup: lookup), "")
    }

    func testAvatarInitial() {
        XCTAssertEqual(DisplayRules.avatarInitial("母屋"), "母")
        XCTAssertEqual(DisplayRules.avatarInitial("alice"), "A")
        XCTAssertEqual(DisplayRules.avatarInitial(""), "#")
    }
}
