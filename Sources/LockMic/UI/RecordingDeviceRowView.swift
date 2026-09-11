import AppKit

final class RowView: NSView {
    private static let markWidth: CGFloat = 16
    private static let iconWidth: CGFloat = 16
    private static let meterWidth: CGFloat = 88
    private static let meterHeight: CGFloat = 10

    private let mark = ChoiceMark()
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let muteBadge = MuteBadgeView()
    private let qualityBadge = CallQualityBadgeView()
    private let warnBadge = NoSignalBadgeView()
    private let detailField = NSTextField(labelWithString: "")
    private let meter = LevelBar()
    private var nameBottom: NSLayoutConstraint?
    private var detailBottom: NSLayoutConstraint?
    private var badgeWidth: NSLayoutConstraint?
    private var muteWidth: NSLayoutConstraint?
    private var qualityWidth: NSLayoutConstraint?
    private var warnWidth: NSLayoutConstraint?
    private var badgeToMeter: NSLayoutConstraint?
    private var badgeToMute: NSLayoutConstraint?
    private var badgeToQuality: NSLayoutConstraint?
    private var muteToMeter: NSLayoutConstraint?
    private var badgeToWarn: NSLayoutConstraint?
    private var warnToMeter: NSLayoutConstraint?
    private var qualityToMute: NSLayoutConstraint?
    private var qualityToWarn: NSLayoutConstraint?
    private var qualityToMeter: NSLayoutConstraint?
    private let onToggle: (String, Bool) -> Void
    private var deviceID = ""
    private var kind: RecordingDeviceKind = .input
    private var canCapture = true
    private var sectionEnabled = true
    private var isMuted = false
    private var showNoSignal = false
    private var showCallQuality = false
    private var isDefaultDevice = false
    private var sourceSampleRate: Double = 0

