import AppKit
import ApplicationServices
import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "BrowserCallBridge")

/// How a web call service is recognised inside a browser page.
struct BrowserCallProfile: Sendable {
    let id: CallServiceID
    /// Is this page (by URL) the service?
    let pageMatches: @Sendable (URL?) -> Bool
    /// Lower-case word in a window title that hints at the service (Picture-in-Picture window,
    /// or a page where a call may start). `nil`: no hint.
    let titleHint: String?
    /// Blank-URL windows whose title has the hint count as the service (Meet's Picture-in-Picture).
    let acceptsBlankPiP: Bool
    /// `true` = muted, `false` = live, `nil` = not the mic button.
    let micState: @Sendable (AXUIElement) -> Bool?

    static let meet = BrowserCallProfile(
        id: .meet,
        pageMatches: { $0?.host == "meet.google.com" },
        titleHint: "meet",
        acceptsBlankPiP: true,
        micState: { button in
            guard AXString.value(button, "AXRole") == "AXButton",
                  let label = AXString.value(button, "AXDescription") ?? AXString.value(button, "AXTitle")
            else { return nil }
            return MeetLabels.muted(for: label)
        }
    )

    static let teams = BrowserCallProfile(
        id: .teams,
        pageMatches: { url in
            guard let host = url?.host else { return false }
            return host == "teams.live.com" || host == "teams.microsoft.com"
                || host.hasSuffix(".teams.microsoft.com") || host == "teams.cloud.microsoft"
        },
        titleHint: "teams",
        acceptsBlankPiP: false,
        micState: { button in
            guard AXString.value(button, "AXDOMIdentifier") == "microphone-button" else { return nil }
            switch AXString.value(button, "AXDescription") {
            case "Mute mic": return false
            case "Unmute mic": return true
            default: return AXString.childCount(button) == 0 // other UI language: no icon child = muted
            }
        }
    )
}

enum AXString {
    static func value(_ el: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    static func childCount(_ el: AXUIElement) -> Int {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success
        else { return 0 }
        return (value as? [AXUIElement])?.count ?? 0
    }
}

/// A web call service (Google Meet, Teams in the browser) through Accessibility. Browsers expose
/// each page's web area with its URL, so the page is found by address in any UI language; the mic
/// button inside is read and pressed like in the Zoom and Teams app bridges. Works in Safari and
/// Chromium browsers. Every call found (tabs in Safari, the visible tab of Chromium browsers,
/// Picture-in-Picture windows, several browsers) is kept in the same mute state, since there is
/// only one microphone.
@MainActor
final class BrowserCallBridge: CallService {
    let profile: BrowserCallProfile
    var id: CallServiceID { profile.id }
    var onEvent: ((CallServiceEvent) -> Void)?
    var hasActiveCall: Bool { lastEvent?.inCall == true }
    /// A page of this service is open in some browser (even before joining a call).
    private(set) var appDetected = false
    var status: CallServiceStatus {
        guard timer != nil else { return .off }
        guard AXIsProcessTrusted() else { return .needsAccess }
        guard appDetected else { return .waiting }
        return hasActiveCall ? .inCall : .connected
    }

    init(profile: BrowserCallProfile) {
        self.profile = profile
    }

    static let browserIDs = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "org.chromium.Chromium",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    private static let pollInterval: TimeInterval = 0.3
    private static let settleTimeout: TimeInterval = 1.5

    private struct Hit: @unchecked Sendable {
        let muted: Bool
        let button: AXUIElement
    }

