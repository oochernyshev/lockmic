import AppKit
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "App")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let audio = AudioDeviceService()
    private let preferences = PreferencesStore()
    private lazy var mic = MicController(audio: audio, preferences: preferences)
    private lazy var recorder = SessionRecorder(audio: audio, mic: mic)
    private var statusItemController: StatusItemController?
    private var dockPreferenceObserver: NSObjectProtocol?
    /// Optimistic until the first menu-bar geometry sample.
    private var menuBarIconVisible = true
    /// Relaunch when the user replaces the .app on disk while we are still running.
    private var bundleReplacementWatcher: BundleReplacementWatcher?
    /// True while stop is running so a second Quit keeps waiting.
    private var isFinalizingForQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // If Finder replaced us on disk before this process fully started, hop to the new binary.
        if AppInstanceGuard.relaunchIfOutdatedOnDisk() {
            return
        }

        bundleReplacementWatcher = BundleReplacementWatcher {
            AppInstanceGuard.relaunchIfOutdatedOnDisk()
        }
        bundleReplacementWatcher?.start()

        let status = StatusItemController(mic: mic, preferences: preferences, recorder: recorder)
        status.onMenuBarIconVisibilityChange = { [weak self] visible in
            self?.setMenuBarIconVisible(visible)
        }
        status.start()
        statusItemController = status
        status.handleMuteChanged(showHUD: false)
        applyActivationPolicy()

        // Periodic GitHub release check → menu-bar / Dock badge when a newer version exists.
        UpdateChecker.shared.start()

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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isFinalizingForQuit {
            return .terminateLater
        }
        guard recorder.isBusy else {
            return .terminateNow
        }
        isFinalizingForQuit = true
        Task { @MainActor in
            if let status = self.statusItemController {
                await status.finalizeRecordingForQuit()
            } else {
                _ = await self.recorder.finalizeAndMix()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Mix wrap already ran in `applicationShouldTerminate`. A sync HAL
        // teardown on main here can deadlock the quit.
        bundleReplacementWatcher?.stop()
        bundleReplacementWatcher = nil
        if let dockPreferenceObserver {
            NotificationCenter.default.removeObserver(dockPreferenceObserver)
        }
        UsageReporter.flush()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        _ = AppInstanceGuard.relaunchIfOutdatedOnDisk()
    }

    /// Dock left-click: toggle mute (Preferences via right-click menu).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if AppInstanceGuard.relaunchIfOutdatedOnDisk() {
            return false
        }
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
