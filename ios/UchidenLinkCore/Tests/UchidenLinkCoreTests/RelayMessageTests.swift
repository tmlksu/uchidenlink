import XCTest
@testable import UchidenLinkCore

final class RelayMessageTests: XCTestCase {
    func testDecodeHelloWithCall() {
        let msg = RelayMessage.decode(#"{"t":"hello","relayVersion":"0.3.0","extension":"1001","account":"1001","registered":true,"serverTime":1700000000,"call":{"callId":"c1","direction":"in","state":"ringing","from":"09012345678","display":"Tanaka","pt":8,"startedAt":1700000000}}"#)
        guard case .hello(let hello) = msg else { return XCTFail("expected hello, got \(String(describing: msg))") }
        XCTAssertEqual(hello.relayVersion, "0.3.0")
        XCTAssertEqual(hello.account, "1001")
        XCTAssertTrue(hello.registered)
        XCTAssertEqual(hello.call?.callId, "c1")
        XCTAssertEqual(hello.call?.pt, 8)
    }

    func testDecodeHelloAccountFallback() {
        let msg = RelayMessage.decode(#"{"t":"hello","extension":"1002","call":null}"#)
        guard case .hello(let hello) = msg else { return XCTFail() }
        XCTAssertEqual(hello.account, "1002")
        XCTAssertNil(hello.call)
    }

    func testDecodeIncomingAndEnded() {
        guard case .incoming(let inc) = RelayMessage.decode(#"{"t":"incoming","callId":"x","from":"1001","display":"","pt":0}"#) else { return XCTFail() }
        XCTAssertEqual(inc.callId, "x")
        guard case .ended(let callId, let reason, let code) = RelayMessage.decode(#"{"t":"ended","callId":"x","reason":"bye","code":200}"#) else { return XCTFail() }
        XCTAssertEqual(callId, "x")
        XCTAssertEqual(reason, "bye")
        XCTAssertEqual(code, 200)
    }

    func testDecodeUnknownAndInvalid() {
        guard case .unknown(let t) = RelayMessage.decode(#"{"t":"something_new"}"#) else { return XCTFail() }
        XCTAssertEqual(t, "something_new")
        XCTAssertNil(RelayMessage.decode("not json"))
        XCTAssertNil(RelayMessage.decode(#"{"no_t":1}"#))
    }

    func testCommandBuilders() {
        let sip = RelayCommand.sipAccount(user: "1001", password: "pw", display: "Me")
        XCTAssertTrue(sip.contains(#""t":"sip_account""#) || sip.contains(#""t": "sip_account""#))
        XCTAssertTrue(sip.contains("1001"))
        let answer = RelayCommand.answer(callId: "c1")
        XCTAssertFalse(answer.contains("\"pt\"")) // pt omitted when nil, like Android
        let answerPt = RelayCommand.answer(callId: "c1", pt: 8)
        XCTAssertTrue(answerPt.contains("8"))
        let dial = RelayCommand.dial(to: "1002")
        XCTAssertTrue(dial.contains("1002"))
        // Round-trip through JSONSerialization to be sure fields are exact.
        let obj = (try? JSONSerialization.jsonObject(with: Data(dial.utf8))) as? [String: Any]
        XCTAssertEqual(obj?["t"] as? String, "dial")
        XCTAssertEqual(obj?["to"] as? String, "1002")
    }
}
