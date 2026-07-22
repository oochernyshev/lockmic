import AppKit
import SwiftUI

@MainActor
final class StatusItemController {
    private let mic: MicController
    private let preferences: PreferencesStore
    private let hud = HUDOverlay()
    private let hotkeys = HotkeyManager()

    private var statusItem: NSStatusItem?
    private var preferencesWindow: NSWindow?
    private var cancellables: [NSObjectProtocol] = []

    init(mic: MicController, preferences: PreferencesStore) {
        self.mic = mic
        self.preferences = preferences
    }

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = statusImage(for: mic.state)
            button.imagePosition = .imageOnly
            button.toolTip = "LockMic"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        item.menu = nil
        statusItem = item

        rebuildMenu()
        registerHotkey()
        observeMic()
    }

    private func observeMic() {
        // Poll published changes via Combine-less simple observation on main after actions.
        // Also refresh icon when app becomes active.
        let center = NotificationCenter.default
        cancellables.append(
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.mic.refreshFromHardware(applyDesired: false)
                    self?.updateIcon()
                }
            }
        )
    }

    func handleMuteChanged(showHUD: Bool) {
        updateIcon()
        rebuildMenu()
        if showHUD, preferences.hudEnabled {
            let displayMuted: Bool = {
                switch mic.state {
                case .muted: return true
                case .unmuted: return false
                default: return mic.desiredMuted
                }
            }()
            hud.show(muted: displayMuted, deviceName: mic.deviceName)
        }
    }

    private func registerHotkey() {
        let chords = preferences.activeHotkeys
        NSLog("LockMic: registering shortcuts %@", preferences.hotkeyDisplayString)
        hotkeys.register(chords: chords) { [weak self] in
            DispatchQueue.main.async {
                self?.toggleFromUser()
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
            statusItem?.menu = buildMenu()
            statusItem?.button?.performClick(nil)
            // Clear menu after so left-click remains toggle
            DispatchQueue.main.async { [weak self] in
                self?.statusItem?.menu = nil
            }
        } else {
            toggleFromUser()
        }
    }

    private func rebuildMenu() {
        // Menu is attached on right-click only; keep icon in sync.
        updateIcon()
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
        let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

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

    @objc private func openPreferences() {
        if preferencesWindow == nil {
            let view = PreferencesView(preferences: preferences, mic: mic)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "LockMic Preferences"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 440, height: 380))
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
        statusItem?.button?.image = statusImage(for: mic.state)
        statusItem?.button?.toolTip = tooltip(for: mic.state)
    }

    private func statusImage(for state: MicState) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let name: String
        switch state {
        case .muted:
            name = "mic.slash.fill"
        case .unmuted:
            name = "mic.fill"
        case .unknown:
            name = "mic"
        case .unsupported:
            name = "exclamationmark.triangle.fill"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "LockMic")?
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
