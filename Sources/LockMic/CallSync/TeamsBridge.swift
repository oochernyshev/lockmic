import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "TeamsBridge")

/// New Microsoft Teams, via its official local "third-party app API" (Settings → Privacy →
/// Manage API). Teams listens on ws://127.0.0.1:8124, asks the user once to allow the
/// connection, then hands out a token that is stored and reused.
@MainActor
final class TeamsBridge: CallService {
    let id = CallServiceID.teams
    var onEvent: ((CallServiceEvent) -> Void)?
    var hasActiveCall: Bool { connected && inMeeting }

    private let preferences: PreferencesStore
    private var task: URLSessionWebSocketTask?
    private var running = false
    private var connected = false
    private var inMeeting = false
    private var isMuted: Bool?
    private var requestID = 0
    private var retryWork: DispatchWorkItem?
    private var retryDelay: TimeInterval = 2

    init(preferences: PreferencesStore) {
        self.preferences = preferences
    }

    func start() {
        guard !running else { return }
        running = true
        connect()
    }

    func stop() {
        running = false
        retryWork?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
        inMeeting = false
        isMuted = nil
    }

    func push(muted: Bool) {
        guard hasActiveCall, isMuted != muted else { return }
        sendAction("toggle-mute")
    }

    // MARK: - Connection

    private func connect() {
        guard running else { return }
        var comps = URLComponents()
        comps.scheme = "ws"
        comps.host = "127.0.0.1"
        comps.port = 8124
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        var items = [
            URLQueryItem(name: "protocol-version", value: "2.0.0"),
            URLQueryItem(name: "manufacturer", value: "LockMic"),
            URLQueryItem(name: "device", value: "Mac"),
            URLQueryItem(name: "app", value: "LockMic"),
            URLQueryItem(name: "app-version", value: version),
        ]
        let token = preferences.teamsAPIToken
        if !token.isEmpty { items.insert(URLQueryItem(name: "token", value: token), at: 0) }
        comps.queryItems = items
        guard let url = comps.url else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                switch result {
                case .failure:
                    self.disconnected()
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.receive(on: task)
                }
            }
        }
    }

    private func disconnected() {
        let wasInMeeting = hasActiveCall
        connected = false
        inMeeting = false
        isMuted = nil
        task = nil
        if wasInMeeting { onEvent?(CallServiceEvent(muted: nil, inCall: false)) }
        guard running else { return }
        // Teams not running / API off: retry quietly with backoff.
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
        retryDelay = min(retryDelay * 2, 30)
    }

    private func handle(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        if let token = obj["tokenRefresh"] as? String, !token.isEmpty {
            preferences.teamsAPIToken = token
        }
        if !connected {
            connected = true
            retryDelay = 2
            sendAction("query-state")
        }
        guard let update = obj["meetingUpdate"] as? [String: Any],
              let state = update["meetingState"] as? [String: Any] else { return }
        inMeeting = state["isInMeeting"] as? Bool ?? false
        isMuted = state["isMuted"] as? Bool
        onEvent?(CallServiceEvent(muted: isMuted, inCall: inMeeting))
    }

    private func sendAction(_ action: String) {
        requestID += 1
        let payload: [String: Any] = [
            "action": action,
            "parameters": [String: Any](),
            "requestId": requestID,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }
}
