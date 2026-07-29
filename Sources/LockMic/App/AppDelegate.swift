import AppKit
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "App")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = PreferencesStore()
    private lazy var mic = MicController(preferences: preferences)
    private var statusItemController: StatusItemController?
    private var dockPreferenceObserver: NSObjectProtocol?
    /// Optimistic until the first menu-bar geometry sample.
    private var menuBarIconVisible = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        let status = StatusItemController(mic: mic, preferences: preferences)
        status.onMenuBarIconVisibilityChange = { [weak self] visible in
            self?.setMenuBarIconVisible(visible)
        }
        status.start()
        statusItemController = status
        status.handleMuteChanged(showHUD: false)
        applyActivationPolicy()

        dockPreferenceObserver = NotificationCenter.default.addObserver(
            forName: .lockMicShowInDockDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyActivationPolicy()
            }
        }

        UsageReporter.start(
            shareEnabled: preferences.shareAnonymousUsage,
            hudMode: UsageReporter.hudMode(
                enabled: preferences.hudEnabled,
                floating: preferences.hudFloating
            )
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let dockPreferenceObserver {
            NotificationCenter.default.removeObserver(dockPreferenceObserver)
        }
        UsageReporter.flush()
    }

    /// Dock left-click: toggle mute (Preferences via right-click menu).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItemController?.handleDockClick()
        return true
    }

    /// Dock right-click: same menu as the status item (prefs, floating HUD, …).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        statusItemController?.makeDockMenu()
    }

    func setMenuBarIconVisible(_ visible: Bool) {
        guard menuBarIconVisible != visible else { return }
        menuBarIconVisible = visible
        log.info("menu bar icon visible=\(visible, privacy: .public)")
        applyActivationPolicy()
    }

    /// Dock when user prefers it, or the menu bar icon is not usable (camera housing / overcrowding).
    func applyActivationPolicy() {
        let showDock = preferences.showInDock || !menuBarIconVisible
        let policy: NSApplication.ActivationPolicy = showDock ? .regular : .accessory
        let changed = NSApp.activationPolicy() != policy
        if changed {
            NSApp.setActivationPolicy(policy)
        }
        // `.regular` resets applicationIconImage to the bundle icon.
        if showDock {
            statusItemController?.refreshDockIcon()
            if changed {
                DispatchQueue.main.async { [weak self] in
                    self?.statusItemController?.refreshDockIcon()
                }
            }
        }
    }
}
