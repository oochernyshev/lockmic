import AppKit
import SwiftUI

@MainActor
final class StatusItemController {
    private let mic: MicController
    private let preferences: PreferencesStore
    private let recorder: SessionRecorder
    private let hud: HUDPresenter
    private let hotkeys: HotkeyCoordinator
    private let recording: RecordingCoordinator
    private let sounds = SoundFeedback()

    private var statusItem: NSStatusItem?
    private var preferencesWindow: NSWindow?
    private var cancellables: [NSObjectProtocol] = []
    private var visibilityTimer: Timer?
    private var reportedMenuBarIconVisible: Bool?
    private var visibilityMismatchCount = 0
    /// Red “update available” badge overlaid on the menu bar button.
    private var updateBadgeView: NSView?
    /// Debounced: menu bar icon on-screen vs hidden (camera housing / overcrowding).
    var onMenuBarIconVisibilityChange: ((Bool) -> Void)?
    /// Last known consent so we only re-apply the feature gate on a real change.
    private var lastFeaturesEnabled: Bool?

    private var featuresEnabled: Bool { preferences.featuresEnabled }

    init(mic: MicController, preferences: PreferencesStore, recorder: SessionRecorder) {
        self.mic = mic
        self.preferences = preferences
        self.recorder = recorder
        self.hud = HUDPresenter(preferences: preferences)
        self.hotkeys = HotkeyCoordinator(mic: mic, preferences: preferences)
        self.recording = RecordingCoordinator(recorder: recorder, preferences: preferences, mic: mic)

        hotkeys.onMuteChanged = { [weak self] showHUD, playSound in
            self?.handleMuteChanged(showHUD: showHUD, playSound: playSound)
        }
        hotkeys.onStartRecording = { [weak self] in
            self?.recording.startIfIdle(source: .keyboard)
        }
        hotkeys.onStopRecording = { [weak self] in
            self?.recording.stop(source: .keyboard)
        }
        recording.onSessionChanged = { [weak self] in
            self?.handleMuteChanged(showHUD: false)
        }
        recording.onToggleMute = { [weak self] in
            self?.toggleFromUser(source: .hud)
        }
        recording.onPresentError = { [weak self] error in
            self?.presentRecordingError(error)
        }
        hud.overlay.onToggle = { [weak self] in
            self?.toggleFromUser(source: .hud)
        }
        hud.overlay.onStopRecording = { [weak self] in
            self?.recording.stop(source: .hud)
        }
    }

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Persist position so users can ⌘-drag the icon among menu bar extras.
        item.autosaveName = "LockMicStatusItem"
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

