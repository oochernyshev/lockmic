import AppKit
import Foundation
import os.log

extension Notification.Name {
    /// Posted when available update and/or check status changes.
    static let lockMicUpdatesDidChange = Notification.Name("LockMic.updatesDidChange")
    /// Open Preferences; `object` is `PreferencesTab.rawValue`.
    static let lockMicOpenPreferencesTab = Notification.Name("LockMic.openPreferencesTab")
}

struct AppUpdateInfo: Equatable, Sendable {
    let version: String
    let releasePageURL: URL
    let dmgURL: URL?
}

enum UpdateCheckStatus: Equatable {
    case idle
    case checking
    case upToDate
    case failed
}

/// Polls GitHub Releases for a newer LockMic build (stable `latest` only).
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private enum Keys {
        static let lastCheckAt = "updateChecker.lastCheckAt"
        static let skippedVersion = "updateChecker.skippedVersion"
    }

    private let log = Logger(subsystem: "com.lockmic.app", category: "UpdateChecker")
    private let apiURL = URL(string: "https://api.github.com/repos/oochernyshev/lockmic/releases/latest")!
    private let checkInterval: TimeInterval = 24 * 60 * 60
    private var inFlight = false

    private(set) var availableUpdate: AppUpdateInfo?
    private(set) var checkStatus: UpdateCheckStatus = .idle

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private init() {}

    func start() {
        // First check shortly after launch, then whenever the app becomes active (if due).
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.checkIfDue()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
    }

    func checkIfDue() {
        if let last = UserDefaults.standard.object(forKey: Keys.lastCheckAt) as? Date,
           Date().timeIntervalSince(last) < checkInterval
        {
            return
        }
        checkNow(userInitiated: false)
    }

    /// - Parameter userInitiated: Preferences “Check for Updates…” — updates status text and re-offers skipped versions.
    func checkNow(userInitiated: Bool = false) {
        guard !inFlight else {
            if userInitiated { setStatus(.checking) }
            return
        }
        inFlight = true
        if userInitiated { setStatus(.checking) }

        Task { [weak self] in
            guard let self else { return }
            defer { self.inFlight = false }

            do {
                let info = try await self.fetchLatest()
                UserDefaults.standard.set(Date(), forKey: Keys.lastCheckAt)

                let newer = Self.isVersion(info.version, newerThan: self.currentVersion)
                let skipped = UserDefaults.standard.string(forKey: Keys.skippedVersion)

                if newer {
                    if skipped == info.version, !userInitiated {
                        self.setAvailable(nil)
                        return
                    }
                    if skipped == info.version, userInitiated {
                        UserDefaults.standard.removeObject(forKey: Keys.skippedVersion)
                    }
                    self.log.info("update available \(info.version, privacy: .public)")
                    self.setAvailable(info)
                    if userInitiated { self.setStatus(.idle) }
                } else {
                    if skipped != nil {
                        UserDefaults.standard.removeObject(forKey: Keys.skippedVersion)
                    }
                    self.setAvailable(nil)
                    if userInitiated { self.setStatus(.upToDate) }
                }
            } catch {
                self.log.error("update check failed: \(error.localizedDescription, privacy: .public)")
                if userInitiated { self.setStatus(.failed) }
            }
        }
    }

    func openUpdate() {
        guard let update = availableUpdate else { return }
        NSWorkspace.shared.open(update.dmgURL ?? update.releasePageURL)
    }

    func skipAvailableUpdate() {
        guard let version = availableUpdate?.version else { return }
        UserDefaults.standard.set(version, forKey: Keys.skippedVersion)
        setAvailable(nil)
        setStatus(.idle)
    }

    // MARK: - State

    private func setAvailable(_ info: AppUpdateInfo?) {
        guard availableUpdate != info else {
            notify()
            return
        }
        availableUpdate = info
        notify()
    }

    private func setStatus(_ status: UpdateCheckStatus) {
        guard checkStatus != status else {
            notify()
            return
        }
        checkStatus = status
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: .lockMicUpdatesDidChange, object: nil)
    }

    // MARK: - Network

    private struct ReleaseDTO: Decodable {
        let tagName: String
        let htmlURL: String
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    private func fetchLatest() async throws -> AppUpdateInfo {
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LockMic/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let dto = try JSONDecoder().decode(ReleaseDTO.self, from: data)
        let version = Self.normalizeVersion(dto.tagName)
        guard let page = URL(string: dto.htmlURL) else { throw URLError(.badURL) }
        let dmg = dto.assets
            .first { $0.name == "LockMic-\(version).dmg" || $0.name.hasSuffix(".dmg") }
            .flatMap { URL(string: $0.browserDownloadURL) }
        return AppUpdateInfo(version: version, releasePageURL: page, dmgURL: dmg)
    }

    // MARK: - Versions

    static func normalizeVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("v") { s.removeFirst() }
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            s = String(s[..<cut])
        }
        return s
    }

    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let a = normalizeVersion(lhs).split(separator: ".").map { Int($0) ?? 0 }
        let b = normalizeVersion(rhs).split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
