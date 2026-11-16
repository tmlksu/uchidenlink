import Foundation

// 履歴・連絡先の端末ローカル保存。Android の HistoryStore.kt / ContactStore.kt と同じデータ意味論・
// 同じ JSON 形式 (配列、キー名・enum 名も同一) なので、ファイルをそのまま持ち回れる
// (spec/fixtures/history.json・contacts.json がゴールデン)。
// どちらも毎回ファイルから読み直す (別インスタンスでも整合する)。メソッドは内部ロックで直列化。

// MARK: - History

/// 通話履歴の方向。IN=着信応答 / OUT=発信 / MISSED=不在着信。
public enum HistoryDirection: String, Sendable, CaseIterable {
    case IN, OUT, MISSED
}

/// 履歴 1 件。`name` は発生時点の解決名 (不明なら ""。表示時は番号にフォールバック)。
/// `startedAt` は epoch ms、`durationSec` は通話秒数 (未応答なら 0)。
public struct HistoryEntry: Equatable, Sendable, Identifiable {
    public var id: String
    public var direction: HistoryDirection
    public var number: String
    public var name: String
    public var startedAt: Int64
    public var durationSec: Int64

    public init(id: String, direction: HistoryDirection, number: String, name: String, startedAt: Int64, durationSec: Int64) {
        self.id = id
        self.direction = direction
        self.number = number
        self.name = name
        self.startedAt = startedAt
        self.durationSec = durationSec
    }

    /// 表示名 (解決名が無ければ番号)。
    public var displayName: String { name.isEmpty ? number : name }
}

public final class HistoryStore: @unchecked Sendable {
    /// 最大保持件数。超えた分は古いものから削除する。
    public static let maxEntries = 200

    private let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    /// 追加する (先頭=最新)。上限を超えたら古いものから捨てる。作成したエントリを返す。
    @discardableResult
    public func add(direction: HistoryDirection, number: String, name: String, startedAt: Int64, durationSec: Int64 = 0) -> HistoryEntry {
        lock.lock()
        defer { lock.unlock() }
        let entry = HistoryEntry(id: UUID().uuidString.lowercased(), direction: direction, number: number,
                                 name: name, startedAt: startedAt, durationSec: max(0, durationSec))
        var all = load()
        all.insert(entry, at: 0)
        save(Array(all.prefix(Self.maxEntries)))
        return entry
    }

    /// 全件 (新しい順)。
    public func all() -> [HistoryEntry] {
        lock.withLock { load() }
    }

    /// 不在着信のみ (新しい順)。
    public func missedOnly() -> [HistoryEntry] {
        lock.withLock { load().filter { $0.direction == .MISSED } }
    }

    /// 通話時間を更新する (応答済み通話の終了時)。該当 id があれば true。
    @discardableResult
    public func updateDuration(id: String, durationSec: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var all = load()
        guard let idx = all.firstIndex(where: { $0.id == id }) else { return false }
        all[idx].durationSec = max(0, durationSec)
        save(all)
        return true
    }

    @discardableResult
    public func remove(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let all = load()
        let kept = all.filter { $0.id != id }
        guard kept.count != all.count else { return false }
        save(kept)
        return true
    }

    public func clear() {
        lock.withLock { save([]) }
    }

    // MARK: 永続化

    private func load() -> [HistoryEntry] {
        guard let objs = JSONFile.readArray(url) else { return [] }
        return objs.map { o in
            HistoryEntry(
                id: JSONFile.string(o, "id") ?? UUID().uuidString.lowercased(),
                direction: HistoryDirection(rawValue: JSONFile.string(o, "direction") ?? "") ?? .MISSED,
                number: JSONFile.string(o, "number") ?? "",
                name: JSONFile.string(o, "name") ?? "",
                startedAt: JSONFile.int64(o, "startedAt") ?? 0,
                durationSec: max(0, JSONFile.int64(o, "durationSec") ?? 0)
            )
        }
    }

    private func save(_ all: [HistoryEntry]) {
        JSONFile.writeArray(url, all.map { e in
            ["id": e.id, "direction": e.direction.rawValue, "number": e.number, "name": e.name,
             "startedAt": e.startedAt, "durationSec": e.durationSec]
        })
    }
}

