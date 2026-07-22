import Foundation
import ServiceManagement

@MainActor
final class PreferencesStore: ObservableObject {
    private enum Keys {
        static let hudEnabled = "hudEnabled"
        static let hudFloating = "hudFloating"
        static let soundEnabled = "soundEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let muteAllInputs = "muteAllInputs"

        static let toggleEnabled = "hotkeyToggleEnabled"
        static let toggleKeyCode = "hotkeyToggleKeyCode"
        static let toggleModifiers = "hotkeyToggleModifiers"

        static let muteEnabled = "hotkeyMuteEnabled"
        static let muteKeyCode = "hotkeyMuteKeyCode"
        static let muteModifiers = "hotkeyMuteModifiers"

        static let unmuteEnabled = "hotkeyUnmuteEnabled"
        static let unmuteKeyCode = "hotkeyUnmuteKeyCode"
        static let unmuteModifiers = "hotkeyUnmuteModifiers"

        // Legacy single-toggle keys (migrated once)
        static let legacyKeyCode = "hotkeyKeyCode"
        static let legacyModifiers = "hotkeyModifiers"
    }

    // Carbon modifier constants
    static let cmdKey: UInt32 = 256
    static let shiftKey: UInt32 = 512
    static let optionKey: UInt32 = 2048
    static let controlKey: UInt32 = 4096

    static let defaultToggle = HotkeyChord(keyCode: 46, modifiers: cmdKey | shiftKey) // ⌘⇧M
    static let defaultMute = HotkeyChord(keyCode: 46, modifiers: cmdKey | shiftKey | controlKey) // ⌃⌘⇧M
    static let defaultUnmute = HotkeyChord(keyCode: 46, modifiers: cmdKey | shiftKey | optionKey) // ⌥⌘⇧M
    static let defaultToggleAlt = HotkeyChord(keyCode: 96, modifiers: cmdKey) // ⌘F5

    @Published var hudEnabled: Bool {
        didSet { UserDefaults.standard.set(hudEnabled, forKey: Keys.hudEnabled) }
    }

    /// When true, the mute HUD stays on screen and updates with mute state.
    @Published var hudFloating: Bool {
        didSet { UserDefaults.standard.set(hudFloating, forKey: Keys.hudFloating) }
    }

    @Published var soundEnabled: Bool {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    @Published var muteAllInputs: Bool {
        didSet { UserDefaults.standard.set(muteAllInputs, forKey: Keys.muteAllInputs) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLoginItem()
        }
    }

    // MARK: - Shortcut bindings

    @Published var toggleShortcutEnabled: Bool {
        didSet { UserDefaults.standard.set(toggleShortcutEnabled, forKey: Keys.toggleEnabled) }
    }

    @Published var toggleChord: HotkeyChord {
        didSet {
            UserDefaults.standard.set(Int(toggleChord.keyCode), forKey: Keys.toggleKeyCode)
            UserDefaults.standard.set(Int(toggleChord.modifiers), forKey: Keys.toggleModifiers)
        }
    }

    @Published var muteShortcutEnabled: Bool {
        didSet { UserDefaults.standard.set(muteShortcutEnabled, forKey: Keys.muteEnabled) }
    }

    @Published var muteChord: HotkeyChord {
        didSet {
            UserDefaults.standard.set(Int(muteChord.keyCode), forKey: Keys.muteKeyCode)
            UserDefaults.standard.set(Int(muteChord.modifiers), forKey: Keys.muteModifiers)
        }
    }

    @Published var unmuteShortcutEnabled: Bool {
        didSet { UserDefaults.standard.set(unmuteShortcutEnabled, forKey: Keys.unmuteEnabled) }
    }

    @Published var unmuteChord: HotkeyChord {
        didSet {
            UserDefaults.standard.set(Int(unmuteChord.keyCode), forKey: Keys.unmuteKeyCode)
            UserDefaults.standard.set(Int(unmuteChord.modifiers), forKey: Keys.unmuteModifiers)
        }
    }

    /// Extra always-on toggle alias (⌘F5) — enable/disable separately.
    @Published var f5ToggleEnabled: Bool {
        didSet { UserDefaults.standard.set(f5ToggleEnabled, forKey: "hotkeyF5ToggleEnabled") }
    }

    init() {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: Keys.hudEnabled) == nil {
            defaults.set(true, forKey: Keys.hudEnabled)
        }
        hudEnabled = defaults.bool(forKey: Keys.hudEnabled)

        if defaults.object(forKey: Keys.hudFloating) == nil {
            defaults.set(false, forKey: Keys.hudFloating)
        }
        hudFloating = defaults.bool(forKey: Keys.hudFloating)

        if defaults.object(forKey: Keys.soundEnabled) == nil {
            defaults.set(true, forKey: Keys.soundEnabled)
        }
        soundEnabled = defaults.bool(forKey: Keys.soundEnabled)

        if defaults.object(forKey: Keys.muteAllInputs) == nil {
            defaults.set(true, forKey: Keys.muteAllInputs)
        }
        muteAllInputs = defaults.bool(forKey: Keys.muteAllInputs)

        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)

