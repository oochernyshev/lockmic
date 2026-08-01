import AppKit

/// Retained for the process lifetime — `NSApplication.delegate` is weak.
private var retainedAppDelegate: AppDelegate?

@main
enum LockMicMain {
    static func main() {
        // New install / `open -n`: take over so the previous process does not keep running.
        AppInstanceGuard.terminateOtherInstances()

        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedAppDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}
