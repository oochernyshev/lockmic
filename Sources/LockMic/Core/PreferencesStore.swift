import AppKit
import Foundation
import os.log
import ServiceManagement

private let log = Logger(subsystem: "com.lockmic.app", category: "Preferences")

extension Notification.Name {
    /// Posted when `PreferencesStore.showInDock` changes so AppDelegate can update activation policy.
    static let lockMicShowInDockDidChange = Notification.Name("LockMic.showInDockDidChange")
}

/// User's preferred UI appearance. `.system` follows macOS's current setting.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// `nil` tells AppKit to follow the system appearance.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class PreferencesStore: ObservableObject {
    private enum Keys {
        static let hudEnabled = "hudEnabled"
        static let hudFloating = "hudFloating"
        static let soundEnabled = "soundEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let muteAllInputs = "muteAllInputs"
        static let recordAllPlayback = "recordAllPlayback"
        static let followDefaultMic = "followDefaultMic"
        static let followDefaultOutput = "followDefaultOutput"
        static let recordingInputUID = "recordingInputUID"
        static let recordingOutputUIDs = "recordingOutputUIDs"
        static let monitorUnselectedDevices = "monitorUnselectedDevices"
        static let recordingBitRate = "recordingBitRate"
        static let recordingsFolderPath = "recordingsFolderPath"
        static let shareAnonymousUsage = "shareAnonymousUsage"
        /// When true, show a Dock icon so Preferences stay reachable if the menu bar is full.
        static let showInDock = "showInDock"
        static let appAppearance = "appAppearance"

        static let toggleEnabled = "hotkeyToggleEnabled"
        static let toggleKeyCode = "hotkeyToggleKeyCode"
        static let toggleModifiers = "hotkeyToggleModifiers"

        static let muteEnabled = "hotkeyMuteEnabled"
        static let muteKeyCode = "hotkeyMuteKeyCode"
        static let muteModifiers = "hotkeyMuteModifiers"

        static let unmuteEnabled = "hotkeyUnmuteEnabled"
        static let unmuteKeyCode = "hotkeyUnmuteKeyCode"
        static let unmuteModifiers = "hotkeyUnmuteModifiers"

        static let startRecEnabled = "hotkeyStartRecordingEnabled"
        static let startRecKeyCode = "hotkeyStartRecordingKeyCode"
        static let startRecModifiers = "hotkeyStartRecordingModifiers"

        static let stopRecEnabled = "hotkeyStopRecordingEnabled"
        static let stopRecKeyCode = "hotkeyStopRecordingKeyCode"
        static let stopRecModifiers = "hotkeyStopRecordingModifiers"

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
    static let defaultStartRecording = HotkeyChord(keyCode: 15, modifiers: cmdKey | shiftKey) // ⌘⇧R
    static let defaultStopRecording = HotkeyChord(keyCode: 15, modifiers: cmdKey | shiftKey | optionKey) // ⌥⌘⇧R
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

    /// When true, the playback tap mixes every app. When false, only the default output.
    @Published var recordAllPlayback: Bool {
        didSet { UserDefaults.standard.set(recordAllPlayback, forKey: Keys.recordAllPlayback) }
    }

    @Published var followDefaultMic: Bool {
        didSet { UserDefaults.standard.set(followDefaultMic, forKey: Keys.followDefaultMic) }
    }

    /// Last explicitly chosen recording mic. Used when `followDefaultMic` is off.
    @Published var recordingInputUID: String {
        didSet { UserDefaults.standard.set(recordingInputUID, forKey: Keys.recordingInputUID) }
    }

    @Published var followDefaultOutput: Bool {
        didSet { UserDefaults.standard.set(followDefaultOutput, forKey: Keys.followDefaultOutput) }
    }

    /// Last explicitly chosen playback outputs. Used when `followDefaultOutput` is off.
    @Published var recordingOutputUIDs: [String] {
        didSet { UserDefaults.standard.set(recordingOutputUIDs, forKey: Keys.recordingOutputUIDs) }
    }

    /// Meter unselected inputs/outputs and warn if they have audio.
    @Published var monitorUnselectedDevices: Bool {
        didSet { UserDefaults.standard.set(monitorUnselectedDevices, forKey: Keys.monitorUnselectedDevices) }
    }

    /// AAC bitrate for microphone, playback, and the mix.
    @Published var recordingBitRate: RecordingBitRate {
        didSet { UserDefaults.standard.set(recordingBitRate.rawValue, forKey: Keys.recordingBitRate) }
    }

    /// Empty means `defaultRecordingsDirectory` (`~/Movies/LockMic`).
    @Published var recordingsFolderPath: String {
        didSet { UserDefaults.standard.set(recordingsFolderPath, forKey: Keys.recordingsFolderPath) }
    }

    static var defaultRecordingsDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("LockMic", isDirectory: true)
    }

    var recordingsDirectory: URL {
        let raw = recordingsFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return Self.defaultRecordingsDirectory
        }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    var recordingsFolderDisplayPath: String {
        (recordingsDirectory.path as NSString).abbreviatingWithTildeInPath
    }

    var usesDefaultRecordingsFolder: Bool {
        let raw = recordingsFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return true }
        return recordingsDirectory.standardizedFileURL
            == Self.defaultRecordingsDirectory.standardizedFileURL
    }

    func setRecordingsFolder(_ url: URL) {
        let folder = url.standardizedFileURL
        if folder == Self.defaultRecordingsDirectory.standardizedFileURL {
            recordingsFolderPath = ""
        } else {
            recordingsFolderPath = folder.path
        }
    }

    func resetRecordingsFolder() {
        recordingsFolderPath = ""
    }

    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLoginItem()
        }
    }

    /// Always show in Dock. When off, Dock still appears automatically if the menu bar icon is hidden.
    @Published var showInDock: Bool {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: Keys.showInDock)
            NotificationCenter.default.post(name: .lockMicShowInDockDidChange, object: nil)
        }
    }

    /// Light / dark / follow-system.
    @Published var appAppearance: AppAppearance {
        didSet {
            UserDefaults.standard.set(appAppearance.rawValue, forKey: Keys.appAppearance)
            NSApp.appearance = appAppearance.nsAppearance
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

    @Published var toggleShortcut: HotkeyPref {
        didSet { Self.save(toggleShortcut, spec: Self.toggleSpec) }
    }
    @Published var muteShortcut: HotkeyPref {
        didSet { Self.save(muteShortcut, spec: Self.muteSpec) }
    }
    @Published var unmuteShortcut: HotkeyPref {
        didSet { Self.save(unmuteShortcut, spec: Self.unmuteSpec) }
    }
    @Published var startRecordingShortcut: HotkeyPref {
        didSet { Self.save(startRecordingShortcut, spec: Self.startRecSpec) }
    }
    @Published var stopRecordingShortcut: HotkeyPref {
        didSet { Self.save(stopRecordingShortcut, spec: Self.stopRecSpec) }
    }
    @Published var pushToTalkShortcut: HotkeyPref {
        didSet { Self.save(pushToTalkShortcut, spec: Self.pttSpec) }
    }
    @Published var pushToMuteShortcut: HotkeyPref {
        didSet { Self.save(pushToMuteShortcut, spec: Self.ptmSpec) }
    }
    @Published var pushToToggleShortcut: HotkeyPref {
        didSet { Self.save(pushToToggleShortcut, spec: Self.pttogSpec) }
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

        if defaults.object(forKey: Keys.recordAllPlayback) == nil {
            defaults.set(false, forKey: Keys.recordAllPlayback)
        }
        recordAllPlayback = defaults.bool(forKey: Keys.recordAllPlayback)
        if defaults.object(forKey: Keys.followDefaultMic) == nil {
            defaults.set(true, forKey: Keys.followDefaultMic)
        }
        followDefaultMic = defaults.bool(forKey: Keys.followDefaultMic)
        recordingInputUID = defaults.string(forKey: Keys.recordingInputUID) ?? ""
        if defaults.object(forKey: Keys.followDefaultOutput) == nil {
            defaults.set(true, forKey: Keys.followDefaultOutput)
        }
        followDefaultOutput = defaults.bool(forKey: Keys.followDefaultOutput)
        recordingOutputUIDs = defaults.stringArray(forKey: Keys.recordingOutputUIDs) ?? []
        if defaults.object(forKey: Keys.monitorUnselectedDevices) == nil {
            defaults.set(true, forKey: Keys.monitorUnselectedDevices)
        }
        monitorUnselectedDevices = defaults.bool(forKey: Keys.monitorUnselectedDevices)
        recordingBitRate = RecordingBitRate.resolved(defaults.integer(forKey: Keys.recordingBitRate))
        recordingsFolderPath = defaults.string(forKey: Keys.recordingsFolderPath) ?? ""

        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)

        if defaults.object(forKey: Keys.showInDock) == nil {
            defaults.set(false, forKey: Keys.showInDock)
        }
        showInDock = defaults.bool(forKey: Keys.showInDock)

        appAppearance = AppAppearance(rawValue: defaults.string(forKey: Keys.appAppearance) ?? "") ?? .system

        // Opt-in only — unset key means not agreed (features disabled).
        if defaults.object(forKey: Keys.shareAnonymousUsage) == nil {
            defaults.set(false, forKey: Keys.shareAnonymousUsage)
        }
        shareAnonymousUsage = defaults.bool(forKey: Keys.shareAnonymousUsage)

        toggleShortcut = Self.load(Self.toggleSpec, from: defaults)
        muteShortcut = Self.load(Self.muteSpec, from: defaults)
        unmuteShortcut = Self.load(Self.unmuteSpec, from: defaults)
        startRecordingShortcut = Self.load(Self.startRecSpec, from: defaults)
        stopRecordingShortcut = Self.load(Self.stopRecSpec, from: defaults)

        if defaults.object(forKey: "hotkeyF5ToggleEnabled") == nil {
            defaults.set(true, forKey: "hotkeyF5ToggleEnabled")
        }
        f5ToggleEnabled = defaults.bool(forKey: "hotkeyF5ToggleEnabled")

        pushToToggleShortcut = Self.load(Self.pttogSpec, from: defaults)
        pushToTalkShortcut = Self.load(Self.pttSpec, from: defaults)
        pushToMuteShortcut = Self.load(Self.ptmSpec, from: defaults)

        NSApp.appearance = appAppearance.nsAppearance
    }

    private struct HotkeySpec {
        let enabledKey: String
        let keyCodeKey: String
        let modifiersKey: String
        let factory: HotkeyChord
        let defaultEnabled: Bool
        var legacyDefaults: [HotkeyChord] = []
        var migrateFrom: (keyCode: String, modifiers: String)? = nil
    }

    private static let space: UInt32 = 49
    private static var legacyControlSpace: HotkeyChord { HotkeyChord(keyCode: space, modifiers: controlKey) }
    private static var legacyOptionSpace: HotkeyChord { HotkeyChord(keyCode: space, modifiers: optionKey) }
    private static var legacyShiftSpace: HotkeyChord { HotkeyChord(keyCode: space, modifiers: shiftKey) }

    private static let toggleSpec = HotkeySpec(
        enabledKey: Keys.toggleEnabled,
        keyCodeKey: Keys.toggleKeyCode,
        modifiersKey: Keys.toggleModifiers,
        factory: defaultToggle,
        defaultEnabled: true,
        migrateFrom: (Keys.legacyKeyCode, Keys.legacyModifiers)
    )
    private static let muteSpec = HotkeySpec(
        enabledKey: Keys.muteEnabled,
        keyCodeKey: Keys.muteKeyCode,
        modifiersKey: Keys.muteModifiers,
        factory: defaultMute,
        defaultEnabled: false
    )
    private static let unmuteSpec = HotkeySpec(
        enabledKey: Keys.unmuteEnabled,
        keyCodeKey: Keys.unmuteKeyCode,
        modifiersKey: Keys.unmuteModifiers,
        factory: defaultUnmute,
        defaultEnabled: false
    )
    private static let startRecSpec = HotkeySpec(
        enabledKey: Keys.startRecEnabled,
        keyCodeKey: Keys.startRecKeyCode,
        modifiersKey: Keys.startRecModifiers,
        factory: defaultStartRecording,
        defaultEnabled: true
    )
    private static let stopRecSpec = HotkeySpec(
        enabledKey: Keys.stopRecEnabled,
        keyCodeKey: Keys.stopRecKeyCode,
        modifiersKey: Keys.stopRecModifiers,
        factory: defaultStopRecording,
        defaultEnabled: true
    )
    private static let pttogSpec = HotkeySpec(
        enabledKey: Keys.pttogEnabled,
        keyCodeKey: Keys.pttogKeyCode,
        modifiersKey: Keys.pttogModifiers,
        factory: defaultPushToToggle,
        defaultEnabled: false,
        legacyDefaults: [legacyControlSpace]
    )
    private static let pttSpec = HotkeySpec(
        enabledKey: Keys.pttEnabled,
        keyCodeKey: Keys.pttKeyCode,
        modifiersKey: Keys.pttModifiers,
        factory: defaultPushToTalk,
        defaultEnabled: false,
        legacyDefaults: [legacyControlSpace, legacyOptionSpace]
    )
    private static let ptmSpec = HotkeySpec(
        enabledKey: Keys.ptmEnabled,
        keyCodeKey: Keys.ptmKeyCode,
        modifiersKey: Keys.ptmModifiers,
        factory: defaultPushToMute,
        defaultEnabled: false,
        legacyDefaults: [legacyControlSpace, legacyShiftSpace]
    )

    private static func load(_ spec: HotkeySpec, from defaults: UserDefaults) -> HotkeyPref {
        if defaults.object(forKey: spec.enabledKey) == nil {
            defaults.set(spec.defaultEnabled, forKey: spec.enabledKey)
        }
        if defaults.object(forKey: spec.keyCodeKey) == nil {
            if let migrate = spec.migrateFrom, defaults.object(forKey: migrate.keyCode) != nil {
                defaults.set(defaults.integer(forKey: migrate.keyCode), forKey: spec.keyCodeKey)
                defaults.set(defaults.integer(forKey: migrate.modifiers), forKey: spec.modifiersKey)
            } else {
                defaults.set(Int(spec.factory.keyCode), forKey: spec.keyCodeKey)
                defaults.set(Int(spec.factory.modifiers), forKey: spec.modifiersKey)
            }
        }
        var chord = HotkeyChord(
            keyCode: UInt32(defaults.integer(forKey: spec.keyCodeKey)),
            modifiers: UInt32(defaults.integer(forKey: spec.modifiersKey))
        )
        if spec.legacyDefaults.contains(chord) {
            defaults.set(Int(spec.factory.keyCode), forKey: spec.keyCodeKey)
            defaults.set(Int(spec.factory.modifiers), forKey: spec.modifiersKey)
            chord = spec.factory
        }
        return HotkeyPref(enabled: defaults.bool(forKey: spec.enabledKey), chord: chord)
    }

    private static func save(_ pref: HotkeyPref, spec: HotkeySpec) {
        let defaults = UserDefaults.standard
        defaults.set(pref.enabled, forKey: spec.enabledKey)
        defaults.set(Int(pref.chord.keyCode), forKey: spec.keyCodeKey)
        defaults.set(Int(pref.chord.modifiers), forKey: spec.modifiersKey)
    }

    /// Named rows used for registration and conflict detection.
    private var namedShortcutRows: [(title: String, pref: HotkeyPref, action: HotkeyAction)] {
        [
            (L10n.keyboardToggle, toggleShortcut, .toggle),
            (L10n.keyboardF5Toggle, HotkeyPref(enabled: f5ToggleEnabled, chord: Self.defaultToggleAlt), .toggle),
            (L10n.keyboardMute, muteShortcut, .mute),
            (L10n.keyboardUnmute, unmuteShortcut, .unmute),
            (L10n.keyboardStartRecording, startRecordingShortcut, .startRecording),
            (L10n.keyboardStopRecording, stopRecordingShortcut, .stopRecording),
            (L10n.keyboardPushFlip, pushToToggleShortcut, .pushToToggle),
            (L10n.keyboardPushTalk, pushToTalkShortcut, .pushToTalk),
            (L10n.keyboardPushMute, pushToMuteShortcut, .pushToMute),
        ]
    }

    /// Bindings registered with the global hotkey manager.
    var activeBindings: [HotkeyBinding] {
        namedShortcutRows.compactMap { row in
            guard row.pref.enabled, !row.pref.chord.isEmpty else { return nil }
            return HotkeyBinding(enabled: true, chord: row.pref.chord, action: row.action)
        }
    }

    /// Human-readable conflict lines for Preferences (empty when none).
    var shortcutConflictMessages: [String] {
        var groups: [HotkeyChord: [String]] = [:]
        for row in namedShortcutRows {
            guard row.pref.enabled, !row.pref.chord.isEmpty else { continue }
            groups[row.pref.chord, default: []].append(row.title)
        }
        return groups
            .filter { $0.value.count > 1 }
            .map { chord, titles in
                L10n.keyboardConflict(chord: chord.displayString, titles: titles.joined(separator: ", "))
            }
            .sorted()
    }

    /// Restore factory shortcut defaults.
    func resetShortcutsToDefaults() {
        toggleShortcut = HotkeyPref(enabled: true, chord: Self.defaultToggle)
        f5ToggleEnabled = true
        muteShortcut = HotkeyPref(enabled: false, chord: Self.defaultMute)
        unmuteShortcut = HotkeyPref(enabled: false, chord: Self.defaultUnmute)
        startRecordingShortcut = HotkeyPref(enabled: true, chord: Self.defaultStartRecording)
        stopRecordingShortcut = HotkeyPref(enabled: true, chord: Self.defaultStopRecording)
        pushToToggleShortcut = HotkeyPref(enabled: false, chord: Self.defaultPushToToggle)
        pushToTalkShortcut = HotkeyPref(enabled: false, chord: Self.defaultPushToTalk)
        pushToMuteShortcut = HotkeyPref(enabled: false, chord: Self.defaultPushToMute)
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
