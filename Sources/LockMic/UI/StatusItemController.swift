import AppKit
import SwiftUI

@MainActor
final class StatusItemController {
    private let mic: MicController
    private let preferences: PreferencesStore
    private let hud = HUDOverlay()
    private let sounds = SoundFeedback()
    private let hotkeys = HotkeyManager()

    private var statusItem: NSStatusItem?
    private var preferencesWindow: NSWindow?
    private var cancellables: [NSObjectProtocol] = []
    /// Tracks last applied floating preference so we only hide/show on a real change.
    private var lastHudFloating: Bool?
    /// Last bindings passed to HotkeyManager (skip re-register when unchanged).
    private var lastRegisteredBindings: [HotkeyBinding] = []
    /// Active momentary hold (push-to-talk / mute / toggle).
    private enum MomentaryHold {
        case none
        case pushToTalk(wasMuted: Bool)
        case pushToMute(wasMuted: Bool)
        case pushToToggle(wasMuted: Bool)

        var isActive: Bool {
            if case .none = self { return false }
            return true
        }

        var hudHold: HUDHoldKind {
            switch self {
            case .none: return .none
            case .pushToTalk: return .talk
            case .pushToMute: return .mute
            case .pushToToggle: return .flip
            }
        }
    }

    private var momentaryHold: MomentaryHold = .none

    init(mic: MicController, preferences: PreferencesStore) {
        self.mic = mic
        self.preferences = preferences
    }

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = true
        if let button = item.button {
            button.image = statusImage(symbolName: symbolName(for: mic.state))
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "LockMic"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        item.menu = nil
        statusItem = item

        hud.onToggle = { [weak self] in
            self?.toggleFromUser()
        }

        updateIcon()
        registerHotkeys()
        observeMic()
        observePreferenceHotkeys()
        syncFloatingHUD()
    }

