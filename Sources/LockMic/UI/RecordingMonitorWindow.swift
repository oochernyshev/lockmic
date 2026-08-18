import AppKit
import QuartzCore

/// AppKit monitor styled like Preferences. Not SwiftUI — a second hosting
/// window crashes button clicks on recent macOS (`MainActor.assumeIsolated`).
@MainActor
final class RecordingMonitorController: NSObject, NSWindowDelegate {
    private static let windowWidth: CGFloat = 520
    private static let waveformHeight: CGFloat = 92

    private var window: NSWindow?
    private var rootStack: NSStackView?
    private var elapsedField: NSTextField?
    private var statusTitle: NSTextField?
    private var statusDot: NSView?
    private var permissionBox: NSView?
    private var permissionTitle: NSTextField?
    private var permissionCaption: NSTextField?
    private var permissionButton: AllowAccessButton?
    private var inputsCard: CardView?
    private var outputsCard: CardView?
    private var followToggle: AccessoryToggle?
    private var followOutputToggle: AccessoryToggle?
    private var stopButton: StopRecordingButton?
    private var preferences: PreferencesStore?
    private var waveform: WaveformView?
    private var timer: Timer?
    private var recorder: SessionRecorder?
    private var onStop: (() -> Void)?
    private var onAllowAccess: (() -> Void)?
    private var rows: [String: RowView] = [:]
    private var waveSessionStart: Date?
    private var lastElapsedSeconds = -1
    private var timerForRecording = false

    var isVisible: Bool { window?.isVisible == true }

    func show(
        recorder: SessionRecorder,
        preferences: PreferencesStore? = nil,
        onStop: @escaping () -> Void,
        onAllowAccess: (() -> Void)? = nil
    ) {
        self.recorder = recorder
        self.preferences = preferences
        self.onStop = onStop
        self.onAllowAccess = onAllowAccess
        if window == nil {
            buildWindow()
        }
        if recorder.recordingStartedAt != waveSessionStart {
            waveform?.reset()
            waveSessionStart = recorder.recordingStartedAt
        }
        rebuildSections()
        syncChrome()
        startTimer()
        guard let window else { return }
        if !window.isVisible {
            positionOnActiveScreen(window)
        }
        window.alphaValue = 1
        window.orderFrontRegardless()
        window.displayIfNeeded()
    }