    private var timer: Timer?
    private var scanning = false
    /// Full tree scans are costly: rare while in a call (cached buttons are re-read in between)
    /// and slow while idle.
    private var lastFullScan: TimeInterval = 0
    private var lastFingerprint = 0
    private var lastHinted = false
    private var lastProbeAt: TimeInterval = 0
    /// In a call the quick path notices a vanished button; new calls change the window fingerprint.
    private static let fullScanInCall: TimeInterval = 15
    /// While a window title carries the profile hint scan often; otherwise only on change or rarely.
    private static let fullScanHinted: TimeInterval = 1.5
    private static let fullScanForced: TimeInterval = 10
    private var lastEvent: CallServiceEvent?
    /// Last known mute state of every call seen in the previous scan, keyed by its button.
    private var calls: [AXUIElement: Bool] = [:]
    private var pending: (muted: Bool, deadline: TimeInterval)?
    /// Consecutive scans without the button. A single miss (tree rebuild, busy page) is not a hang-up.
    private var misses = 0
    private static let missesToLeave = 4
    private nonisolated static let queue = DispatchQueue(label: "com.lockmic.browser-call-scan", qos: .userInitiated)

    func start() {
        guard timer == nil else { return }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastEvent = nil
        calls = [:]
        pending = nil
        misses = 0
    }

    func push(muted: Bool) {
        var pressed = false
        for (button, _) in calls where press(button, toMuted: muted) { pressed = true }
        guard pressed else { return }
        pending = (muted, ProcessInfo.processInfo.systemUptime + Self.settleTimeout)
        lastEvent = CallServiceEvent(muted: muted, inCall: true)
    }

    /// Presses `button` if its label says it is not yet in the wanted state.
    @discardableResult
    private func press(_ button: AXUIElement, toMuted muted: Bool) -> Bool {
        guard let seen = profile.micState(button), seen != muted else { return false }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        return true
    }

    // MARK: - Polling (tree walk runs off the main thread)

    private func poll() {
        guard AXIsProcessTrusted() else { lastEvent = nil; return }
        guard !scanning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let lastFull = lastFullScan
        let lastPrint = lastFingerprint
        let lastHinted = lastHinted
        let probeDue = now - lastProbeAt >= 1 // window probe once a second; quick reads run more often
        let inCall = !calls.isEmpty
        let cached = calls.keys.map { Hit(muted: false, button: $0) }
        let profile = profile
        scanning = true
        Self.queue.async { [weak self] in
            let print = probeDue ? Self.fingerprint(hint: profile.titleHint) : (hash: lastPrint, hinted: lastHinted)
            let interval = inCall ? Self.fullScanInCall
                : (print.hinted ? Self.fullScanHinted : Self.fullScanForced)
            let full = print.hash != lastPrint || now - lastFull >= interval
            var hits: [Hit]?
            var pageSeen: Bool?
            if full {
                let result = Self.scan(profile)
                hits = result.hits
                pageSeen = result.pageSeen
            } else if inCall {
                hits = Self.quickScan(cached, profile)
            } else {
                hits = nil // nothing changed and no call: skip the tree walk
            }
            let skipped = !full && !inCall
            Task { @MainActor in
                guard let self else { return }
                self.scanning = false
                self.lastFingerprint = print.hash
                self.lastHinted = print.hinted
                if probeDue { self.lastProbeAt = now }
                if full { self.lastFullScan = now }
                if let pageSeen { self.appDetected = pageSeen }
                if skipped { return }
                if let hits {
                    self.finish(hits)
                } else {
                    self.lastFullScan = 0 // cached button went stale: rescan next tick
                }
            }
        }
    }

    private func finish(_ hits: [Hit]) {
        if hits.isEmpty, lastEvent?.inCall == true, misses < Self.missesToLeave {
            misses += 1
            lastFullScan = 0
            return
        }
        if !hits.isEmpty { misses = 0 }
        let previous = calls
        calls = Dictionary(hits.map { ($0.button, $0.muted) }, uniquingKeysWith: { _, last in last })

        let synced = lastEvent?.muted
        if let wait = pending {
            let settled = hits.allSatisfy { $0.muted == wait.muted }
            if hits.isEmpty || settled || ProcessInfo.processInfo.systemUptime > wait.deadline {
                pending = nil
            } else {
                return // stale labels right after our own press
            }
        }

        // A call that appeared while others are running adopts the current synced state.
        if lastEvent?.inCall == true, let synced {
            for hit in hits where previous[hit.button] == nil && hit.muted != synced {
                press(hit.button, toMuted: synced)
            }
        }

        // The state a user just changed in any call; unchanged calls do not vote.
        let changed = hits.filter { previous[$0.button] != nil && previous[$0.button] != $0.muted }
        let muted = changed.last?.muted ?? (lastEvent?.inCall == true ? lastEvent?.muted : hits.first?.muted)
        let event = CallServiceEvent(muted: muted, inCall: !hits.isEmpty)
        if let last = lastEvent, last.inCall == event.inCall, last.muted == event.muted { return }
        let wasInCall = lastEvent?.inCall ?? false
        lastEvent = event
        log.info("event inCall=\(event.inCall, privacy: .public) muted=\(event.muted.map { String($0) } ?? "nil", privacy: .public) calls=\(hits.count, privacy: .public)")
        if event.inCall || wasInCall { onEvent?(event) }
    }