        applyFeatureAvailability(force: true)
        observeMic()
        observePreferenceHotkeys()
        observeUpdateAvailability()
        startMenuBarVisibilityMonitoring()
        refreshUpdateBadge()
    }

    /// Left-click Dock tile: toggle mute (or open Preferences when features are disabled).
    func handleDockClick() {
        if featuresEnabled {
            toggleFromUser(source: .dock)
        } else {
            presentPreferences(source: .menu)
        }
    }

    /// Re-apply HUD Dock art after activation-policy changes (macOS resets to bundle icon).
    func refreshDockIcon() {
        updateDockIcon()
    }

    // MARK: - Menu bar icon visibility

    private func startMenuBarVisibilityMonitoring() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refreshMenuBarIconVisibility(force: true)
        }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshMenuBarIconVisibility(force: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        visibilityTimer = timer

        cancellables.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshMenuBarIconVisibility(force: true)
                }
            }
        )
    }

    private func refreshMenuBarIconVisibility(force: Bool) {
        let visible = StatusItemVisibility.isIconVisiblyPlaced(statusItem: statusItem)

        if force || reportedMenuBarIconVisible == nil {
            visibilityMismatchCount = 0
            publishMenuBarIconVisibility(visible)
            return
        }
        if visible == reportedMenuBarIconVisible {
            visibilityMismatchCount = 0
            return
        }
        // Two consecutive samples (~2s) before flipping Dock policy — avoids flicker.
        visibilityMismatchCount += 1
        if visibilityMismatchCount >= 2 {
            visibilityMismatchCount = 0
            publishMenuBarIconVisibility(visible)
        }
    }

    private func publishMenuBarIconVisibility(_ visible: Bool) {
        guard reportedMenuBarIconVisible != visible else { return }
        reportedMenuBarIconVisible = visible
        onMenuBarIconVisibilityChange?(visible)
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
                    self.refreshMenuBarIconVisibility(force: false)
                    if self.hotkeys.isHoldActive {
                        self.mic.refreshDeviceList()
                        self.updateIcon()
                        return
                    }
                    self.mic.refreshFromHardware(applyDesired: true)
                    self.updateIcon()
                    self.recording.retryCaptureIfAccessGranted()
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
                    self?.hotkeys.registerIfNeeded(enabled: self?.featuresEnabled == true)
                    self?.syncFloatingHUDIfNeeded()
                }
            }
        )
    }

    private func observeUpdateAvailability() {
        cancellables.append(
            NotificationCenter.default.addObserver(
                forName: .lockMicUpdatesDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.updateIcon()
                    self?.hud.refreshUpdateBadge()
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
            hotkeys.disable()
            hud.hide()
        } else {
            hotkeys.registerIfNeeded(force: true, enabled: true)
            syncFloatingHUDIfNeeded(force: true)
        }
        updateIcon()
    }

    /// - Parameters:
    ///   - showHUD: present toast/floating update when appropriate.
    ///   - playSound: defaults to `showHUD`. Pass `false` for hold UI with no mute change.
    func handleMuteChanged(showHUD: Bool, playSound: Bool? = nil) {
        updateIcon()
        guard featuresEnabled else { return }

        let muted = mic.effectiveMuted
        let shouldPlay = playSound ?? showHUD

        if shouldPlay, preferences.soundEnabled, !recorder.isRecording {
            sounds.play(muted: muted)
        }

        hud.present(
            muted: muted,
            userInitiated: showHUD,
            hold: hotkeys.hudHold,
            recording: recorder.isRecording,
            featuresEnabled: true
        )
    }

    func syncFloatingHUD() {
        syncFloatingHUDIfNeeded(force: true)
    }

    private func syncFloatingHUDIfNeeded(force: Bool = false) {
        hud.syncFloating(
            muted: mic.effectiveMuted,
            hold: hotkeys.hudHold,
            recording: recorder.isRecording,
            featuresEnabled: featuresEnabled,
            force: force
        )
    }

    private func toggleFromUser(source: UsageReporter.ActivationSource) {
        guard featuresEnabled else {
            presentPreferences(source: .menuBar)
            return
        }
        UsageReporter.record(.toggle, source: source)
        mic.toggle()
        handleMuteChanged(showHUD: true)
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            if featuresEnabled {
                toggleFromUser(source: .menuBar)
            } else {
                showMenuFromStatusItem()
            }
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenuFromStatusItem()
        } else if featuresEnabled {
            toggleFromUser(source: .menuBar)
        } else {
            showMenuFromStatusItem()
        }
    }

    private func showMenuFromStatusItem() {
        guard let button = statusItem?.button else { return }
        let menu = makeContextMenu(includeQuit: true)
        statusItem?.menu = menu
        button.performClick(nil)
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.menu = nil
        }
    }

    /// Dock right-click menu (same actions as the menu bar; system already provides Quit).
    func makeDockMenu() -> NSMenu {
        makeContextMenu(includeQuit: false)
    }

    /// Shared menu for the status item and Dock tile.
    private func makeContextMenu(includeQuit: Bool) -> NSMenu {
        let menu = NSMenu()
        // Display HUD checkboxes share one action; `.automatic` can treat that as
        // select-one (radio), so one monitor stays checked and "deselect all" fails.
        menu.selectionMode = .selectAny

        if !featuresEnabled {
            let disabled = NSMenuItem(
                title: L10n.menuStatusDisabled,
                action: nil,
                keyEquivalent: ""
            )
            disabled.isEnabled = false
            menu.addItem(disabled)

            let hint = NSMenuItem(
                title: L10n.menuAgreeHint,
                action: nil,
                keyEquivalent: ""
            )
            hint.isEnabled = false
            menu.addItem(hint)

            menu.addItem(.separator())

            let agree = NSMenuItem(
                title: L10n.menuAgreeEnable,
                action: #selector(agreeAndEnable),
                keyEquivalent: ""
            )
            agree.target = self
            menu.addItem(agree)

            menu.addItem(.separator())
            appendUpdateMenuItems(to: menu)

            let prefs = NSMenuItem(title: L10n.menuPreferences, action: #selector(openPreferences), keyEquivalent: "")
            prefs.target = self
            menu.addItem(prefs)

            if includeQuit {
                menu.addItem(.separator())
                let quit = NSMenuItem(title: L10n.menuQuit, action: #selector(quit), keyEquivalent: "q")
                quit.target = self
                menu.addItem(quit)
            }
            return menu
        }

        let statusTitle: String = {
            switch mic.state {
            case .muted: return L10n.menuStatusMuted
            case .unmuted: return L10n.menuStatusUnmuted
            case .unknown: return L10n.menuStatusUnknown
            case .unsupported(let name): return L10n.menuStatusCantMute(name)
            }
        }()
        let statusLine = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        let deviceItem = NSMenuItem(title: L10n.menuDevice(mic.deviceName), action: nil, keyEquivalent: "")
        deviceItem.isEnabled = false
        menu.addItem(deviceItem)

        let scopeItem = NSMenuItem(
            title: preferences.muteAllInputs ? L10n.menuScopeAll : L10n.menuScopeDefault,
            action: nil,
            keyEquivalent: ""
        )
        scopeItem.isEnabled = false
        menu.addItem(scopeItem)

        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: mic.effectiveMuted ? L10n.menuUnmuteMic : L10n.menuMuteMic,
            action: #selector(menuToggle),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.image = NSImage.menuItemSymbol(mic.effectiveMuted ? "mic.slash.fill" : "mic.fill")
        menu.addItem(toggle)

        let muteAll = NSMenuItem(
            title: L10n.menuMuteAll,
            action: #selector(toggleMuteAllInputs),
            keyEquivalent: ""
        )
        muteAll.target = self
        muteAll.state = preferences.muteAllInputs ? .on : .off
        menu.addItem(muteAll)

        menu.addItem(.separator())

        let record = NSMenuItem(
            title: recorder.isRecording ? L10n.menuStopRecording : L10n.menuStartRecording,
            action: #selector(toggleRecording),
            keyEquivalent: ""
        )
        record.target = self
        record.image = NSImage.menuItemSymbol(recorder.isRecording ? "stop.circle" : "record.circle")
        menu.addItem(record)

        let showRecordings = NSMenuItem(
            title: L10n.menuShowRecordings,
            action: #selector(showRecordingsFolder),
            keyEquivalent: ""
        )
        showRecordings.target = self
        menu.addItem(showRecordings)

        if recorder.isRecording {
            let showMonitor = NSMenuItem(
                title: L10n.menuShowRecordingMonitor,
                action: #selector(showRecordingMonitor),
                keyEquivalent: ""
            )
            showMonitor.target = self
            menu.addItem(showMonitor)
        }

        if preferences.hudFloating {
            menu.addItem(.separator())
            let floatingHeader = NSMenuItem(title: L10n.menuFloatingHUD, action: nil, keyEquivalent: "")
            floatingHeader.isEnabled = false
            menu.addItem(floatingHeader)

            for screen in hud.overlay.screenVisibilities() {
                let item = NSMenuItem(
                    title: screen.name,
                    action: #selector(toggleFloatingHUDOnDisplay(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = screen.id
                item.identifier = NSUserInterfaceItemIdentifier("lockmic.hud.display.\(screen.id)")
                if let numeric = UInt32(screen.id) {
                    item.tag = Int(numeric)
                }
                item.state = screen.isVisible ? .on : .off
                menu.addItem(item)
            }

            if hud.overlay.hasAnyVisibleDisplay() {
                let hideAll = NSMenuItem(
                    title: L10n.menuHideAllDisplays,
                    action: #selector(hideFloatingHUDOnAllDisplays),
                    keyEquivalent: ""
                )
                hideAll.target = self
                menu.addItem(hideAll)
            }
            if hud.overlay.hasAnyHiddenDisplay() {
                let showAll = NSMenuItem(
                    title: L10n.menuShowAllDisplays,
                    action: #selector(showFloatingHUDOnAllDisplays),
                    keyEquivalent: ""
                )
                showAll.target = self
                menu.addItem(showAll)
            }
        }

        menu.addItem(.separator())

        appendUpdateMenuItems(to: menu)

        let prefs = NSMenuItem(title: L10n.menuPreferences, action: #selector(openPreferences), keyEquivalent: "")
        prefs.target = self
        menu.addItem(prefs)

        if includeQuit {
            menu.addItem(.separator())
            let quit = NSMenuItem(title: L10n.menuQuit, action: #selector(quit), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
        }

        return menu
    }

    private func appendUpdateMenuItems(to menu: NSMenu) {
        guard let update = UpdateChecker.shared.availableUpdate else { return }

        let title = L10n.menuUpdateAvailable(update.version)
        let updateItem = NSMenuItem(
            title: title,
            action: #selector(installAvailableUpdate),
            keyEquivalent: ""
        )
        updateItem.target = self
        updateItem.attributedTitle = Self.updateMenuAttributedTitle(title)
        menu.addItem(updateItem)

        let skip = NSMenuItem(
            title: L10n.menuSkipUpdate,
            action: #selector(skipAvailableUpdate),
            keyEquivalent: ""
        )
        skip.target = self
        menu.addItem(skip)
        menu.addItem(.separator())
    }

    /// Red “● Update to …” — Dock menus ignore item images, so the marker lives in the title.
    private static func updateMenuAttributedTitle(_ title: String) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: "●  ",
            attributes: [
                .font: font,
                .foregroundColor: NSColor.systemRed,
            ]
        ))
        result.append(NSAttributedString(
            string: title,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]
        ))
        return result
    }

    @objc private func agreeAndEnable() {
        preferences.shareAnonymousUsage = true
        applyFeatureAvailability(force: true)
    }

    @objc private func menuToggle() {
        toggleFromUser(source: .menu)
    }

    @objc private func toggleRecording() {
        recording.toggle(source: .menu)
    }

    @objc private func showRecordingMonitor() {
        recording.showMonitor()
    }

    @objc private func showRecordingsFolder() {
        recording.showRecordingsFolder()
    }

    func finalizeRecordingForQuit() async {
        await recording.finalizeForQuit()
    }

    private func presentRecordingError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.recordingAlertTitle
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.recordingAlertOK)
        alert.runModal()
    }

    @objc private func toggleMuteAllInputs() {
        guard featuresEnabled else { return }
        preferences.muteAllInputs.toggle()
        mic.preferenceMuteScopeChanged()
        handleMuteChanged(showHUD: false)
    }

    @objc private func toggleFloatingHUDOnDisplay(_ sender: NSMenuItem) {
        guard let id = displayID(from: sender) else { return }
        hud.overlay.toggleDisplayHidden(id)
    }

    @objc private func hideFloatingHUDOnAllDisplays() {
        hud.overlay.setAllDisplaysHidden(true)
    }

    @objc private func showFloatingHUDOnAllDisplays() {
        hud.overlay.setAllDisplaysHidden(false)
    }

    /// Dock menus copy items and may drop `representedObject`; `tag` survives.
    private func displayID(from item: NSMenuItem) -> String? {
        if let id = item.representedObject as? String, !id.isEmpty {
            return id
        }
        if item.tag != 0 {
            return String(UInt32(truncatingIfNeeded: item.tag))
        }
        return nil
    }

    @objc private func openPreferences() {
        presentPreferences(source: .menu)
    }

    @objc private func installAvailableUpdate() {
        presentPreferences(source: .menu, tab: .about)
    }

    @objc private func skipAvailableUpdate() {
        UpdateChecker.shared.skipAvailableUpdate()
    }

    private func presentPreferences(
        source: UsageReporter.ActivationSource,
        tab: PreferencesTab = .general
    ) {
        if featuresEnabled {
            UsageReporter.record(.openPreferences, source: source)
        }
        if preferencesWindow == nil {
            let view = PreferencesView(
                preferences: preferences,
                mic: mic,
                recorder: recorder,
                initialTab: tab
            )
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
        } else {
            NotificationCenter.default.post(
                name: .lockMicOpenPreferencesTab,
                object: tab.rawValue
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func updateIcon() {
        statusItem?.button?.appearsDisabled = false
        statusItem?.button?.image = featuresEnabled
            ? statusImage(symbolName: symbolName(for: mic.state))
            : disabledStatusImage()
        statusItem?.button?.toolTip = tooltip(for: mic.state)
        statusItem?.isVisible = true
        refreshUpdateBadge()
        updateDockIcon()
    }

    private func updateDockIcon() {
        let style = DockIconRenderer.style(
            featuresEnabled: featuresEnabled,
            state: mic.state,
            effectiveMuted: mic.effectiveMuted
        )
        let updateAvailable = UpdateChecker.shared.availableUpdate != nil
        NSApp.applicationIconImage = DockIconRenderer.image(style: style, updateAvailable: updateAvailable)
    }

    /// Small red dot on the menu bar status button when a newer release exists.
    private func refreshUpdateBadge() {
        guard let button = statusItem?.button else { return }
        let show = UpdateChecker.shared.availableUpdate != nil

        if !show {
            updateBadgeView?.removeFromSuperview()
            updateBadgeView = nil
            return
        }

        let badge: NSView
        if let existing = updateBadgeView {
            badge = existing
        } else {
            badge = NSView(frame: .zero)
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor.systemRed.cgColor
            badge.layer?.cornerRadius = 3.5
            badge.layer?.masksToBounds = true
            badge.translatesAutoresizingMaskIntoConstraints = true
            button.addSubview(badge)
            updateBadgeView = badge
        }

        let diameter: CGFloat = 7
        let inset: CGFloat = 1
        let size = button.bounds.size
        let isFlipped = button.isFlipped
        let x = max(0, size.width - diameter - inset)
        let y: CGFloat = isFlipped ? inset : max(0, size.height - diameter - inset)
        badge.frame = NSRect(x: x, y: y, width: diameter, height: diameter)
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
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
        menuBarSymbolImage(systemName: symbolName, accessibilityDescription: "LockMic")
    }

    private func disabledStatusImage() -> NSImage {
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
            switch hotkeys.hudHold {
            case .none: return nil
            case .talk: return "Holding push-to-talk"
            case .mute: return "Holding push-to-mute"
            case .flip: return "Holding push-to-flip"
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

        var lines = [base]
        if let holdLine {
            lines.append(holdLine)
        }
        if let update = UpdateChecker.shared.availableUpdate {
            lines.append(L10n.menuUpdateAvailable(update.version))
        }
        return lines.joined(separator: "\n")
    }
}

extension NSImage {
    /// Square template glyph for `NSMenuItem`. Raw SF Symbols carry a short, wide
    /// `alignmentRect` that AppKit uses to lay out menu icons, which squashes them.
    static func menuItemSymbol(_ name: String) -> NSImage? {
        let canvas = NSSize(width: 16, height: 16)
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
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
}
