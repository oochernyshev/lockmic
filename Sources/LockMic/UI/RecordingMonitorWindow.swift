import AppKit
import Combine

/// AppKit monitor styled like Preferences. Not SwiftUI — a second hosting
/// window crashes button clicks on recent macOS (`MainActor.assumeIsolated`).
@MainActor
final class RecordingMonitorController: NSObject, NSWindowDelegate {
    private static let windowWidth: CGFloat = 520
    private static let waveformHeight: CGFloat = 92

    private var window: NSWindow?
    private var rootStack: NSStackView?
    private var elapsedField: NSTextField?
    private var sizeField: NSTextField?
    private var statusDot: NSView?
    private var waveCard: CardView?
    private var permissionBox: NSView?
    private var permissionTitle: NSTextField?
    private var permissionCaption: NSTextField?
    private var permissionButton: AllowAccessButton?
    private var inputsCard: CardView?
    private var outputsCard: CardView?
    private var followToggle: AccessoryToggle?
    private var followOutputToggle: AccessoryToggle?
    private var muteButton: MuteToggleButton?
    private var stopButton: StopRecordingButton?
    private var preferences: PreferencesStore?
    private var mic: MicController?
    private var waveform: WaveformView?
    private var timer: Timer?
    private var recorder: SessionRecorder?
    private var onStop: (() -> Void)?
    private var onAllowAccess: (() -> Void)?
    private var onToggleMute: (() -> Void)?
    private var rows: [String: RowView] = [:]
    private var waveSessionStart: Date?
    private var lastElapsedSeconds = -1
    private var timerForRecording = false
    private var warnLatch: [String: WarnLatch] = [:]
    private var recorderCancellables = Set<AnyCancellable>()
    private var micCancellables = Set<AnyCancellable>()

    var isVisible: Bool { window?.isVisible == true }

    func show(
        recorder: SessionRecorder,
        preferences: PreferencesStore? = nil,
        mic: MicController? = nil,
        onStop: @escaping () -> Void,
        onAllowAccess: (() -> Void)? = nil,
        onToggleMute: (() -> Void)? = nil
    ) {
        self.recorder = recorder
        self.preferences = preferences
        self.mic = mic
        self.onStop = onStop
        self.onAllowAccess = onAllowAccess
        self.onToggleMute = onToggleMute
        if window == nil {
            buildWindow()
        }
        if recorder.recordingStartedAt != waveSessionStart {
            waveform?.reset()
            waveSessionStart = recorder.recordingStartedAt
            lastElapsedSeconds = -1
            warnLatch.removeAll()
        }
        observeRecorder(recorder)
        observeMic(mic)
        rebuildSections()
        syncChrome()
        startTimer()
        guard let window else { return }
        if !window.isVisible {
            positionOnActiveScreen(window)
        }
        window.alphaValue = 1
        window.orderFrontRegardless()
        window.invalidateShadow()
        window.displayIfNeeded()
    }

    func hide() {
        saveWindowOrigin()
        recorderCancellables.removeAll()
        micCancellables.removeAll()
        timer?.invalidate()
        timer = nil
        warnLatch.removeAll()
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        if recorder?.isRecording != true {
            onStop?()
        }
        return false
    }

    func windowDidMove(_ notification: Notification) {
        saveWindowOrigin()
    }