    private func observeMic() {
        cancellables.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.mic.refreshFromHardware(applyDesired: false)
                    self?.updateIcon()
                }
            }
        )
    }

    private func observePreferenceHotkeys() {
        // Prefer-scoped updates: only re-register / re-show when those prefs actually change.
        // (HUD drag/hide writes UserDefaults frequently and must not thrash hotkeys.)
        cancellables.append(
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.registerHotkeysIfNeeded()
                    self?.syncFloatingHUDIfNeeded()
                }
            }
        )
    }

    func handleMuteChanged(showHUD: Bool) {
        updateIcon()

        let displayMuted = currentDisplayMuted()

        if showHUD, preferences.soundEnabled {
            sounds.play(muted: displayMuted)
        }

        presentHUD(muted: displayMuted, userInitiated: showHUD)
    }

    /// Floating = always interactive; momentary hold keeps toast HUD up without auto-hide.
    private func presentHUD(muted: Bool, userInitiated: Bool) {
        let hold = momentaryHold.hudHold

        if preferences.hudFloating {
            hud.show(
                muted: muted,
                deviceName: mic.deviceName,
                persistent: true,
                interactive: true,
                hold: hold
            )
            return
        }

        guard preferences.hudEnabled, userInitiated || momentaryHold.isActive else { return }

        // While PTT/PTM/flip is held, keep HUD visible (non-interactive toast layout).
        let holdVisible = momentaryHold.isActive
        hud.show(
            muted: muted,
            deviceName: mic.deviceName,
            persistent: holdVisible,
            interactive: false,
            hold: hold
        )
    }

    /// Show or hide the always-on floating mute indicator based on preference.
    func syncFloatingHUD() {
        syncFloatingHUDIfNeeded(force: true)
    }

    private func syncFloatingHUDIfNeeded(force: Bool = false) {
        let floating = preferences.hudFloating
        guard force || floating != lastHudFloating else { return }

        if floating {
            hud.show(
                muted: currentDisplayMuted(),
                deviceName: mic.deviceName,
                persistent: true,
                interactive: true,
                hold: momentaryHold.hudHold
            )
        } else if lastHudFloating == true {
            // Only dismiss when floating is turned off — don't cancel toast HUDs.
            hud.hide()
        }
        lastHudFloating = floating
    }

    private func currentDisplayMuted() -> Bool {
        switch mic.state {
        case .muted: return true
        case .unmuted: return false
        default: return mic.desiredMuted
        }
    }

    private func registerHotkeys() {
        registerHotkeysIfNeeded(force: true)
    }

    private func registerHotkeysIfNeeded(force: Bool = false) {
        let bindings = preferences.activeBindings
        guard force || bindings != lastRegisteredBindings else { return }
        lastRegisteredBindings = bindings
        hotkeys.register(bindings: bindings) { [weak self] action, phase in
            DispatchQueue.main.async {
                self?.handleHotkeyAction(action, phase: phase)
            }
        }
    }

    private func handleHotkeyAction(_ action: HotkeyAction, phase: HotkeyPhase) {
        switch action {
        case .toggle:
            guard phase == .pressed, !momentaryHold.isActive else { return }
            toggleFromUser()
        case .mute:
            guard phase == .pressed, !momentaryHold.isActive else { return }
            guard !mic.isMuted else { return }
            mic.setMuted(true)
            handleMuteChanged(showHUD: true)
        case .unmute:
            guard phase == .pressed, !momentaryHold.isActive else { return }
            guard mic.isMuted else { return }
            mic.setMuted(false)
            handleMuteChanged(showHUD: true)
        case .pushToTalk:
            handleMomentary(phase: phase, mode: .talk)
        case .pushToMute:
            handleMomentary(phase: phase, mode: .mute)
        case .pushToToggle:
            handleMomentary(phase: phase, mode: .toggle)
        }
    }

    private enum MomentaryMode {
        case talk
        case mute
        case toggle
    }

    private func handleMomentary(phase: HotkeyPhase, mode: MomentaryMode) {
        switch phase {
        case .pressed:
            guard case .none = momentaryHold else { return }
            let wasMuted = mic.desiredMuted || mic.isMuted
            let targetMuted: Bool
            switch mode {
            case .talk:
                momentaryHold = .pushToTalk(wasMuted: wasMuted)
                targetMuted = false
            case .mute:
                momentaryHold = .pushToMute(wasMuted: wasMuted)
                targetMuted = true
            case .toggle:
                momentaryHold = .pushToToggle(wasMuted: wasMuted)
                targetMuted = !wasMuted
            }
            let changed = (mic.isMuted || mic.desiredMuted) != targetMuted
            if changed {
                mic.setMuted(targetMuted)
            }
            // Always present HUD for hold (stays up until release when not floating).
            handleMuteChanged(showHUD: true)
        case .released:
            let wasMuted: Bool?
            switch (mode, momentaryHold) {
            case (.talk, .pushToTalk(let w)),
                 (.mute, .pushToMute(let w)),
                 (.toggle, .pushToToggle(let w)):
                wasMuted = w
            default:
                wasMuted = nil
            }
            guard let wasMuted else { return }
            momentaryHold = .none
            let currentlyMuted = mic.isMuted || mic.desiredMuted
            if currentlyMuted != wasMuted {
                mic.setMuted(wasMuted)
                // Toast shows restored state then auto-hides (hold already cleared).
                handleMuteChanged(showHUD: true)
            } else if !preferences.hudFloating, preferences.hudEnabled {
                // End hold-visible HUD with a short toast (no second sound if state unchanged).
                updateIcon()
                presentHUD(muted: currentDisplayMuted(), userInitiated: true)
            }
        }
    }

    private func toggleFromUser() {
        mic.toggle()
        handleMuteChanged(showHUD: true)
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            toggleFromUser()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenuFromStatusItem()
        } else {
            toggleFromUser()
        }
    }

    private func showMenuFromStatusItem() {
        guard let button = statusItem?.button else { return }
        let menu = buildMenu()
        statusItem?.menu = menu
        button.performClick(nil)
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.menu = nil
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let statusTitle: String = {
            switch mic.state {
            case .muted: return "Status: Muted"
            case .unmuted: return "Status: Unmuted"
            case .unknown: return "Status: Unknown"
            case .unsupported(let name): return "Status: Can’t mute (\(name))"
            }
        }()
        let statusLine = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        let deviceItem = NSMenuItem(title: "Device: \(mic.deviceName)", action: nil, keyEquivalent: "")
        deviceItem.isEnabled = false
        menu.addItem(deviceItem)

        let scopeItem = NSMenuItem(
            title: preferences.muteAllInputs ? "Scope: All input devices" : "Scope: Default input only",
            action: nil,
            keyEquivalent: ""
        )
        scopeItem.isEnabled = false
        menu.addItem(scopeItem)

        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: mic.isMuted ? "Unmute Microphone" : "Mute Microphone",
            action: #selector(menuToggle),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let muteAll = NSMenuItem(
            title: "Mute All Input Devices",
            action: #selector(toggleMuteAllInputs),
            keyEquivalent: ""
        )
        muteAll.target = self
        muteAll.state = preferences.muteAllInputs ? .on : .off
        menu.addItem(muteAll)

        if preferences.hudFloating {
            menu.addItem(.separator())
            let floatingHeader = NSMenuItem(title: "Floating HUD", action: nil, keyEquivalent: "")
            floatingHeader.isEnabled = false
            menu.addItem(floatingHeader)

            for screen in hud.screenVisibilities() {
                let item = NSMenuItem(
                    title: screen.name,
                    action: #selector(toggleFloatingHUDOnDisplay(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = screen.id
                item.state = screen.isVisible ? .on : .off
                menu.addItem(item)
            }

            if hud.hasAnyHiddenDisplay() {
                let showAll = NSMenuItem(
                    title: "Show on All Displays",
                    action: #selector(showFloatingHUDOnAllDisplays),
                    keyEquivalent: ""
                )
                showAll.target = self
                menu.addItem(showAll)
            }
        }

        menu.addItem(.separator())

        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit LockMic", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func menuToggle() {
        toggleFromUser()
    }

    @objc private func toggleMuteAllInputs() {
        preferences.muteAllInputs.toggle()
        mic.preferenceMuteScopeChanged()
        handleMuteChanged(showHUD: false)
    }

    @objc private func toggleFloatingHUDOnDisplay(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let currentlyVisible = sender.state == .on
        hud.setDisplayHidden(id, hidden: currentlyVisible)
    }

    @objc private func showFloatingHUDOnAllDisplays() {
        hud.setAllDisplaysHidden(false)
    }

    @objc private func openPreferences() {
        if preferencesWindow == nil {
            let view = PreferencesView(preferences: preferences, mic: mic)
            let hosting = NSHostingController(rootView: view)
            hosting.view.wantsLayer = true
            hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
            let window = NSWindow(contentViewController: hosting)
            window.title = "LockMic Preferences"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.minSize = NSSize(width: 520, height: 380)
            window.setContentSize(NSSize(width: 560, height: 460))
            window.isOpaque = false
            window.backgroundColor = .clear
            window.center()
            window.isReleasedWhenClosed = false
            preferencesWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func updateIcon() {
        statusItem?.button?.image = statusImage(symbolName: symbolName(for: mic.state))
        statusItem?.button?.toolTip = tooltip(for: mic.state)
        statusItem?.isVisible = true
    }

    private func symbolName(for state: MicState) -> String {
        switch state {
        case .muted: return "mic.slash.fill"
        case .unmuted: return "mic.fill"
        case .unknown: return "mic"
        case .unsupported: return "exclamationmark.triangle.fill"
        }
    }

    private func statusImage(symbolName: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "LockMic")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = true
        return image
    }

    private func tooltip(for state: MicState) -> String {
        let holdLine: String? = {
            switch momentaryHold {
            case .none: return nil
            case .pushToTalk: return "Holding push-to-talk"
            case .pushToMute: return "Holding push-to-mute"
            case .pushToToggle: return "Holding push-to-flip"
            }
        }()

        let base: String
        switch state {
        case .muted:
            base = "LockMic: Muted — \(mic.deviceName)\nClick to unmute · Right-click for menu"
        case .unmuted:
            base = "LockMic: Unmuted — \(mic.deviceName)\nClick to mute · Right-click for menu"
        case .unknown:
            base = "LockMic: Microphone state unknown"
        case .unsupported(let name):
            base = "LockMic: Cannot mute \(name)"
        }
        if let holdLine {
            return "\(base)\n\(holdLine)"
        }
        return base
    }
}
