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
        case .talk: return L10n.hudTalking
        case .mute: return L10n.hudHoldMute
        case .flip: return L10n.hudHolding
        }
    }
}
