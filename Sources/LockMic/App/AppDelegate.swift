import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = PreferencesStore()
    private lazy var mic = MicController(preferences: preferences)
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only — hide dock icon for agent-style utility.
        NSApp.setActivationPolicy(.accessory)

        let status = StatusItemController(mic: mic, preferences: preferences)
        status.start()
        statusItemController = status

        // Initial icon/HUD sync without toast
        status.handleMuteChanged(showHUD: false)

        UsageReporter.start(
            shareEnabled: preferences.shareAnonymousUsage,
            hudMode: UsageReporter.hudMode(
                enabled: preferences.hudEnabled,
                floating: preferences.hudFloating
            )
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        UsageReporter.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}
