import AppKit

/// Shared chrome for the monitor window's action pills. AppKit bezels go
/// grey in a non-activating panel, so every button here paints its own
/// fill via `updateLayer()` instead of relying on `bezelStyle`; subclasses
/// only need to supply colors for their states.
class PillButton: NSButton {
    var cornerRadius: CGFloat = 7 { didSet { layer?.cornerRadius = cornerRadius } }
    var horizontalPadding: CGFloat = 20
    var verticalPadding: CGFloat = 8
    var titleFontSize: CGFloat = NSFont.systemFontSize

    init(title: String, symbolName: String? = nil, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .shadowlessSquare
        focusRingType = .none
        wantsLayer = true
        layer?.masksToBounds = true
        if let symbolName {
            imagePosition = .imageLeading
            imageHugsTitle = true
            contentTintColor = .white
            image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        }
        setTitle(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setTitle(_ title: String) {
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: titleFontSize, weight: .semibold),
            ]
        )
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += horizontalPadding
        size.height += verticalPadding
        return size
    }

    override var wantsUpdateLayer: Bool { true }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Background fill for the current state. Subclasses override.
    func fillColor() -> NSColor { .clear }

    /// Title/tint color for the current state. Override when it varies (e.g. disabled).
    func titleTextColor() -> NSColor { .white }

    override func updateLayer() {
        layer?.cornerRadius = cornerRadius
        layer?.backgroundColor = fillColor().cgColor
        let color = titleTextColor()
        contentTintColor = color
        attributedTitle = NSAttributedString(
            string: attributedTitle.string,
            attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: titleFontSize, weight: .semibold),
            ]
        )
    }
}

/// Accent fill.
final class AllowAccessButton: PillButton {
    init(title: String, target: AnyObject?, action: Selector) {
        super.init(title: title, target: target, action: action)
        cornerRadius = 6
        horizontalPadding = 16
        verticalPadding = 6
        titleFontSize = NSFont.smallSystemFontSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func fillColor() -> NSColor {
        let color = NSColor.controlAccentColor
        return isHighlighted ? (color.blended(withFraction: 0.18, of: .black) ?? color) : color
    }
}

/// HUD colors and filled mic; flips fill/icon/title with mute state.
final class MuteToggleButton: PillButton {
    private var isMuted = false

    init(target: AnyObject?, action: Selector) {
        super.init(title: L10n.hudUnmuted, symbolName: "mic.fill", target: target, action: action)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(muted: Bool) {
        isMuted = muted
        let title = muted ? L10n.hudMuted : L10n.hudUnmuted
        image = NSImage(systemSymbolName: muted ? "mic.slash.fill" : "mic.fill", accessibilityDescription: title)
        setTitle(title)
        needsDisplay = true
    }

    override func fillColor() -> NSColor {
        NSColor.black.withAlphaComponent(isMuted ? (isHighlighted ? 0.78 : 0.62) : (isHighlighted ? 0.66 : 0.50))
    }
}

/// Folder icon, same pill chrome as Mute / Stop.
final class ShowRecordingsButton: PillButton {
    init(title: String, target: AnyObject?, action: Selector) {
        super.init(title: title, symbolName: "folder.fill", target: target, action: action)
        toolTip = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func fillColor() -> NSColor {
        NSColor.black.withAlphaComponent(isHighlighted ? 0.66 : 0.50)
    }
}

/// Red fill, dims when disabled.
final class StopRecordingButton: PillButton {
    init(title: String, target: AnyObject?, action: Selector) {
        super.init(title: title, symbolName: "stop.fill", target: target, action: action)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override func fillColor() -> NSColor {
        let red = NSColor.systemRed
        guard isEnabled else { return red.withAlphaComponent(0.28) }
        return isHighlighted ? (red.blended(withFraction: 0.22, of: .black) ?? red) : red
    }

    override func titleTextColor() -> NSColor {
        isEnabled ? .white : .white.withAlphaComponent(0.55)
    }
}
