import AVFoundation
import UchidenLinkCore
import SwiftUI
import VisionKit

/// 設定 (UI-DESIGN §1.4)。入力はインライン、欄を離れたら (または完了キーで) その欄だけ保存する。
/// 必須チェックは保存時には行わず、状態カードに「未入力: …」を出し、「開始」を押したときだけ検証する。
struct SettingsScreen: View {
    @EnvironmentObject private var manager: CallManager

    enum Field: Hashable { case relayURL, accessId, accessSecret, devToken, sipUser, sipPassword, sipDisplay, mockURL }

    @State private var draft = AppSettings()
    @State private var loaded = false
    @FocusState private var focus: Field?
    @State private var revealSecret = false
    @State private var revealToken = false
    @State private var revealPassword = false
    @State private var startError = ""
    // 設定コード
    @State private var scanning = false
    @State private var pasting = false
    @State private var pasteText = ""
    @State private var pendingPayload: ProvisioningPayload?
    @State private var provisionError: String?
    @State private var provisionInfo: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    section(L10n.settingsSecConn) { connectionCard }
                    section(L10n.settingsSecProvision) { provisionCard }
                    section(L10n.settingsSecSip) { sipCard }
                    section(L10n.settingsSecBehavior) { behaviorCard }
                    section(L10n.settingsSecAudio) { audioCard }
                    section(L10n.settingsSecPermission) { permissionCard }
                    section(L10n.settingsSecTest) { testCard }
                    #if DEBUG
                    section(L10n.settingsSecDebug) { debugCard }
                    #endif
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Nocturne.bg.ignoresSafeArea())
            .navigationTitle(L10n.navSettings)
            .onAppear {
                guard !loaded else { return }
                loaded = true
                draft = manager.settings
            }
            .onChange(of: focus) { old, _ in
                if old != nil { save() }
            }
            .sheet(isPresented: $scanning) {
                QRScanner { text in
                    scanning = false
                    handleProvision(text)
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $pasting) { pasteSheet }
            .alert(L10n.provisionConfirmTitle, isPresented: Binding(get: { pendingPayload != nil }, set: { if !$0 { pendingPayload = nil } }), presenting: pendingPayload) { p in
                Button(L10n.provisionConfirmApply) { applyProvision(p) }
                Button(L10n.commonCancel, role: .cancel) {}
            } message: { p in
                Text(provisionLines(p).joined(separator: "\n") + "\n\n" + L10n.provisionConfirmNote)
            }
            .alert(L10n.provisionErrorTitle, isPresented: Binding(get: { provisionError != nil }, set: { if !$0 { provisionError = nil } })) {
                Button(L10n.commonOk) {}
            } message: { Text(provisionError ?? "") }
        }
    }

    // MARK: - Cards

    private var statusCard: some View {
        NocturneCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle().fill(statusDot).frame(width: 9, height: 9)
                        Text(statusTitle.replacingOccurrences(of: "● ", with: "").replacingOccurrences(of: "○ ", with: ""))
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(Nocturne.text)
                    }
                    Text(statusDetail).font(.system(size: 13)).foregroundStyle(Nocturne.textDim).lineLimit(1)
                    if !manager.settings.missingRequired.isEmpty {
                        Text(L10n.settingsSetupMissing(manager.settings.missingRequired.joined(separator: "・")))
                            .font(.system(size: 12)).foregroundStyle(Nocturne.missed)
                    }
                    if !startError.isEmpty {
                        Text(startError).font(.system(size: 12)).foregroundStyle(Nocturne.missed)
                    }
                    if !manager.lastError.isEmpty {
                        Text(manager.lastError).font(.system(size: 12)).foregroundStyle(Nocturne.textDim).lineLimit(3)
                    }
                }
                Spacer()
                Button(manager.settings.enabled ? L10n.settingsConnStop : L10n.settingsConnStart) {
                    if manager.settings.enabled {
                        manager.setEnabled(false)
                    } else {
                        let missing = manager.settings.missingRequired
                        if !missing.isEmpty {
                            startError = L10n.settingsErrStartMissing(missing.joined(separator: "・"))
                            return
                        }
                        startError = ""
                        manager.setEnabled(true)
                    }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Nocturne.accentText)
            }
            .padding(16)
        }
    }

    private var statusTitle: String {
        switch manager.conn {
        case .connected: return L10n.settingsConnTitleOnline
        case .connecting: return L10n.settingsConnTitleConnecting
        case .retrying: return L10n.settingsConnTitleRetry
        case .disabled: return L10n.settingsConnTitleDisabled
        case .offline: return L10n.settingsConnTitleOffline
        }
    }

    private var statusDot: Color {
        switch manager.conn {
        case .connected: return manager.registered ? Nocturne.accent : Nocturne.textDim
        case .connecting, .retrying: return Nocturne.textDim
        case .disabled, .offline: return Nocturne.border
        }
    }

    private var statusDetail: String {
        let host: String
        if !manager.settings.mockURL.isEmpty {
            host = "mock relay"
        } else {
            host = checkRelayURL(manager.settings.host, allowLoopbackCleartext: true).normalizedURL
                .flatMap { parseRelayWsURL($0) }.map { "wss://\($0.host)" } ?? L10n.commonUnset
        }
        let ext = manager.account.isEmpty ? (manager.settings.sipUser.isEmpty ? L10n.commonUnset : manager.settings.sipUser) : manager.account
        return L10n.settingsConnDetail(host, ext)
    }

    private var connectionCard: some View {
        NocturneCard {
            VStack(alignment: .leading, spacing: 0) {
                Text(.init(L10n.settingsConnNote))
                    .font(.system(size: 12)).foregroundStyle(Nocturne.textDim)
                    .padding(16)
                CardDivider()
                field(L10n.settingsRowRelayUrl, text: $draft.host, prompt: L10n.settingsHintRelayUrl, f: .relayURL, keyboard: .URL)
                if let err = relayURLError {
                    Text(err).font(.system(size: 12)).foregroundStyle(Nocturne.missed).padding(.horizontal, 16).padding(.bottom, 8)
                }
                CardDivider()
                field(L10n.settingsRowAccessId, text: $draft.cfClientId, f: .accessId)
                CardDivider()
                secretField(L10n.settingsRowAccessSecret, text: $draft.cfClientSecret, reveal: $revealSecret, f: .accessSecret)
                CardDivider()
                secretField(L10n.settingsRowDevToken, text: $draft.devToken, reveal: $revealToken, f: .devToken, prompt: L10n.settingsHintDevToken)
            }
        }
    }

    private var relayURLError: String? {
        #if DEBUG
        let allow = true
        #else
        let allow = false
        #endif
        switch checkRelayURL(draft.host, allowLoopbackCleartext: allow) {
        case .ok, .empty: return nil
        case .cleartext: return L10n.settingsErrUrlCleartextRelease
        case .invalid(let reason): return "\(L10n.settingsRowRelayUrl): \(reason)"
        }
    }

    private var provisionCard: some View {
        NocturneCard {
            VStack(alignment: .leading, spacing: 0) {
                Button { startScan() } label: { row(L10n.provisionScan, systemImage: "qrcode.viewfinder") }
                CardDivider()
                Button { pasteText = UIPasteboard.general.string ?? ""; pasting = true } label: { row(L10n.provisionPaste, systemImage: "doc.on.clipboard") }
                if let info = provisionInfo {
                    CardDivider()
                    Text(info).font(.system(size: 12)).foregroundStyle(Nocturne.accentText).padding(16)
                }
            }
        }
    }

    private var sipCard: some View {
        NocturneCard {
            VStack(alignment: .leading, spacing: 0) {
                field(L10n.settingsRowSipUser, text: $draft.sipUser, f: .sipUser, keyboard: .numberPad)
                CardDivider()
                secretField(L10n.settingsRowSipPassword, text: $draft.sipPassword, reveal: $revealPassword, f: .sipPassword)
                CardDivider()
                field(L10n.settingsRowSipDisplay, text: $draft.sipDisplay, f: .sipDisplay)
                CardDivider()
                Text(L10n.settingsSipNote).font(.system(size: 12)).foregroundStyle(Nocturne.textDim).padding(16)
            }
        }
    }

    private var behaviorCard: some View {
        NocturneCard {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.settingsModeTitle).foregroundStyle(Nocturne.text)
                    Text(L10n.settingsModeDescForeground).font(.system(size: 12)).foregroundStyle(Nocturne.textDim)
                }
                .padding(16)
                CardDivider()
                if manager.hasEarpiece {
                    toggleRow(L10n.settingsSwSpeaker, L10n.settingsSwSpeakerDesc, isOn: Binding(
                        get: { manager.settings.speakerOnAnswer },
                        set: { v in var s = manager.settings; s.speakerOnAnswer = v; manager.applySettings(s); draft.speakerOnAnswer = v }))
                    CardDivider()
                }
                toggleRow(L10n.settingsSwDeviceContacts, L10n.settingsSwDeviceContactsDesc, isOn: Binding(
                    get: { manager.settings.showDeviceContacts },
                    set: { v in
                        Task {
                            // ON にするときだけ権限を求め、拒否されたら OFF に戻す (UI-DESIGN §1.3)
                            let granted = v ? await DeviceContacts.requestAccess() : false
                            var s = manager.settings
                            s.showDeviceContacts = v && granted
                            manager.applySettings(s)
                            draft.showDeviceContacts = s.showDeviceContacts
                        }
                    }))
            }
        }
    }

    private var audioCard: some View {
        NocturneCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.settingsGain(draft.micGain)).foregroundStyle(Nocturne.text)
                Slider(value: $draft.micGain, in: 0.5...4.5, step: 0.1) { editing in
                    if !editing { save() }
                }
                .tint(Nocturne.accent)
            }
            .padding(16)
        }
    }

    private var permissionCard: some View {
        NocturneCard {
            Button {
                if AVAudioApplication.shared.recordPermission == .undetermined {
                    AVAudioApplication.requestRecordPermission { _ in }
                } else if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack {
                    Text(L10n.settingsRowPermMic).foregroundStyle(Nocturne.text)
                    Spacer()
                    Text(AVAudioApplication.shared.recordPermission == .granted ? L10n.settingsPermAllowed : L10n.settingsPermDenied)
                        .foregroundStyle(AVAudioApplication.shared.recordPermission == .granted ? Nocturne.textDim : Nocturne.missed)
                    Image(systemName: "chevron.right").foregroundStyle(Nocturne.textDim).font(.system(size: 13))
                }
                .padding(16)
            }
            .buttonStyle(.plain)
        }
    }

    private var testCard: some View {
        NocturneCard {
            Button { manager.showTestIncoming() } label: { row(L10n.settingsTestIncoming, systemImage: "phone.arrow.down.left") }
                .disabled(manager.isInCall)
        }
    }

    #if DEBUG
    private var debugCard: some View {
        NocturneCard {
            VStack(alignment: .leading, spacing: 0) {
                field(L10n.settingsDebugMockUrl, text: $draft.mockURL, f: .mockURL, keyboard: .URL)
                CardDivider()
                Button { manager.toggleLoopbackTest() } label: {
                    row(manager.loopbackActive ? L10n.settingsDebugLoopbackStop : L10n.settingsDebugLoopbackStart, systemImage: "waveform")
                }
            }
        }
    }
    #endif

    private var footer: some View {
        let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return Text(L10n.settingsFooter("\(app) (\(build))", manager.relayVersion.isEmpty ? "-" : manager.relayVersion, String(manager.settings.deviceId.prefix(8))))
            .font(.system(size: 11)).foregroundStyle(Nocturne.textDim)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
    }

    // MARK: - Rows

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Nocturne.textDim).padding(.leading, 4)
            content()
        }
    }

    private func row(_ title: String, systemImage: String) -> some View {
        HStack {
            Image(systemName: systemImage).foregroundStyle(Nocturne.accentText).frame(width: 24)
            Text(title).foregroundStyle(Nocturne.text)
            Spacer()
        }
        .padding(16)
        .contentShape(Rectangle())
    }

    private func field(_ label: String, text: Binding<String>, prompt: String = "", f: Field, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Nocturne.textDim)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(Nocturne.textDim.opacity(0.6)))
                .focused($focus, equals: f)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { save() }
                .foregroundStyle(Nocturne.text)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func secretField(_ label: String, text: Binding<String>, reveal: Binding<Bool>, f: Field, prompt: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Nocturne.textDim)
            HStack {
                Group {
                    if reveal.wrappedValue {
                        TextField("", text: text, prompt: Text(prompt).foregroundStyle(Nocturne.textDim.opacity(0.6)))
                    } else {
                        SecureField("", text: text, prompt: Text(prompt).foregroundStyle(Nocturne.textDim.opacity(0.6)))
                    }
                }
                .focused($focus, equals: f)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { save() }
                .foregroundStyle(Nocturne.text)
                Button { reveal.wrappedValue.toggle() } label: {
                    Image(systemName: reveal.wrappedValue ? "eye.slash" : "eye").foregroundStyle(Nocturne.textDim)
                }
                .accessibilityLabel(reveal.wrappedValue ? L10n.settingsSecretHide : L10n.settingsSecretShow)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func toggleRow(_ title: String, _ desc: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Nocturne.text)
                Text(desc).font(.system(size: 12)).foregroundStyle(Nocturne.textDim)
            }
        }
        .tint(Nocturne.accent)
        .padding(16)
    }

    // MARK: - Save

    /// 欄を離れたときの保存 (下書きの入力欄の値を反映。動作トグルは各トグルで即時保存)。
    private func save() {
        var s = manager.settings
        s.host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        s.cfClientId = draft.cfClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        s.cfClientSecret = draft.cfClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        s.devToken = draft.devToken.trimmingCharacters(in: .whitespacesAndNewlines)
        s.sipUser = draft.sipUser.trimmingCharacters(in: .whitespacesAndNewlines)
        s.sipPassword = draft.sipPassword // 前後の空白も値の一部
        s.sipDisplay = draft.sipDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        s.mockURL = draft.mockURL.trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
        s.micGain = (draft.micGain * 10).rounded() / 10
        if s != manager.settings { manager.applySettings(s) }
    }

    // MARK: - 設定コード (ProvisioningPayload)

    private func startScan() {
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            scanning = true
        } else {
            provisionError = L10n.provisionNoCamera
        }
    }

    private var pasteSheet: some View {
        NavigationStack {
            TextEditor(text: $pasteText)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding()
                .background(Nocturne.surface)
                .navigationTitle(L10n.provisionPasteTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.commonCancel) { pasting = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.provisionPasteOk) {
                            pasting = false
                            handleProvision(pasteText)
                        }
                    }
                }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
    }

    private func handleProvision(_ text: String) {
        #if DEBUG
        let allow = true
        #else
        let allow = false
        #endif
        switch ProvisioningPayload.parse(text, allowLoopbackCleartext: allow) {
        case .ok(let p): pendingPayload = p
        case .error(let msg): provisionError = msg
        }
    }

    /// 確認ダイアログの行 (秘密は「含む」とだけ出す)。
    private func provisionLines(_ p: ProvisioningPayload) -> [String] {
        func v(_ s: String) -> String { s.isEmpty ? L10n.provisionLineCleared : s }
        var lines: [String] = []
        if let host = p.relayHost() { lines.append(L10n.provisionLineRelay(host)) }
        if let cid = p.accessClientId { lines.append(L10n.provisionLineAccess(v(cid))) }
        if p.accessClientSecret != nil { lines.append(L10n.provisionLineAccessSecret) }
        if p.devToken != nil { lines.append(L10n.provisionLineDevToken) }
        if let u = p.sipUser { lines.append(L10n.provisionLineUser(v(u))) }
        if p.sipPassword != nil { lines.append(L10n.provisionLinePassword) }
        if let d = p.sipDisplay { lines.append(L10n.provisionLineDisplay(v(d))) }
        if let m = p.mode { lines.append(L10n.provisionLineMode(m)) }
        return lines
    }

    private func applyProvision(_ p: ProvisioningPayload) {
        var s = manager.settings
        s.apply(p)
        manager.applySettings(s)
        draft = manager.settings
        let missing = s.missingRequired
        provisionInfo = missing.isEmpty ? L10n.provisionApplied : L10n.provisionAppliedMissing(missing.joined(separator: "・"))
    }
}

/// QR コードの読み取り (VisionKit。カメラ権限は初回に OS が尋ねる)。
struct QRScanner: UIViewControllerRepresentable {
    var onText: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onText: onText) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onText: (String) -> Void
        private var done = false
        init(onText: @escaping (String) -> Void) { self.onText = onText }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case .barcode(let code) = item, let s = code.payloadStringValue {
                    done = true
                    scanner.stopScanning()
                    onText(s)
                    return
                }
            }
        }
    }
}
