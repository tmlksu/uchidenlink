import Foundation
import UchidenLinkCore

/// relay との WebSocket (docs/PROTOCOL.md)。テキスト = JSON 制御、バイナリ = RTP そのまま。
///
/// スレッド:
/// - URLSession のデリゲート/完了は専用の直列キュー (`netQueue`) で受ける。
/// - **バイナリ (RTP) は netQueue 上で直接 `audioSink` に渡す** (メインスレッドを経由しない。
///   UI の処理で音声パケットの処理と到着時刻の計測が遅れないように)。
/// - テキストと接続状態の変化はメインアクターに渡す (`onEvent`)。
@MainActor
final class RelayClient: NSObject {
    enum Event {
        case connected
        /// `httpStatus` は WS 昇格前に失敗したとき (Cloudflare Access の 302/403 など) に入る。
        case disconnected(httpStatus: Int?)
        case message(RelayMessage)
    }

    var onEvent: ((Event) -> Void)?

    /// RTP の受け口 (netQueue から呼ばれる)。`arrivalNs` は受信直後の単調時計。
    nonisolated(unsafe) var audioSink: (@Sendable (Data, UInt64) -> Void)?

    /// Android の "UchidenLink/<version>-<flavor>" に合わせる (flavor の位置に OS)。
    nonisolated static let clientVersion: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        return "UchidenLink/\(version)-ios"
    }()

    private let netQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "io.github.tmlksu.uchidenlink.relay"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?
    private(set) var isConnected = false
    /// 現在のタスク (どのスレッドからも読める)。音声送信と、古い世代の完了の判定に使う。
    private let current = TaskBox()

    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionWebSocketTask?
        private var opened = false
        func set(_ task: URLSessionWebSocketTask?) { lock.withLock { self.task = task; opened = false } }
        /// このタスクで最初の受信なら true (接続済みの通知を 1 回だけ出すため)。
        func markOpened(_ t: URLSessionWebSocketTask) -> Bool {
            lock.withLock {
                guard task === t, !opened else { return false }
                opened = true
                return true
            }
        }
        func get() -> URLSessionWebSocketTask? { lock.withLock { task } }
        func isCurrent(_ t: URLSessionWebSocketTask) -> Bool { lock.withLock { task === t } }
    }

    /// 設定から接続先 URL を作る。DEBUG のモック URL が空でなければそのまま使う。
    nonisolated static func sessionURL(settings: AppSettings) -> URL? {
        let mock = settings.mockURL.trimmingCharacters(in: .whitespaces)
        if !mock.isEmpty {
            return URL(string: mock)
        }
        #if DEBUG
        let allowLoopback = true
        #else
        let allowLoopback = false
        #endif
        guard let normalized = checkRelayURL(settings.host, allowLoopbackCleartext: allowLoopback).normalizedURL else {
            return nil
        }
        return URL(string: normalized)
    }

    func connect(settings: AppSettings) {
        disconnect(notify: false)
        guard let url = Self.sessionURL(settings: settings) else {
            AppLog.connectionEvent("connect skipped: relay URL is empty or invalid")
            onEvent?(.disconnected(httpStatus: nil))
            return
        }
        var request = URLRequest(url: url)
        if settings.hasAccessToken {
            request.setValue(settings.cfClientId, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(settings.cfClientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        if !settings.devToken.isEmpty {
            request.setValue("Bearer \(settings.devToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(settings.deviceId, forHTTPHeaderField: "X-Device-Id")
        request.setValue(Self.clientVersion, forHTTPHeaderField: "X-Client-Version")

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: nil, delegateQueue: netQueue)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        current.set(task)
        AppLog.connectionEvent("connecting to \(url.scheme ?? "?")://\(url.host ?? "?") (access headers: \(settings.hasAccessToken))")
        task.resume()
        receiveLoop(task)
        startPingLoop()
    }

    func disconnect(notify: Bool = true) {
        pingTask?.cancel()
        pingTask = nil
        if let task {
            task.cancel(with: .goingAway, reason: nil)
        }
        task = nil
        current.set(nil)
        session?.invalidateAndCancel()
        session = nil
        if isConnected {
            isConnected = false
            if notify { onEvent?(.disconnected(httpStatus: nil)) }
        }
    }

    /// 送れたら true (未接続なら false)。
    @discardableResult
    func sendText(_ text: String) -> Bool {
        guard let task, isConnected else { return false }
        task.send(.string(text)) { error in
            if let error {
                AppLog.connectionEvent("send failed: \(error.localizedDescription)")
            }
        }
        return true
    }

    /// 音声送信 (どのスレッドからでも)。WS 未接続なら false (tx.lost)。
    /// `onError` は送信が失敗したときに netQueue から呼ばれる (tx.drop)。
    nonisolated func sendAudio(_ data: Data, onError: (@Sendable () -> Void)? = nil) -> Bool {
        guard let task = current.get() else { return false }
        task.send(.data(data)) { error in
            if error != nil { onError?() }
        }
        return true
    }

    // MARK: - Receive loop (netQueue)

    private nonisolated func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, self.current.isCurrent(task) else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    let now = DispatchTime.now().uptimeNanoseconds
                    self.markConnectedIfNeeded(task)
                    self.audioSink?(data, now)
                case .string(let text):
                    let msg = RelayMessage.decode(text)
                    Task { @MainActor [weak self] in
                        guard let self, self.task === task else { return }
                        self.markConnected()
                        if let msg {
                            self.onEvent?(.message(msg))
                        } else {
                            AppLog.connectionEvent("undecodable text frame")
                        }
                    }
                @unknown default:
                    break
                }
                self.receiveLoop(task)
            case .failure(let error):
                let status = (task.response as? HTTPURLResponse)?.statusCode
                Task { @MainActor [weak self] in
                    guard let self, self.task === task else { return }
                    if let status {
                        AppLog.connectionEvent("websocket failed: HTTP \(status) (\(error.localizedDescription))")
                    } else {
                        AppLog.connectionEvent("websocket failed: \(error.localizedDescription)")
                    }
                    self.teardownAfterFailure()
                    self.onEvent?(.disconnected(httpStatus: status))
                }
            }
        }
    }

    private nonisolated func markConnectedIfNeeded(_ task: URLSessionWebSocketTask) {
        guard current.markOpened(task) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.task === task, !self.isConnected else { return }
            self.markConnected()
        }
    }

    private func markConnected() {
        guard !isConnected else { return }
        isConnected = true
        AppLog.connectionEvent("websocket open")
        onEvent?(.connected)
    }

    private func teardownAfterFailure() {
        pingTask?.cancel()
        pingTask = nil
        task = nil
        current.set(nil)
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
    }

    /// WS ping を 20 秒ごと (PROTOCOL: relay は 40 秒無応答で切る)。
    /// pong が 15 秒返らなければ半死にの接続とみなして切断する (再接続は CallManager が行う)。
    private func startPingLoop() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, let task = self.task, self.isConnected else { continue }
                let pong = PongFlag()
                task.sendPing { error in
                    pong.set()
                    if let error {
                        AppLog.connectionEvent("ws ping failed: \(error.localizedDescription)")
                    }
                }
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, self.task === task else { continue }
                if !pong.isSet {
                    AppLog.connectionEvent("ws pong timeout (15s): dropping connection")
                    self.teardownAfterFailure()
                    task.cancel(with: .goingAway, reason: nil)
                    self.onEvent?(.disconnected(httpStatus: nil))
                    return
                }
            }
        }
    }

    private final class PongFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }
}
