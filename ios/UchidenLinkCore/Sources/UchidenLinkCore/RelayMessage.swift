import Foundation

/// Control messages of the uchidenlink relay protocol (docs/PROTOCOL.md v1.2).
/// Text WebSocket frames are JSON objects with a mandatory "t" field;
/// binary frames are raw RTP (handled elsewhere). Decoding is tolerant in
/// the same way as the Android RelayProtocol (missing fields take defaults).

public struct CallInfo: Equatable, Sendable {
    public var callId: String = ""
    public var direction: String = "in" // "in" | "out"
    public var state: String = "ringing" // "ringing" | "active"
    public var from: String = ""
    public var display: String = ""
    public var pt: Int = 0
    public var startedAt: Int64 = 0
}

public struct HelloInfo: Equatable, Sendable {
    public var relayVersion: String = ""
    public var `extension`: String = ""
    /// v1.1: bound SIP user; falls back to `extension` when absent/blank.
    public var account: String = ""
    public var registered: Bool = false
    public var call: CallInfo?
    public var serverTime: Int64 = 0
}

public struct IncomingInfo: Equatable, Sendable {
    public var callId: String = ""
    public var from: String = ""
    public var display: String = ""
    public var pt: Int = 0
}

public enum RelayMessage: Equatable, Sendable {
    case hello(HelloInfo)
    case registration(ok: Bool, detail: String)
    case incoming(IncomingInfo)
    case ringing(callId: String, early: Bool)
    case answered(callId: String, pt: Int)
    case ended(callId: String, reason: String, code: Int)
    case error(code: String, message: String)
    case pong(ts: Int64)
    case unknown(type: String)

    public static func decode(_ text: String) -> RelayMessage? {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let t = obj["t"] as? String
        else { return nil }

        func str(_ key: String) -> String { obj[key] as? String ?? "" }
        func int(_ key: String) -> Int { (obj[key] as? NSNumber)?.intValue ?? 0 }
        func int64(_ key: String) -> Int64 { (obj[key] as? NSNumber)?.int64Value ?? 0 }
        func bool(_ key: String) -> Bool { (obj[key] as? NSNumber)?.boolValue ?? false }

        switch t {
        case "hello":
            var hello = HelloInfo()
            hello.relayVersion = str("relayVersion")
            hello.extension = str("extension")
            let account = str("account")
            hello.account = account.isEmpty ? hello.extension : account
            hello.registered = bool("registered")
            hello.serverTime = int64("serverTime")
            if let callObj = obj["call"] as? [String: Any] {
                var call = CallInfo()
                call.callId = callObj["callId"] as? String ?? ""
                call.direction = callObj["direction"] as? String ?? "in"
                call.state = callObj["state"] as? String ?? "ringing"
                call.from = callObj["from"] as? String ?? ""
                call.display = callObj["display"] as? String ?? ""
                call.pt = (callObj["pt"] as? NSNumber)?.intValue ?? 0
                call.startedAt = (callObj["startedAt"] as? NSNumber)?.int64Value ?? 0
                hello.call = call
            }
            return .hello(hello)
        case "registration":
            return .registration(ok: bool("ok"), detail: str("detail"))
        case "incoming":
            var info = IncomingInfo()
            info.callId = str("callId")
            info.from = str("from")
            info.display = str("display")
            info.pt = int("pt")
            return .incoming(info)
        case "ringing":
            return .ringing(callId: str("callId"), early: bool("early"))
        case "answered":
            return .answered(callId: str("callId"), pt: int("pt"))
        case "ended":
            return .ended(callId: str("callId"), reason: str("reason"), code: int("code"))
        case "error":
            return .error(code: str("code"), message: str("message"))
        case "pong":
            return .pong(ts: int64("ts"))
        default:
            return .unknown(type: t)
        }
    }
}

/// Builders for app -> relay control messages (field names per PROTOCOL.md).
public enum RelayCommand {
    private static func json(_ fields: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: []),
              let s = String(data: data, encoding: .utf8)
        else { return "{}" }
        return s
    }

    /// v1.1: bind this device to a SIP account. Sent right after the first hello.
    public static func sipAccount(user: String, password: String, display: String) -> String {
        json(["t": "sip_account", "user": user, "password": password, "display": display])
    }

    public static func answer(callId: String, pt: Int? = nil) -> String {
        var fields: [String: Any] = ["t": "answer", "callId": callId]
        if let pt { fields["pt"] = pt }
        return json(fields)
    }

    /// NOTE: relay treats reject as rejecting the call as a whole (all devices
    /// stop ringing, caller gets 486). There is no "silence only this device".
    public static func reject(callId: String, code: Int? = nil) -> String {
        var fields: [String: Any] = ["t": "reject", "callId": callId]
        if let code { fields["code"] = code }
        return json(fields)
    }

    /// BYE while in a call; CANCEL while an outgoing call is ringing
    /// (the protocol has no separate cancel message).
    public static func hangup(callId: String) -> String {
        json(["t": "hangup", "callId": callId])
    }

    public static func dial(to: String) -> String {
        json(["t": "dial", "to": to])
    }

    /// v1.3: push トークン登録。iOS は provider="apns-voip" と env (development|production)。
    public static func registerPush(provider: String, token: String, env: String? = nil) -> String {
        var fields: [String: Any] = ["t": "register_push", "provider": provider, "token": token]
        if let env { fields["env"] = env }
        return json(fields)
    }

    public static func ping(ts: Int64) -> String {
        json(["t": "ping", "ts": ts])
    }
}
