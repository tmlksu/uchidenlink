import AVFoundation
import AudioToolbox
import CallKit
import Foundation
import Network
import PushKit
import UchidenLinkCore
import SwiftUI
import UIKit

/// 通話画面 (CallView) に出す状態。
struct CallUIState: Equatable {
    enum Phase: Equatable {
        case ringingIn
        case ringingOut(early: Bool)
        /// 応答操作の後、relay の `answered` 待ち
        case connecting
        case active(since: Date)
    }

    var phase: Phase
    var name: String
    var number: String
    var incoming: Bool
    var isTest: Bool
}

/// relay 接続・CallKit・音声エンジンを持ち、relay の遷移をそのまま写す呼の状態機械を回す。
/// 状態はすべてメインアクター。CXProvider のデリゲートはここへ飛ぶ。
@MainActor
final class CallManager: ObservableObject {
    enum ConnState: Equatable {
        case disabled, connecting, connected, retrying, offline
    }

    // 接続状態 (キーパッドの状態ピル・設定の状態カード)
    @Published private(set) var conn: ConnState = .offline
    @Published private(set) var registered = false
    @Published private(set) var account = ""
    @Published private(set) var relayVersion = ""
    @Published private(set) var statusText: String = L10n.settingsStatusInitial
    @Published var lastError: String = ""

    // 通話
    @Published private(set) var callUI: CallUIState?
    @Published private(set) var isMuted = false
    @Published private(set) var isSpeaker = false
    @Published var dtmfDigits = ""
    /// 「通話終了 01:08」(1.5 秒表示して消す)
    @Published var endToast: String?
    /// 履歴・連絡先が変わったら進む (一覧の再読込用)
    @Published private(set) var dataVersion = 0

    @Published private(set) var settings: AppSettings
    let history: HistoryStore
    let contacts: ContactStore
    let relay = RelayClient()
    let audio = AudioEngine()
    let hasEarpiece = UIDevice.current.userInterfaceIdiom == .phone

    var isInCall: Bool { callUI != nil }

    private var provider: CXProvider?
    private var providerDelegate: ProviderDelegate?
    private let callController = CXCallController()
    private let pathMonitor = NWPathMonitor()
    private var netType = "other"
    /// フィーダースレッドから読む「通話中かつ接続中」(下り途絶時に張り直してよいか)。
    private let link = LinkFlag()

    private enum CallDirection { case incoming, outgoing }
    private enum CallPhase { case ringingIn, ringingOut, active }

    private struct ActiveCall {
        var uuid: UUID
        var callId: String?
        var direction: CallDirection
        var phase: CallPhase
        var remote: String
        var display: String
        var pt: Int = 0
        var isTest = false
        var early = false
        var answeredAt: Date?
        var createdAt = Date()
        var historyId: String?
        var userAnswered = false
        /// push で起こされて WSS 接続前に応答された: 突合後に answer を送る
        var answerWhenConnected = false
        var fromPush = false
        var pendingAnswerAction: ActionResult?
        var answerTimeout: Task<Void, Never>?
        var ghostTimer: Task<Void, Never>?
        var reconnectDeadline: Task<Void, Never>?
    }

    /// 1 通話分の品質統計 (呼が確立してから終話後の送信まで)。
    private final class StatsSession {
        let callId: String
        let startedNs: UInt64
        let net: String
        let rtt = CallRtt()
        var report: CallStatsReport?
        var sent = false
        var periodic: Task<Void, Never>?
        var lastRxPkts: Int64 = 0
        var lastTxPkts: Int64 = 0
        var finalAudio: AudioStatsSnapshot?
        init(callId: String, startedNs: UInt64, net: String) {
            self.callId = callId
            self.startedNs = startedNs
            self.net = net
        }
    }