    private func buildWindow() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 420),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.recordingMonitorTitle
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        window.level = .statusBar
        // Frost is a sibling behind chrome so thinning it does not fade controls,
        // and so it is not the content root (that reblurs on every waveform tick).
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.delegate = self

        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 420))
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor

        let frost = NSVisualEffectView()
        frost.translatesAutoresizingMaskIntoConstraints = false
        frost.material = .hudWindow
        frost.blendingMode = .behindWindow
        frost.state = .active
        frost.alphaValue = 0.75
        content.addSubview(frost)
        NSLayoutConstraint.activate([
            frost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            frost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            frost.topAnchor.constraint(equalTo: content.topAnchor),
            frost.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = PreferencesChrome.pageSpacing
        root.edgeInsets = NSEdgeInsets(top: 44, left: 16, bottom: 12, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let inputs = CardView(maxVisibleRows: 5)
        let outputs = CardView(maxVisibleRows: 5)
        let follow = AccessoryToggle(title: L10n.recordingFollowDefaultMic)
        follow.target = self
        follow.action = #selector(followDefaultClicked)
        inputs.setAccessory(follow)
        followToggle = follow
        let followOut = AccessoryToggle(title: L10n.recordingFollowDefaultOutput)
        followOut.target = self
        followOut.action = #selector(followDefaultOutputClicked)
        outputs.setAccessory(followOut)
        followOutputToggle = followOut
        inputsCard = inputs
        outputsCard = outputs

        let waveCard = CardView()
        waveCard.setHeaderHidden(true)
        waveCard.setBodyInsets(NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14))
        let waveBox = NSView()
        waveBox.translatesAutoresizingMaskIntoConstraints = false
        let wave = WaveformView()
        wave.translatesAutoresizingMaskIntoConstraints = false
        let statusChip = MonitorChip(title: L10n.recordingStatusRecording, showsDot: true)
        statusChip.dotView.layer?.backgroundColor = NSColor.systemRed.cgColor
        statusDot = statusChip.dotView
        let elapsedChip = MonitorChip(title: "00:00", showsDot: false, monospaced: true)
        elapsedField = elapsedChip.label
        let sizeChip = MonitorChip(
            title: RecordingBitRate.default.sizeChipText(onDisk: 0),
            showsDot: false,
            monospaced: true
        )
        sizeField = sizeChip.label
        waveBox.addSubview(wave)
        waveBox.addSubview(statusChip)
        waveBox.addSubview(sizeChip)
        waveBox.addSubview(elapsedChip)
        NSLayoutConstraint.activate([
            wave.leadingAnchor.constraint(equalTo: waveBox.leadingAnchor),
            wave.trailingAnchor.constraint(equalTo: waveBox.trailingAnchor),
            wave.topAnchor.constraint(equalTo: waveBox.topAnchor),
            wave.bottomAnchor.constraint(equalTo: waveBox.bottomAnchor),
            wave.heightAnchor.constraint(equalToConstant: Self.waveformHeight),
            statusChip.leadingAnchor.constraint(equalTo: waveBox.leadingAnchor, constant: 8),
            statusChip.topAnchor.constraint(equalTo: waveBox.topAnchor, constant: 8),
            elapsedChip.trailingAnchor.constraint(equalTo: waveBox.trailingAnchor, constant: -8),
            elapsedChip.topAnchor.constraint(equalTo: waveBox.topAnchor, constant: 8),
            sizeChip.trailingAnchor.constraint(equalTo: elapsedChip.leadingAnchor, constant: -6),
            sizeChip.topAnchor.constraint(equalTo: waveBox.topAnchor, constant: 8),
        ])
        waveCard.addRow(waveBox)
        waveform = wave
        self.waveCard = waveCard

        let permission = makePermissionBox()
        permission.isHidden = true
        permissionBox = permission

        let mute = MuteToggleButton(target: self, action: #selector(muteClicked))
        muteButton = mute
        let stop = StopRecordingButton(title: L10n.menuStopRecording, target: self, action: #selector(stopClicked))
        stopButton = stop
        let leading = NSView()
        let trailing = NSView()
        leading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailing.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 10
        actions.addArrangedSubview(leading)
        actions.addArrangedSubview(mute)
        actions.addArrangedSubview(stop)
        actions.addArrangedSubview(trailing)
        leading.widthAnchor.constraint(equalTo: trailing.widthAnchor).isActive = true

        root.addArrangedSubview(permission)
        root.addArrangedSubview(inputs)
        root.addArrangedSubview(outputs)
        root.addArrangedSubview(waveCard)
        root.addArrangedSubview(actions)
        let inset = root.edgeInsets.left + root.edgeInsets.right
        [permission, inputs, outputs, waveCard, actions].forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -inset).isActive = true
        }
        rootStack = root

        window.contentView = content
        self.window = window
    }

    private func positionOnActiveScreen(_ window: NSWindow) {
        fitWindow()
        var frame = window.frame
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.originXKey) != nil {
            // Restore the title-bar corner so a taller/shorter device list
            // does not walk the window down the screen.
            frame.origin.x = defaults.double(forKey: Self.originXKey)
            frame.origin.y = defaults.double(forKey: Self.originMaxYKey) - frame.height
            frame = Self.clamped(frame, to: NSScreen.screens.map(\.visibleFrame))
        } else if let visible = (NSApp.currentEvent?.window?.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = visible.midX - frame.width / 2
            frame.origin.y = visible.midY - frame.height / 2
        }
        window.setFrame(frame, display: true)
    }

    private func saveWindowOrigin() {
        guard let window, window.isVisible else { return }
        let frame = window.frame
        UserDefaults.standard.set(frame.origin.x, forKey: Self.originXKey)
        UserDefaults.standard.set(frame.maxY, forKey: Self.originMaxYKey)
    }

    private static let originXKey = "monitorWindowX"
    private static let originMaxYKey = "monitorWindowMaxY"

    private static func clamped(_ frame: NSRect, to visibles: [NSRect]) -> NSRect {
        let visible = visibles.first { $0.intersects(frame) } ?? visibles.first
        guard let visible else { return frame }
        var f = frame
        f.origin.x = min(max(f.origin.x, visible.minX), max(visible.minX, visible.maxX - f.width))
        f.origin.y = min(max(f.origin.y, visible.minY), max(visible.minY, visible.maxY - f.height))
        return f
    }

    private func fitWindow() {
        guard let window, let visual = window.contentView, let root = rootStack else { return }
        visual.layoutSubtreeIfNeeded()
        let height = root.fittingSize.height
        let top = window.frame.maxY
        window.setContentSize(NSSize(width: Self.windowWidth, height: max(300, height)))
        var frame = window.frame
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true)
    }

    private func startTimer() {
        let recording = recorder?.isRecording == true
        if timer != nil, timerForRecording == recording { return }
        timer?.invalidate()
        timerForRecording = recording
        // Waveform bars are ~55 ms; 15 Hz is enough and avoids a 30 Hz MainActor hop.
        let interval = recording ? 1.0 / 15.0 : 0.5
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// Under an hour: `05:23`. From 60 minutes: `5:00:00`.
    private static func elapsedText(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
        }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func tick() {
        guard let recorder else { return }
        if recorder.isRecording != timerForRecording {
            startTimer()
        }
        if !recorder.isRecording {
            // Access can flip while still not recording (TCC allow / Settings return).
            syncChrome()
            return
        }
        let seconds = recorder.recordedElapsedSeconds()
        if seconds != lastElapsedSeconds {
            lastElapsedSeconds = seconds
            elapsedField?.stringValue = Self.elapsedText(seconds)
            sizeField?.stringValue = recorder.mixSizeChipText()
        }
        syncRowLevels()
        waveform?.push(recorder.liveWaveformLevel())
    }

    private func syncRows(from devices: [RecordingDeviceRow]? = nil) {
        guard let recorder else { return }
        for device in devices ?? recorder.devices {
            rows[device.id]?.apply(device, muted: isInputMuted(device))
        }
    }

    /// Default badge and selection live on `devices`, not the meter tick.
    /// Same IDs with a new default must `apply`, not only `applyLevel`.
    /// `$devices` emits in `willSet` — use the published array, not `recorder.devices`.
    private func syncDeviceRows(from devices: [RecordingDeviceRow]? = nil) {
        guard let recorder, inputsCard != nil else { return }
        let devices = devices ?? recorder.devices
        let ids = Set(devices.map(\.id))
        if ids != Set(rows.keys) {
            rebuildSections(from: devices)
        } else {
            syncRows(from: devices)
            syncFollowToggles()
        }
    }

    private func isInputMuted(_ device: RecordingDeviceRow) -> Bool {
        guard device.kind == .input, let mic, mic.effectiveMuted else { return false }
        guard let row = mic.inputDevices.first(where: { $0.uid == device.id }) else {
            return device.isDefault
        }
        // Follow LockMic intent for devices we control. A raw HAL mute read can
        // stay true while a capture is open, even after the user has unmuted.
        return row.isInScope && row.supportsMute && !row.isVirtual
    }

    private func syncRowLevels() {
        guard let recorder else { return }
        let now = Date()
        let selectedInputPeak = recorder.devices
            .filter { $0.kind == .input && $0.isEnabled }
            .map { recorder.meterLinearPeak(for: $0) }
            .max() ?? 0
        for device in recorder.devices {
            let level = recorder.meterLevel(for: device)
            var missed = recorder.isRecording
                && !device.isEnabled
                && !isInputMuted(device)
            if missed, device.kind == .input {
                let peak = recorder.meterLinearPeak(for: device)
                missed = peak >= Self.inputBleedFloor
                    && peak >= selectedInputPeak * Self.inputBleedRatio
            } else if missed {
                missed = level >= Self.signalFloor
            }
            rows[device.id]?.applyLevel(
                device,
                level: level,
                noSignal: latchedWarning(id: device.id, want: missed, selected: device.isEnabled, now: now)
            )
        }
    }

    private static let signalFloor: Float = 0.04
    /// Linear peak: unselected must be ~10 dB hotter than the chosen mic.
    private static let inputBleedFloor: Float = 0.02
    private static let inputBleedRatio: Float = 3
    private static let warnNeedAudio: TimeInterval = 1
    private static let warnNeedPause: TimeInterval = 1
    private static let warnHold: TimeInterval = 2

    private struct WarnLatch {
        var visible = false
        var holdUntil = Date.distantPast
        var heardSince: Date?
        var silentSince: Date?
    }

    /// Show after ~1 s of audio; hide after ~1 s of pause. 2 s cooldown after hide.
    private func latchedWarning(id: String, want: Bool, selected: Bool, now: Date) -> Bool {
        if selected {
            warnLatch[id] = WarnLatch()
            return false
        }
        var latch = warnLatch[id] ?? WarnLatch()
        if want {
            latch.silentSince = nil
            if latch.heardSince == nil { latch.heardSince = now }
        } else {
            latch.heardSince = nil
            if latch.silentSince == nil { latch.silentSince = now }
        }
        let meaningful = latch.heardSince.map { now.timeIntervalSince($0) >= Self.warnNeedAudio } ?? false
        let paused = latch.silentSince.map { now.timeIntervalSince($0) >= Self.warnNeedPause } ?? false
        let held = now < latch.holdUntil
        if latch.visible {
            if paused {
                latch.visible = false
                latch.holdUntil = now.addingTimeInterval(Self.warnHold)
            }
        } else if meaningful, !held {
            latch.visible = true
        }
        warnLatch[id] = latch
        return latch.visible
    }

    private func rebuildSections(from devices: [RecordingDeviceRow]? = nil) {
        guard let recorder, let inputsCard, let outputsCard else { return }
        let devices = devices ?? recorder.devices
        rows.removeAll()
        inputsCard.setTitle(L10n.recordingInputsHeader)
        outputsCard.setTitle(L10n.recordingOutputsHeader)
        syncFollowToggles()
        inputsCard.removeRows()
        outputsCard.removeRows()

        for device in devices where device.kind == .input {
            let row = RowView(device: device, muted: isInputMuted(device)) { [weak self] id, on in
                self?.recorder?.setDeviceEnabled(id, enabled: on)
                self?.syncRows()
            }
            rows[device.id] = row
            inputsCard.addRow(row)
        }
        for device in devices where device.kind == .output {
            let row = RowView(device: device, muted: false) { [weak self] id, on in
                self?.recorder?.setDeviceEnabled(id, enabled: on)
                self?.syncRows()
            }
            rows[device.id] = row
            outputsCard.addRow(row)
        }
        inputsCard.refreshScrolling()
        outputsCard.refreshScrolling()
        syncChrome()
        fitWindow()
    }

    /// AppKit does not observe `@Published` on its own — keep the cards in
    /// sync as soon as mic / playback access or `isRecording` changes.
    private func observeRecorder(_ recorder: SessionRecorder) {
        recorderCancellables.removeAll()
        Publishers.CombineLatest3(
            recorder.$isRecording,
            recorder.$microphoneAccess,
            recorder.$playbackAccess
        )
        .sink { [weak self] _, _, _ in
            self?.syncChrome()
        }
        .store(in: &recorderCancellables)

        recorder.$devices
            .sink { [weak self] devices in
                self?.syncDeviceRows(from: devices)
            }
            .store(in: &recorderCancellables)
    }

    private func observeMic(_ mic: MicController?) {
        micCancellables.removeAll()
        guard let mic else { return }
        Publishers.CombineLatest(mic.$state, mic.$inputDevices)
            .sink { [weak self] _, _ in
                self?.syncMuteStatus()
            }
            .store(in: &micCancellables)
    }

    private func syncMuteStatus() {
        muteButton?.apply(muted: mic?.effectiveMuted == true)
        guard let recorder else { return }
        for device in recorder.devices where device.kind == .input {
            rows[device.id]?.applyMute(isInputMuted(device))
        }
    }

    private func syncChrome() {
        let kind: PermissionKind?
        if recorder?.isRecording != true {
            if recorder?.microphoneAccess == .denied {
                kind = .microphone
            } else if recorder?.playbackAccess == .denied {
                kind = .playback
            } else {
                kind = nil
            }
        } else {
            kind = nil
        }
        let denied = kind != nil
        if let kind {
            permissionTitle?.stringValue = kind.title
            permissionCaption?.stringValue = kind.caption
            permissionButton?.setTitle(kind.button)
            statusDot?.layer?.backgroundColor = NSColor.systemOrange.cgColor
        } else {
            statusDot?.layer?.backgroundColor = NSColor.systemRed.cgColor
        }
        if permissionBox?.isHidden == denied {
            permissionBox?.isHidden = !denied
            fitWindow()
        }

        let inputsOn = recorder?.isRecording == true || recorder?.microphoneAccess == .granted
        let outputsOn = recorder?.isRecording == true || recorder?.playbackAccess == .granted
        inputsCard?.setDimmed(!inputsOn)
        outputsCard?.setDimmed(!outputsOn)
        followToggle?.setEnabled(inputsOn)
        followOutputToggle?.setEnabled(outputsOn)
        stopButton?.isEnabled = true
        for device in recorder?.devices ?? [] {
            let on = device.kind == .input ? inputsOn : outputsOn
            rows[device.id]?.setSectionEnabled(on)
        }
    }

    private enum PermissionKind {
        case microphone
        case playback

        var title: String {
            switch self {
            case .microphone: return L10n.recordingPermissionMicTitle
            case .playback: return L10n.recordingPermissionPlaybackTitle
            }
        }

        var caption: String {
            switch self {
            case .microphone: return L10n.recordingPermissionMicCaption
            case .playback: return L10n.recordingPermissionPlaybackCaption
            }
        }

        var button: String {
            switch self {
            case .microphone: return L10n.recordingPermissionMicButton
            case .playback: return L10n.recordingPermissionPlaybackButton
            }
        }
    }

    private func makePermissionBox() -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = PreferencesChrome.cardCornerRadius
        box.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.28).cgColor

        let title = makeLabel(
            L10n.recordingPermissionMicTitle,
            font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        )
        permissionTitle = title
        let caption = NSTextField(wrappingLabelWithString: L10n.recordingPermissionMicCaption)
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        caption.maximumNumberOfLines = 3
        permissionCaption = caption

        let allow = AllowAccessButton(
            title: L10n.recordingPermissionMicButton,
            target: self,
            action: #selector(allowAccessClicked)
        )
        permissionButton = allow

        let text = NSStackView(views: [title, caption])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let column = NSStackView(views: [text, allow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        column.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            column.topAnchor.constraint(equalTo: box.topAnchor),
            column.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    @objc private func allowAccessClicked() {
        onAllowAccess?()
    }

    @objc private func stopClicked() {
        onStop?()
    }

    @objc private func muteClicked() {
        onToggleMute?()
    }

    @objc private func followDefaultClicked() {
        guard let recorder, let followToggle else { return }
        recorder.setFollowDefaultInput(followToggle.isOn)
        followToggle.isOn = recorder.followDefaultInput
        preferences?.followDefaultMic = recorder.followDefaultInput
        syncRows()
    }

    @objc private func followDefaultOutputClicked() {
        guard let recorder, let followOutputToggle else { return }
        recorder.setFollowDefaultOutput(followOutputToggle.isOn)
        followOutputToggle.isOn = recorder.followDefaultOutput
        preferences?.followDefaultOutput = recorder.followDefaultOutput
        if recorder.followDefaultOutput {
            preferences?.recordAllPlayback = false
        }
        syncRows()
    }

    private func syncFollowToggles() {
        guard let recorder else { return }
        followToggle?.isOn = recorder.followDefaultInput
        followOutputToggle?.isOn = recorder.followDefaultOutput
        if let preferences {
            if preferences.followDefaultMic != recorder.followDefaultInput {
                preferences.followDefaultMic = recorder.followDefaultInput
            }
            if preferences.followDefaultOutput != recorder.followDefaultOutput {
                preferences.followDefaultOutput = recorder.followDefaultOutput
            }
        }
    }

    private func makeLabel(_ text: String, font: NSFont) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }
}
