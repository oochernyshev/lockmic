import Foundation

/// Best-effort: how LockMic was installed (drives Preferences update copy).
enum AppInstallMethod: Equatable {
    case appStore
    case homebrew
    case direct
    case unknown

    static func detect(bundleURL: URL = Bundle.main.bundleURL) -> AppInstallMethod {
        let path = bundleURL.resolvingSymlinksInPath().path

        if path.contains("/DerivedData/") || path.contains("/build/") {
            return .unknown
        }

        // Mac App Store builds contain Apple's receipt inside the app bundle.
        // Check this before the /Applications heuristic, since Store apps live there too.
        let receiptURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("_MASReceipt", isDirectory: true)
            .appendingPathComponent("receipt", isDirectory: false)
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            return .appStore
        }

        if path.localizedCaseInsensitiveContains("/Caskroom/lockmic/") {
            return .homebrew
        }

        let caskroomExists =
            FileManager.default.fileExists(atPath: "/opt/homebrew/Caskroom/lockmic")
            || FileManager.default.fileExists(atPath: "/usr/local/Caskroom/lockmic")

        let inApps = path.hasPrefix("/Applications/")
            || path.hasPrefix(NSHomeDirectory() + "/Applications/")

        if caskroomExists, inApps { return .homebrew }
        if inApps { return .direct }
        return .unknown
    }
}
