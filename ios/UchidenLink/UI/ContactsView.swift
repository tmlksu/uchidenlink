import Contacts
import ContactsUI
import UchidenLinkCore
import SwiftUI

/// 連絡先 (UI-DESIGN §1.3)。グループ「ウチ」「ソト」(+ 設定で ON のとき「端末」)。
/// 行タップ = 発信、スワイプ = 編集/削除、右下の「＋」で追加。
struct ContactsView: View {
    @EnvironmentObject private var manager: CallManager
    var dial: (String) -> Void

    @State private var query = ""
    @State private var all: [Contact] = []
    @State private var device: [DeviceContacts.Entry] = []
    @State private var editing: EditTarget?
    @State private var deleting: Contact?

    struct EditTarget: Identifiable {
        var id: String
        var contact: Contact?
        var name = ""
        var number = ""
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                List {
                    if all.isEmpty && device.isEmpty {
                        Text(L10n.contactsEmpty)
                            .foregroundStyle(Nocturne.textDim)
                            .listRowBackground(Color.clear)
                    }
                    group(L10n.groupUchi, ContactStore.filter(all, query: query).filter { $0.group == .UCHI })
                    group(L10n.groupSoto, ContactStore.filter(all, query: query).filter { $0.group == .SOTO })
                    if manager.settings.showDeviceContacts {
                        deviceGroup
                    }
                }
                .scrollContentBackground(.hidden)
                .searchable(text: $query, prompt: L10n.contactsSearchHint.replacingOccurrences(of: "🔍 ", with: ""))
                Button {
                    editing = EditTarget(id: UUID().uuidString)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Nocturne.accent, in: Circle())
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                }
                .padding(20)
                .accessibilityLabel(L10n.contactsAddTitle)
            }
            .background(Nocturne.bg.ignoresSafeArea())
            .navigationTitle(L10n.contactsTitle)
            .sheet(item: $editing) { t in
                ContactEditor(initialName: t.contact?.name ?? t.name, initialNumber: t.contact?.number ?? t.number,
                              initialGroup: t.contact?.group ?? .SOTO,
                              title: t.contact == nil ? L10n.contactsAddTitle : L10n.contactsEditTitle) { name, number, group in
                    if let c = t.contact {
                        manager.contacts.update(id: c.id, name: name, number: number, group: group)
                    } else {
                        manager.contacts.add(name: name, number: number, group: group)
                    }
                    manager.notifyDataChanged()
                }
                .presentationDetents([.medium, .large])
            }
            .confirmationDialog(deleting.map { L10n.contactsDeleteMsg($0.name) } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button(L10n.commonDelete, role: .destructive) {
                    if let c = deleting { manager.contacts.remove(id: c.id) }
                    manager.notifyDataChanged()
                    deleting = nil
                }
            }
            .onAppear(perform: reload)
            .onChange(of: manager.dataVersion) { _, _ in reload() }
            .onChange(of: manager.settings.showDeviceContacts) { _, _ in reload() }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [Contact]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { c in
                    ContactRow(name: c.name, subtitle: c.number) { dial(c.number) }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { deleting = c } label: { Label(L10n.commonDeleteItem, systemImage: "trash") }
                            Button { editing = EditTarget(id: c.id, contact: c) } label: { Label(L10n.commonEdit, systemImage: "pencil") }
                                .tint(Nocturne.accent)
                        }
                        .contextMenu {
                            Button { dial(c.number) } label: { Label(L10n.contactsCall, systemImage: "phone") }
                            Button { editing = EditTarget(id: c.id, contact: c) } label: { Label(L10n.commonEdit, systemImage: "pencil") }
                            Button(role: .destructive) { deleting = c } label: { Label(L10n.commonDeleteItem, systemImage: "trash") }
                        }
                }
            } header: {
                Text(title).font(.system(size: 12)).foregroundStyle(Nocturne.textDim)
            }
        }
    }

    @ViewBuilder
    private var deviceGroup: some View {
        let items = DeviceContacts.filter(device, query: query)
        if !items.isEmpty {
            Section {
                ForEach(items.prefix(200)) { e in
                    // 端末側は読み取り専用: タップ = 発信、長押し = 連絡先に保存 (ローカルへコピー)
                    ContactRow(name: e.name, subtitle: e.label.isEmpty ? e.number : "\(e.number)・\(e.label)") { dial(e.number) }
                        .contextMenu {
                            Button { dial(e.number) } label: { Label(L10n.contactsCall, systemImage: "phone") }
                            Button {
                                manager.contacts.add(name: e.name, number: e.number, group: .SOTO)
                                manager.notifyDataChanged()
                            } label: { Label(L10n.contactsSaveToLocal, systemImage: "square.and.arrow.down") }
                        }
                }
            } header: {
                Text(L10n.groupDevice).font(.system(size: 12)).foregroundStyle(Nocturne.textDim)
            }
        }
    }

    private func reload() {
        all = manager.contacts.all()
        guard manager.settings.showDeviceContacts else {
            device = []
            return
        }
        Task {
            let loaded = await DeviceContacts.loadAll()
            device = loaded
        }
    }
}

