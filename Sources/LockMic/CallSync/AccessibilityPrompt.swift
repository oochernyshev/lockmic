import ApplicationServices
import Foundation

/// The one place that shows macOS's Accessibility permission dialog.
@MainActor
enum AccessibilityPrompt {
    private static var askedThisRun = false

    /// Asks at most once per app run, and only while access is missing. Sync sources call this when
    /// they start, so a prompt the setup wizard already showed is not repeated at finish.
    static func requestOnce() {
        guard !AXIsProcessTrusted(), !askedThisRun else { return }
        askedThisRun = true
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// The person pressed a button: always show the dialog while access is missing.
    static func requestNow() {
        guard !AXIsProcessTrusted() else { return }
        askedThisRun = true
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}
