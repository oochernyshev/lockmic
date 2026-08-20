import AppKit
import QuartzCore

/// Accent fill — system bezels go grey in a non-activating panel.
final class AllowAccessButton: NSButton {
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

/// Same pill chrome as Stop Recording: icon + title, own fill so it
/// does not go grey in a non-activating panel. HUD colors and filled mic.
final class MuteToggleButton: NSButton {
    private var isMuted = false

    init(target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .shadowlessSquare
        imagePosition = .imageLeading
        imageHugsTitle = true
        contentTintColor = .white
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        focusRingType = .none
        apply(muted: false)
    }

    func apply(muted: Bool) {
        isMuted = muted
        let title = muted ? L10n.hudMuted : L10n.hudUnmuted
        image = NSImage(systemSymbolName: muted ? "mic.slash.fill" : "mic.fill", accessibilityDescription: title)
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            ]
        )
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 20
        size.height += 8
        return size
    }

    override var wantsUpdateLayer: Bool { true }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
    }

    override func updateLayer() {
        let titleColor = NSColor.white
        layer?.backgroundColor = NSColor.black.withAlphaComponent(
            isMuted ? (isHighlighted ? 0.78 : 0.62) : (isHighlighted ? 0.66 : 0.50)
        ).cgColor
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

/// System bezels go grey in a non-activating panel. Paint our own fill.
final class StopRecordingButton: NSButton {
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

enum RecordingMonitorChrome {
    /// Solid enough to read on the HUD-glass window.
    static var blockFill: NSColor {
        NSColor.windowBackgroundColor.withAlphaComponent(0.88)
    }

    static var blockStroke: NSColor {
        NSColor.labelColor.withAlphaComponent(0.14)
    }
}

private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// Preferences-style inset card (fill + hairline + 10pt corner).
final class CardView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let header = NSStackView()
    private let rows = NSStackView()
    private let scroller = NSScrollView()
    private let bodyStack = NSStackView()
    private var scrollerHeight: NSLayoutConstraint?
    private var leadingAccessory: NSView?
    private var accessory: NSView?
    private var maxVisibleRows: Int?

    convenience init(maxVisibleRows: Int? = nil) {
        self.init(frame: .zero)
        self.maxVisibleRows = maxVisibleRows
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = PreferencesChrome.cardCornerRadius
        layer?.borderWidth = 1

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
        rows.translatesAutoresizingMaskIntoConstraints = false

        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroller.contentView = clip
        scroller.drawsBackground = false
        scroller.backgroundColor = .clear
        scroller.borderType = .noBorder
        scroller.hasHorizontalScroller = false
        scroller.hasVerticalScroller = false
        scroller.autohidesScrollers = true
        scroller.scrollerStyle = .overlay
        scroller.automaticallyAdjustsContentInsets = false
        scroller.contentInsets = NSEdgeInsets()
        scroller.documentView = rows
        let verticalScroller = ThinTransparentScroller()
        verticalScroller.controlSize = .regular
        scroller.verticalScroller = verticalScroller
        let height = scroller.heightAnchor.constraint(equalToConstant: 0)
        height.priority = .required
        scrollerHeight = height

        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = PreferencesChrome.contentSpacing
        bodyStack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.addArrangedSubview(header)
        bodyStack.addArrangedSubview(scroller)
        addSubview(bodyStack)
        NSLayoutConstraint.activate([
            bodyStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyStack.topAnchor.constraint(equalTo: topAnchor),
            bodyStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: bodyStack.widthAnchor, constant: -28),
            scroller.widthAnchor.constraint(equalTo: bodyStack.widthAnchor, constant: -28),
            height,
            rows.topAnchor.constraint(equalTo: clip.topAnchor),
            rows.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            rows.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = RecordingMonitorChrome.blockFill.cgColor
        layer?.borderColor = RecordingMonitorChrome.blockStroke.cgColor
    }

    func setTitle(_ title: String) {
        titleField.stringValue = title
    }

    func setHeaderHidden(_ hidden: Bool) {
        header.isHidden = hidden
        bodyStack.setCustomSpacing(hidden ? 0 : PreferencesChrome.contentSpacing, after: header)
    }

    func setBodyInsets(_ insets: NSEdgeInsets) {
        bodyStack.edgeInsets = insets
    }

    func setLeadingAccessory(_ view: NSView?) {
        if let leadingAccessory {
            header.removeArrangedSubview(leadingAccessory)
            leadingAccessory.removeFromSuperview()
        }
        leadingAccessory = view
        if let view {
            header.insertArrangedSubview(view, at: 0)
        }
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
        refreshScrolling()
    }

    func addRow(_ row: NSView) {
        if !rows.arrangedSubviews.isEmpty {
            let line = NSBox()
            line.boxType = .separator
            rows.addArrangedSubview(line)
        }
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        refreshScrolling()
    }

    func refreshScrolling() {
        layoutSubtreeIfNeeded()
        let count = rows.arrangedSubviews.filter { !($0 is NSBox) }.count
        let shouldScroll = maxVisibleRows.map { count > $0 } ?? false
        scroller.hasVerticalScroller = shouldScroll
        scroller.verticalScrollElasticity = shouldScroll ? .automatic : .none
        let height: CGFloat
        if shouldScroll, let limit = maxVisibleRows {
            height = heightOfVisibleRows(limit)
        } else {
            height = max(rows.fittingSize.height, 0)
        }
        if let scrollerHeight, abs(scrollerHeight.constant - height) > 0.5 {
            scrollerHeight.constant = height
        }
    }

    private func heightOfVisibleRows(_ limit: Int) -> CGFloat {
        var height: CGFloat = 0
        var devices = 0
        for view in rows.arrangedSubviews {
            if view is NSBox {
                if devices > 0, devices < limit {
                    height += max(view.fittingSize.height, 1)
                }
                continue
            }
            devices += 1
            if devices <= limit {
                let rowHeight = view.fittingSize.height
                height += rowHeight > 1 ? rowHeight : view.intrinsicContentSize.height
            }
        }
        return height
    }

    func setDimmed(_ dimmed: Bool) {
        alphaValue = dimmed ? 0.42 : 1
    }
}

/// Compact pill overlaid on the waveform (status / size / elapsed).
final class MonitorChip: NSView {
    let dotView = NSView()
    let label = NSTextField(labelWithString: "")
    private let showsDot: Bool

    init(title: String, showsDot: Bool, monospaced: Bool = false) {
        self.showsDot = showsDot
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3.5
        dotView.isHidden = !showsDot
        dotView.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = title
        label.font = monospaced
            ? .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            : .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .labelColor
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(dotView)
        addSubview(label)
        if showsDot {
            NSLayoutConstraint.activate([
                dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
                dotView.widthAnchor.constraint(equalToConstant: 7),
                dotView.heightAnchor.constraint(equalToConstant: 7),
                label.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 5),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])
        } else {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.82).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        if showsDot, dotView.layer?.backgroundColor == nil {
            dotView.layer?.backgroundColor = NSColor.systemRed.cgColor
        }
    }
}

/// Compact orange “Muted” capsule matching Preferences device status.
final class MuteBadgeView: NSView {
    private let dot = NSView()
    private let label = NSTextField(labelWithString: L10n.devicesStatusMuted)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(dot)
        addSubview(label)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let text = label.intrinsicContentSize
        return NSSize(width: 7 + 6 + 5 + text.width + 7, height: 18)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.18).cgColor
        dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
    }
}

