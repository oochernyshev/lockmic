import AppKit
import ApplicationServices
import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "ZoomBridge")

/// Zoom sync through Accessibility: polls Zoom's Meeting menu ("Mute audio" / "Unmute audio")
/// about every 0.2 s while Zoom runs, and presses the item to change state.
/// Titles are matched in English only; other Zoom languages simply never report a call.
@MainActor
final class ZoomBridge: CallService {
    let id = CallServiceID.zoom
    var onEvent: ((CallServiceEvent) -> Void)?
    var hasActiveCall: Bool { lastEvent?.inCall == true }
    var status: CallServiceStatus {
        guard timer != nil else { return .off }
        guard Self.hasAccess else { return .needsAccess }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        else { return .waiting }
        return hasActiveCall ? .inCall : .connected
    }

    static let bundleID = "us.zoom.xos"
    private static let muteTitle = "Mute audio"
    private static let unmuteTitle = "Unmute audio"

    private var timer: Timer?
    private var lastEvent: CallServiceEvent?
    /// Zoom renames the menu item ~400-500 ms after a press. Until it shows the state we
    /// asked for (or the deadline passes) older readings are stale, not user actions.
    private var pending: (muted: Bool, deadline: TimeInterval)?
    private static let pollInterval: TimeInterval = 0.2
    private static let settleTimeout: TimeInterval = 1.5

    /// Shows the system Accessibility prompt. Call only when the user enables this integration.
    static func requestAccess() -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static var hasAccess: Bool { AXIsProcessTrusted() }

    func start() {
        guard timer == nil else { return }
        _ = Self.requestAccess()
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
        pending = nil
    }

    func push(muted: Bool) {
        let seen = readState()
        log.info("push muted=\(muted, privacy: .public) trusted=\(Self.hasAccess, privacy: .public) zoomInCall=\(seen?.inCall ?? false, privacy: .public) zoomMuted=\(seen.map { String($0.muted) } ?? "nil", privacy: .public) hasActiveCall=\(self.hasActiveCall, privacy: .public)")
        guard let state = seen, state.inCall, let item = state.item else { return }
        // Right after our own press the menu title is stale: trust what we asked for.
        let current = pending.map { $0.muted } ?? state.muted
        guard current != muted else { return }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        pending = (muted, ProcessInfo.processInfo.systemUptime + Self.settleTimeout)
        lastEvent = CallServiceEvent(muted: muted, inCall: true)
    }

    // MARK: - Polling

    private func poll() {
        guard Self.hasAccess else { return }
        let state = readState()
        if let wait = pending {
            if state?.muted == wait.muted || state?.inCall != true
                || ProcessInfo.processInfo.systemUptime > wait.deadline {
                pending = nil
            } else {
                return // stale title right after our own press
            }
        }
        let event = CallServiceEvent(muted: state?.muted, inCall: state?.inCall ?? false)
        if let last = lastEvent, last.inCall == event.inCall, last.muted == event.muted { return }
        let wasInCall = lastEvent?.inCall ?? false
        lastEvent = event
        log.info("event inCall=\(event.inCall, privacy: .public) muted=\(event.muted.map { String($0) } ?? "nil", privacy: .public)")
        if event.inCall || wasInCall { onEvent?(event) }
    }

    private struct ZoomState {
        let muted: Bool
        let inCall: Bool
        let item: AXUIElement?
    }

    private func readState() -> ZoomState? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
        else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.3)
        guard let bar = element(root, kAXMenuBarAttribute) else { return nil }
        let tops = children(bar)
        // Mute lives in the "Meeting" menu; scanning only it keeps the 0.5 s poll cheap.
        let meeting = tops.filter { string($0, kAXTitleAttribute) == "Meeting" }
        for top in (meeting.isEmpty ? tops : meeting) {
            for menu in children(top) {
                for item in children(menu) {
                    guard let title = string(item, kAXTitleAttribute) else { continue }
                    if title == Self.muteTitle { return ZoomState(muted: false, inCall: true, item: item) }
                    if title == Self.unmuteTitle { return ZoomState(muted: true, inCall: true, item: item) }
                }
            }
        }
        return nil
    }

    private func string(_ el: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func children(_ el: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
