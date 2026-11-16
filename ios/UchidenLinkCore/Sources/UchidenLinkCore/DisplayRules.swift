import Foundation

/// 画面表示の規則 (UI-DESIGN.md v1.4)。文言そのものは spec/strings.json から生成した
/// `L10n` (アプリ側) が持ち、ここは判定と書式だけを持つ (テスト可能にするため)。
public enum DisplayRules {
    /// 内線番号か (2〜4 桁の数字。UI-DESIGN §1.1)。
    public static func isExtension(_ number: String) -> Bool {
        let n = normalizePhoneNumber(number)
        return (2...4).contains(n.count) && n.allSatisfy { $0.isASCII && $0.isNumber }
    }

    public enum KeypadCaption: Equatable, Sendable {
        case empty
        case contact(name: String)
        case extensionNumber
        case external
    }

    /// キーパッドの番号下キャプション: 連絡先一致名 > 内線 > 外線 (未入力は empty)。
    public static func keypadCaption(number: String, contactName: String?) -> KeypadCaption {
        if number.isEmpty { return .empty }
        if let contactName, !contactName.isEmpty { return .contact(name: contactName) }
        return isExtension(number) ? .extensionNumber : .external
    }

    public enum HistoryTime: Equatable, Sendable {
        /// 今日 = HH:mm
        case today(String)
        /// 昨日
        case yesterday
        /// それ以前 = M/d
        case date(String)
    }

    /// 履歴の右端の時刻 (今日=HH:mm / 昨日=「昨日」/ それ以前=M/d)。
    public static func historyTime(epochMs: Int64, now: Date, calendar: Calendar = .current) -> HistoryTime {
        let date = Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000)
        if calendar.isDate(date, inSameDayAs: now) {
            let c = calendar.dateComponents([.hour, .minute], from: date)
            return .today(String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0))
        }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            return .yesterday
        }
        let c = calendar.dateComponents([.month, .day], from: date)
        return .date("\(c.month ?? 0)/\(c.day ?? 0)")
    }

    /// 通話時間の表示 `mm:ss` (1 時間以上は `h:mm:ss`)。
    public static func duration(seconds: Int64) -> String {
        let s = max(0, seconds)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// アバター円の文字 (名前の 1 文字目。空なら "#")。
    public static func avatarInitial(_ name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespaces).first else { return "#" }
        return String(first).uppercased()
    }

    /// キーパッドの英字 (0 は "+")。
    public static let keypadLetters: [String: String] = [
        "1": "", "2": "ABC", "3": "DEF", "4": "GHI", "5": "JKL", "6": "MNO",
        "7": "PQRS", "8": "TUV", "9": "WXYZ", "*": "", "0": "+", "#": "",
    ]

    /// 着信の表示名解決: relay の display が空、または番号だけのときは連絡先を引く (UI-DESIGN §1.3)。
    public static func resolveName(display: String, number: String, lookup: (String) -> String?) -> String {
        let d = display.trimmingCharacters(in: .whitespaces)
        let looksLikeNumber = !d.isEmpty && normalizePhoneNumber(d).allSatisfy { $0.isNumber || $0 == "+" || $0 == "*" || $0 == "#" }
        if d.isEmpty || looksLikeNumber || d == number {
            if let name = lookup(number), !name.isEmpty { return name }
        }
        return d
    }
}
