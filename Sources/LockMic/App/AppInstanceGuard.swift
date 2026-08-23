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

        let otherPIDs = Set(others.map(\.processIdentifier))
        for app in others {
            app.terminate()
        }
        // Only wait for wrap if the other process is still recording. Otherwise
        // `isTerminated` on a cached NSRunningApplication can sit false for a long time.
        let wait: TimeInterval = RecordingSessionLock.isHeld(by: otherPIDs) ? 5.0 : 0.4
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            let still = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .contains { otherPIDs.contains($0.processIdentifier) }
            if !still { return }
            usleep(50_000)
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            where otherPIDs.contains(app.processIdentifier)
        {
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

/// PID file so a new launch can tell if the outgoing process is wrapping a mix.
enum RecordingSessionLock {
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LockMic/recording.lock", isDirectory: false)
    }

    static func acquire() {
        let file = url
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? String(ProcessInfo.processInfo.processIdentifier).write(
            to: file,
            atomically: true,
            encoding: .utf8
        )
    }

    static func release() {
        let file = url
        let mine = String(ProcessInfo.processInfo.processIdentifier)
        if let existing = try? String(contentsOf: file, encoding: .utf8),
           existing.trimmingCharacters(in: .whitespacesAndNewlines) != mine
        {
            return
        }
        try? FileManager.default.removeItem(at: file)
    }

    static func isHeld(by pids: Set<pid_t>) -> Bool {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return pids.contains(pid)
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
