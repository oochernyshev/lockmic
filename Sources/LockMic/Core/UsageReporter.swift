import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "Usage")

/// Anonymous GA4 Measurement Protocol — one network hit per action (and on launch/quit).
@MainActor
enum UsageReporter {
    /// How the HUD is configured at report time.
    enum HUDMode: String {
        /// No toast and no floating indicator.
        case hidden
        /// Toast HUD on mute actions (not always on).
        case visible
        /// Always-on floating HUD.
        case persistent
    }

    /// How a user action was triggered.
    enum ActivationSource: String {
        case keyboard
        case hud
        /// Left-click on the menu bar status item.
        case menuBar = "menu_bar"
        /// Item in the status-item context menu.
        case menu
    }

    enum Action: String, CaseIterable {
        case toggle
        case mute
        case unmute
        case pushToTalk
        case pushToMute
        case pushToFlip
        case openPreferences

        /// GA4 event name (snake_case, ≤40 chars).
        var eventName: String {
            switch self {
            case .toggle: return "action_toggle"
            case .mute: return "action_mute"
            case .unmute: return "action_unmute"
            case .pushToTalk: return "action_push_to_talk"
            case .pushToMute: return "action_push_to_mute"
            case .pushToFlip: return "action_push_to_flip"
            case .openPreferences: return "action_open_preferences"
            }
        }
    }

    private enum Config {
        static let measurementID = "G-0ZRQC93T49"
        static let apiSecret = "FKDW0mhXTba00epDCorSbA"
        static let collectURL = URL(string: "https://www.google-analytics.com/mp/collect")!
    }

    private enum Keys {
        static let clientID = "usage.clientId"
    }

    private static var shareEnabled = true
    /// Shared session so rapid actions reuse connections.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()

    // MARK: - Public API

    /// Call once at launch after preferences are loaded.
    static func start(shareEnabled: Bool, hudMode: HUDMode) {
        self.shareEnabled = shareEnabled
        guard shareEnabled else {
            log.debug("Usage reporting disabled by preference")
            return
        }

        var params = baseParams()
        params["hud_mode"] = hudMode.rawValue
        send(events: [event(name: "app_start", params: params)])
    }

    static func setShareEnabled(_ enabled: Bool) {
        shareEnabled = enabled
    }

    /// Fire-and-forget: send this action to GA4 immediately.
    static func record(_ action: Action, source: ActivationSource) {
        guard shareEnabled else { return }

        var params = baseParams()
        params["action"] = action.rawValue
        params["activation_source"] = source.rawValue
        send(events: [event(name: action.eventName, params: params)])
    }

    /// Send `app_quit` on terminate. Blocks briefly so the request can finish before exit.
    static func flush() {
        guard shareEnabled else { return }
        send(events: [event(name: "app_quit", params: baseParams())], waitUpTo: 2)
    }

    /// Map preference flags to a single HUD mode for analytics.
    static func hudMode(enabled: Bool, floating: Bool) -> HUDMode {
        if floating { return .persistent }
        if enabled { return .visible }
        return .hidden
    }

    // MARK: - Network

    /// - Parameter waitUpTo: if non-nil, block until the request finishes or the timeout elapses (for quit).
    private static func send(events: [[String: Any]], waitUpTo timeout: TimeInterval? = nil) {
        guard !events.isEmpty else { return }

        let clientID = ensureClientID()
        let body: [String: Any] = [
            "client_id": clientID,
            "non_personalized_ads": true,
            "events": events,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            log.error("Failed to encode usage payload")
            return
        }

        var components = URLComponents(url: Config.collectURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "measurement_id", value: Config.measurementID),
            URLQueryItem(name: "api_secret", value: Config.apiSecret),
        ]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        if let timeout {
            request.timeoutInterval = timeout
        }

        let names = events.compactMap { $0["name"] as? String }.joined(separator: ",")
        log.debug("Sending usage events: \(names, privacy: .public)")

        if let timeout {
            let semaphore = DispatchSemaphore(value: 0)
            session.dataTask(with: request) { _, response, error in
                if let error {
                    log.debug("Usage report failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    log.debug("Usage report HTTP \(code)")
                }
                semaphore.signal()
            }.resume()
            _ = semaphore.wait(timeout: .now() + timeout)
        } else {
            session.dataTask(with: request) { _, response, error in
                if let error {
                    log.debug("Usage report failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                log.debug("Usage report HTTP \(code)")
            }.resume()
        }
    }

    // MARK: - Helpers

    private static func ensureClientID() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: Keys.clientID), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: Keys.clientID)
        return id
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func baseParams() -> [String: Any] {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return [
            "engagement_time_msec": 1,
            "app_version": version,
            "os_version": osVersion,
            "platform": "macos",
            "report_day": dayString(Date()),
        ]
    }

    private static func event(name: String, params: [String: Any]) -> [String: Any] {
        [
            "name": name,
            "params": params,
        ]
    }
}
