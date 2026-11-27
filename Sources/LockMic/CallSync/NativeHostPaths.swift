import Foundation

/// Keep in sync with `Sources/NativeHost/main.swift`.
enum NativeHostPaths {
    static let hostName = "com.lockmic.host"

    static var socketPath: String {
        let dir = NSHomeDirectory() + "/Library/Application Support/LockMic"
        return dir + "/sync.sock"
    }
}
