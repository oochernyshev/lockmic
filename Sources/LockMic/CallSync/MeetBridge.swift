import AppKit
import ApplicationServices
import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "MeetBridge")

/// Google Meet in the browser through Accessibility. Browsers expose the page's web area with its
/// URL, so Meet is found by `meet.google.com` (any language); the mic button inside is read and
/// pressed like in the Zoom and Teams bridges. Works in Safari and Chromium browsers.
/// Only the visible tab is exposed by Chromium browsers, so that is the call that syncs.
@MainActor
final class MeetBridge: CallService {
    let id = CallServiceID.meet
    var onEvent: ((CallServiceEvent) -> Void)?
    var hasActiveCall: Bool { lastEvent?.inCall == true }
    var appDetected: Bool { !Self.runningBrowsers().isEmpty }
    var status: CallServiceStatus {
        guard timer != nil else { return .off }
        guard AXIsProcessTrusted() else { return .needsAccess }
        guard appDetected else { return .waiting }
        return hasActiveCall ? .inCall : .connected
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
    private var lastEvent: CallServiceEvent?
    private var lastButton: AXUIElement?
    private var pending: (muted: Bool, deadline: TimeInterval)?
    /// Consecutive scans without the button. A single miss (tree rebuild, busy page) is not a hang-up.
    private var misses = 0
    private static let missesToLeave = 4
    private nonisolated static let queue = DispatchQueue(label: "com.lockmic.meet-scan", qos: .userInitiated)

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
        lastButton = nil
        pending = nil
        misses = 0
    }

    func push(muted: Bool) {
        guard let button = lastButton,
              let label = Self.label(of: button), let seen = MeetLabels.muted(for: label) else { return }
        let current = pending.map { $0.muted } ?? seen
        guard current != muted else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        pending = (muted, ProcessInfo.processInfo.systemUptime + Self.settleTimeout)
        lastEvent = CallServiceEvent(muted: muted, inCall: true)
    }

    // MARK: - Polling (tree walk runs off the main thread)

    private func poll() {
        guard AXIsProcessTrusted() else { lastEvent = nil; return }
        guard !scanning else { return }
        scanning = true
        Self.queue.async { [weak self] in
            let hit = Self.scan()
            Task { @MainActor in
                self?.scanning = false
                self?.finish(hit)
            }
        }
    }

    private func finish(_ scanned: Hit?) {
        let hit = scanned
        if hit == nil, lastEvent?.inCall == true, misses < Self.missesToLeave {
            misses += 1
            return
        }
        if hit != nil { misses = 0 }
        lastButton = hit?.button
        if let wait = pending {
            if hit == nil || hit?.muted == wait.muted || ProcessInfo.processInfo.systemUptime > wait.deadline {
                pending = nil
            } else {
                return // stale label right after our own press
            }
        }
        let event = CallServiceEvent(muted: hit?.muted, inCall: hit != nil)
        if let last = lastEvent, last.inCall == event.inCall, last.muted == event.muted { return }
        let wasInCall = lastEvent?.inCall ?? false
        lastEvent = event
        log.info("event inCall=\(event.inCall, privacy: .public) muted=\(event.muted.map { String($0) } ?? "nil", privacy: .public)")
        if event.inCall || wasInCall { onEvent?(event) }
    }

    // MARK: - Accessibility

    private nonisolated static func runningBrowsers() -> [NSRunningApplication] {
        browserIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
    }

    private nonisolated static func scan() -> Hit? {
        for app in runningBrowsers() {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.5)
            // Chromium builds the web tree only for assistive tech that asks.
            AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)
            var budget = 12000
            if let hit = search(root, inMeet: false, budget: &budget) { return hit }
        }
        return nil
    }

    private nonisolated static func search(_ el: AXUIElement, inMeet: Bool, budget: inout Int) -> Hit? {
        budget -= 1
        if budget <= 0 { return nil }
        let role = string(el, "AXRole")
        var inMeet = inMeet
        if role == "AXWebArea" {
            inMeet = url(el)?.host == "meet.google.com"
            if !inMeet { return nil } // skip other tabs entirely
        }
        if inMeet, role == "AXButton",
           let label = label(of: el), let muted = MeetLabels.muted(for: label) {
            return Hit(muted: muted, button: el)
        }
        for child in children(el) {
            if let hit = search(child, inMeet: inMeet, budget: &budget) { return hit }
        }
        return nil
    }

    private nonisolated static func label(of el: AXUIElement) -> String? {
        string(el, "AXDescription") ?? string(el, "AXTitle")
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