    init(device: RecordingDeviceRow, muted: Bool, onToggle: @escaping (String, Bool) -> Void) {
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

        muteBadge.setContentHuggingPriority(.defaultLow, for: .horizontal)
        muteBadge.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        qualityBadge.setContentHuggingPriority(.defaultLow, for: .horizontal)
        qualityBadge.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        qualityBadge.isHidden = true
        warnBadge.setContentHuggingPriority(.defaultLow, for: .horizontal)
        warnBadge.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        warnBadge.isHidden = true

        detailField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        [mark, iconView, nameField, badge, qualityBadge, muteBadge, warnBadge, detailField, meter].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        nameBottom = nameField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9)
        detailBottom = detailField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        badgeWidth = badge.widthAnchor.constraint(equalToConstant: 0)
        muteWidth = muteBadge.widthAnchor.constraint(equalToConstant: 0)
        qualityWidth = qualityBadge.widthAnchor.constraint(equalToConstant: 0)
        warnWidth = warnBadge.widthAnchor.constraint(equalToConstant: 0)
        badgeToMeter = badge.trailingAnchor.constraint(equalTo: meter.leadingAnchor, constant: -10)
        badgeToMute = badge.trailingAnchor.constraint(equalTo: muteBadge.leadingAnchor, constant: -6)
        badgeToQuality = badge.trailingAnchor.constraint(equalTo: qualityBadge.leadingAnchor, constant: -6)
        muteToMeter = muteBadge.trailingAnchor.constraint(equalTo: meter.leadingAnchor, constant: -10)
        badgeToWarn = badge.trailingAnchor.constraint(equalTo: warnBadge.leadingAnchor, constant: -6)
        warnToMeter = warnBadge.trailingAnchor.constraint(equalTo: meter.leadingAnchor, constant: -10)
        qualityToMute = qualityBadge.trailingAnchor.constraint(equalTo: muteBadge.leadingAnchor, constant: -6)
        qualityToWarn = qualityBadge.trailingAnchor.constraint(equalTo: warnBadge.leadingAnchor, constant: -6)
        qualityToMeter = qualityBadge.trailingAnchor.constraint(equalTo: meter.leadingAnchor, constant: -10)

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
            qualityBadge.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            muteBadge.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            warnBadge.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),

            meter.trailingAnchor.constraint(equalTo: trailingAnchor),
            meter.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            meter.widthAnchor.constraint(equalToConstant: Self.meterWidth),
            meter.heightAnchor.constraint(equalToConstant: Self.meterHeight),

            detailField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            detailField.trailingAnchor.constraint(equalTo: meter.leadingAnchor, constant: -10),
            detailField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 1),
        ])
        apply(device, muted: muted)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let height: CGFloat = detailField.isHidden ? 34 : 48
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    func apply(_ device: RecordingDeviceRow, muted: Bool = false) {
        deviceID = device.id
        kind = device.kind
        canCapture = device.canCapture
        isDefaultDevice = device.isDefault
        mark.style = device.kind == .input ? .radio : .checkbox
        mark.isOn = device.isEnabled
        nameField.stringValue = device.name
        applyEnabledLook()
        updateSourceBadge()
        detailField.stringValue = device.detail ?? ""
        let hasDetail = !(device.detail ?? "").isEmpty
        detailField.isHidden = !hasDetail
        nameBottom?.isActive = !hasDetail
        detailBottom?.isActive = hasDetail
        invalidateIntrinsicContentSize()
        showCallQuality = device.isCallQuality
        applyMute(muted)
    }

    func applyMute(_ muted: Bool) {
        let show = muted && kind == .input
        isMuted = show
        applyIcon()
        layoutTrailingBadges()
        syncMeter()
    }

    func setNoSignal(_ on: Bool) {
        let show = on && !isMuted
        guard showNoSignal != show else { return }
        showNoSignal = show
        layoutTrailingBadges()
    }

    private func layoutTrailingBadges() {
        let mute = isMuted
        let warn = showNoSignal && !mute
        let quality = showCallQuality
        muteBadge.isHidden = !mute
        warnBadge.isHidden = !warn
        qualityBadge.isHidden = !quality
        muteWidth?.isActive = !mute
        warnWidth?.isActive = !warn
        qualityWidth?.isActive = !quality

        badgeToQuality?.isActive = quality
        badgeToMute?.isActive = mute && !quality
        badgeToWarn?.isActive = warn && !quality
        badgeToMeter?.isActive = !mute && !warn && !quality

        qualityToMute?.isActive = quality && mute
        qualityToWarn?.isActive = quality && warn
        qualityToMeter?.isActive = quality && !mute && !warn

        muteToMeter?.isActive = mute
        warnToMeter?.isActive = warn

        muteBadge.setContentHuggingPriority(mute ? .required : .defaultLow, for: .horizontal)
        muteBadge.setContentCompressionResistancePriority(mute ? .required : .defaultLow, for: .horizontal)
        qualityBadge.setContentHuggingPriority(quality ? .required : .defaultLow, for: .horizontal)
        qualityBadge.setContentCompressionResistancePriority(quality ? .required : .defaultLow, for: .horizontal)
        warnBadge.setContentHuggingPriority(warn ? .required : .defaultLow, for: .horizontal)
        warnBadge.setContentCompressionResistancePriority(warn ? .required : .defaultLow, for: .horizontal)
        warnBadge.setBlinking(warn)
        applyIcon()
    }

    private static var symbolCache: [String: NSImage] = [:]

    private static func symbolImage(_ name: String) -> NSImage? {
        if let cached = symbolCache[name] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        if let image { symbolCache[name] = image }
        return image
    }

    private func applyIcon() {
        let symbol: String
        if kind == .output {
            symbol = "speaker.wave.2.fill"
        } else if isMuted {
            symbol = "mic.slash.fill"
        } else {
            symbol = "mic.fill"
        }
        iconView.image = Self.symbolImage(symbol)
        if isMuted {
            iconView.contentTintColor = .systemOrange
        } else {
            iconView.contentTintColor = canCapture ? .controlAccentColor : .secondaryLabelColor
        }
    }

    func setSectionEnabled(_ enabled: Bool) {
        guard sectionEnabled != enabled else { return }
        sectionEnabled = enabled
        applyEnabledLook()
    }

    private func applyEnabledLook() {
        let on = canCapture && sectionEnabled
        let enabledChanged = mark.isEnabled != on
        mark.isEnabled = on
        let dim: CGFloat
        if !on {
            dim = 0.4
        } else if !mark.isOn {
            dim = 0.42
        } else {
            dim = 1
        }
        mark.alphaValue = dim
        iconView.alphaValue = dim
        nameField.alphaValue = dim
        badge.alphaValue = dim
        qualityBadge.alphaValue = 1
        detailField.alphaValue = dim
        meter.alphaValue = on ? 1 : 0.4
        syncMeter()
        if enabledChanged {
            window?.invalidateCursorRects(for: self)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Own every click in the row so labels/icon/meter don’t swallow it.
    /// `super` does the superview→local conversion; testing `bounds` directly
    /// only hit the first row, then a selected radio ignored the rest.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        mark.performClick(self)
    }

    override func resetCursorRects() {
        if mark.isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    func applyLevel(
        _ device: RecordingDeviceRow,
        level: Float,
        sampleRate: Double,
        noSignal: Bool = false
    ) {
        let wasOn = mark.isOn
        mark.isOn = device.isEnabled
        if wasOn != mark.isOn {
            applyEnabledLook()
        }
        meter.level = isMuted ? 0 : level
        if sourceSampleRate != sampleRate {
            sourceSampleRate = sampleRate
            updateSourceBadge()
        }
        setNoSignal(noSignal)
        syncMeter()
    }

    private func updateSourceBadge() {
        var parts: [String] = []
        if isDefaultDevice { parts.append(L10n.devicesBadgeDefault) }
        if sourceSampleRate > 0 {
            let khz = sourceSampleRate / 1_000
            let value = khz.rounded() == khz
                ? String(Int(khz))
                : String(format: "%.1f", locale: .current, khz)
            parts.append(L10n.recordingDeviceSampleRate(value))
        }
        badge.stringValue = parts.joined(separator: " · ")
        badge.isHidden = parts.isEmpty
        badgeWidth?.isActive = parts.isEmpty
    }

    private func syncMeter() {
        meter.muted = isMuted
        meter.active = mark.isOn && canCapture && sectionEnabled && !isMuted
    }

    @objc private func changed() {
        onToggle(deviceID, mark.isOn)
    }
}

/// Compact checkbox + label for the Inputs card header.
final class AccessoryToggle: NSView {
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
final class ChoiceMark: NSControl {
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        if style == .radio {
            guard !isOn else { return }
            isOn = true
        } else {
            isOn.toggle()
        }
        sendAction(action, to: target)
    }

    override func mouseDown(with event: NSEvent) {
        performClick(self)
    }

    override func resetCursorRects() {
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}

/// Segmented LED strip. Redraws only when the lit count / state changes.
final class LevelBar: NSView {
    private static let segmentCount = 16
    private static let yellowStart = 10
    private static let redStart = 13
    private static let gap: CGFloat = 1
    private static let greenOn = NSColor.systemGreen.withAlphaComponent(0.95)
    private static let greenOff = NSColor.systemGreen.withAlphaComponent(0.32)
    private static let yellowOn = NSColor.systemYellow.withAlphaComponent(0.95)
    private static let yellowOff = NSColor.systemYellow.withAlphaComponent(0.32)
    private static let redOn = NSColor.systemRed.withAlphaComponent(0.95)
    private static let redOff = NSColor.systemRed.withAlphaComponent(0.32)
    private static let mutedOn = NSColor.systemOrange.withAlphaComponent(0.95)
    private static let mutedOff = NSColor.systemOrange.withAlphaComponent(0.32)
    /// Gray LEDs that stay readable on HUD glass in both light and dark.
    private static let idleOn = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(white: 0.88, alpha: 0.52)
        }
        return NSColor(white: 0.22, alpha: 0.48)
    }
    private static let idleOff = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(white: 0.88, alpha: 0.16)
        }
        return NSColor(white: 0.22, alpha: 0.14)
    }

    private var litCount = 0

    var level: Float = 0 {
        didSet {
            let next = Self.litSegments(level)
            if next != litCount {
                litCount = next
                needsDisplay = true
            }
        }
    }
    var active = true {
        didSet {
            if active != oldValue { needsDisplay = true }
        }
    }
    var muted = false {
        didSet {
            if muted != oldValue { needsDisplay = true }
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 88, height: 10) }
    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance { drawSegments() }
    }

    private func drawSegments() {
        let count = Self.segmentCount
        let gap = Self.gap
        let width = (bounds.width - gap * CGFloat(count - 1)) / CGFloat(count)
        guard width > 0, bounds.height > 0 else { return }
        let radius = min(width, bounds.height) / 2
        let path = NSBezierPath()
        for i in 0..<count {
            let rect = NSRect(
                x: CGFloat(i) * (width + gap),
                y: 0,
                width: width,
                height: bounds.height
            )
            path.removeAllPoints()
            path.appendRoundedRect(rect, xRadius: radius, yRadius: radius)
            Self.color(segment: i, lit: i < litCount, muted: muted, active: active).setFill()
            path.fill()
        }
    }

    private static func litSegments(_ level: Float) -> Int {
        let clamped = min(1, max(0, level))
        return min(segmentCount, Int((clamped * Float(segmentCount)).rounded(.toNearestOrAwayFromZero)))
    }

    private static func color(segment: Int, lit: Bool, muted: Bool, active: Bool) -> NSColor {
        if muted { return lit ? mutedOn : mutedOff }
        if !active { return lit ? idleOn : idleOff }
        if segment >= redStart { return lit ? redOn : redOff }
        if segment >= yellowStart { return lit ? yellowOn : yellowOff }
        return lit ? greenOn : greenOff
    }
}