final class RowView: NSView {
    private static let markWidth: CGFloat = 16
    private static let iconWidth: CGFloat = 16
    private static let meterWidth: CGFloat = 88

    private let mark = ChoiceMark()
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let muteBadge = MuteBadgeView()
    private let detailField = NSTextField(labelWithString: "")
    private let meter = LevelBar()
    private var nameBottom: NSLayoutConstraint?
    private var detailBottom: NSLayoutConstraint?
    private var badgeWidth: NSLayoutConstraint?
    private var muteWidth: NSLayoutConstraint?
    private var badgeToMeter: NSLayoutConstraint?
    private var badgeToMute: NSLayoutConstraint?
    private var muteToMeter: NSLayoutConstraint?
    private let onToggle: (String, Bool) -> Void
    private var deviceID = ""
    private var kind: RecordingDeviceKind = .input
    private var canCapture = true
    private var sectionEnabled = true
    private var isMuted = false

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

        detailField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        [mark, iconView, nameField, badge, muteBadge, detailField, meter].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        nameBottom = nameField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9)
        detailBottom = detailField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        badgeWidth = badge.widthAnchor.constraint(equalToConstant: 0)
        muteWidth = muteBadge.widthAnchor.constraint(equalToConstant: 0)
        badgeToMeter = badge.trailingAnchor.constraint(equalTo: meter.leadingAnchor, constant: -10)
        badgeToMute = badge.trailingAnchor.constraint(equalTo: muteBadge.leadingAnchor, constant: -6)
        muteToMeter = muteBadge.trailingAnchor.constraint(equalTo: meter.leadingAnchor, constant: -10)

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
            muteBadge.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),

            meter.trailingAnchor.constraint(equalTo: trailingAnchor),
            meter.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            meter.widthAnchor.constraint(equalToConstant: Self.meterWidth),
            meter.heightAnchor.constraint(equalToConstant: 6),

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
        mark.style = device.kind == .input ? .radio : .checkbox
        mark.isOn = device.isEnabled
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
        invalidateIntrinsicContentSize()
        applyMute(muted)
    }

    func applyMute(_ muted: Bool) {
        let show = muted && kind == .input
        isMuted = show
        muteBadge.isHidden = !show
        muteWidth?.isActive = !show
        badgeToMute?.isActive = show
        muteToMeter?.isActive = show
        badgeToMeter?.isActive = !show
        muteBadge.setContentHuggingPriority(show ? .required : .defaultLow, for: .horizontal)
        muteBadge.setContentCompressionResistancePriority(show ? .required : .defaultLow, for: .horizontal)
        applyIcon()
        syncMeter()
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
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
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
        mark.isEnabled = on
        mark.alphaValue = on ? 1 : 0.4
        iconView.alphaValue = on ? 1 : 0.55
        nameField.alphaValue = on ? 1 : 0.55
        syncMeter()
    }

    func applyLevel(_ device: RecordingDeviceRow, level: Float) {
        mark.isOn = device.isEnabled
        meter.level = level
        syncMeter()
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

final class LevelBar: NSView {
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
    var muted = false {
        didSet {
            if muted != oldValue { needsDisplay = true }
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 96, height: 7) }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3.5, yRadius: 3.5).fill()
        let width = bounds.width * CGFloat(min(1, max(0, level)))
        guard width >= 1 else { return }
        let fill = NSRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
        let color: NSColor
        if muted {
            color = NSColor.systemOrange.withAlphaComponent(0.7)
        } else if !active {
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
final class WaveformView: NSView {
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
    /// Left fade only — playhead and bars flush to the trailing edge.
    private let leadingFade: CGFloat = 12
    private let secondsPerBar: TimeInterval = 0.055

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.masksToBounds = true
        layer?.actions = Self.noAnim
        strip.anchorPoint = .zero
        strip.actions = Self.noAnim
        layer?.addSublayer(strip)
        for chrome in [mid, top, playhead] {
            chrome.actions = Self.noAnim
            layer?.addSublayer(chrome)
        }
        fade.actions = Self.noAnim
        layer?.mask = fade
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }
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
            layer?.backgroundColor = NSColor.clear.cgColor
            mid.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor
            top.backgroundColor = NSColor.separatorColor.cgColor
            playhead.backgroundColor = NSColor.systemRed.cgColor
            let red = NSColor.systemRed.cgColor
            for bar in bars { bar.backgroundColor = red }
            for bar in pool { bar.backgroundColor = red }
        }
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
    }

    private func layoutChrome() {
        let hair = pixel
        top.isHidden = true
        let playX = bounds.maxX - hair
        mid.frame = CGRect(
            x: leadingFade,
            y: bounds.midY.rounded(.down),
            width: max(0, playX - leadingFade),
            height: hair
        )
        playhead.frame = CGRect(x: playX, y: 8, width: hair, height: max(0, bounds.height - 16))
        fade.frame = bounds
        let fadeEnd = bounds.width > 0 ? min(1, 28 / bounds.width) : 0.06
        fade.locations = [0, fadeEnd as NSNumber]
        layoutStrip()
    }

    private func layoutStrip() {
        let playX = bounds.maxX - pixel
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
