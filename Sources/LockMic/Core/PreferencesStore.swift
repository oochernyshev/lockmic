import Foundation
import os.log
import ServiceManagement

private let log = Logger(subsystem: "com.lockmic.app", category: "Preferences")

@MainActor
final class PreferencesStore: ObservableObject {
    private enum Keys {
        static let hudEnabled = "hudEnabled"
        static let hudFloating = "hudFloating"
        static let soundEnabled = "soundEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let muteAllInputs = "muteAllInputs"
        static let shareAnonymousUsage = "shareAnonymousUsage"

        static let toggleEnabled = "hotkeyToggleEnabled"
        static let toggleKeyCode = "hotkeyToggleKeyCode"
        static let toggleModifiers = "hotkeyToggleModifiers"

        static let muteEnabled = "hotkeyMuteEnabled"
        static let muteKeyCode = "hotkeyMuteKeyCode"
        static let muteModifiers = "hotkeyMuteModifiers"

        static let unmuteEnabled = "hotkeyUnmuteEnabled"
        static let unmuteKeyCode = "hotkeyUnmuteKeyCode"
        static let unmuteModifiers = "hotkeyUnmuteModifiers"

        static let pttEnabled = "hotkeyPushToTalkEnabled"
        static let pttKeyCode = "hotkeyPushToTalkKeyCode"
        static let pttModifiers = "hotkeyPushToTalkModifiers"

        static let ptmEnabled = "hotkeyPushToMuteEnabled"
        static let ptmKeyCode = "hotkeyPushToMuteKeyCode"
        static let ptmModifiers = "hotkeyPushToMuteModifiers"

        static let pttogEnabled = "hotkeyPushToToggleEnabled"
        static let pttogKeyCode = "hotkeyPushToToggleKeyCode"
        static let pttogModifiers = "hotkeyPushToToggleModifiers"

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
    /// Hold to invert mute — Option+Space by default.
    static let defaultPushToToggle = HotkeyChord(keyCode: 49, modifiers: optionKey) // ⌥Space
    /// Hold to talk — Shift+Space by default.
    static let defaultPushToTalk = HotkeyChord(keyCode: 49, modifiers: shiftKey) // ⇧Space
    /// Hold to mute — Shift+Option+Space by default.
    static let defaultPushToMute = HotkeyChord(keyCode: 49, modifiers: shiftKey | optionKey) // ⇧⌥Space

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

    /// Required opt-in: anonymous GA4 usage. When false, LockMic features stay disabled.
    @Published var shareAnonymousUsage: Bool {
        didSet {
            UserDefaults.standard.set(shareAnonymousUsage, forKey: Keys.shareAnonymousUsage)
            UsageReporter.setShareEnabled(shareAnonymousUsage)
        }
    }

    /// App mute/hotkey/HUD features are only active after stats agreement.
    var featuresEnabled: Bool { shareAnonymousUsage }

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

    /// Hold to unmute; release restores previous mute state.
    @Published var pushToTalkEnabled: Bool {
        didSet { UserDefaults.standard.set(pushToTalkEnabled, forKey: Keys.pttEnabled) }
    }

    @Published var pushToTalkChord: HotkeyChord {
        didSet {
            UserDefaults.standard.set(Int(pushToTalkChord.keyCode), forKey: Keys.pttKeyCode)
            UserDefaults.standard.set(Int(pushToTalkChord.modifiers), forKey: Keys.pttModifiers)
        }
    }

    /// Hold to mute; release restores previous mute state.
    @Published var pushToMuteEnabled: Bool {
        didSet { UserDefaults.standard.set(pushToMuteEnabled, forKey: Keys.ptmEnabled) }
    }

    @Published var pushToMuteChord: HotkeyChord {
        didSet {
            UserDefaults.standard.set(Int(pushToMuteChord.keyCode), forKey: Keys.ptmKeyCode)
            UserDefaults.standard.set(Int(pushToMuteChord.modifiers), forKey: Keys.ptmModifiers)
        }
    }

    /// Hold to invert mute; release restores previous state (UI: Push to flip).
    @Published var pushToToggleEnabled: Bool {
        didSet { UserDefaults.standard.set(pushToToggleEnabled, forKey: Keys.pttogEnabled) }
    }

