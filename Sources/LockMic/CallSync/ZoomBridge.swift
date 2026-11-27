import AppKit
import ApplicationServices
import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "ZoomBridge")

/// Zoom sync through Accessibility: polls Zoom's Meeting menu ("Mute audio" / "Unmute audio")
/// about every 0.2 s while Zoom runs, and presses the item to change state.
/// The item is found by its language-independent identifier (`onMuteAudio:`); its state comes
/// from Zoom's own localized titles (see `ZoomMenuStrings`), so any language Zoom ships works.
@MainActor
final class ZoomBridge: CallService {
    let id = CallServiceID.zoom
    var onEvent: ((CallServiceEvent) -> Void)?
    var hasActiveCall: Bool { lastEvent?.inCall == true }
    var callCount: Int { hasActiveCall ? 1 : 0 }
    var backgroundCallTabs: Int { 0 }
    func observedMuted(truth: Bool) -> Bool? {
        guard hasActiveCall, pending == nil, let muted = lastEvent?.muted else { return nil }
        return muted
    }
    var appDetected: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }
    var status: CallServiceStatus {
        guard timer != nil else { return .off }
        guard Self.hasAccess else { return .needsAccess }
        guard appDetected else { return .waiting }
        return hasActiveCall ? .inCall : .connected
    }

    static let bundleID = "us.zoom.xos"
    private static let muteItemID = "onMuteAudio:"

    private var timer: Timer?
    private var lastEvent: CallServiceEvent?
    /// The found menu item is re-read cheaply; the full menu scan runs only occasionally.
    private var cachedItem: AXUIElement?
    private var cachedTitles = ZoomMenuStrings.Titles()
    private var lastFullScan: TimeInterval = 0
    private static let fullScanInCall: TimeInterval = 2
    /// Without a meeting, scan the menus only when Zoom's windows changed, or this often as a fallback.
    private static let fullScanIdle: TimeInterval = 5
    private var lastFingerprint = 0
    private var lastProbeAt: TimeInterval = 0
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
        cachedItem = nil
        lastEvent = nil
        pending = nil
    }

    func push(muted: Bool) {
        let seen = readState()
        log.info("push muted=\(muted, privacy: .public) trusted=\(Self.hasAccess, privacy: .public) zoomInCall=\(seen?.inCall ?? false, privacy: .public) zoomMuted=\(seen?.muted.map { String($0) } ?? "nil", privacy: .public) hasActiveCall=\(self.hasActiveCall, privacy: .public)")
        guard let state = seen, state.inCall, let item = state.item else { return }
        // Right after our own press the menu title is stale: trust what we asked for.
        guard let current = pending.map({ $0.muted }) ?? state.muted, current != muted else { return }
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
        /// `nil` when the title is in a language we could not map.
        let muted: Bool?
        let inCall: Bool
        let item: AXUIElement?
    }

    private func readState() -> ZoomState? {
        let now = ProcessInfo.processInfo.systemUptime
        if let item = cachedItem, now - lastFullScan < Self.fullScanInCall,
           let title = string(item, kAXTitleAttribute) {
            let muted: Bool? = cachedTitles.unmute.contains(title) ? true
                : cachedTitles.mute.contains(title) ? false : nil
            return ZoomState(muted: muted, inCall: true, item: item)
        }
        if cachedItem == nil {
            if now - lastProbeAt < 1 { return nil } // idle: probe windows once a second
            lastProbeAt = now
            let print = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first.map {
                AXWindowFingerprint.probe(AXUIElementCreateApplication($0.processIdentifier)).hash
            } ?? 0
            let changed = print != lastFingerprint
            lastFingerprint = print
            if !changed, now - lastFullScan < Self.fullScanIdle { return nil }
        }
        lastFullScan = now
        let state = scanMenus()
        cachedItem = state?.item
        return state
    }

    private func scanMenus() -> ZoomState? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
        else { return nil }
        let titles = ZoomMenuStrings.titles(for: app)
        cachedTitles = titles
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.3)
        guard let bar = element(root, kAXMenuBarAttribute) else { return nil }
        // Menu names are localized, so scan every menu (about 10 ms in total).
        for top in children(bar) {
            for menu in children(top) {
                for item in children(menu) {
                    let title = string(item, kAXTitleAttribute) ?? ""
                    let isMuteItem = string(item, kAXIdentifierAttribute) == Self.muteItemID
                        || titles.mute.contains(title) || titles.unmute.contains(title)
                    guard isMuteItem else { continue }
                    let muted: Bool? = titles.unmute.contains(title) ? true
                        : titles.mute.contains(title) ? false : nil
                    return ZoomState(muted: muted, inCall: true, item: item)
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