        // Toggle shortcut (migrate legacy if needed)
        if defaults.object(forKey: Keys.toggleEnabled) == nil {
            defaults.set(true, forKey: Keys.toggleEnabled)
        }
        toggleShortcutEnabled = defaults.bool(forKey: Keys.toggleEnabled)

        if defaults.object(forKey: Keys.toggleKeyCode) == nil {
            if defaults.object(forKey: Keys.legacyKeyCode) != nil {
                defaults.set(defaults.integer(forKey: Keys.legacyKeyCode), forKey: Keys.toggleKeyCode)
                defaults.set(defaults.integer(forKey: Keys.legacyModifiers), forKey: Keys.toggleModifiers)
            } else {
                defaults.set(Int(Self.defaultToggle.keyCode), forKey: Keys.toggleKeyCode)
                defaults.set(Int(Self.defaultToggle.modifiers), forKey: Keys.toggleModifiers)
            }
        }
        toggleChord = HotkeyChord(
            keyCode: UInt32(defaults.integer(forKey: Keys.toggleKeyCode)),
            modifiers: UInt32(defaults.integer(forKey: Keys.toggleModifiers))
        )

        // Mute-only (off by default)
        if defaults.object(forKey: Keys.muteEnabled) == nil {
            defaults.set(false, forKey: Keys.muteEnabled)
        }
        muteShortcutEnabled = defaults.bool(forKey: Keys.muteEnabled)
        if defaults.object(forKey: Keys.muteKeyCode) == nil {
            defaults.set(Int(Self.defaultMute.keyCode), forKey: Keys.muteKeyCode)
            defaults.set(Int(Self.defaultMute.modifiers), forKey: Keys.muteModifiers)
        }
        muteChord = HotkeyChord(
            keyCode: UInt32(defaults.integer(forKey: Keys.muteKeyCode)),
            modifiers: UInt32(defaults.integer(forKey: Keys.muteModifiers))
        )

        // Unmute-only (off by default)
        if defaults.object(forKey: Keys.unmuteEnabled) == nil {
            defaults.set(false, forKey: Keys.unmuteEnabled)
        }
        unmuteShortcutEnabled = defaults.bool(forKey: Keys.unmuteEnabled)
        if defaults.object(forKey: Keys.unmuteKeyCode) == nil {
            defaults.set(Int(Self.defaultUnmute.keyCode), forKey: Keys.unmuteKeyCode)
            defaults.set(Int(Self.defaultUnmute.modifiers), forKey: Keys.unmuteModifiers)
        }
        unmuteChord = HotkeyChord(
            keyCode: UInt32(defaults.integer(forKey: Keys.unmuteKeyCode)),
            modifiers: UInt32(defaults.integer(forKey: Keys.unmuteModifiers))
        )

        if defaults.object(forKey: "hotkeyF5ToggleEnabled") == nil {
            defaults.set(true, forKey: "hotkeyF5ToggleEnabled")
        }
        f5ToggleEnabled = defaults.bool(forKey: "hotkeyF5ToggleEnabled")
    }

    /// Bindings registered with the global hotkey manager.
    var activeBindings: [HotkeyBinding] {
        var list: [HotkeyBinding] = []
        if toggleShortcutEnabled {
            list.append(HotkeyBinding(enabled: true, chord: toggleChord, action: .toggle))
        }
        if f5ToggleEnabled {
            list.append(HotkeyBinding(enabled: true, chord: Self.defaultToggleAlt, action: .toggle))
        }
        if muteShortcutEnabled {
            list.append(HotkeyBinding(enabled: true, chord: muteChord, action: .mute))
        }
        if unmuteShortcutEnabled {
            list.append(HotkeyBinding(enabled: true, chord: unmuteChord, action: .unmute))
        }
        return list
    }

    /// Restore factory shortcut defaults.
    func resetShortcutsToDefaults() {
        toggleShortcutEnabled = true
        toggleChord = Self.defaultToggle
        f5ToggleEnabled = true

        muteShortcutEnabled = false
        muteChord = Self.defaultMute

        unmuteShortcutEnabled = false
        unmuteChord = Self.defaultUnmute
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
