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
    /// Tracks last applied floating preference so we only hide on a true off transition.
    private var lastHudFloating: Bool?
    /// Active momentary hold (push-to-talk / push-to-mute).
    private enum MomentaryHold {
        case none
        case pushToTalk(wasMuted: Bool)
        case pushToMute(wasMuted: Bool)

        var isActive: Bool {
            if case .none = self { return false }
            return true
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
        // Re-register shortcuts and sync floating HUD when Preferences change.
        cancellables.append(
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.registerHotkeys()
                    self?.syncFloatingHUD()
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

        if preferences.hudFloating {
            hud.show(muted: displayMuted, deviceName: mic.deviceName, persistent: true)
        } else if showHUD, preferences.hudEnabled {
            hud.show(muted: displayMuted, deviceName: mic.deviceName, persistent: false)
        }
    }

    /// Show or hide the always-on floating mute indicator based on preference.
    func syncFloatingHUD() {
        let floating = preferences.hudFloating
        if floating {
            hud.show(muted: currentDisplayMuted(), deviceName: mic.deviceName, persistent: true)
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
        hotkeys.register(bindings: preferences.activeBindings) { [weak self] action, phase in
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
            handlePushToTalk(phase: phase)
        case .pushToMute:
            handlePushToMute(phase: phase)
        }
    }

    private func handlePushToTalk(phase: HotkeyPhase) {
        switch phase {
        case .pressed:
            guard case .none = momentaryHold else { return }
            let wasMuted = mic.desiredMuted || mic.isMuted
            momentaryHold = .pushToTalk(wasMuted: wasMuted)
            if wasMuted {
                mic.setMuted(false)
                handleMuteChanged(showHUD: true)
            }
        case .released:
            guard case .pushToTalk(let wasMuted) = momentaryHold else { return }
            momentaryHold = .none
            if wasMuted {
                mic.setMuted(true)
                handleMuteChanged(showHUD: true)
            }
        }
    }

    private func handlePushToMute(phase: HotkeyPhase) {
        switch phase {
        case .pressed:
            guard case .none = momentaryHold else { return }
            let wasMuted = mic.desiredMuted || mic.isMuted
            momentaryHold = .pushToMute(wasMuted: wasMuted)
            if !wasMuted {
                mic.setMuted(true)
                handleMuteChanged(showHUD: true)
            }
        case .released:
            guard case .pushToMute(let wasMuted) = momentaryHold else { return }
            momentaryHold = .none
            if !wasMuted {
                mic.setMuted(false)
                handleMuteChanged(showHUD: true)
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
        switch state {
        case .muted:
            return "LockMic: Muted — \(mic.deviceName)\nClick to unmute · Right-click for menu"
        case .unmuted:
            return "LockMic: Unmuted — \(mic.deviceName)\nClick to mute · Right-click for menu"
        case .unknown:
            return "LockMic: Microphone state unknown"
        case .unsupported(let name):
            return "LockMic: Cannot mute \(name)"
        }
    }
}
