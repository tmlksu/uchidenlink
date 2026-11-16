import Foundation
import Security
import UchidenLinkCore

/// Minimal Keychain string store. Items use
/// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly so a future VoIP-push
/// wake (Phase 0b) can read credentials while the device is locked
/// (design §6 / Opus M10). Nothing here is ever logged.
enum KeychainStore {
    private static var service: String { Bundle.main.bundleIdentifier ?? "io.github.tmlksu.uchidenlink" }

    static func get(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ key: String, _ value: String) -> Bool {
        let data = Data(value.utf8)
        let query = baseQuery(key)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func delete(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

/// アプリ設定。秘密 (Access Secret・SIP パスワード・Dev Token) と接続情報は Keychain、
/// 秘密でない動作設定は UserDefaults (UI-DESIGN §1.4 の「動作」「音声」カード)。
struct AppSettings: Equatable {
    /// relay URL (`sip.example.com` / `wss://…` / `https://…`)。Phase 0a はホスト名だけを入れていたので
    /// キー名は "host" のまま。checkRelayURL がどちらの形でも正規化する。
    var host: String = ""
    var cfClientId: String = ""
    var cfClientSecret: String = ""
    var devToken: String = ""
    var sipUser: String = ""
    var sipPassword: String = ""
    var sipDisplay: String = ""
    /// DEBUG: LAN モック relay の ws:// URL。空 = `host` を使う。
    var mockURL: String = ""
    var deviceId: String = ""

    // 動作 (UserDefaults)
    /// 接続を有効にするか (設定の「停止」/「開始」)。
    var enabled: Bool = true
    /// 応答時にスピーカー出力にする (既定 OFF。受話口を持たない端末は常にスピーカー)。
    var speakerOnAnswer: Bool = false
    /// 端末の連絡先を一覧に表示する (既定 OFF)。
    var showDeviceContacts: Bool = false
    /// マイクゲイン (0.5〜4.5)。
    var micGain: Double = 1.0

    private enum Key {
        static let host = "host"
        static let cfClientId = "cfClientId"
        static let cfClientSecret = "cfClientSecret"
        static let devToken = "devToken"
        static let sipUser = "sipUser"
        static let sipPassword = "sipPassword"
        static let sipDisplay = "sipDisplay"
        static let mockURL = "mockURL"
        static let deviceId = "deviceId"
        static let enabled = "pref.enabled"
        static let speakerOnAnswer = "pref.speakerOnAnswer"
        static let showDeviceContacts = "pref.showDeviceContacts"
        static let micGain = "pref.micGain"
    }

    static func load() -> AppSettings {
        var s = AppSettings()
        if let v = KeychainStore.get(Key.host), !v.isEmpty { s.host = v }
        s.cfClientId = KeychainStore.get(Key.cfClientId) ?? ""
        s.cfClientSecret = KeychainStore.get(Key.cfClientSecret) ?? ""
        s.devToken = KeychainStore.get(Key.devToken) ?? ""
        s.sipUser = KeychainStore.get(Key.sipUser) ?? ""
        s.sipPassword = KeychainStore.get(Key.sipPassword) ?? ""
        s.sipDisplay = KeychainStore.get(Key.sipDisplay) ?? ""
        s.mockURL = KeychainStore.get(Key.mockURL) ?? ""
        if let id = KeychainStore.get(Key.deviceId), !id.isEmpty {
            s.deviceId = id
        } else {
            // Device-Id は一度だけ生成して保存 (失われたら新しい端末として登録し直すだけ。設計 Q6)。
            s.deviceId = UUID().uuidString
            KeychainStore.set(Key.deviceId, s.deviceId)
        }
        let d = UserDefaults.standard
        s.enabled = d.object(forKey: Key.enabled) as? Bool ?? true
        s.speakerOnAnswer = d.bool(forKey: Key.speakerOnAnswer)
        s.showDeviceContacts = d.bool(forKey: Key.showDeviceContacts)
        if let g = d.object(forKey: Key.micGain) as? Double { s.micGain = max(0.5, min(4.5, g)) }
        return s
    }

    func save() {
        KeychainStore.set(Key.host, host)
        KeychainStore.set(Key.cfClientId, cfClientId)
        KeychainStore.set(Key.cfClientSecret, cfClientSecret)
        KeychainStore.set(Key.devToken, devToken)
        KeychainStore.set(Key.sipUser, sipUser)
        KeychainStore.set(Key.sipPassword, sipPassword)
        KeychainStore.set(Key.sipDisplay, sipDisplay)
        KeychainStore.set(Key.mockURL, mockURL)
        KeychainStore.set(Key.deviceId, deviceId)
        let d = UserDefaults.standard
        d.set(enabled, forKey: Key.enabled)
        d.set(speakerOnAnswer, forKey: Key.speakerOnAnswer)
        d.set(showDeviceContacts, forKey: Key.showDeviceContacts)
        d.set(micGain, forKey: Key.micGain)
    }

    var hasSipAccount: Bool { !sipUser.isEmpty }
    var hasAccessToken: Bool { !cfClientId.isEmpty && !cfClientSecret.isEmpty }

    /// 接続に関わる項目が変わったか (変わったら張り直す)。
    func connectionDiffers(from o: AppSettings) -> Bool {
        host != o.host || cfClientId != o.cfClientId || cfClientSecret != o.cfClientSecret || devToken != o.devToken
            || sipUser != o.sipUser || sipPassword != o.sipPassword || sipDisplay != o.sipDisplay
            || mockURL != o.mockURL || enabled != o.enabled
    }

    /// 未入力の必須項目 (状態カードに出す。保存時には検証しない = UI-DESIGN §1.4)。
    var missingRequired: [String] {
        var out: [String] = []
        if host.trimmingCharacters(in: .whitespaces).isEmpty && mockURL.isEmpty { out.append(L10n.settingsMissingRelayUrl) }
        if !hasAccessToken && devToken.isEmpty && mockURL.isEmpty { out.append(L10n.settingsMissingAuth) }
        if !hasSipAccount { out.append(L10n.settingsMissingSip) }
        return out
    }

    /// 設定コードの内容を上書きする (含まれていた項目だけ)。
    mutating func apply(_ p: ProvisioningPayload) {
        if let v = p.relayURL { host = v }
        if let v = p.accessClientId { cfClientId = v }
        if let v = p.accessClientSecret { cfClientSecret = v }
        if let v = p.devToken { devToken = v }
        if let v = p.sipUser { sipUser = v }
        if let v = p.sipPassword { sipPassword = v }
        if let v = p.sipDisplay { sipDisplay = v }
    }
}
