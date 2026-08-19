import Foundation

struct HotkeyChord: Equatable, Sendable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32

    var displayString: String {
        HotkeyManager.displayString(keyCode: keyCode, modifiers: modifiers)
    }

    var isEmpty: Bool {
        keyCode == 0 && modifiers == 0
    }
}

enum HotkeyAction: String, Sendable {
    case toggle
    case mute
    case unmute
    case startRecording
    case stopRecording
    /// Hold to unmute; release restores prior mute state.
    case pushToTalk
    /// Hold to mute; release restores prior mute state.
    case pushToMute
    /// Hold to invert mute; release restores prior mute state (UI: “Push to flip”).
    case pushToToggle

    var isMomentary: Bool {
        switch self {
        case .pushToTalk, .pushToMute, .pushToToggle: return true
        default: return false
        }
    }
}

enum HotkeyPhase: String, Sendable {
    case pressed
    case released
}

struct HotkeyBinding: Equatable, Sendable {
    var enabled: Bool
    var chord: HotkeyChord
    var action: HotkeyAction

    var isActive: Bool {
        enabled && !chord.isEmpty
    }
}

/// One user-editable shortcut row (enable + chord).
struct HotkeyPref: Equatable, Sendable {
    var enabled: Bool
    var chord: HotkeyChord
}
