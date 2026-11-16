import SwiftUI

/// 4 タブ (キーパッド / 履歴 / 連絡先 / 設定) + 通話画面 (UI-DESIGN §1, §2)。
/// iOS への適応: ボトムナビ → タブバー、通話画面 → fullScreenCover。アプリ外の「縮小ピル」は
/// CallKit の Dynamic Island / ステータスバーの通話表示が担うので自前では出さない。
struct RootView: View {
    enum Tab: Hashable { case keypad, history, contacts, settings }

    @EnvironmentObject private var manager: CallManager
    @State private var tab: Tab = .keypad
    @State private var showCall = false
    /// キーパッドの入力 (履歴・連絡先からの発信でも共有しない。Android と同じく番号は直接発信)
    @State private var dialNumber = ""

    var body: some View {
        TabView(selection: $tab) {
            KeypadView(number: $dialNumber, openSettings: { tab = .settings }, openCall: { showCall = true })
                .tabItem { Label(L10n.navKeypad, systemImage: "circle.grid.3x3.fill") }
                .tag(Tab.keypad)
            HistoryView(dial: dial)
                .tabItem { Label(L10n.navHistory, systemImage: "clock") }
                .tag(Tab.history)
            ContactsView(dial: dial)
                .tabItem { Label(L10n.navContacts, systemImage: "person.crop.circle") }
                .tag(Tab.contacts)
            SettingsScreen()
                .tabItem { Label(L10n.navSettings, systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(Nocturne.accent)
        .preferredColorScheme(.dark)
        .overlay(alignment: .topTrailing) {
            if !showCall, manager.callUI != nil, tab != .keypad {
                BackToCallPill { showCall = true }
                    .padding(.trailing, 16)
                    .padding(.top, 4)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = manager.endToast {
                ToastView(text: toast).padding(.bottom, 72)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: manager.endToast)
        .fullScreenCover(isPresented: $showCall) {
            CallView(minimize: { showCall = false })
                .environmentObject(manager)
        }
        .onChange(of: manager.callUI?.phase == nil) { _, noCall in
            // 呼が始まったら通話画面を出し、終わったら閉じる
            showCall = !noCall
        }
        .onAppear {
            if manager.callUI != nil { showCall = true }
            #if DEBUG
            // 画面確認用: UCHIDENLINK_UI_TAB=keypad|history|contacts|settings
            switch ProcessInfo.processInfo.environment["UCHIDENLINK_UI_TAB"] {
            case "history": tab = .history
            case "contacts": tab = .contacts
            case "settings": tab = .settings
            default: break
            }
            #endif
        }
    }

    private func dial(_ number: String) {
        manager.startOutgoing(number: number)
    }
}