    func hide() {
        saveWindowOrigin()
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if recorder?.isRecording == true {
            hide()
        } else {
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
        // Opaque window — a visual-effect root reblurs on every subview
        // redraw and makes the waveform look like it is flickering.
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.delegate = self

        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 420))
        content.autoresizingMask = [.width, .height]

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = PreferencesChrome.pageSpacing
        root.edgeInsets = NSEdgeInsets(top: 44, left: 16, bottom: 12, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        let waveBar = NSView()
        waveBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(waveBar)

        let elapsed = makeLabel("00:00", font: .monospacedDigitSystemFont(ofSize: 13, weight: .medium))
        elapsed.textColor = .secondaryLabelColor
        elapsed.alignment = .center
        elapsed.translatesAutoresizingMaskIntoConstraints = false
        elapsedField = elapsed
        waveBar.addSubview(elapsed)

        let wave = WaveformView()
        wave.translatesAutoresizingMaskIntoConstraints = false
        waveBar.addSubview(wave)
        waveform = wave

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: waveBar.topAnchor),
            waveBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            waveBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            waveBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            waveBar.heightAnchor.constraint(equalToConstant: Self.waveformHeight),
            elapsed.leadingAnchor.constraint(equalTo: waveBar.leadingAnchor, constant: 14),
            elapsed.centerYAnchor.constraint(equalTo: waveBar.centerYAnchor),
            elapsed.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
            wave.leadingAnchor.constraint(equalTo: elapsed.trailingAnchor, constant: 10),
            wave.trailingAnchor.constraint(equalTo: waveBar.trailingAnchor),
            wave.topAnchor.constraint(equalTo: waveBar.topAnchor),
            wave.bottomAnchor.constraint(equalTo: waveBar.bottomAnchor),
        ])

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 9),
        ])
        let title = makeLabel(L10n.recordingStatusRecording, font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold))
        statusTitle = title
        statusDot = dot
        header.addArrangedSubview(dot)
        header.addArrangedSubview(title)

        let inputs = CardView()
        let outputs = CardView()
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

        let permission = makePermissionBox()
        permission.isHidden = true
        permissionBox = permission

        let stop = StopRecordingButton(title: L10n.menuStopRecording, target: self, action: #selector(stopClicked))
        stopButton = stop
        let stopRow = NSStackView()
        stopRow.orientation = .horizontal
        stopRow.alignment = .centerY
        stopRow.addArrangedSubview(NSView())
        stopRow.addArrangedSubview(stop)
        stopRow.addArrangedSubview(NSView())

        root.addArrangedSubview(header)
        root.addArrangedSubview(permission)
        root.addArrangedSubview(inputs)
        root.addArrangedSubview(outputs)
        root.addArrangedSubview(stopRow)
        let inset = root.edgeInsets.left + root.edgeInsets.right
        [header, permission, inputs, outputs, stopRow].forEach { view in
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
        let height = root.fittingSize.height + Self.waveformHeight
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

    private func tick() {
        guard let recorder else { return }
        if recorder.isRecording != timerForRecording {
            startTimer()
            syncChrome()
        }
        guard recorder.isRecording else { return }
        if let start = recorder.recordingStartedAt {
            let seconds = max(0, Int(Date().timeIntervalSince(start)))
            if seconds != lastElapsedSeconds {
                lastElapsedSeconds = seconds
                elapsedField?.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60)
            }
        }
        let ids = Set(recorder.devices.map(\.id))
        if ids != Set(rows.keys) {
            rebuildSections()
            return
        }
        syncRowLevels()
        syncFollowToggles()
        waveform?.push(recorder.liveWaveformLevel())
    }

    private func syncRows() {
        guard let recorder else { return }
        for device in recorder.devices {
            rows[device.id]?.apply(device)
        }
    }

    private func syncRowLevels() {
        guard let recorder else { return }
        for device in recorder.devices {
            rows[device.id]?.applyLevel(device, level: recorder.meterLevel(for: device))
        }
    }

    private func rebuildSections() {
        guard let recorder, let inputsCard, let outputsCard else { return }
        rows.removeAll()
        inputsCard.setTitle(L10n.recordingInputsHeader)
        outputsCard.setTitle(L10n.recordingOutputsHeader)
        syncFollowToggles()
        inputsCard.removeRows()
        outputsCard.removeRows()

        for device in recorder.devices where device.kind == .input {
            let row = RowView(device: device) { [weak self] id, on in
                self?.recorder?.setDeviceEnabled(id, enabled: on)
                self?.syncRows()
            }
            rows[device.id] = row
            inputsCard.addRow(row)
        }
        for device in recorder.devices where device.kind == .output {
            let row = RowView(device: device) { [weak self] id, on in
                self?.recorder?.setDeviceEnabled(id, enabled: on)
                self?.syncRows()
            }
            rows[device.id] = row
            outputsCard.addRow(row)
        }
        syncChrome()
        fitWindow()
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
            statusTitle?.stringValue = kind.title
            statusDot?.layer?.backgroundColor = NSColor.systemOrange.cgColor
        } else {
            statusTitle?.stringValue = L10n.recordingStatusRecording
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
        stopButton?.isEnabled = recorder?.isRecording == true
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
        guard recorder?.isRecording == true else { return }
        onStop?()
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

/// Accent fill — system bezels go grey in a non-activating panel.
private final class AllowAccessButton: NSButton {
    init(title: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .shadowlessSquare
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            ]
        )
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        focusRingType = .none
    }

    func setTitle(_ title: String) {
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            ]
        )
        invalidateIntrinsicContentSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 16
        size.height += 6
        return size
    }

    override var wantsUpdateLayer: Bool { true }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
    }

    override func updateLayer() {
        let color = NSColor.controlAccentColor
        layer?.backgroundColor = (isHighlighted ? color.blended(withFraction: 0.18, of: .black) : color)?.cgColor
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// System bezels go grey in a non-activating panel. Paint our own fill.
private final class StopRecordingButton: NSButton {
    init(title: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .shadowlessSquare
        imagePosition = .imageLeading
        imageHugsTitle = true
        contentTintColor = .white
        image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: title)
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            ]
        )
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 20
        size.height += 8
        return size
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override var wantsUpdateLayer: Bool { true }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
    }

    override func updateLayer() {
        let red = NSColor.systemRed
        let titleColor = isEnabled ? NSColor.white : NSColor.white.withAlphaComponent(0.55)
        if !isEnabled {
            layer?.backgroundColor = red.withAlphaComponent(0.28).cgColor
        } else {
            layer?.backgroundColor = (isHighlighted ? red.blended(withFraction: 0.22, of: .black) : red)?.cgColor
        }
        contentTintColor = titleColor
        attributedTitle = NSAttributedString(
            string: attributedTitle.string,
            attributes: [
                .foregroundColor: titleColor,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            ]
        )
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Preferences-style inset card (fill + hairline + 10pt corner).
private final class CardView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let header = NSStackView()
    private let rows = NSStackView()
    private var accessory: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = PreferencesChrome.cardCornerRadius
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.045).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor

        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.textColor = .secondaryLabelColor
        titleField.alignment = .left
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.addArrangedSubview(titleField)
        header.addArrangedSubview(spacer)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0

        let stack = NSStackView(views: [header, rows])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = PreferencesChrome.contentSpacing
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            rows.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setTitle(_ title: String) {
        titleField.stringValue = title
    }

    func setAccessory(_ view: NSView?) {
        if let accessory {
            header.removeArrangedSubview(accessory)
            accessory.removeFromSuperview()
        }
        accessory = view
        if let view {
            header.addArrangedSubview(view)
        }
    }

    func removeRows() {
        rows.arrangedSubviews.forEach {
            rows.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    func addRow(_ row: NSView) {
        if !rows.arrangedSubviews.isEmpty {
            let line = NSBox()
            line.boxType = .separator
            rows.addArrangedSubview(line)
        }
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }

    func setDimmed(_ dimmed: Bool) {
        alphaValue = dimmed ? 0.42 : 1
    }
}

private final class RowView: NSView {
    private static let markWidth: CGFloat = 16
    private static let iconWidth: CGFloat = 16
    private static let meterWidth: CGFloat = 88

    private let mark = ChoiceMark()
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let meter = LevelBar()
    private var nameBottom: NSLayoutConstraint?
    private var detailBottom: NSLayoutConstraint?
    private var badgeWidth: NSLayoutConstraint?
    private let onToggle: (String, Bool) -> Void
    private var deviceID = ""
    private var canCapture = true
    private var sectionEnabled = true

    init(device: RecordingDeviceRow, onToggle: @escaping (String, Bool) -> Void) {
        self.onToggle = onToggle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        mark.target = self
        mark.action = #selector(changed)
        mark.style = device.kind == .input ? .radio : .checkbox

        iconView.imageScaling = .scaleProportionallyDown

        nameField.font = .systemFont(ofSize: NSFont.systemFontSize)
        nameField.alignment = .left
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.usesSingleLineMode = true
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameField.setContentHuggingPriority(.init(1), for: .horizontal)

        badge.font = .systemFont(ofSize: 11, weight: .medium)
        badge.textColor = .secondaryLabelColor
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        detailField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        [mark, iconView, nameField, badge, detailField, meter].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        nameBottom = nameField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9)
        detailBottom = detailField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        badgeWidth = badge.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: leadingAnchor),
            mark.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: Self.markWidth),
            mark.heightAnchor.constraint(equalToConstant: Self.markWidth),

            iconView.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconWidth),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconWidth),

            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            nameField.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -6),

            badge.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: meter.leadingAnchor, constant: -10),

            meter.trailingAnchor.constraint(equalTo: trailingAnchor),
            meter.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            meter.widthAnchor.constraint(equalToConstant: Self.meterWidth),
            meter.heightAnchor.constraint(equalToConstant: 6),

            detailField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            detailField.trailingAnchor.constraint(equalTo: meter.leadingAnchor, constant: -10),
            detailField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 1),
        ])
        apply(device)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ device: RecordingDeviceRow) {
        deviceID = device.id
        canCapture = device.canCapture
        mark.style = device.kind == .input ? .radio : .checkbox
        mark.isOn = device.isEnabled
        let symbol = device.kind == .input ? "mic.fill" : "speaker.wave.2.fill"
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.contentTintColor = device.canCapture ? .controlAccentColor : .secondaryLabelColor
        nameField.stringValue = device.name
        applyEnabledLook()
        let showBadge = device.isDefault
        badge.stringValue = showBadge ? L10n.devicesBadgeDefault : ""
        badge.isHidden = !showBadge
        badgeWidth?.isActive = !showBadge
        detailField.stringValue = device.detail ?? ""
        let hasDetail = !(device.detail ?? "").isEmpty
        detailField.isHidden = !hasDetail
        nameBottom?.isActive = !hasDetail
        detailBottom?.isActive = hasDetail
        meter.active = device.isEnabled && device.canCapture && sectionEnabled
    }

    func setSectionEnabled(_ enabled: Bool) {
        guard sectionEnabled != enabled else { return }
        sectionEnabled = enabled
        applyEnabledLook()
    }

    private func applyEnabledLook() {
        let on = canCapture && sectionEnabled
        mark.isEnabled = on
        mark.alphaValue = on ? 1 : 0.4
        iconView.alphaValue = on ? 1 : 0.55
        nameField.alphaValue = on ? 1 : 0.55
        meter.active = mark.isOn && on
    }

    func applyLevel(_ device: RecordingDeviceRow, level: Float) {
        mark.isOn = device.isEnabled
        meter.level = level
        meter.active = device.isEnabled && device.canCapture && sectionEnabled
    }

    @objc private func changed() {
        onToggle(deviceID, mark.isOn)
    }
}

