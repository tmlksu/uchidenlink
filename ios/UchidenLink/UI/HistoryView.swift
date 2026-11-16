import UchidenLinkCore
import SwiftUI

/// 履歴 (UI-DESIGN §1.2)。行タップで再発信、スワイプで削除、長押しで「削除」「連絡先に追加」。
struct HistoryView: View {
    @EnvironmentObject private var manager: CallManager
    var dial: (String) -> Void

    @State private var missedOnly = false
    @State private var entries: [HistoryEntry] = []
    @State private var confirmClear = false
    @State private var addTarget: HistoryEntry?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("", selection: $missedOnly) {
                        Text(L10n.historySegAll).tag(false)
                        Text(L10n.historySegMissed).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                if entries.isEmpty {
                    Text(L10n.historyEmpty)
                        .foregroundStyle(Nocturne.textDim)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(entries) { e in
                            HistoryRow(entry: e, name: resolvedName(e))
                                .contentShape(Rectangle())
                                .onTapGesture { dial(e.number) }
                                .listRowBackground(Nocturne.surface)
                                .listRowSeparatorTint(Nocturne.border)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { remove(e) } label: {
                                        Label(L10n.commonDeleteItem, systemImage: "trash")
                                    }
                                }
                                .contextMenu {
                                    Button { dial(e.number) } label: { Label(L10n.contactsCall, systemImage: "phone") }
                                    Button { addTarget = e } label: { Label(L10n.historyMenuAdd, systemImage: "person.badge.plus") }
                                    Button(role: .destructive) { remove(e) } label: { Label(L10n.commonDeleteItem, systemImage: "trash") }
                                }
                        }
                    } footer: {
                        Text(L10n.historyNote)
                            .font(.system(size: 12))
                            .foregroundStyle(Nocturne.textDim)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Nocturne.bg.ignoresSafeArea())
            .navigationTitle(L10n.historyTitle)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(L10n.historyClear, role: .destructive) { confirmClear = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(entries.isEmpty)
                }
            }
            .confirmationDialog(L10n.historyClearMsg, isPresented: $confirmClear, titleVisibility: .visible) {
                Button(L10n.historyClear, role: .destructive) {
                    manager.history.clear()
                    manager.notifyDataChanged()
                }
            }
            .sheet(item: $addTarget) { e in
                ContactEditor(initialName: e.name, initialNumber: e.number, title: L10n.historyMenuAdd) { name, number, group in
                    manager.contacts.add(name: name, number: number, group: group)
                    manager.notifyDataChanged()
                }
                .presentationDetents([.medium, .large])
            }
            .onAppear(perform: reload)
            .onChange(of: manager.dataVersion) { _, _ in reload() }
            .onChange(of: missedOnly) { _, _ in reload() }
        }
    }

    private func resolvedName(_ e: HistoryEntry) -> String {
        if !e.name.isEmpty { return e.name }
        return manager.contacts.lookup(e.number) ?? e.number
    }

    private func reload() {
        entries = missedOnly ? manager.history.missedOnly() : manager.history.all()
    }

    private func remove(_ e: HistoryEntry) {
        manager.history.remove(id: e.id)
        manager.notifyDataChanged()
    }
}

private struct HistoryRow: View {
    var entry: HistoryEntry
    var name: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(entry.direction == .MISSED ? Nocturne.missed : Nocturne.accentText)
                .frame(width: 36, height: 36)
                .background(Nocturne.surfaceHi, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 16))
                    .foregroundStyle(entry.direction == .MISSED ? Nocturne.missed : Nocturne.text)
                    .lineLimit(1)
                Text("\(kind)・\(entry.number)")
                    .font(.system(size: 13))
                    .foregroundStyle(Nocturne.textDim)
                    .lineLimit(1)
            }
            Spacer()
            Text(time)
                .font(.system(size: 13))
                .foregroundStyle(Nocturne.textDim)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch entry.direction {
        case .IN, .MISSED: return "arrow.down.left"
        case .OUT: return "arrow.up.right"
        }
    }

    private var kind: String {
        switch entry.direction {
        case .IN: return L10n.historyKindIn
        case .OUT: return L10n.historyKindOut
        case .MISSED: return L10n.historyKindMissed
        }
    }

    private var time: String {
        switch DisplayRules.historyTime(epochMs: entry.startedAt, now: Date()) {
        case .today(let s), .date(let s): return s
        case .yesterday: return L10n.historyTimeYesterday
        }
    }
}