// MARK: - Contacts

/// 連絡先のグループ。ウチ=内線・家族 / ソト=外線。
public enum ContactGroup: String, Sendable, CaseIterable {
    case UCHI, SOTO
}

public struct Contact: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var number: String
    public var group: ContactGroup

    public init(id: String, name: String, number: String, group: ContactGroup) {
        self.id = id
        self.name = name
        self.number = number
        self.group = group
    }
}

private let hyphens: Set<Character> = ["-", "－", "‐", "‑", "‒", "–", "—", "―", "ー"]

/// 番号比較用の正規化: 空白・ハイフン類 (全角・ダッシュ類・長音を含む) を除去する。Android と同じ。
public func normalizePhoneNumber(_ raw: String) -> String {
    String(raw.filter { !$0.isWhitespace && !hyphens.contains($0) })
}

public final class ContactStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    @discardableResult
    public func add(name: String, number: String, group: ContactGroup) -> Contact {
        lock.lock()
        defer { lock.unlock() }
        let c = Contact(id: UUID().uuidString.lowercased(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        number: number.trimmingCharacters(in: .whitespacesAndNewlines), group: group)
        var all = load()
        all.append(c)
        save(all)
        return c
    }

    @discardableResult
    public func update(id: String, name: String, number: String, group: ContactGroup) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var all = load()
        guard let idx = all.firstIndex(where: { $0.id == id }) else { return false }
        all[idx] = Contact(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                           number: number.trimmingCharacters(in: .whitespacesAndNewlines), group: group)
        save(all)
        return true
    }

    @discardableResult
    public func remove(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let all = load()
        let kept = all.filter { $0.id != id }
        guard kept.count != all.count else { return false }
        save(kept)
        return true
    }

    /// 全件 (登録順)。
    public func all() -> [Contact] {
        lock.withLock { load() }
    }

    /// 名前の部分一致、または番号の前方一致 (正規化後)。空なら全件。
    public func search(_ query: String) -> [Contact] {
        lock.withLock { Self.filter(load(), query: query) }
    }

    /// 一覧の絞り込み (UI がキャッシュした配列にも同じ規則を使う)。
    public static func filter(_ list: [Contact], query: String) -> [Contact] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return list }
        let nq = normalizePhoneNumber(q)
        return list.filter { c in
            c.name.contains(q) || (!nq.isEmpty && normalizePhoneNumber(c.number).hasPrefix(nq))
        }
    }

    /// 着信時の名前解決: 番号の正規化一致で最初に見つかった名前。無ければ nil。
    public func lookup(_ number: String) -> String? {
        let n = normalizePhoneNumber(number)
        guard !n.isEmpty else { return nil }
        return lock.withLock { load().first { normalizePhoneNumber($0.number) == n }?.name }
    }

    private func load() -> [Contact] {
        guard let objs = JSONFile.readArray(url) else { return [] }
        return objs.map { o in
            Contact(
                id: JSONFile.string(o, "id") ?? UUID().uuidString.lowercased(),
                name: JSONFile.string(o, "name") ?? "",
                number: JSONFile.string(o, "number") ?? "",
                group: ContactGroup(rawValue: JSONFile.string(o, "group") ?? "") ?? .SOTO
            )
        }
    }

    private func save(_ all: [Contact]) {
        JSONFile.writeArray(url, all.map { c in
            ["id": c.id, "name": c.name, "number": c.number, "group": c.group.rawValue]
        })
    }
}

// MARK: - JSON file helpers

enum JSONFile {
    static func readArray(_ url: URL) -> [[String: Any]]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return nil }
        return arr.compactMap { $0 as? [String: Any] }
    }

    static func writeArray(_ url: URL, _ objs: [[String: Any]]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: objs, options: [.sortedKeys]) else { return }
        // 原子的に書く (一時ファイル → rename)。iOS ではデータ保護を「初回ロック解除後」にする
        // (将来の VoIP push 起床でロック中でも履歴を書けるように)。
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: [.atomic])
        #endif
    }

    static func string(_ o: [String: Any], _ key: String) -> String? {
        o[key] as? String
    }

    static func int64(_ o: [String: Any], _ key: String) -> Int64? {
        (o[key] as? NSNumber)?.int64Value
    }
}