    private var call: ActiveCall?
    private var statsSession: StatsSession?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var started = false
    private var sipAccountSentThisConnection = false
    private var toastTask: Task<Void, Never>?
    // VoIP push (Phase 0b)
    private var pushRegistry: PKPushRegistry?
    private var pushDelegate: PushDelegate?
    private(set) var voipToken: String?
    let apsEnvironment = ApsEnvironment.from(provisioningProfile: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision").flatMap { try? Data(contentsOf: $0) })

    init() {
        var s = AppSettings.load()
        #if DEBUG
        // 検証用 (devicectl --environment-variables):
        // UCHIDENLINK_MOCK_URL = LAN のモック relay、UCHIDENLINK_HOST = relay URL の上書き。
        let env = ProcessInfo.processInfo.environment
        if let mock = env["UCHIDENLINK_MOCK_URL"], !mock.isEmpty {
            s.mockURL = mock
            AppLog.connectionEvent("DEBUG: mock URL override active")
        }
        if let host = env["UCHIDENLINK_HOST"], !host.isEmpty {
            s.host = host
        }
        // モック relay 専用: Keychain が空のシミュレータで内線番号だけ与える (パスワードは使わない)
        if !s.mockURL.isEmpty, let user = env["UCHIDENLINK_SIP_USER"], !user.isEmpty {
            s.sipUser = user
        }
        #endif
        self.settings = s
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        history = HistoryStore(url: dir.appendingPathComponent("history.json"))
        contacts = ContactStore(url: dir.appendingPathComponent("contacts.json"))
        #if DEBUG
        autotest = AutoTest.fromEnvironment()
        if ProcessInfo.processInfo.environment["UCHIDENLINK_SEED_DEMO"] == "1", history.all().isEmpty {
            // 画面確認用のデモデータ (シミュレータのみで使う)
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            contacts.add(name: "母屋", number: "2101", group: .UCHI)
            contacts.add(name: "玄関インターホン", number: "2110", group: .UCHI)
            contacts.add(name: "区役所", number: "03-1234-5678", group: .SOTO)
            history.add(direction: .OUT, number: "03-1234-5678", name: "区役所", startedAt: now - 3 * 86_400_000, durationSec: 95)
            history.add(direction: .MISSED, number: "2110", name: "玄関インターホン", startedAt: now - 86_400_000)
            history.add(direction: .IN, number: "2101", name: "母屋", startedAt: now - 3_600_000, durationSec: 68)
        }
        #endif
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        setupProvider()
        audio.micGain = Float(settings.micGain)
        let relay = self.relay
        audio.onSendFrame = { data, stats in
            relay.sendAudio(data, onError: { stats.tx.onSendError() })
        }
        let link = self.link
        audio.onRxStall = { [weak self] in
            guard link.connectedInCall else { return false }
            Task { @MainActor [weak self] in self?.reconnectAfterRxStall() }
            return true
        }
        let audio = self.audio
        relay.audioSink = { data, arrivalNs in
            audio.receivePacket(data, arrivalNs: arrivalNs)
        }
        relay.onEvent = { [weak self] event in
            self?.handleRelayEvent(event)
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let type: String
            if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
                type = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                type = "cellular"
            } else {
                type = "other"
            }
            Task { @MainActor [weak self] in self?.netType = type }
        }
        pathMonitor.start(queue: DispatchQueue(label: "io.github.tmlksu.uchidenlink.path"))
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshRoute() }
        }
        #if DEBUG
        if let autotest {
            AppLog.statsEvent("[autotest] armed: dial=\(autotest.number) hangupAfter=\(autotest.hangupSec)s tuning: \(audio.tuning)")
        }
        #endif
        setupPushKit()
        connect()
        #if DEBUG
        if ProcessInfo.processInfo.environment["UCHIDENLINK_UI_TEST_INCOMING"] == "1" {
            Task { try? await Task.sleep(for: .seconds(1)); showTestIncoming() }
        }
        #endif
    }

    private var isAppActive: Bool { UIApplication.shared.applicationState == .active }

    /// シーンの前面/背面。常駐接続は持たない (設計: フォアグラウンド WSS + VoIP push)。
    func scenePhaseChanged(active: Bool) {
        guard started else { return }
        if active {
            if !relay.isConnected, settings.enabled { connect() }
        } else if call == nil {
            AppLog.connectionEvent("background without a call: disconnecting (foreground-only model)")
            reconnectTask?.cancel()
            relay.disconnect(notify: false)
            setConn(.offline)
        }
    }

    private func setupProvider() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.phoneNumber, .generic]
        config.includesCallsInRecents = true
        let provider = CXProvider(configuration: config)
        let delegate = ProviderDelegate(owner: self)
        provider.setDelegate(delegate, queue: .main)
        self.provider = provider
        self.providerDelegate = delegate
        // セッションの有効化は CallKit が行う。カテゴリだけここで決める。
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        } catch {
            AppLog.audioEvent("setCategory failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Connection management

    func connect() {
        reconnectTask?.cancel()
        guard settings.enabled else {
            setConn(.disabled)
            relay.disconnect(notify: false)
            return
        }
        setConn(call == nil ? .connecting : .retrying)
        sipAccountSentThisConnection = false
        relay.connect(settings: settings)
    }

    /// 設定画面の「停止」/「開始」。
    func setEnabled(_ enabled: Bool) {
        var s = settings
        s.enabled = enabled
        applySettings(s)
    }

    /// 設定を保存する。接続に関わる項目が変わったときだけ張り直す (通話中は張り直さない)。
    func applySettings(_ newSettings: AppSettings) {
        let old = settings
        settings = newSettings
        settings.save()
        audio.micGain = Float(settings.micGain)
        if settings.connectionDiffers(from: old), call == nil {
            AppLog.connectionEvent("settings changed: reconnecting")
            registered = false
            connect()
        }
    }

    private func setConn(_ c: ConnState) {
        conn = c
        switch c {
        case .disabled: statusText = L10n.settingsConnTitleDisabled
        case .connecting: statusText = L10n.settingsConnTitleConnecting
        case .retrying: statusText = L10n.settingsConnTitleRetry
        case .offline: statusText = L10n.settingsConnTitleOffline
        case .connected: statusText = registered ? L10n.settingsConnTitleOnline : L10n.keypadStatusUnregistered
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        guard settings.enabled else { return }
        if let active = call, active.phase == .active {
            // 通話中 (設計 §2.6): すぐに再試行する。猶予切れの判断は reconnectDeadline が持つ。
            setConn(.retrying)
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.connect()
            }
            return
        }
        // 待機中: 1 秒 -> 60 秒の指数バックオフ (設計 §2.2)
        let delay = min(60.0, pow(2.0, Double(min(reconnectAttempt, 6))))
        reconnectAttempt += 1
        setConn(.retrying)
        AppLog.connectionEvent("state: reconnect scheduled in \(Int(delay))s")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    /// 通話中に下り RTP が 3 秒途絶えた (同一網のまま上流が死んだ等)。張り直す (QUALITY_STATS.md)。
    private func reconnectAfterRxStall() {
        guard call?.phase == .active else { return }
        AppLog.connectionEvent("rx stall (3s without RTP during a call): reconnecting")
        relay.disconnect(notify: false)
        startInCallReconnectDeadline()
        connect()
    }

    // MARK: - Relay events

    private func handleRelayEvent(_ event: RelayClient.Event) {
        switch event {
        case .connected:
            reconnectAttempt = 0
            setConn(.connected)
            audio.onRelayConnected()
            AppLog.connectionEvent("state: websocket connected")
        case .disconnected(let httpStatus):
            link.connectedInCall = false
            if let httpStatus {
                lastError = "HTTP \(httpStatus)"
                AppLog.connectionEvent("state: disconnected (HTTP \(httpStatus))")
            } else {
                AppLog.connectionEvent("state: disconnected")
            }
            registered = false
            setConn(.offline)
            if call?.phase == .active {
                startInCallReconnectDeadline()
            }
            scheduleReconnect()
        case .message(let message):
            handleMessage(message)
        }
    }

    private func startInCallReconnectDeadline() {
        guard let active = call, active.phase == .active, active.reconnectDeadline == nil else { return }
        AppLog.callEvent("in-call disconnect: starting 35s resume deadline (relay RESUME_TIMEOUT 30s)")
        call?.reconnectDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(35))
            guard !Task.isCancelled, let self else { return }
            AppLog.callEvent("in-call resume deadline exceeded: ending call locally")
            self.finishCall(endedReason: .failed, message: L10n.callEndedFailed)
        }
    }

    private func handleMessage(_ message: RelayMessage) {
        switch message {
        case .hello(let hello):
            relayVersion = hello.relayVersion
            registered = hello.registered
            account = hello.account
            setConn(.connected)
            AppLog.connectionEvent("hello: relay=\(hello.relayVersion) account=\(hello.account) registered=\(hello.registered) call=\(hello.call != nil)")
            // PROTOCOL v1.1: 接続ごとに、最初の hello を受けたら sip_account を送る
            if settings.hasSipAccount, !sipAccountSentThisConnection {
                sipAccountSentThisConnection = true
                relay.sendText(RelayCommand.sipAccount(user: settings.sipUser, password: settings.sipPassword, display: settings.sipDisplay))
                AppLog.connectionEvent("sip_account sent")
                sendRegisterPush()
            }
            reconcileHelloCall(hello.call)
            if hello.registered { onRegistered() }
        case .registration(let ok, let detail):
            registered = ok
            setConn(.connected)
            AppLog.connectionEvent("registration ok=\(ok) detail=\(detail)")
            if ok { onRegistered() }
        case .incoming(let info):
            handleIncoming(callId: info.callId, from: info.from, display: info.display, pt: info.pt)
        case .ringing(let callId, let early):
            AppLog.callEvent("ringing: early=\(early)")
            if var active = call, active.direction == .outgoing, active.phase == .ringingOut {
                active.callId = callId
                active.early = early
                call = active
                provider?.reportOutgoingCall(with: active.uuid, startedConnectingAt: Date())
                updateCallUI()
            }
        case .answered(let callId, let pt):
            AppLog.callEvent("answered: pt=\(pt)")
            guard var active = call, active.callId == callId || active.callId == nil else { return }
            active.callId = callId
            active.pt = pt
            active.phase = .active
            active.answeredAt = Date()
            audio.setPayloadType(UInt8(pt))
            if active.direction == .outgoing {
                provider?.reportOutgoingCall(with: active.uuid, connectedAt: Date())
            } else if active.historyId == nil {
                // 着信に応答した = IN (通話時間は終話時に更新。Android と同じ)
                active.historyId = history.add(direction: .IN, number: active.remote, name: active.display, startedAt: nowMs()).id
                dataVersion += 1
            }
            if let action = active.pendingAnswerAction {
                active.pendingAnswerAction = nil
                active.answerTimeout?.cancel()
                active.answerTimeout = nil
                action.fulfill()
                AppLog.callEvent("answer action fulfilled")
            }
            call = active
            beginStats(callId: callId)
            updateCallUI()
            #if DEBUG
            autotestOnAnswered()
            #endif
        case .ended(let callId, let reason, let code):
            AppLog.callEvent("ended: reason=\(reason) code=\(code)")
            guard let active = call, active.callId == callId else { return }
            finishCall(endedReason: Self.endedReason(for: reason), message: Self.endedMessage(reason: reason, code: code, answered: active.answeredAt != nil))
        case .error(let code, let message):
            lastError = Self.errorText(code: code, message: message)
            AppLog.connectionEvent("relay error: \(code)")
            if var active = call, active.pendingAnswerAction != nil {
                active.pendingAnswerAction?.fail()
                active.pendingAnswerAction = nil
                active.answerTimeout?.cancel()
                active.answerTimeout = nil
                call = active
            }
            if code == "no_account" || code == "dial_failed", let active = call, active.direction == .outgoing, active.phase == .ringingOut {
                finishCall(endedReason: .failed, message: lastError)
            }
        case .pong(let ts):
            if let s = statsSession { s.rtt.onPong(ts: ts, nowMs: uptimeMs()) }
        case .unknown(let type):
            AppLog.connectionEvent("unknown relay message type: \(type)")
        }
    }

    private static func endedReason(for reason: String) -> CXCallEndedReason {
        switch reason {
        case "answered_elsewhere": return .answeredElsewhere
        case "timeout": return .unanswered
        case "error": return .failed
        default: return .remoteEnded
        }
    }

    private static func endedMessage(reason: String, code: Int, answered: Bool) -> String? {
        switch reason {
        case "bye": return nil // 通話時間のトーストを出す
        case "answered_elsewhere": return L10n.callEndedElsewhere
        case "cancel": return L10n.callEndedCancel
        case "reject": return L10n.callEndedReject(code)
        case "timeout": return L10n.callEndedTimeout(code)
        default: return answered ? nil : L10n.callEndedOther(reason, code)
        }
    }

    private static func errorText(code: String, message: String) -> String {
        switch code {
        case "account_password_mismatch": return L10n.errorAccountPasswordMismatch
        case "account_failed": return L10n.errorAccountFailed(message)
        case "no_account": return L10n.errorNoAccount
        default: return L10n.errorOther(code, message)
        }
    }

    // MARK: - Incoming

    private func handleIncoming(callId: String, from: String, display: String, pt: Int) {
        let uuid = CallUUID.derive(callId: callId)
        if let active = call, active.callId == callId {
            // 同じ呼 (push で先に report 済み、または hello.call との重複)。二重に作らない。
            if active.answerWhenConnected, relay.isConnected {
                sendPendingAnswer()
            }
            return
        }
        if call != nil {
            // 同時 1 通話。通話中の 2 本目は記録だけして無視する (reject は全端末を止めるので送らない)。
            AppLog.callEvent("incoming while busy: ignored locally (no reject sent)")
            return
        }
        let name = DisplayRules.resolveName(display: display, number: from) { [weak self] in self?.lookupName($0) }
        AppLog.callEvent("incoming: reporting to CallKit")
        call = ActiveCall(uuid: uuid, callId: callId, direction: .incoming, phase: .ringingIn, remote: from, display: name, pt: pt)
        reportIncoming(uuid: uuid, from: from, display: name)
        // 幽霊対策 (設計 §2.4): ~30 秒で解決しなければローカルで片付ける (relay は 25 秒で ended)。
        call?.ghostTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, let active = self.call, active.phase == .ringingIn else { return }
            AppLog.callEvent("ghost timer fired: ending unreported call locally")
            self.finishCall(endedReason: .unanswered, message: nil)
        }
        updateCallUI()
    }

    /// 接続し直した後の hello.call の突き合わせ (設計 §2.4 の入口 2 / RESUME)。
    private func reconcileHelloCall(_ info: CallInfo?) {
        if let info {
            if info.direction == "in", info.state == "ringing" {
                if var active = call, active.callId == info.callId {
                    active.pt = info.pt
                    call = active
                }
                handleIncoming(callId: info.callId, from: info.from, display: info.display, pt: info.pt)
                return
            }
            if info.state == "active", var active = call, active.callId == info.callId {
                let wasResume = active.reconnectDeadline != nil
                active.reconnectDeadline?.cancel()
                active.reconnectDeadline = nil
                active.phase = .active
                active.pt = info.pt
                if active.answeredAt == nil { active.answeredAt = Date() }
                audio.setPayloadType(UInt8(info.pt))
                call = active
                link.connectedInCall = true
                AppLog.callEvent("hello.call: re-attached to active call (RESUME\(wasResume ? " after disconnect" : ""))")
                updateCallUI()
                return
            }
            if info.direction == "out", var active = call, active.direction == .outgoing,
               active.callId == nil || active.callId == info.callId {
                active.callId = info.callId
                call = active
                return
            }
        }
        // relay はこの端末の呼を持っていない。前の接続で始まった呼なら、切れている間に終わっている。
        guard let active = call, !active.isTest else { return }
        let knownToRelay = active.callId != nil
        if knownToRelay {
            AppLog.callEvent("hello without our call: call ended while disconnected")
            finishCall(endedReason: .remoteEnded, message: active.answeredAt == nil ? nil : L10n.callEndedFailed)
        }
    }

    private func reportIncoming(uuid: UUID, from: String, display: String, completion: (@Sendable () -> Void)? = nil) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: Self.handleType(for: from), value: from)
        update.localizedCallerName = display.isEmpty ? from : display
        update.supportsDTMF = true
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.hasVideo = false
        provider?.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error {
                // 二重配送の callUUIDAlreadyExists を含む。ログだけ (reject は全端末を止めるので送らない)。
                AppLog.callEvent("reportNewIncomingCall failed: \(error.localizedDescription)")
            } else {
                AppLog.callEvent("reportNewIncomingCall succeeded")
            }
            completion?()
        }
    }

    private static func handleType(for number: String) -> CXHandle.HandleType {
        number.allSatisfy({ $0.isNumber || $0 == "+" || $0 == "*" || $0 == "#" }) ? .phoneNumber : .generic
    }

    /// 設定の「テスト着信を表示」: relay を通さずに着信 UI (CallKit + アプリの通話画面) を確かめる。
    func showTestIncoming() {
        guard call == nil else { return }
        let uuid = UUID()
        call = ActiveCall(uuid: uuid, callId: nil, direction: .incoming, phase: .ringingIn,
                          remote: "101", display: L10n.settingsTestDisplay, isTest: true)
        reportIncoming(uuid: uuid, from: "101", display: L10n.settingsTestDisplay)
        updateCallUI()
    }

    // MARK: - Outgoing

    func startOutgoing(number: String) {
        let trimmed = number.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            lastError = L10n.keypadNeedNumber
            return
        }
        guard call == nil else { return }
        guard settings.hasSipAccount else {
            lastError = L10n.errorNoAccount
            return
        }
        // マイク権限が無いと VPIO が入出力とも回らない (エンジンの start は成功してしまう)。
        // 未決定なら発信の前に尋ね、答えを待ってから発信し直す。
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            AppLog.audioEvent("record permission undetermined: requesting before dial")
            AVAudioApplication.requestRecordPermission { granted in
                Task { @MainActor [weak self] in
                    AppLog.audioEvent("record permission answered: granted=\(granted)")
                    if granted {
                        self?.startOutgoing(number: trimmed)
                    } else {
                        self?.lastError = L10n.commonMicPermission
                    }
                }
            }
            return
        case .denied:
            AppLog.audioEvent("record permission denied: not dialing")
            lastError = L10n.commonMicPermission
            return
        default:
            break
        }
        let uuid = UUID()
        let name = contacts.lookup(trimmed) ?? ""
        call = ActiveCall(uuid: uuid, callId: nil, direction: .outgoing, phase: .ringingOut, remote: trimmed, display: name)
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: Self.handleType(for: trimmed), value: trimmed))
        action.isVideo = false
        action.contactIdentifier = name.isEmpty ? nil : name
        request(action) { [weak self] error in
            Task { @MainActor [weak self] in
                if let error {
                    AppLog.callEvent("start call request failed: \(error.localizedDescription)")
                    self?.lastError = L10n.outgoingFailedDial(error.localizedDescription)
                    self?.clearCall()
                } else {
                    AppLog.callEvent("start call requested")
                }
            }
        }
        updateCallUI()
    }

    func answerFromUI() {
        guard let active = call, active.direction == .incoming, active.phase == .ringingIn else { return }
        request(CXAnswerCallAction(call: active.uuid)) { error in
            if let error { AppLog.callEvent("answer request failed: \(error.localizedDescription)") }
        }
    }

    func endCurrentCallFromUI() {
        guard let active = call else { return }
        request(CXEndCallAction(call: active.uuid)) { error in
            if let error {
                AppLog.callEvent("end call request failed: \(error.localizedDescription)")
            }
        }
    }

    func setMutedFromUI(_ muted: Bool) {
        guard let active = call else { return }
        request(CXSetMutedCallAction(call: active.uuid, muted: muted)) { error in
            if let error { AppLog.callEvent("mute request failed: \(error.localizedDescription)") }
        }
    }

    func setSpeaker(_ on: Bool) {
        guard hasEarpiece else { return } // 受話口の無い端末 (iPad) は常にスピーカー
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none)
        } catch {
            AppLog.audioEvent("overrideOutputAudioPort failed: \(error.localizedDescription)")
        }
        refreshRoute()
    }

    /// 通話中の DTMF (in-band。UI-DESIGN §3.1)。
    func sendDtmf(_ digit: Character) {
        guard call?.phase == .active else { return }
        audio.sendDtmf(digit)
        dtmfDigits.append(digit)
        // ローカルの短い操作音 (システムの DTMF 音 1200〜1211)
        let ids: [Character: SystemSoundID] = ["0": 1200, "1": 1201, "2": 1202, "3": 1203, "4": 1204, "5": 1205,
                                               "6": 1206, "7": 1207, "8": 1208, "9": 1209, "*": 1210, "#": 1211]
        if let id = ids[digit] { AudioServicesPlaySystemSound(id) }
    }

    private func refreshRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        isSpeaker = !hasEarpiece || outputs.contains { $0.portType == .builtInSpeaker }
        updateProximity()
    }

    private func updateProximity() {
        // 通話中かつスピーカー OFF の間だけ近接センサーで画面を消す (UI-DESIGN §3.1)
        let enable = hasEarpiece && call?.phase == .active && !isSpeaker
        if UIDevice.current.isProximityMonitoringEnabled != enable {
            UIDevice.current.isProximityMonitoringEnabled = enable
        }
    }

    // MARK: - CallKit へのアクション要求

    /// CXCallController への要求。シミュレータには CallKit が無いので (requesttransaction error 1)、
    /// DEBUG のシミュレータに限り、プロバイダを通さず直接 perform* を呼び、音声セッションも自分で有効化する
    /// (モック relay 相手に通話フロー全体を検証するため。実機の経路は変えない)。
    private func request(_ action: CXCallAction, completion: @escaping @Sendable (Error?) -> Void) {
        #if DEBUG && targetEnvironment(simulator)
        let noop = ActionResult(callUUID: action.callUUID, fulfill: {}, fail: {})
        switch action {
        case is CXStartCallAction:
            performStart(noop)
            simulatorActivateAudio()
        case is CXAnswerCallAction:
            performAnswer(noop)
            simulatorActivateAudio()
        case is CXEndCallAction:
            performEnd(noop)
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            didDeactivateAudioSession()
        case let a as CXSetMutedCallAction:
            performSetMuted(a.isMuted, noop)
        default:
            break
        }
        completion(nil)
        #else
        callController.request(CXTransaction(action: action), completion: completion)
        #endif
    }

    #if DEBUG && targetEnvironment(simulator)
    private func simulatorActivateAudio() {
        guard call != nil else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            AppLog.audioEvent("simulator session activation failed: \(error.localizedDescription)")
        }
        didActivateAudioSession()
    }
    #endif

    // MARK: - CallKit action handling (ProviderDelegate から)

    fileprivate func performAnswer(_ action: ActionResult) {
        guard var active = call, active.uuid == action.callUUID else {
            action.fail()
            return
        }
        active.userAnswered = true
        if active.isTest {
            active.phase = .active
            active.answeredAt = Date()
            call = active
            action.fulfill()
            updateCallUI()
            return
        }
        AppLog.callEvent("answer action: sending answer to relay")
        // 順序 (設計 §2.4): WSS 接続を確認 -> answer -> relay の answered を待つ -> fulfill。5 秒で失敗。
        guard let callId = active.callId else {
            action.fail()
            return
        }
        let connected = relay.isConnected
        active.pendingAnswerAction = action
        active.answerWhenConnected = !connected
        // push 起床直後は WSS がまだ無い: 接続と hello.call の突合を待ってから answer を送る (長めに待つ)
        let timeout = connected ? 5 : 12
        active.answerTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, var current = self.call, let pending = current.pendingAnswerAction else { return }
            AppLog.callEvent("answer action timed out after 5s")
            pending.fail()
            current.pendingAnswerAction = nil
            current.answerTimeout = nil
            self.call = current
            self.updateCallUI()
        }
        call = active
        if connected {
            relay.sendText(RelayCommand.answer(callId: callId, pt: active.pt))
        } else {
            AppLog.callEvent("answer queued until websocket reconnects (push wake)")
            if conn != .connecting { connect() }
        }
        updateCallUI()
    }

    private func sendPendingAnswer() {
        guard var active = call, active.answerWhenConnected, let callId = active.callId else { return }
        active.answerWhenConnected = false
        call = active
        AppLog.callEvent("sending queued answer")
        relay.sendText(RelayCommand.answer(callId: callId, pt: active.pt))
    }

    fileprivate func performEnd(_ action: ActionResult) {
        guard let active = call, active.uuid == action.callUUID else {
            action.fulfill()
            return
        }
        if let callId = active.callId, !active.isTest {
            // 終了直前の RTT 計測 (hangup の前に 1 回だけ)
            sendEndPing()
            switch active.phase {
            case .ringingIn:
                // 注意 (設計 R2): relay の reject は呼全体の拒否 (全端末の着信が止まり、発信側は 486)。
                relay.sendText(RelayCommand.reject(callId: callId))
                AppLog.callEvent("end action: reject sent (global reject, design R2)")
            case .ringingOut, .active:
                relay.sendText(RelayCommand.hangup(callId: callId))
                AppLog.callEvent("end action: hangup sent")
            }
        }
        action.fulfill()
        finishCall(endedReason: nil, message: nil)
    }

    fileprivate func performStart(_ action: ActionResult) {
        guard var active = call, active.uuid == action.callUUID else {
            action.fail()
            return
        }
        // dial を送ってすぐ fulfill する (fulfill を遅らせると didActivateAudioSession も遅れ、
        // 早期メディアを失う。§2.5)。
        guard relay.sendText(RelayCommand.dial(to: active.remote)) else {
            AppLog.callEvent("start action failed: websocket not connected")
            action.fail()
            lastError = L10n.outgoingFailedDial(L10n.keypadStatusOffline)
            clearCall()
            return
        }
        AppLog.callEvent("start action: dial sent, fulfilling immediately")
        active.phase = .ringingOut
        active.historyId = history.add(direction: .OUT, number: active.remote, name: active.display, startedAt: nowMs()).id
        dataVersion += 1
        call = active
        action.fulfill()
        updateCallUI()
    }

    fileprivate func performSetMuted(_ muted: Bool, _ action: ActionResult) {
        audio.muted = muted
        isMuted = muted
        AppLog.callEvent("muted: \(muted)")
        action.fulfill()
    }

    fileprivate func performPlayDTMF(_ digits: String, _ action: ActionResult) {
        // CallKit の画面 (ロック中など) のキーパッドからの DTMF
        for ch in digits { audio.sendDtmf(ch) }
        action.fulfill()
    }

    fileprivate func providerDidReset() {
        AppLog.callEvent("provider did reset")
        #if DEBUG && targetEnvironment(simulator)
        if true { return } // シミュレータには CallKit が無く reset が来る (シムで代替中)
        #endif
        audio.stop()
        finishCall(endedReason: nil, message: nil)
    }

    fileprivate func didActivateAudioSession() {
        AppLog.audioEvent("didActivateAudioSession")
        if call?.isTest == true { return }
        audio.start()
        if !hasEarpiece || settings.speakerOnAnswer {
            setSpeaker(true)
        }
        refreshRoute()
    }

    fileprivate func didDeactivateAudioSession() {
        AppLog.audioEvent("didDeactivateAudioSession")
        audio.stop()
    }

    // MARK: - 終話

    /// どの経路の終話もここに集める: CallKit への報告、履歴、統計、トースト、片付け。
    /// `endedReason` が nil = CallKit の End アクション経由 (CallKit は既に終了を知っている)。
    private func finishCall(endedReason: CXCallEndedReason?, message: String?) {
        guard let active = call else { return }
        if let endedReason {
            provider?.reportCall(with: active.uuid, endedAt: Date(), reason: endedReason)
        }
        // 履歴 (Android と同じ: 応答済みは通話時間を更新、着信の未応答は MISSED を 1 回)
        if !active.isTest {
            if let answeredAt = active.answeredAt {
                if let id = active.historyId {
                    history.updateDuration(id: id, durationSec: Int64(Date().timeIntervalSince(answeredAt)))
                }
            } else if active.direction == .incoming {
                history.add(direction: .MISSED, number: active.remote, name: active.display, startedAt: Int64(active.createdAt.timeIntervalSince1970 * 1000))
            }
            dataVersion += 1
        }
        if let answeredAt = active.answeredAt, message == nil {
            showToast(L10n.callEndToast(DisplayRules.duration(seconds: Int64(Date().timeIntervalSince(answeredAt)))))
        } else if let message {
            showToast(message)
        }
        endStats()
        audio.stop()
        clearCall()
    }

    private func showToast(_ text: String) {
        endToast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            self?.endToast = nil
        }
    }

    private func clearCall() {
        call?.ghostTimer?.cancel()
        call?.answerTimeout?.cancel()
        call?.reconnectDeadline?.cancel()
        if call?.pendingAnswerAction != nil {
            call?.pendingAnswerAction?.fail()
        }
        call = nil
        link.connectedInCall = false
        isMuted = false
        audio.muted = false
        dtmfDigits = ""
        updateCallUI()
        updateProximity()
        if !isAppActive {
            // 背面 (push で起こされた着信の後など): 常駐接続は持たないので切る。次の着信は push で来る。
            AppLog.connectionEvent("call cleared in background: disconnecting (foreground-only model)")
            reconnectTask?.cancel()
            relay.disconnect(notify: false)
            setConn(.offline)
            return
        }
        // 通話中の短い再試行ループから、待機中のバックオフへ戻す
        if !relay.isConnected, settings.enabled, conn == .offline || conn == .retrying { scheduleReconnect() }
    }

    private func updateCallUI() {
        guard let active = call else {
            callUI = nil
            return
        }
        let phase: CallUIState.Phase
        switch active.phase {
        case .ringingIn: phase = active.pendingAnswerAction != nil ? .connecting : .ringingIn
        case .ringingOut: phase = .ringingOut(early: active.early)
        case .active: phase = .active(since: active.answeredAt ?? Date())
        }
        callUI = CallUIState(phase: phase, name: active.display, number: active.remote,
                             incoming: active.direction == .incoming, isTest: active.isTest)
        updateProximity()
    }

    // MARK: - 品質統計 (QUALITY_STATS.md / PROTOCOL v1.2)

    private func uptimeMs() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }
    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func beginStats(callId: String) {
        if let s = statsSession, s.callId == callId { return } // 同じ呼 (RESUME) は続ける
        endStats()
        audio.beginCallStats()
        let s = StatsSession(callId: callId, startedNs: DispatchTime.now().uptimeNanoseconds, net: netType)
        statsSession = s
        link.connectedInCall = relay.isConnected
        // RTT (開始直後): JSON ping を 1 回だけ
        let ts = uptimeMs()
        s.rtt.markStartPing(ts: ts)
        relay.sendText(RelayCommand.ping(ts: ts))
        // 通話中 5 秒ごとの [stats] (OSLog)。値は既存カウンタを読むだけ。
        s.periodic = Task { [weak self] in
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.statsSession === s else { return }
                elapsed += 5
                let snap = self.audio.snapshot(resetWindow: true)
                AppLog.statsEvent("[stats] t=\(elapsed)s \(Self.describe(snap, prevRx: s.lastRxPkts, prevTx: s.lastTxPkts))")
                s.lastRxPkts = snap.rx.pkts
                s.lastTxPkts = snap.tx.pkts
            }
        }
        AppLog.statsEvent("[stats] start callId=\(callId) net=\(netType) tuning: \(audio.tuning)")
    }

    private func sendEndPing() {
        guard let s = statsSession, !s.rtt.endPingSent else { return }
        let ts = uptimeMs()
        s.rtt.markEndPing(ts: ts)
        relay.sendText(RelayCommand.ping(ts: ts))
    }

    private func endStats() {
        guard let s = statsSession else { return }
        statsSession = nil
        s.periodic?.cancel()
        audio.endCallStats()
        sendEndPing()
        let snap = audio.snapshot(resetWindow: false)
        s.finalAudio = snap
        var r = CallStatsReport(callId: s.callId, durMs: Int64((DispatchTime.now().uptimeNanoseconds - s.startedNs) / 1_000_000), net: s.net)
        r.apply(rx: snap.rx)
        r.rxReconnects = snap.reconnects
        r.jbUnderrun = snap.jb.underrun
        r.jbOverflow = snap.jb.overflow
        r.playUnderrun = Int64(snap.playUnderrun)
        r.txPkts = snap.tx.pkts
        r.txDrop = snap.tx.drop
        r.txLost = snap.tx.lost
        r.txLateMs = snap.tx.lateMs
        s.report = r
        // 終了直前の ping の pong を少しだけ待ってから出す (通話終了時の 1 回きり)
        Task { [weak self] in
            for _ in 0..<10 {
                if s.rtt.endMs >= 0 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.emitCallStats(s)
        }
    }

    private func emitCallStats(_ s: StatsSession) {
        guard !s.sent, var r = s.report else { return }
        s.sent = true
        r.rttStartMs = s.rtt.startMs
        r.rttEndMs = s.rtt.endMs
        let json = r.json()
        AppLog.statsEvent("[stats] call_stats \(json)")
        if let a = s.finalAudio {
            AppLog.statsEvent("[stats] summary \(Self.describe(a, prevRx: 0, prevTx: 0))")
        }
        if relayVersionAtLeast(relayVersion, callStatsMinRelayVersion) {
            if relay.sendText(json) {
                AppLog.statsEvent("[stats] call_stats sent to relay")
            } else {
                AppLog.statsEvent("[stats] call_stats not sent (websocket down)")
            }
        } else {
            AppLog.statsEvent("[stats] call_stats not sent: relay \(relayVersion) < \(callStatsMinRelayVersion)")
        }
        #if DEBUG
        autotestFinished(report: r, audio: s.finalAudio)
        #endif
    }

    private static func describe(_ a: AudioStatsSnapshot, prevRx: Int64, prevTx: Int64) -> String {
        "rx=\(a.rx.pkts)(+\(a.rx.pkts - prevRx)) gaps=\(a.rx.gaps) reorder=\(a.rx.reorder) dup=\(a.rx.duplicates) "
            + "jitter=\(a.rx.jitterMs)ms maxGap=\(a.rx.maxGapMs)ms stall=\(a.rx.stall100)/\(a.rx.stall200)/\(a.rx.stall500) "
            + "jb[depth=\(a.jb.depth) target=\(a.jb.target) max=\(a.jb.maxDepth) under=\(a.jb.underrun) late=\(a.jb.late) "
            + "ovf=\(a.jb.overflow) skipMiss=\(a.jb.skippedMissing) skipLat=\(a.jb.skippedForLatency) resync=\(a.jb.resyncs) played=\(a.jb.played)] "
            + "play[under=\(a.playUnderrun) \(a.playUnderrunMs)ms ring=\(a.ringMinMs)-\(a.ringMaxMs)ms feedLate=\(a.feederMaxLateMs)ms] "
            + "tx=\(a.tx.pkts)(+\(a.tx.pkts - prevTx)) lost=\(a.tx.lost) drop=\(a.tx.drop) txLate=\(a.tx.lateMs)ms "
            + "io=\(String(format: "%.1f", a.ioBufferMs))ms hw=\(Int(a.hwRate)) tap=\(a.tapFrames) reconnects=\(a.reconnects) "
            + "peak[rx=\(a.rxPeak) tx=\(a.txPeak)]"
    }

    // MARK: - VoIP push (Phase 0b, PROTOCOL v1.3)

    private func setupPushKit() {
        let registry = PKPushRegistry(queue: .main)
        let delegate = PushDelegate(owner: self)
        registry.delegate = delegate
        registry.desiredPushTypes = [.voIP]
        pushRegistry = registry
        pushDelegate = delegate
        AppLog.pushEvent("PushKit registered (aps-environment=\(apsEnvironment))")
    }

    fileprivate func pushTokenUpdated(_ token: String?) {
        voipToken = token
        if let token {
            AppLog.pushEvent("VoIP token: \(VoipPush.masked(token))")
            if relay.isConnected { sendRegisterPush() }
        } else {
            AppLog.pushEvent("VoIP token invalidated")
        }
    }

    private func sendRegisterPush() {
        guard let token = voipToken else { return }
        if relay.sendText(RelayCommand.registerPush(provider: "apns-voip", token: token, env: apsEnvironment)) {
            AppLog.pushEvent("register_push sent (apns-voip, \(apsEnvironment))")
        }
    }

    /// VoIP push を受けた。**必ず** CallKit に report してから completion を呼ぶ (PushKit の規則)。
    /// UUID は callId から決定的に導出するので、WSS の incoming / hello.call と同じ呼は 1 つにまとまる。
    fileprivate func handleVoipPush(_ payload: [AnyHashable: Any], completion: @escaping @Sendable () -> Void) {
        guard let info = VoipPush.parse(payload) else {
            // 解釈できなくても report は必須。ダミーを出して即終了する。
            AppLog.pushEvent("VoIP push with unknown payload: reporting a placeholder call and ending it")
            let uuid = UUID()
            reportIncoming(uuid: uuid, from: "", display: L10n.callUnknown) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.provider?.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                    completion()
                }
            }
            return
        }
        AppLog.pushEvent("VoIP push: incoming (app active=\(isAppActive), ws=\(relay.isConnected))")
        let uuid = CallUUID.derive(callId: info.callId)
        if let active = call, active.callId != info.callId {
            // 通話中に別の着信の push: report だけして即終了 (reject は全端末を止めるので送らない)
            reportIncoming(uuid: uuid, from: info.from, display: info.display) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.provider?.reportCall(with: uuid, endedAt: Date(), reason: .unanswered)
                    completion()
                }
            }
            return
        }
        if call == nil {
            let name = DisplayRules.resolveName(display: info.display, number: info.from) { [weak self] in self?.lookupName($0) }
            var c = ActiveCall(uuid: uuid, callId: info.callId, direction: .incoming, phase: .ringingIn, remote: info.from, display: name)
            c.fromPush = true
            call = c
            call?.ghostTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, let active = self.call, active.phase == .ringingIn else { return }
                AppLog.callEvent("ghost timer fired (push call): ending locally")
                self.finishCall(endedReason: .unanswered, message: nil)
            }
            updateCallUI()
        }
        // 既に WSS で知っている呼でも report する (同じ UUID なので CallKit 側で重複として弾かれる)
        let display = call?.display ?? info.display
        reportIncoming(uuid: uuid, from: info.from, display: display) {
            completion()
        }
        // 突合: WSS を張って hello.call を待つ (ringing → そのまま、null → 終わっていたので片付け)
        if !relay.isConnected, settings.enabled, conn != .connecting {
            connect()
        }
    }

    // MARK: - 自動の発着信を外から使う (Recents / Siri)

    func handleStartCallIntent(number: String) {
        startOutgoing(number: number)
    }

    /// 着信の名前解決: アプリの連絡先 → (設定で ON かつ権限があるときだけ) 端末の連絡先 (UI-DESIGN §1.3)。
    private func lookupName(_ number: String) -> String? {
        if let n = contacts.lookup(number) { return n }
        return settings.showDeviceContacts ? DeviceContacts.lookup(number) : nil
    }

    func notifyDataChanged() {
        dataVersion += 1
    }

    // MARK: - DEBUG: 自動テスト (内線 2180 / 2199 への発信を人手を介さず回す)

    #if DEBUG
    /// UCHIDENLINK_AUTODIAL=<内線> / UCHIDENLINK_AUTOHANGUP_SEC=<秒> で有効。無ければ完全に無効。
    /// 登録完了後に 1 回だけ発信し、応答から指定秒で終話し、最終統計を [autotest] に出す。
    /// 安全のため内線 (2〜4 桁) 以外には発信しない。
    private struct AutoTest {
        var number: String
        var hangupSec: Int
        var fired = false
        var answered = false
        var hangupTask: Task<Void, Never>?
        var noAnswerTask: Task<Void, Never>?
        /// UCHIDENLINK_AUTOTEST_STEPS="10:mute,20:unmute,22:dtmf=123,24:speaker=off"
        /// (応答からの秒:操作)。通話中の操作を人手なしで確かめるため。
        var steps: [(sec: Int, action: String)] = []
        var stepTasks: [Task<Void, Never>] = []

        static func fromEnvironment() -> AutoTest? {
            let env = ProcessInfo.processInfo.environment
            guard let number = env["UCHIDENLINK_AUTODIAL"]?.trimmingCharacters(in: .whitespaces), !number.isEmpty else { return nil }
            let sec = Int(env["UCHIDENLINK_AUTOHANGUP_SEC"] ?? "") ?? 30
            var t = AutoTest(number: number, hangupSec: max(3, min(sec, 120)))
            for item in (env["UCHIDENLINK_AUTOTEST_STEPS"] ?? "").split(separator: ",") {
                let parts = item.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, let s = Int(parts[0]), s >= 0 { t.steps.append((s, parts[1])) }
            }
            return t
        }
    }

    private var autotest: AutoTest?

    private func onRegistered() {
        guard var t = autotest, !t.fired, call == nil else { return }
        guard DisplayRules.isExtension(t.number) else {
            AppLog.statsEvent("[autotest] refused: \(t.number) is not an extension (2-4 digits)")
            autotest = nil
            return
        }
        t.fired = true
        AppLog.statsEvent("[autotest] registered: dialing \(t.number) in 2s")
        t.noAnswerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(47))
            guard !Task.isCancelled, let self, self.autotest?.answered == false else { return }
            AppLog.statsEvent("[autotest] result=not_answered (45s)")
            self.endCurrentCallFromUI()
            AppLog.statsEvent("[autotest] done")
        }
        autotest = t
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.startOutgoing(number: t.number)
            if self.call == nil {
                AppLog.statsEvent("[autotest] result=failed dial not started: \(self.lastError)")
                AppLog.statsEvent("[autotest] done")
            }
        }
    }

    private func autotestOnAnswered() {
        guard var t = autotest, t.fired, !t.answered else { return }
        t.answered = true
        t.noAnswerTask?.cancel()
        AppLog.statsEvent("[autotest] answered: hanging up in \(t.hangupSec)s")
        let sec = t.hangupSec
        t.hangupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(sec))
            guard !Task.isCancelled, let self else { return }
            AppLog.statsEvent("[autotest] hangup")
            self.endCurrentCallFromUI()
        }
        for step in t.steps where step.sec < sec {
            let action = step.action
            t.stepTasks.append(Task { [weak self] in
                try? await Task.sleep(for: .seconds(step.sec))
                guard !Task.isCancelled, let self, self.call?.phase == .active else { return }
                self.autotestRun(action)
            })
        }
        autotest = t
    }

    private func autotestRun(_ action: String) {
        AppLog.statsEvent("[autotest] step: \(action)")
        switch action {
        case "mute": setMutedFromUI(true)
        case "unmute": setMutedFromUI(false)
        case "speaker=on": setSpeaker(true)
        case "speaker=off": setSpeaker(false)
        case let a where a.hasPrefix("dtmf="):
            for ch in a.dropFirst(5) { sendDtmf(ch) }
        default:
            AppLog.statsEvent("[autotest] unknown step: \(action)")
        }
        AppLog.statsEvent("[autotest] state: muted=\(isMuted) speaker=\(isSpeaker) dtmf=\(dtmfDigits.count) digits")
    }

    private func autotestFinished(report: CallStatsReport, audio: AudioStatsSnapshot?) {
        guard let t = autotest, t.answered else { return }
        t.hangupTask?.cancel()
        t.stepTasks.forEach { $0.cancel() }
        AppLog.statsEvent("[autotest] result=ok number=\(t.number) dur=\(report.durMs)ms call_stats=\(report.json())")
        AppLog.statsEvent("[autotest] done")
        autotest = nil
    }
    #else
    private func onRegistered() {}
    #endif

    // MARK: - DEBUG loopback test

    #if DEBUG
    @Published var loopbackActive = false

    func toggleLoopbackTest() {
        if loopbackActive {
            audio.loopback = false
            audio.stop()
            // ループバック試験は CallKit を使わず自分でセッションを有効化する
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            loopbackActive = false
            AppLog.audioEvent("loopback test stopped")
        } else {
            guard call == nil else { return }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                AppLog.audioEvent("loopback session activation failed: \(error.localizedDescription)")
                return
            }
            audio.setPayloadType(0)
            audio.loopback = true
            audio.start()
            loopbackActive = true
            AppLog.audioEvent("loopback test started (mic -> G.711 -> speaker)")
        }
    }
    #endif
}

