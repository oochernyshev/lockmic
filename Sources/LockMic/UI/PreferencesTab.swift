import Foundation

enum PreferencesTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case appearance
    case devices
    case recording
    case meetings
    case keyboard
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.tabGeneral
        case .appearance: return L10n.tabAppearance
        case .devices: return L10n.tabDevices
        case .recording: return L10n.tabRecording
        case .meetings: return L10n.tabMeetings
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
        case .meetings: return "calendar"
        case .keyboard: return "keyboard"
        case .about: return "info.circle"
        }
    }
}