    // MARK: - Accessibility

    private nonisolated static func runningBrowsers() -> [NSRunningApplication] {
        browserIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
    }

    /// Window titles/sizes of every running browser, hashed. `hinted`: some title carries the hint.
    private nonisolated static func fingerprint(hint: String?) -> (hash: Int, hinted: Bool) {
        var hasher = Hasher()
        var hinted = false
        for app in runningBrowsers() {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.5)
            let probe = AXWindowFingerprint.probe(root)
            hasher.combine(app.processIdentifier)
            hasher.combine(probe.hash)
            if let hint, probe.titles.contains(where: { $0.localizedCaseInsensitiveContains(hint) }) { hinted = true }
        }
        return (hasher.finalize(), hinted)
    }

    /// Re-reads the state of already known buttons. `nil` when any of them is gone.
    private nonisolated static func quickScan(_ cached: [Hit], _ profile: BrowserCallProfile) -> [Hit]? {
        var hits: [Hit] = []
        for known in cached {
            guard let muted = profile.micState(known.button) else { return nil }
            hits.append(Hit(muted: muted, button: known.button))
        }
        return hits
    }

    /// `pageSeen`: some page of the service is open, whether or not a call is running.
    private nonisolated static func scan(_ profile: BrowserCallProfile) -> (hits: [Hit], pageSeen: Bool) {
        var found: [Hit] = []
        var pageSeen = false
        for app in runningBrowsers() {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.5)
            // Chromium builds the web tree only for assistive tech that asks.
            AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)
            var budget = 12000
            for window in children(root) where string(window, "AXRole") == "AXWindow" {
                // Meet's Picture-in-Picture window has a blank URL but a "Meet – …" title.
                let pip = profile.acceptsBlankPiP && profile.titleHint.map {
                    string(window, "AXTitle")?.localizedCaseInsensitiveContains($0) == true
                } == true
                search(window, profile, inPage: false, pipWindow: pip, budget: &budget,
                       into: &found, pageSeen: &pageSeen)
            }
        }
        return (found, pageSeen)
    }

    private nonisolated static func search(
        _ el: AXUIElement, _ profile: BrowserCallProfile, inPage: Bool, pipWindow: Bool,
        budget: inout Int, into found: inout [Hit], pageSeen: inout Bool
    ) {
        budget -= 1
        if budget <= 0 { return }
        let role = string(el, "AXRole")
        var inPage = inPage
        if role == "AXWebArea" {
            let page = url(el)
            inPage = profile.pageMatches(page)
                || (pipWindow && (page == nil || page?.scheme == "about"))
            if !inPage { return } // skip other pages entirely
            pageSeen = true
        }
        if inPage, let muted = profile.micState(el) {
            found.append(Hit(muted: muted, button: el))
            return // one mic button per call
        }
        for child in children(el) {
            search(child, profile, inPage: inPage, pipWindow: pipWindow, budget: &budget,
                   into: &found, pageSeen: &pageSeen)
        }
    }

    private nonisolated static func url(_ el: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXURL" as CFString, &value) == .success else { return nil }
        return value as? URL
    }

    private nonisolated static func string(_ el: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private nonisolated static func children(_ el: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
