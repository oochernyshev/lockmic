import AppKit
import SwiftUI

@MainActor
final class StatusItemController {
    private let mic: MicController
    private let preferences: PreferencesStore
    private let recorder: SessionRecorder
    private let hud = HUDOverlay()
    private let sounds = SoundFeedback()
    private let hotkeys = HotkeyManager()

    private var statusItem: NSStatusItem?
    private var preferencesWindow: NSWindow?
    private let recordingMonitor = RecordingMonitorController()
    private var cancellables: [NSObjectProtocol] = []
    private var visibilityTimer: Timer?
    private var reportedMenuBarIconVisible: Bool?
    private var visibilityMismatchCount = 0
    /// Red “update available” badge overlaid on the menu bar button.
    private var updateBadgeView: NSView?
    /// Debounced: menu bar icon on-screen vs hidden (camera housing / overcrowding).
    var onMenuBarIconVisibilityChange: ((Bool) -> Void)?

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

    init(mic: MicController, preferences: PreferencesStore, recorder: SessionRecorder) {
        self.mic = mic
        self.preferences = preferences
        self.recorder = recorder
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

        hud.onToggle = { [weak self] in
            self?.toggleFromUser(source: .hud)
        }
        hud.onStopRecording = { [weak self] in
            self?.stopRecordingNow(source: .hud)
        }

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
                    // Mid PTT/PTM/flip: list only — re-applying mute would clobber
                    // restore-on-release.
                    if self.momentaryHold.isActive {
                        self.mic.refreshDeviceList()
                        self.updateIcon()
                        return
                    }
                    // Re-apply sticky intent. Copying HAL here (applyDesired: false)
                    // lets Meet/Chrome unmute stick after the user clicks Dock / prefs.
                    self.mic.refreshFromHardware(applyDesired: true)
                    self.updateIcon()
                    self.retryCaptureIfAccessGranted()
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

        if shouldPlay, preferences.soundEnabled, !recorder.isRecording {
            sounds.play(muted: muted)
        }

        presentHUD(muted: muted, userInitiated: showHUD)
    }