/// Compact checkbox + label for the Inputs card header.
private final class AccessoryToggle: NSView {
    let mark = ChoiceMark()
    private let label = NSTextField(labelWithString: "")

    var isOn: Bool {
        get { mark.isOn }
        set { mark.isOn = newValue }
    }

    func setEnabled(_ enabled: Bool) {
        mark.isEnabled = enabled
        label.textColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor
    }

    weak var target: AnyObject?
    var action: Selector?

    init(title: String) {
        super.init(frame: .zero)
        mark.style = .checkbox
        mark.target = self
        mark.action = #selector(clicked)
        label.stringValue = title
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [mark, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 14),
            mark.heightAnchor.constraint(equalToConstant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func clicked() {
        if let action {
            _ = target?.perform(action)
        }
    }
}

/// Circle for mics (one at a time), square for playback.
private final class ChoiceMark: NSControl {
    enum Style {
        case radio
        case checkbox
    }

    var style: Style = .checkbox {
        didSet { if style != oldValue { needsDisplay = true } }
    }

    var isOn = false {
        didSet { if isOn != oldValue { needsDisplay = true } }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

    override func draw(_ dirtyRect: NSRect) {
        let side: CGFloat = 14
        let box = NSRect(
            x: ((bounds.width - side) / 2).rounded(.toNearestOrAwayFromZero),
            y: ((bounds.height - side) / 2).rounded(.toNearestOrAwayFromZero),
            width: side,
            height: side
        )
        let accent = (isEnabled ? NSColor.controlAccentColor : NSColor.secondaryLabelColor)
            .withAlphaComponent(isEnabled ? 1 : 0.45)
        let line = NSBezierPath()
        line.lineWidth = 1.5
        if style == .radio {
            line.appendOval(in: box.insetBy(dx: 0.75, dy: 0.75))
        } else {
            line.appendRoundedRect(box.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
        }
        if isOn {
            accent.setFill()
            line.fill()
            if style == .radio {
                NSColor.white.setFill()
                let dot = box.insetBy(dx: 4.2, dy: 4.2)
                NSBezierPath(ovalIn: dot).fill()
            } else {
                let check = NSBezierPath()
                check.lineWidth = 1.6
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                // Unflipped view: origin is bottom-left — valley first, then up.
                check.move(to: NSPoint(x: box.minX + 3.2, y: box.midY - 0.2))
                check.line(to: NSPoint(x: box.minX + 6.1, y: box.minY + 3.4))
                check.line(to: NSPoint(x: box.maxX - 3.1, y: box.maxY - 3.6))
                NSColor.white.setStroke()
                check.stroke()
            }
        } else {
            accent.setStroke()
            line.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if style == .radio {
            guard !isOn else { return }
            isOn = true
        } else {
            isOn.toggle()
        }
        sendAction(action, to: target)
    }
}

private final class LevelBar: NSView {
    var level: Float = 0 {
        didSet {
            if abs(level - oldValue) > 0.02 { needsDisplay = true }
        }
    }
    var active = true {
        didSet {
            if active != oldValue { needsDisplay = true }
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 96, height: 7) }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3.5, yRadius: 3.5).fill()
        let width = max(3, bounds.width * CGFloat(min(1, max(0, level))))
        let fill = NSRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
        let color: NSColor
        if !active {
            color = NSColor.secondaryLabelColor.withAlphaComponent(0.35)
        } else if level > 0.85 {
            color = .systemOrange
        } else {
            color = .controlAccentColor
        }
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 3.5, yRadius: 3.5).fill()
    }
}

/// Voice Memos–style strip using a scrolling layer of recycled bar layers.
/// The GPU moves the strip (`position`); we never swap `contents`, which flickered.
private final class WaveformView: NSView {
    private static let noAnim: [String: CAAction] = [
        "contents": NSNull(),
        "bounds": NSNull(),
        "position": NSNull(),
        "frame": NSNull(),
        "backgroundColor": NSNull(),
        "opacity": NSNull(),
        "sublayers": NSNull(),
        "transform": NSNull(),
        "colors": NSNull(),
    ]

    private let strip = CALayer()
    private let mid = CALayer()
    private let top = CALayer()
    private let playhead = CALayer()
    private let fade = CAGradientLayer()

    private var bars: [CALayer] = []
    private var pool: [CALayer] = []
    private var nextBarX: CGFloat = 0
    private var lastCommit: Date?
    private var pendingPeak: Float = 0
    private let inset: CGFloat = 16
    private let secondsPerBar: TimeInterval = 0.055

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = true
        layer?.masksToBounds = true
        layer?.actions = Self.noAnim
        strip.anchorPoint = .zero
        strip.actions = Self.noAnim
        layer?.addSublayer(strip)
        for chrome in [mid, top, fade, playhead] {
            chrome.actions = Self.noAnim
            layer?.addSublayer(chrome)
        }
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutChrome()
        CATransaction.commit()
    }

    func reset() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            bar.removeFromSuperlayer()
            pool.append(bar)
        }
        bars.removeAll(keepingCapacity: true)
        nextBarX = 0
        lastCommit = nil
        pendingPeak = 0
        layoutChrome()
        CATransaction.commit()
    }

    func push(_ level: Float) {
        pendingPeak = max(pendingPeak, min(1, max(0, level)))
        let now = Date()
        if let lastCommit, now.timeIntervalSince(lastCommit) < secondsPerBar {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        appendBar(pendingPeak)
        pendingPeak = 0
        lastCommit = now
        recycleOffscreenBars()
        compactIfNeeded()
        layoutStrip()
        CATransaction.commit()
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }
    private var pixel: CGFloat { 1 / scale }
    private var step: CGFloat { pixel * 2 }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let bg = NSColor.windowBackgroundColor.cgColor
            layer?.backgroundColor = bg
            mid.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor
            top.backgroundColor = NSColor.separatorColor.cgColor
            playhead.backgroundColor = NSColor.systemRed.cgColor
            fade.colors = [bg, bg.copy(alpha: 0) ?? bg]
            let red = NSColor.systemRed.cgColor
            for bar in bars { bar.backgroundColor = red }
            for bar in pool { bar.backgroundColor = red }
        }
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
    }

    private func layoutChrome() {
        let hair = pixel
        top.frame = CGRect(x: 0, y: bounds.maxY - hair, width: bounds.width, height: hair)
        mid.frame = CGRect(x: inset, y: bounds.midY.rounded(.down), width: max(0, bounds.width - inset * 2), height: hair)
        playhead.frame = CGRect(x: bounds.maxX - inset, y: 10, width: hair, height: max(0, bounds.height - 20))
        fade.frame = CGRect(x: 0, y: 0, width: 28, height: bounds.height)
        layoutStrip()
    }

    private func layoutStrip() {
        let playX = bounds.maxX - inset
        strip.frame = CGRect(
            x: playX - nextBarX,
            y: 0,
            width: max(nextBarX + 8, 8),
            height: bounds.height
        )
    }

    private func appendBar(_ amplitude: Float) {
        let bar: CALayer
        if let reused = pool.popLast() {
            bar = reused
        } else {
            bar = CALayer()
            bar.actions = Self.noAnim
            bar.backgroundColor = NSColor.systemRed.cgColor
        }
        let maxBar = max(3, bounds.height / 2 - 12)
        let height = max(pixel, CGFloat(pow(amplitude, 1.25)) * maxBar)
        bar.frame = CGRect(
            x: nextBarX,
            y: bounds.midY - height,
            width: pixel,
            height: height * 2
        )
        strip.addSublayer(bar)
        bars.append(bar)
        nextBarX += step
    }

    private func recycleOffscreenBars() {
        let cutoff = -strip.frame.minX - step
        while let first = bars.first, first.frame.maxX < cutoff {
            first.removeFromSuperlayer()
            pool.append(first)
            bars.removeFirst()
        }
    }

    private func compactIfNeeded() {
        guard nextBarX > bounds.width * 6, let first = bars.first else { return }
        let origin = first.frame.minX
        guard origin > 0 else { return }
        for bar in bars {
            var frame = bar.frame
            frame.origin.x -= origin
            bar.frame = frame
        }
        nextBarX -= origin
    }
}
