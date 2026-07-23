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
    /// Active momentary hold (push-to-talk / mute / flip).
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
    /// Last known consent so we only re-apply the feature gate on a real change.
    private var lastFeaturesEnabled: Bool?

    private var featuresEnabled: Bool { preferences.featuresEnabled }

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

        applyFeatureAvailability(force: true)
        observeMic()
        observePreferenceHotkeys()
    }

    private func observeMic() {
        cancellables.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    // Mid PTT/PTM/flip: do not re-read HAL into desiredMuted — that
                    // would desync restore-on-release. Device list only is safe.
                    if self.momentaryHold.isActive {
                        self.mic.refreshDeviceList()
                        self.updateIcon()
                        return
                    }
                    self.mic.refreshFromHardware(applyDesired: false)
                    self.updateIcon()
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
                    self?.applyFeatureAvailability()
                    self?.registerHotkeysIfNeeded()
                    self?.syncFloatingHUDIfNeeded()
                }
            }
        )
    }

    /// Enable or disable mute/hotkeys/HUD based on anonymous-stats agreement.
    private func applyFeatureAvailability(force: Bool = false) {
        let enabled = featuresEnabled
        guard force || lastFeaturesEnabled != enabled else { return }
        lastFeaturesEnabled = enabled

        if !enabled {
            endMomentaryHoldForDisable()
            lastRegisteredBindings = []
            hotkeys.register(bindings: []) { _, _ in }
            hud.hide()
            lastHudFloating = false
        } else {
            registerHotkeysIfNeeded(force: true)
            syncFloatingHUDIfNeeded(force: true)
        }
        updateIcon()
    }

    private func endMomentaryHoldForDisable() {
        guard momentaryHold.isActive else { return }
        momentaryHold = .none
        mic.suppressDeviceResync = false
    }

    /// - Parameters:
    ///   - showHUD: present toast/floating update when appropriate.
    ///   - playSound: defaults to `showHUD`. Pass `false` for hold UI with no mute change.
    func handleMuteChanged(showHUD: Bool, playSound: Bool? = nil) {
        updateIcon()
        guard featuresEnabled else { return }

        let muted = mic.effectiveMuted
        let shouldPlay = playSound ?? showHUD

        if shouldPlay, preferences.soundEnabled {
            sounds.play(muted: muted)
        }

        presentHUD(muted: muted, userInitiated: showHUD)
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
        guard featuresEnabled else {
            if lastHudFloating != false {
                hud.hide()
                lastHudFloating = false
            }
            return
        }

        let floating = preferences.hudFloating
        guard force || floating != lastHudFloating else { return }

        if floating {
            hud.show(
                muted: mic.effectiveMuted,
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

    private func registerHotkeysIfNeeded(force: Bool = false) {
        let bindings = featuresEnabled ? preferences.activeBindings : []
        guard force || bindings != lastRegisteredBindings else { return }
        lastRegisteredBindings = bindings
        hotkeys.register(bindings: bindings) { [weak self] action, phase in
            DispatchQueue.main.async {
                self?.handleHotkeyAction(action, phase: phase)
            }
        }
    }

    private func handleHotkeyAction(_ action: HotkeyAction, phase: HotkeyPhase) {
        guard featuresEnabled else { return }
        switch action {
        case .toggle:
            guard phase == .pressed, !momentaryHold.isActive else { return }
            toggleFromUser()
        case .mute:
            guard phase == .pressed, !momentaryHold.isActive else { return }
            guard !mic.effectiveMuted else { return }
            UsageReporter.record(.mute)
            mic.setMuted(true)
            handleMuteChanged(showHUD: true)
        case .unmute:
            guard phase == .pressed, !momentaryHold.isActive else { return }
            guard mic.effectiveMuted else { return }
            UsageReporter.record(.unmute)
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
        guard featuresEnabled else { return }
        switch phase {
        case .pressed:
            guard case .none = momentaryHold else { return }
            let wasMuted = mic.effectiveMuted
            let targetMuted: Bool
            switch mode {
            case .talk:
                UsageReporter.record(.pushToTalk)
                momentaryHold = .pushToTalk(wasMuted: wasMuted)
                targetMuted = false
            case .mute:
                UsageReporter.record(.pushToMute)
                momentaryHold = .pushToMute(wasMuted: wasMuted)
                targetMuted = true
            case .toggle:
                UsageReporter.record(.pushToFlip)
                momentaryHold = .pushToToggle(wasMuted: wasMuted)
                targetMuted = !wasMuted
            }
            mic.suppressDeviceResync = true
            let changed = mic.effectiveMuted != targetMuted
            if changed {
                mic.setMuted(targetMuted)
            }
            // Always show hold HUD; sound only when mute actually changed.
            handleMuteChanged(showHUD: true, playSound: changed)
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
            mic.suppressDeviceResync = false
            if mic.effectiveMuted != wasMuted {
                mic.setMuted(wasMuted)
                // Toast shows restored state then auto-hides (hold already cleared).
                handleMuteChanged(showHUD: true, playSound: true)
            } else {
                // End hold UI without a second beep.
                handleMuteChanged(showHUD: true, playSound: false)
            }
            // Catch up: re-apply post-hold desired mute to any devices that appeared mid-hold.
            mic.refreshFromHardware(applyDesired: true)
            updateIcon()
        }
    }

    private func toggleFromUser() {
        guard featuresEnabled else {
            openPreferences()
            return
        }
        UsageReporter.record(.toggle)
        mic.toggle()
        handleMuteChanged(showHUD: true)
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            if featuresEnabled {
                toggleFromUser()
            } else {
                showMenuFromStatusItem()
            }
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenuFromStatusItem()
        } else if featuresEnabled {
            toggleFromUser()
        } else {
            // Left-click while disabled: open menu so agreement is one click away.
            showMenuFromStatusItem()
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

        if !featuresEnabled {
            let disabled = NSMenuItem(
                title: "Status: Disabled — agreement required",
                action: nil,
                keyEquivalent: ""
            )
            disabled.isEnabled = false
            menu.addItem(disabled)

            let hint = NSMenuItem(
                title: "Agree to anonymous stats to enable mute control",
                action: nil,
                keyEquivalent: ""
            )
            hint.isEnabled = false
            menu.addItem(hint)

            menu.addItem(.separator())

            let agree = NSMenuItem(
                title: "Agree & Enable LockMic",
                action: #selector(agreeAndEnable),
                keyEquivalent: ""
            )
            agree.target = self
            menu.addItem(agree)

            let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
            prefs.target = self
            menu.addItem(prefs)

            menu.addItem(.separator())

            let quit = NSMenuItem(title: "Quit LockMic", action: #selector(quit), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
            return menu
        }

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
            title: mic.effectiveMuted ? "Unmute Microphone" : "Mute Microphone",
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

    @objc private func agreeAndEnable() {
        preferences.shareAnonymousUsage = true
        applyFeatureAvailability(force: true)
    }

    @objc private func menuToggle() {
        toggleFromUser()
    }

    @objc private func toggleMuteAllInputs() {
        guard featuresEnabled else { return }
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
        if featuresEnabled {
            UsageReporter.record(.openPreferences)
        }
        if preferencesWindow == nil {
            let view = PreferencesView(preferences: preferences, mic: mic)
                .onExitCommand { [weak self] in
                    self?.preferencesWindow?.performClose(nil)
                }
            let hosting = NSHostingController(rootView: view)
            hosting.view.wantsLayer = true
            hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
            let window = EscapeToCloseWindow(contentViewController: hosting)
            window.title = "LockMic Preferences"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.minSize = NSSize(
                width: PreferencesChrome.windowMinSize.width,
                height: PreferencesChrome.windowMinSize.height
            )
            window.setContentSize(NSSize(
                width: PreferencesChrome.windowIdealSize.width,
                height: PreferencesChrome.windowIdealSize.height
            ))
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
        // Never use appearsDisabled — it greys/shrinks the menu-bar glyph and looks broken.
        statusItem?.button?.appearsDisabled = false
        statusItem?.button?.image = featuresEnabled
            ? statusImage(symbolName: symbolName(for: mic.state))
            : disabledStatusImage()
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

    /// Menu-bar template icon sized to match system status items (~18pt cell).
    private func statusImage(symbolName: String) -> NSImage {
        menuBarSymbolImage(systemName: symbolName, accessibilityDescription: "LockMic")
    }

    /// Full-size “needs agreement” icon — same visual weight as mute/unmute, not a tiny nested glyph.
    private func disabledStatusImage() -> NSImage {
        // Distinct from mute (mic.slash): raised hand = permission / agreement required.
        menuBarSymbolImage(
            systemName: "hand.raised.fill",
            accessibilityDescription: "LockMic disabled — agreement required",
            weight: .semibold
        )
    }

    private func menuBarSymbolImage(
        systemName: String,
        accessibilityDescription: String,
        weight: NSFont.Weight = .medium
    ) -> NSImage {
        let pointSize: CGFloat = 16
        let canvas = NSSize(width: 18, height: 18)
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(scale: .large))

        guard let symbol = NSImage(systemSymbolName: systemName, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(config) else {
            return NSImage(size: canvas)
        }

        // Draw into a fixed canvas so compound SF Symbols don’t shrink in the status item.
        let image = NSImage(size: canvas, flipped: false) { bounds in
            let symbolSize = symbol.size
            let scale = min(bounds.width / max(symbolSize.width, 1), bounds.height / max(symbolSize.height, 1))
            let drawSize = NSSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
            let origin = NSPoint(
                x: bounds.midX - drawSize.width / 2,
                y: bounds.midY - drawSize.height / 2
            )
            symbol.draw(
                in: NSRect(origin: origin, size: drawSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            return true
        }
        image.isTemplate = true
        return image
    }

    private func tooltip(for state: MicState) -> String {
        if !featuresEnabled {
            return "LockMic: Disabled\nAgree to anonymous usage statistics to enable\nClick for menu · Preferences to agree"
        }

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