    @Published var pushToToggleChord: HotkeyChord {
        didSet {
            UserDefaults.standard.set(Int(pushToToggleChord.keyCode), forKey: Keys.pttogKeyCode)
            UserDefaults.standard.set(Int(pushToToggleChord.modifiers), forKey: Keys.pttogModifiers)
        }
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

        // Opt-in only — unset key means not agreed (features disabled).
        if defaults.object(forKey: Keys.shareAnonymousUsage) == nil {
            defaults.set(false, forKey: Keys.shareAnonymousUsage)
        }
        shareAnonymousUsage = defaults.bool(forKey: Keys.shareAnonymousUsage)

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

        // Momentary shortcuts (all off by default). UI order: flip → talk → mute.
        let space: UInt32 = 49
        let legacyControlSpace = HotkeyChord(keyCode: space, modifiers: Self.controlKey)
        let legacyOptionSpace = HotkeyChord(keyCode: space, modifiers: Self.optionKey)
        let legacyShiftSpace = HotkeyChord(keyCode: space, modifiers: Self.shiftKey)

        if defaults.object(forKey: Keys.pttogEnabled) == nil {
            defaults.set(false, forKey: Keys.pttogEnabled)
        }
        pushToToggleEnabled = defaults.bool(forKey: Keys.pttogEnabled)
        pushToToggleChord = Self.loadChord(
            defaults: defaults,
            keyCodeKey: Keys.pttogKeyCode,
            modifiersKey: Keys.pttogModifiers,
            factory: Self.defaultPushToToggle,
            legacyDefaults: [legacyControlSpace]
        )

        if defaults.object(forKey: Keys.pttEnabled) == nil {
            defaults.set(false, forKey: Keys.pttEnabled)
        }
        pushToTalkEnabled = defaults.bool(forKey: Keys.pttEnabled)
        pushToTalkChord = Self.loadChord(
            defaults: defaults,
            keyCodeKey: Keys.pttKeyCode,
            modifiersKey: Keys.pttModifiers,
            factory: Self.defaultPushToTalk,
            // Prior factory defaults for talk: ⌃Space, then ⌥Space
            legacyDefaults: [legacyControlSpace, legacyOptionSpace]
        )

        if defaults.object(forKey: Keys.ptmEnabled) == nil {
            defaults.set(false, forKey: Keys.ptmEnabled)
        }
        pushToMuteEnabled = defaults.bool(forKey: Keys.ptmEnabled)
        pushToMuteChord = Self.loadChord(
            defaults: defaults,
            keyCodeKey: Keys.ptmKeyCode,
            modifiersKey: Keys.ptmModifiers,
            factory: Self.defaultPushToMute,
            // Prior factory defaults for mute: ⌃Space, then ⇧Space
            legacyDefaults: [legacyControlSpace, legacyShiftSpace]
        )
    }

    /// Load a stored chord, writing the factory default if missing, or migrating known legacy factory chords.
    private static func loadChord(
        defaults: UserDefaults,
        keyCodeKey: String,
        modifiersKey: String,
        factory: HotkeyChord,
        legacyDefaults: [HotkeyChord]
    ) -> HotkeyChord {
        if defaults.object(forKey: keyCodeKey) == nil {
            defaults.set(Int(factory.keyCode), forKey: keyCodeKey)
            defaults.set(Int(factory.modifiers), forKey: modifiersKey)
            return factory
        }
        let stored = HotkeyChord(
            keyCode: UInt32(defaults.integer(forKey: keyCodeKey)),
            modifiers: UInt32(defaults.integer(forKey: modifiersKey))
        )
        if legacyDefaults.contains(stored) {
            defaults.set(Int(factory.keyCode), forKey: keyCodeKey)
            defaults.set(Int(factory.modifiers), forKey: modifiersKey)
            return factory
        }
        return stored
    }

    /// Named rows used for registration and conflict detection.
    private var namedShortcutRows: [(title: String, enabled: Bool, chord: HotkeyChord, action: HotkeyAction)] {
        [
            ("Toggle mute", toggleShortcutEnabled, toggleChord, .toggle),
            ("⌘F5 toggle", f5ToggleEnabled, Self.defaultToggleAlt, .toggle),
            ("Mute", muteShortcutEnabled, muteChord, .mute),
            ("Unmute", unmuteShortcutEnabled, unmuteChord, .unmute),
            ("Push to flip", pushToToggleEnabled, pushToToggleChord, .pushToToggle),
            ("Push to talk", pushToTalkEnabled, pushToTalkChord, .pushToTalk),
            ("Push to mute", pushToMuteEnabled, pushToMuteChord, .pushToMute),
        ]
    }

    /// Bindings registered with the global hotkey manager.
    var activeBindings: [HotkeyBinding] {
        namedShortcutRows.compactMap { row in
            guard row.enabled, !row.chord.isEmpty else { return nil }
            return HotkeyBinding(enabled: true, chord: row.chord, action: row.action)
        }
    }

    /// Human-readable conflict lines for Preferences (empty when none).
    var shortcutConflictMessages: [String] {
        var groups: [HotkeyChord: [String]] = [:]
        for row in namedShortcutRows {
            guard row.enabled, !row.chord.isEmpty else { continue }
            groups[row.chord, default: []].append(row.title)
        }
        return groups
            .filter { $0.value.count > 1 }
            .map { chord, titles in
                "\(chord.displayString) is used by \(titles.joined(separator: ", "))"
            }
            .sorted()
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

        pushToToggleEnabled = false
        pushToToggleChord = Self.defaultPushToToggle

        pushToTalkEnabled = false
        pushToTalkChord = Self.defaultPushToTalk

        pushToMuteEnabled = false
        pushToMuteChord = Self.defaultPushToMute
    }

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Launch at login update failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