struct ContactRow: View {
    var name: String
    var subtitle: String
    var call: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AvatarCircle(name: name)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 16)).foregroundStyle(Nocturne.text).lineLimit(1)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Nocturne.textDim).lineLimit(1)
            }
            Spacer()
            Image(systemName: "phone.fill")
                .foregroundStyle(Nocturne.accent)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: call)
        .listRowBackground(Nocturne.surface)
        .listRowSeparatorTint(Nocturne.border)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// 追加/編集のシート (名前 / 番号 / グループ)。「端末の連絡先から選ぶ」は権限不要のピッカー。
struct ContactEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var initialName: String
    @State var initialNumber: String
    var initialGroup: ContactGroup = .SOTO
    var title: String
    var save: (String, String, ContactGroup) -> Void

    @State private var name = ""
    @State private var number = ""
    @State private var group: ContactGroup = .SOTO
    @State private var loaded = false
    @State private var picking = false
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(L10n.contactsNameHint, text: $name)
                TextField(L10n.contactsNumberHint, text: $number)
                    .keyboardType(.phonePad)
                Picker(L10n.contactsGroupLabel, selection: $group) {
                    Text(L10n.groupUchi).tag(ContactGroup.UCHI)
                    Text(L10n.groupSoto).tag(ContactGroup.SOTO)
                }
                .pickerStyle(.segmented)
                Button(L10n.contactsPickFromDevice) { picking = true }
                if !error.isEmpty {
                    Text(error).foregroundStyle(Nocturne.missed).font(.system(size: 13))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Nocturne.bg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.commonCancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.commonSave) {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        let num = number.trimmingCharacters(in: .whitespaces)
                        guard !n.isEmpty, !num.isEmpty else {
                            error = L10n.contactsNeedBoth
                            return
                        }
                        save(n, num, group)
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $picking) {
                PhonePicker { pickedName, pickedNumber in
                    if !pickedName.isEmpty { name = pickedName }
                    number = pickedNumber
                    group = .SOTO
                }
                .ignoresSafeArea()
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                name = initialName
                number = initialNumber
                group = initialGroup
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// 電話番号 1 件を選ばせる CNContactPicker (権限不要。複数番号の人もシステム UI 側で選べる)。
struct PhonePicker: UIViewControllerRepresentable {
    var onPick: (String, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let vc = CNContactPickerViewController()
        vc.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        vc.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        vc.predicateForSelectionOfProperty = NSPredicate(format: "key == 'phoneNumbers'")
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (String, String) -> Void
        init(onPick: @escaping (String, String) -> Void) { self.onPick = onPick }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
            guard let phone = contactProperty.value as? CNPhoneNumber else { return }
            let name = CNContactFormatter.string(from: contactProperty.contact, style: .fullName) ?? ""
            onPick(name, phone.stringValue)
        }
    }
}

/// 端末の連絡先 (設定で ON のときだけ。番号 1 件 = 1 行。権限判定とクエリだけを持つ)。
enum DeviceContacts {
    struct Entry: Identifiable, Sendable {
        var id: String
        var name: String
        var number: String
        var label: String
    }

    static func requestAccess() async -> Bool {
        (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    static var authorized: Bool {
        let s = CNContactStore.authorizationStatus(for: .contacts)
        return s == .authorized || s == .limited
    }

    /// バックグラウンドで読む (件数が多くても UI を止めない)。
    static func loadAll() async -> [Entry] {
        guard authorized else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactPhoneNumbersKey as CNKeyDescriptor]
            var out: [Entry] = []
            let req = CNContactFetchRequest(keysToFetch: keys)
            req.sortOrder = .userDefault
            try? store.enumerateContacts(with: req) { c, _ in
                let name = CNContactFormatter.string(from: c, style: .fullName) ?? ""
                for (i, p) in c.phoneNumbers.enumerated() {
                    let label = p.label.map { CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0) } ?? ""
                    out.append(Entry(id: "\(c.identifier)#\(i)", name: name, number: p.value.stringValue, label: label))
                }
            }
            return out
        }.value
    }

    static func filter(_ list: [Entry], query: String) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return list }
        let nq = normalizePhoneNumber(q)
        return list.filter { $0.name.contains(q) || (!nq.isEmpty && normalizePhoneNumber($0.number).hasPrefix(nq)) }
    }

    /// 着信時の名前解決 (権限があるときだけ)。
    static func lookup(_ number: String) -> String? {
        guard authorized else { return nil }
        let store = CNContactStore()
        let pred = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: number))
        let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
        guard let c = try? store.unifiedContacts(matching: pred, keysToFetch: keys).first else { return nil }
        return CNContactFormatter.string(from: c, style: .fullName)
    }
}
