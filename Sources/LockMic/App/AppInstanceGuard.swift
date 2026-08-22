import AppKit
import Darwin

/// Ensures one LockMic process, and picks up an on-disk upgrade without a manual Quit.
enum AppInstanceGuard {
    /// Quit any other process with our bundle ID (graceful, then force).
    /// Call as early as possible at launch so the new binary wins after an install.
    static func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }
        guard !others.isEmpty else { return }

        for app in others {
            app.terminate()
        }
        // Give the other process time to stop capture and wrap the mix — a session in
        // progress needs to flush buffered audio and remux the whole file to .m4a, which
        // can take a while, so don't force-kill it mid-write.
        let deadline = Date().addingTimeInterval(20.0)
        while Date() < deadline {
            if others.allSatisfy(\.isTerminated) { break }
            usleep(50_000)
        }
        for app in others where !app.isTerminated {
            app.forceTerminate()
        }
    }

    /// `Contents/Info.plist` on disk differs from this process’s build (app was replaced while running).
    static var isRunningOutdatedBinary: Bool {
        guard let disk = diskBuildNumber() else { return false }
        let running = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return !running.isEmpty && disk != running
    }

    /// Start a fresh instance from the on-disk `.app`, then quit this process.
    @discardableResult
    static func relaunchIfOutdatedOnDisk() -> Bool {
        guard isRunningOutdatedBinary else { return false }
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            NSApp.terminate(nil)
        }
        return true
    }

    private static func diskBuildNumber() -> String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        return NSDictionary(contentsOf: url)?["CFBundleVersion"] as? String
    }
}

/// Fires when `Info.plist` is replaced (e.g. drag-install over `/Applications` while running).
final class BundleReplacementWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: CInt = -1
    private let onReplace: () -> Void

    init(onReplace: @escaping () -> Void) {
        self.onReplace = onReplace
    }

    deinit {
        stop()
    }

    func start() {
        stop()
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist").path
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.delete, .rename, .write, .extend, .attrib],
            queue: .main
        )
        let watchedFD = fd
        src.setEventHandler { [weak self] in
            // Let Finder finish the replace before reading the new plist.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self?.onReplace()
            }
        }
        src.setCancelHandler {
            if watchedFD >= 0 {
                close(watchedFD)
            }
        }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
        fd = -1
    }
}
