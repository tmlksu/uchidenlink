import Foundation

// relay URL の検証と、設定コード (QR / 貼り付け) の解釈。
// Android の RelayProtocol.kt (checkRelayUrl) / ProvisioningPayload.kt と同じ規則・同じ文言。
// ゴールデン: spec/fixtures/provisioning.json (両 OS のテストが同じ表を読む)。

public let relaySessionPath = "/v1/session"

public enum RelayURLCheck: Equatable, Sendable {
    /// 使える。`url` は正規化済み (`ws(s)://host[:port]/v1/session`)。
    case ok(url: String)
    case empty
    /// 平文で使えないホスト。`loopbackAllowed` はこのビルドでループバックの平文を許しているか。
    case cleartext(host: String, loopbackAllowed: Bool)
    case invalid(reason: String)

    public var message: String {
        switch self {
        case .ok: return "ok"
        case .empty: return "relay URL が空です"
        case .cleartext(let host, let loopbackAllowed):
            return loopbackAllowed
                ? "平文の ws:// / http:// はループバック (127.0.0.1 / localhost) 以外には使えません。wss:// を指定してください (host=\(host))"
                : "平文の ws:// / http:// は使えません。wss:// を指定してください (host=\(host))"
        case .invalid(let reason): return "relay URL が不正です: \(reason)"
        }
    }

    public var normalizedURL: String? {
        if case .ok(let url) = self { return url }
        return nil
    }
}

/// 平文接続を許すループバックのホスト名 (Android と同じ。`::1` は含めない)。
public func isLoopbackHost(_ host: String) -> Bool {
    ["127.0.0.1", "localhost"].contains(host.trimmingCharacters(in: .whitespaces).lowercased())
}

/// `ws(s)://` URL のホストとスキーム。URLComponents で解釈できなければ nil。
public func parseRelayWsURL(_ ws: String) -> (host: String, secure: Bool, port: Int?)? {
    guard let c = URLComponents(string: ws), let scheme = c.scheme?.lowercased(),
          scheme == "ws" || scheme == "wss",
          let host = c.host, !host.isEmpty
    else { return nil }
    return (host.lowercased(), scheme == "wss", c.port)
}

/// 設定の relay URL (`wss://relay.example.com`、`https://…/`、`relay.example.com` など) を検証し、
/// WebSocket 接続先 (`…/v1/session`) に正規化する。
public func checkRelayURL(_ input: String, allowLoopbackCleartext: Bool) -> RelayURLCheck {
    var u = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if u.isEmpty { return .empty }
    let lower = u.lowercased()
    if lower.hasPrefix("http://") {
        u = "ws://" + u.dropFirst(7)
    } else if lower.hasPrefix("https://") {
        u = "wss://" + u.dropFirst(8)
    } else if lower.hasPrefix("ws://") {
        u = "ws://" + u.dropFirst(5)
    } else if lower.hasPrefix("wss://") {
        u = "wss://" + u.dropFirst(6)
    } else if lower.contains("://") {
        return .invalid(reason: "未対応のスキーム")
    } else {
        u = "wss://" + u
    }
    while u.hasSuffix("/") { u.removeLast() }
    if !u.hasSuffix(relaySessionPath) { u += relaySessionPath }
    guard let parsed = parseRelayWsURL(u) else { return .invalid(reason: "URL として解釈できません") }
    if !parsed.secure && !(allowLoopbackCleartext && isLoopbackHost(parsed.host)) {
        return .cleartext(host: parsed.host, loopbackAllowed: allowLoopbackCleartext)
    }
    return .ok(url: u)
}

/// 設定コードの中身。形式は 1 行の JSON (`{"uchidenlink":1, ...}`)。含まれていたキーだけを上書きする。
///
/// | キー | 設定項目 |
/// |---|---|
/// | `url` | relay URL |
/// | `cid` / `cs` | Access Service Token の Client ID / Secret (`cid` には `cs` が必須) |
/// | `tok` | Dev Token |
/// | `user` / `pw` / `name` | SIP の内線番号 / パスワード / 表示名 |
/// | `mode` | `PERSISTENT` / `PUSH` (iOS は接続モードを持たないので検証のみして使わない) |
///
/// 秘密を含むため、読み取った文字列・エラー文に値を出さない。適用前に接続先ホストを見せて確認すること。
public struct ProvisioningPayload: Equatable, Sendable {
    public var relayURL: String?
    public var accessClientId: String?
    public var accessClientSecret: String?
    public var devToken: String?
    public var sipUser: String?
    public var sipPassword: String?
    public var sipDisplay: String?
    public var mode: String?

    public static let version = 1
    public static let maxLength = 2048
    private static let knownKeys = ["url", "cid", "cs", "tok", "user", "pw", "name", "mode"]
    private static let modes = ["PERSISTENT", "PUSH"]

    public enum Result: Equatable, Sendable {
        case ok(ProvisioningPayload)
        case error(String)
    }

    /// relay URL のホスト名 (確認ダイアログ用)。URL を含まなければ nil。
    public func relayHost() -> String? {
        guard let url = relayURL, !url.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if case .ok(let n) = checkRelayURL(url, allowLoopbackCleartext: true), let p = parseRelayWsURL(n) {
            return p.host
        }
        return url
    }

    public static func parse(_ text: String, allowLoopbackCleartext: Bool) -> Result {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .error("内容が空です") }
        if s.count > maxLength { return .error("内容が長すぎます") }
        guard let data = s.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              o["uchidenlink"] != nil
        else { return .error("ウチ電Link の設定コードではありません") }

        // 数値であること ("1" や true は不可)
        var ver = -1
        if let n = o["uchidenlink"] as? NSNumber, CFGetTypeID(n) == CFNumberGetTypeID(),
           !CFNumberIsFloatType(n) {
            ver = n.intValue
        }
        if ver > version { return .error("新しい形式の設定コードです。アプリを更新してください") }
        if ver != version { return .error("設定コードの版が不正です") }
        if !knownKeys.contains(where: { o[$0] != nil }) { return .error("設定項目が含まれていません") }

        struct TypeError: Error { let key: String }
        func str(_ key: String) throws -> String? {
            guard let v = o[key], !(v is NSNull) else { return nil }
            guard let s = v as? String else { throw TypeError(key: key) }
            return s
        }

        do {
            var p = ProvisioningPayload()
            let url = try str("url")?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url, !url.isEmpty {
                let c = checkRelayURL(url, allowLoopbackCleartext: allowLoopbackCleartext)
                if case .ok = c {} else { return .error("relay URL を使えません: \(c.message)") }
            }
            p.relayURL = url
            let cid = try str("cid")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cs = try str("cs")?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cid, !cid.isEmpty, (cs ?? "").isEmpty {
                return .error("Access Client ID に対応する Client Secret がありません")
            }
            p.accessClientId = cid
            p.accessClientSecret = cs
            if let m = try str("mode")?.trimmingCharacters(in: .whitespacesAndNewlines) {
                guard let known = modes.first(where: { $0.caseInsensitiveCompare(m) == .orderedSame }) else {
                    return .error("モード「\(m)」は不明です (PERSISTENT / PUSH)")
                }
                p.mode = known
            }
            p.devToken = try str("tok")
            p.sipUser = try str("user")?.trimmingCharacters(in: .whitespacesAndNewlines)
            // パスワードは前後の空白も値の一部 (Android と同じ)
            p.sipPassword = try str("pw")
            p.sipDisplay = try str("name")?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .ok(p)
        } catch let e as TypeError {
            return .error("「\(e.key)」は文字列で指定してください")
        } catch {
            return .error("設定コードが不正です")
        }
    }
}
