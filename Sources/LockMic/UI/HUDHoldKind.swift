import Foundation

/// Why the HUD is held on-screen (momentary shortcuts).
enum HUDHoldKind: Equatable, Sendable {
    case none
    case talk
    case mute
    case flip

    var caption: String? {
        switch self {
        case .none: return nil
        case .talk: return "Talking"
        case .mute: return "Hold mute"
        case .flip: return "Holding"
        }
    }
}
