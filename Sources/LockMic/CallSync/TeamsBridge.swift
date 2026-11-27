import AppKit
import ApplicationServices
import Foundation

/// New Microsoft Teams through Accessibility: the call window's "Mute mic" / "Unmute mic"
/// button is read every ~0.2 s and pressed on command. The button is found by its web id
/// (`microphone-button`), so the UI language does not matter for locating it. Its state comes
/// from the English labels, and for any other language from the button's structure
/// (an icon child is present while the mic is live).
@MainActor
final class TeamsBridge: CallService {
    let id = CallServiceID.teams
    var onEvent: ((CallServiceEvent) -> Void)?
    var hasActiveCall: Bool { lastEvent?.inCall == true }
    var appDetected: Bool { !Self.teamsApps.isEmpty }
    var callCount: Int { hasActiveCall ? 1 : 0 }
    var status: CallServiceStatus {
        guard timer != nil else { return .off }
        guard AXIsProcessTrusted() else { return .needsAccess }
        guard appDetected else { return .waiting }
        return hasActiveCall ? .inCall : .connected
    }

    private static let bundleID = "com.microsoft.teams2"
    private static var teamsApps: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    }
    private static let pollInterval: TimeInterval = 0.2
    private static let settleTimeout: TimeInterval = 1.5

    private var timer: Timer?
    private var lastEvent: CallServiceEvent?
    /// The found button is re-read cheaply; the window tree walk runs only occasionally.
    private var cachedButton: AXUIElement?
    private var lastFullScan: TimeInterval = 0
    private var lastFingerprint = 0
    private var lastProbeAt: TimeInterval = 0
    private static let fullScanInCall: TimeInterval = 2
    /// Without a call, walk the tree only when Teams' windows changed, or this often as a fallback.
    private static let fullScanIdle: TimeInterval = 5
    /// The button label lags behind a press; until it shows the requested state, older
    /// readings are stale, not user actions.
    private var pending: (muted: Bool, deadline: TimeInterval)?

    /// Shows the system Accessibility prompt. Called only when the user enables this integration.
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
        cachedButton = nil
        lastEvent = nil
        pending = nil
    }

    func push(muted: Bool) {
        guard let state = readMicButton() else { return }
        guard let current = pending.map({ $0.muted }) ?? state.muted, current != muted else { return }
        AXUIElementPerformAction(state.button, kAXPressAction as CFString)
        pending = (muted, ProcessInfo.processInfo.systemUptime + Self.settleTimeout)
        lastEvent = CallServiceEvent(muted: muted, inCall: true)
    }

    // MARK: - Polling

    private func poll() {
        guard AXIsProcessTrusted() else {
            lastEvent = nil
            return
        }
        let state = readMicButton()
        if let wait = pending {
            if state?.muted == wait.muted || state == nil
                || ProcessInfo.processInfo.systemUptime > wait.deadline {
                pending = nil
            } else {
                return
            }
        }
        let event = CallServiceEvent(muted: state?.muted, inCall: state != nil)
        if let last = lastEvent, last.inCall == event.inCall, last.muted == event.muted { return }
        let wasInCall = lastEvent?.inCall ?? false
        lastEvent = event
        if event.inCall || wasInCall { onEvent?(event) }
    }

    private func readMicButton() -> (muted: Bool?, button: AXUIElement)? {
        let now = ProcessInfo.processInfo.systemUptime
        if let button = cachedButton, now - lastFullScan < Self.fullScanInCall,
           let muted = quickState(of: button) {
            return (muted.value, button)
        }
        if cachedButton == nil {
            if now - lastProbeAt < 1 { return nil } // idle: probe windows once a second
            lastProbeAt = now
            let print = Self.teamsApps.first.map {
                AXWindowFingerprint.probe(AXUIElementCreateApplication($0.processIdentifier)).hash
            } ?? 0
            let changed = print != lastFingerprint
            lastFingerprint = print
            if !changed, now - lastFullScan < Self.fullScanIdle { return nil }
        }
        lastFullScan = now
        let hit = scanWindows()
        cachedButton = hit?.button
        return hit
    }

    /// One AX call (two for non-English labels). `nil` means the button is gone.
    private func quickState(of button: AXUIElement) -> (value: Bool?, ok: Bool)? {
        guard let description = string(button, "AXDescription") else {
            // No label: either gone (children unreadable too) or a language without one.
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(button, kAXChildrenAttribute as CFString, &value) == .success
            else { return nil }
            return ((value as? [AXUIElement] ?? []).isEmpty, true)
        }
        switch description {
        case "Mute mic": return (false, true)
        case "Unmute mic": return (true, true)
        default: return (children(button).isEmpty, true)
        }
    }

    private func scanWindows() -> (muted: Bool?, button: AXUIElement)? {
        guard let app = Self.teamsApps.first else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.3)
        // Web content only exposes its tree once asked.
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, true as CFTypeRef)
        var budget = 1500
        for window in children(root) where string(window, "AXRole") == "AXWindow" {
            if let hit = findMic(in: window, budget: &budget) { return hit }
        }
        return nil
    }

    private func findMic(in element: AXUIElement, budget: inout Int) -> (muted: Bool?, button: AXUIElement)? {
        budget -= 1
        if budget <= 0 { return nil }
        let description = string(element, "AXDescription")
        if string(element, "AXDOMIdentifier") == "microphone-button"
            || (string(element, "AXRole") == "AXButton" && (description == "Mute mic" || description == "Unmute mic"))
        {
            switch description {
            case "Mute mic": return (false, element)
            case "Unmute mic": return (true, element)
            default:
                // Other UI language: the live-mic button has an icon child, the muted one has none.
                return (children(element).isEmpty, element)
            }
        }
        for child in children(element) {
            if let hit = findMic(in: child, budget: &budget) { return hit }
        }
        return nil
    }

    private func string(_ el: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func children(_ el: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