    /// Floating = always interactive; momentary hold keeps toast HUD up without auto-hide.
    private func presentHUD(muted: Bool, userInitiated: Bool) {
        let hold = momentaryHold.hudHold
        let recording = recorder.isRecording

        if preferences.hudFloating {
            hud.show(
                muted: muted,
                deviceName: mic.deviceName,
                persistent: true,
                interactive: true,
                hold: hold,
                recording: recording
            )
            return
        }

        if recording {
            hud.show(
                muted: muted,
                deviceName: mic.deviceName,
                persistent: true,
                interactive: false,
                hold: hold,
                recording: true
            )
            return
        }

        guard preferences.hudEnabled, userInitiated || momentaryHold.isActive else {
            hud.hide()
            return
        }

        // While PTT/PTM/flip is held, keep HUD visible (non-interactive toast layout).
        let holdVisible = momentaryHold.isActive
        hud.show(
            muted: muted,
            deviceName: mic.deviceName,
            persistent: holdVisible,
            interactive: false,
            hold: hold,
            recording: recorder.isRecording
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
                hold: momentaryHold.hudHold,
                recording: recorder.isRecording
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
            toggleFromUser(source: .keyboard)
        case .mute:
            guard phase == .pressed, !momentaryHold.isActive else { return }
            guard !mic.effectiveMuted else { return }
            UsageReporter.record(.mute, source: .keyboard)
            mic.setMuted(true)
            handleMuteChanged(showHUD: true)
        case .unmute:
            guard phase == .pressed, !momentaryHold.isActive else { return }
            guard mic.effectiveMuted else { return }
            UsageReporter.record(.unmute, source: .keyboard)
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
                UsageReporter.record(.pushToTalk, source: .keyboard)
                momentaryHold = .pushToTalk(wasMuted: wasMuted)
                targetMuted = false
            case .mute:
                UsageReporter.record(.pushToMute, source: .keyboard)
                momentaryHold = .pushToMute(wasMuted: wasMuted)
                targetMuted = true
            case .toggle:
                UsageReporter.record(.pushToFlip, source: .keyboard)
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
            // Left-click while disabled: open menu so agreement is one click away.
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
        // Only when an update is known — manual “Check for Updates…” lives in Preferences → About.
        guard let update = UpdateChecker.shared.availableUpdate else { return }

        let title = L10n.menuUpdateAvailable(update.version)
        let updateItem = NSMenuItem(
            title: title,
            action: #selector(installAvailableUpdate),
            keyEquivalent: ""
        )
        updateItem.target = self
        // Dock menus ignore `NSMenuItem.image`; a red bullet in the title works
        // for both Dock and menu-bar context menus.
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
        if recorder.isRecording {
            stopRecordingNow(source: .menu)
            return
        }
        guard featuresEnabled else { return }
        Task { await startRecording(source: .menu) }
    }

    private func startRecording(source: UsageReporter.ActivationSource) async {
        let scope = currentPlaybackScope()
        recorder.previewSession(
            playback: scope,
            followInput: preferences.followDefaultMic,
            followOutput: preferences.followDefaultOutput
        )
        // Menu teardown can eat a panel shown in the same click; wait a turn.
        await nextMainRunLoopTurn()
        showRecordingMonitor()
        await beginCapture(scope: scope, source: source)
    }

    private func currentPlaybackScope() -> PlaybackRecordScope {
        preferences.recordAllPlayback && !preferences.followDefaultOutput ? .all : .default
    }

    private func beginCapture(scope: PlaybackRecordScope, source: UsageReporter.ActivationSource) async {
        do {
            try await recorder.start(
                playback: scope,
                bitRate: preferences.recordingBitRate,
                followInput: preferences.followDefaultMic,
                followOutput: preferences.followDefaultOutput,
                in: preferences.recordingsDirectory
            )
            UsageReporter.record(.startRecording, source: source)
            handleMuteChanged(showHUD: false)
            showRecordingMonitor()
        } catch SessionRecorderError.microphoneDenied, SessionRecorderError.playbackDenied {
            showRecordingMonitor()
        } catch {
            recordingMonitor.hide()
            recorder.cancelPreview()
            presentRecordingError(error)
        }
    }

    private func retryAccessFromMonitor() {
        if recorder.microphoneAccess == .denied {
            Task { await retryMicrophoneAccess() }
        } else {
            Task { await retryPlaybackAccess() }
        }
    }

    private func retryMicrophoneAccess() async {
        if await SessionRecorder.requestMicrophoneAccess() {
            await beginCapture(scope: currentPlaybackScope(), source: .monitor)
            return
        }
        openMicrophoneSettings()
    }

    private func retryPlaybackAccess() async {
        if await SystemAudioAccess.request() {
            await beginCapture(scope: currentPlaybackScope(), source: .monitor)
            return
        }
        openPlaybackSettings()
    }

    private func retryCaptureIfAccessGranted() {
        guard !recorder.isRecording, recordingMonitor.isVisible else { return }
        let blocked = recorder.microphoneAccess == .denied || recorder.playbackAccess == .denied
        guard blocked else { return }
        recorder.refreshCaptureAccess()
        // Mic (or playback) may now be granted while the other is still denied —
        // refresh chrome so the matching card undims instead of staying stuck.
        showRecordingMonitor()
        if recorder.microphoneAccess == .denied || recorder.playbackAccess == .denied { return }
        Task { await beginCapture(scope: currentPlaybackScope(), source: .monitor) }
    }

    private func openMicrophoneSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    private func openPlaybackSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    private func nextMainRunLoopTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    @objc private func showRecordingMonitor() {
        recordingMonitor.show(
            recorder: recorder,
            preferences: preferences,
            mic: mic,
            onStop: { [weak self] in
                self?.stopRecordingNow(source: .monitor)
            },
            onAllowAccess: { [weak self] in
                self?.retryAccessFromMonitor()
            },
            onToggleMute: { [weak self] in
                self?.toggleFromUser(source: .hud)
            }
        )
    }

    /// Stop capture immediately; mix in the background.
    private func stopRecordingNow(source: UsageReporter.ActivationSource) {
        if !recorder.isRecording {
            recordingMonitor.hide()
            recorder.cancelPreview()
            handleMuteChanged(showHUD: false)
            return
        }
        recordingMonitor.hide()
        let pending: SessionRecorder.PendingMix
        do {
            pending = try recorder.stopAndPrepareMix(
                keepDeviceRecordings: preferences.keepDeviceRecordings
            )
        } catch {
            handleMuteChanged(showHUD: false)
            presentRecordingError(error)
            return
        }
        UsageReporter.record(.stopRecording, source: source)
        handleMuteChanged(showHUD: false)
        Task {
            let mixed = await recorder.completeMix(pending)
            if !mixed {
                UsageReporter.record(.mixFailed, source: source)
            }
        }
    }

    /// Stop capture and finish the mix before Quit. Safe if a mix is already running.
    func finalizeRecordingForQuit() async {
        let wasRecording = recorder.isRecording
        if wasRecording {
            recordingMonitor.hide()
        }
        let mixed = await recorder.finalizeAndMix(
            keepDeviceRecordings: preferences.keepDeviceRecordings
        )
        if wasRecording {
            UsageReporter.record(.stopRecording, source: .menu)
        }
        handleMuteChanged(showHUD: false)
        if !mixed {
            UsageReporter.record(.mixFailed, source: .menu)
        }
    }

    @objc private func showRecordingsFolder() {
        UsageReporter.record(.showRecordings, source: .menu)
        let folder = preferences.recordingsDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
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
        guard let id = sender.representedObject as? String else { return }
        let currentlyVisible = sender.state == .on
        hud.setDisplayHidden(id, hidden: currentlyVisible)
    }

    @objc private func showFloatingHUDOnAllDisplays() {
        hud.setAllDisplaysHidden(false)
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
        // Never use appearsDisabled — it greys/shrinks the menu-bar glyph and looks broken.
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
            // Keep the badge out of layout / hit-testing for the status button.
            badge.translatesAutoresizingMaskIntoConstraints = true
            button.addSubview(badge)
            updateBadgeView = badge
        }

        let diameter: CGFloat = 7
        let inset: CGFloat = 1
        let size = button.bounds.size
        // Status button is flipped on some systems; pin to visual top-right.
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
