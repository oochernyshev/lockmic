import Foundation

enum PreferencesTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case devices
    case keyboard
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.tabGeneral
        case .devices: return L10n.tabDevices
        case .keyboard: return L10n.tabKeyboard
        case .about: return L10n.tabAbout
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
