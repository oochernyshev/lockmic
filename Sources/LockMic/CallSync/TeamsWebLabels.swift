import Foundation

/// Mic button labels of Teams on the web, for the states the button structure cannot tell apart
/// (the guest "light meeting" page). Matched as lower-case substrings; `nil` = unknown label.
enum TeamsWebLabels {
    private static let mutedLabels = [
        "unmute", "turn mic on", "turn on mic", "turn on microphone",
        "включить микрофон", "включить звук",
    ]
    private static let liveLabels = [
        "mute mic", "turn mic off", "turn off mic", "turn off microphone",
        "отключить микрофон", "выключить микрофон",
    ]

    static func muted(for label: String) -> Bool? {
        let text = label.lowercased()
        // "Unmute" contains "mute": test the muted labels first.
        if mutedLabels.contains(where: text.contains) { return true }
        if liveLabels.contains(where: text.contains) { return false }
        return nil
    }
}
