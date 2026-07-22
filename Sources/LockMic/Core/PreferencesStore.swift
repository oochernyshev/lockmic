import Foundation
import ServiceManagement

@MainActor
final class PreferencesStore: ObservableObject {
    private enum Keys {
        static let hudEnabled = "hudEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let muteAllInputs = "muteAllInputs"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
    }

    /// Carbon key codes / modifiers (HIToolbox).
    enum Hotkeys {
        /// ⌘⇧M
        static let commandShiftM = HotkeyChord(
            keyCode: 46, // kVK_ANSI_M
            modifiers: UInt32(cmdKey | shiftKey)
        )
        /// ⌘F5 — often used as a mic-style shortcut (note: system default for VoiceOver)
        static let commandF5 = HotkeyChord(
            keyCode: 96, // kVK_F5
            modifiers: UInt32(cmdKey)
        )

        static let allDefaults: [HotkeyChord] = [commandShiftM, commandF5]
    }

    @Published var hudEnabled: Bool {
        didSet { UserDefaults.standard.set(hudEnabled, forKey: Keys.hudEnabled) }
    }

    /// When true (default), mute every input device — not only the system default.
    @Published var muteAllInputs: Bool {
        didSet { UserDefaults.standard.set(muteAllInputs, forKey: Keys.muteAllInputs) }
    }

    /// Primary Carbon key code (⌘⇧M by default). Kept for prefs UI / future rebinding.
    @Published var hotkeyKeyCode: UInt32 {
        didSet { UserDefaults.standard.set(Int(hotkeyKeyCode), forKey: Keys.hotkeyKeyCode) }
    }

    @Published var hotkeyModifiers: UInt32 {
        didSet { UserDefaults.standard.set(Int(hotkeyModifiers), forKey: Keys.hotkeyModifiers) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLoginItem()
        }
    }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.hudEnabled) == nil {
            defaults.set(true, forKey: Keys.hudEnabled)
        }
        hudEnabled = defaults.bool(forKey: Keys.hudEnabled)

        // Default ON: mute all input devices for safety with Zoom/Teams device pickers.
        if defaults.object(forKey: Keys.muteAllInputs) == nil {
            defaults.set(true, forKey: Keys.muteAllInputs)
        }
        muteAllInputs = defaults.bool(forKey: Keys.muteAllInputs)

        let defaultMods = Hotkeys.commandShiftM.modifiers
        let legacyDefaultMods: UInt32 = UInt32(controlKey | optionKey | cmdKey)

        if defaults.object(forKey: Keys.hotkeyKeyCode) == nil {
            defaults.set(Int(Hotkeys.commandShiftM.keyCode), forKey: Keys.hotkeyKeyCode)
        }
        if defaults.object(forKey: Keys.hotkeyModifiers) == nil {
            defaults.set(Int(defaultMods), forKey: Keys.hotkeyModifiers)
        } else if UInt32(defaults.integer(forKey: Keys.hotkeyModifiers)) == legacyDefaultMods {
            defaults.set(Int(defaultMods), forKey: Keys.hotkeyModifiers)
        }
        hotkeyKeyCode = UInt32(defaults.integer(forKey: Keys.hotkeyKeyCode))
        hotkeyModifiers = UInt32(defaults.integer(forKey: Keys.hotkeyModifiers))
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
    }

    /// All active mute-toggle shortcuts.
    var activeHotkeys: [HotkeyChord] {
        var chords: [HotkeyChord] = [
            HotkeyChord(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers),
        ]
        // Always include ⌘F5 as an additional mic shortcut (unless primary is already that).
        let cmdF5 = Hotkeys.commandF5
        if !chords.contains(cmdF5) {
            chords.append(cmdF5)
        }
        return chords
    }

    var hotkeyDisplayString: String {
        activeHotkeys.map(\.displayString).joined(separator: "  ·  ")
    }

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Launch at login update failed: \(error.localizedDescription)")
        }
    }
}

// Carbon modifier constants (ApplicationServices / Carbon.HIToolbox)
private let cmdKey: Int = 256
private let shiftKey: Int = 512
private let optionKey: Int = 2048
private let controlKey: Int = 4096