/// フィーダースレッドから読むフラグ。
private final class LinkFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var connectedInCall: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// CallKit のアクションの結果の返し口。CXAction は Sendable でないが、別の実行文脈から
/// fulfill/fail してよい。シミュレータのシムでは何もしない closure を入れる。
struct ActionResult: @unchecked Sendable {
    let callUUID: UUID
    let fulfill: () -> Void
    let fail: () -> Void

    init(callUUID: UUID, fulfill: @escaping () -> Void, fail: @escaping () -> Void) {
        self.callUUID = callUUID
        self.fulfill = fulfill
        self.fail = fail
    }

    init(_ action: CXCallAction) {
        self.init(callUUID: action.callUUID, fulfill: { action.fulfill() }, fail: { action.fail() })
    }
}

/// CXProvider のデリゲート: すべてメインアクターの CallManager に渡す。
private final class ProviderDelegate: NSObject, CXProviderDelegate {
    weak var owner: CallManager?

    init(owner: CallManager) {
        self.owner = owner
    }

    func providerDidReset(_ provider: CXProvider) {
        guard let owner else { return }
        Task { @MainActor in owner.providerDidReset() }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let owner else { action.fail(); return }
        let r = ActionResult(action)
        Task { @MainActor in owner.performAnswer(r) }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let owner else { action.fulfill(); return }
        let r = ActionResult(action)
        Task { @MainActor in owner.performEnd(r) }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard let owner else { action.fail(); return }
        let r = ActionResult(action)
        Task { @MainActor in owner.performStart(r) }
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard let owner else { action.fulfill(); return }
        let r = ActionResult(action)
        let muted = action.isMuted
        Task { @MainActor in owner.performSetMuted(muted, r) }
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        guard let owner else { action.fulfill(); return }
        let r = ActionResult(action)
        let digits = action.digits
        Task { @MainActor in owner.performPlayDTMF(digits, r) }
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        AppLog.callEvent("provider timed out performing action: \(type(of: action))")
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        guard let owner else { return }
        Task { @MainActor in owner.didActivateAudioSession() }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        guard let owner else { return }
        Task { @MainActor in owner.didDeactivateAudioSession() }
    }
}

/// PKPushRegistry のデリゲート (キューは main)。
private final class PushDelegate: NSObject, PKPushRegistryDelegate, @unchecked Sendable {
    weak var owner: CallManager?

    init(owner: CallManager) {
        self.owner = owner
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let token = VoipPush.hexToken(pushCredentials.token)
        MainActor.assumeIsolated { owner?.pushTokenUpdated(token) }
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        MainActor.assumeIsolated { owner?.pushTokenUpdated(nil) }
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType, completion: @escaping () -> Void) {
        let box = PayloadBox(payload.dictionaryPayload)
        let done = UncheckedCompletion(completion)
        MainActor.assumeIsolated {
            guard type == .voIP, let owner else {
                done.call()
                return
            }
            owner.handleVoipPush(box.value) { done.call() }
        }
    }
}

private final class PayloadBox: @unchecked Sendable {
    let value: [AnyHashable: Any]
    init(_ value: [AnyHashable: Any]) { self.value = value }
}

private final class UncheckedCompletion: @unchecked Sendable {
    private let f: () -> Void
    init(_ f: @escaping () -> Void) { self.f = f }
    func call() { f() }
}
