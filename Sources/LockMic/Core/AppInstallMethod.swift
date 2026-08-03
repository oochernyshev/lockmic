import Foundation

/// Best-effort: how LockMic was installed (drives Preferences update copy).
enum AppInstallMethod: Equatable {
    case homebrew
    case direct
    case unknown

    static func detect(bundleURL: URL = Bundle.main.bundleURL) -> AppInstallMethod {
        let path = bundleURL.resolvingSymlinksInPath().path

        if path.contains("/DerivedData/") || path.contains("/build/") {
            return .unknown
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
