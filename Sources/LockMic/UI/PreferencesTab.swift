import Foundation

enum PreferencesTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case devices
    case keyboard
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .devices: return "Devices"
        case .keyboard: return "Keyboard"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .devices: return "mic.fill"
        case .keyboard: return "keyboard"
        case .about: return "info.circle"
        }
    }
}
