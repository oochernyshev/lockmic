import Foundation

enum PreferencesTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case appearance
    case devices
    case recording
    case alerts
    case keyboard
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.tabGeneral
        case .appearance: return L10n.tabAppearance
        case .devices: return L10n.tabDevices
        case .recording: return L10n.tabRecording
        case .alerts: return L10n.tabAlerts
        case .keyboard: return L10n.tabKeyboard
        case .about: return L10n.tabAbout
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .devices: return "mic.fill"
        case .recording: return "record.circle"
        case .alerts: return "bell"
        case .keyboard: return "keyboard"
        case .about: return "info.circle"
        }
    }
}
