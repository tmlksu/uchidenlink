import Foundation

/// VoIP push (PROTOCOL v1.3) の受け口。relay の APNs payload:
/// `{"uchidenlink":1,"type":"incoming","callId":"…","from":"…","display":"…"}`
/// PushKit は 1 件ごとに必ず CallKit へ report しなければならない (しないと OS がアプリを終了させ、
/// 繰り返すと push を止める) ので、解釈できない payload でも呼び出し側はダミーの呼を report して即終了する。
public enum VoipPush {
    public struct Incoming: Equatable, Sendable {
        public var callId: String
        public var from: String
        public var display: String
    }

    /// payload を解釈する。着信として使えなければ nil。
    public static func parse(_ payload: [AnyHashable: Any]) -> Incoming? {
        guard let version = payload["uchidenlink"] as? NSNumber, version.intValue >= 1 else { return nil }
        let type = payload["type"] as? String ?? "incoming"
        guard type == "incoming",
              let callId = payload["callId"] as? String, !callId.isEmpty
        else { return nil }
        return Incoming(callId: callId, from: payload["from"] as? String ?? "", display: payload["display"] as? String ?? "")
    }

    /// PushKit のトークン (Data) を relay に送る 16 進文字列 (小文字) にする。
    public static func hexToken(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// ログ用に伏せたトークン。
    public static func masked(_ hex: String) -> String {
        hex.count <= 8 ? "***" : "\(hex.prefix(4))…\(hex.suffix(4))"
    }
}

/// APNs の環境 (register_push の env)。署名に使ったプロファイル (embedded.mobileprovision) の
/// `aps-environment` を読む。プロファイルが無い (App Store / TestFlight 配布) なら production。
public enum ApsEnvironment {
    public static let development = "development"
    public static let production = "production"

    /// `embedded.mobileprovision` の中身 (CMS 署名の中に XML plist が平文で入っている) から判定する。
    public static func from(provisioningProfile data: Data?) -> String {
        guard let data,
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return production }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let ent = plist["Entitlements"] as? [String: Any],
              let env = ent["aps-environment"] as? String
        else { return production }
        return env == development ? development : production
    }
}
