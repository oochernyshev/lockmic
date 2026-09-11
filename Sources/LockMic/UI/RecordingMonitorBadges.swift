import AppKit
import QuartzCore

/// Shared chrome for the small dot + label capsules on a device row.
/// Subclasses supply text and colors only.
class PillBadgeView: NSView {
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")

    init(text: String, tooltip: String? = nil, accessibilityLabel: String? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        toolTip = tooltip
        if let accessibilityLabel {
            setAccessibilityLabel(accessibilityLabel)
        }

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = text
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

    /// Capsule background. Subclasses override.
    func fillColor() -> NSColor { .clear }
    /// Dot color. Subclasses override.
    func dotColor() -> NSColor { .clear }

    override func updateLayer() {
        layer?.backgroundColor = fillColor().cgColor
        dot.layer?.backgroundColor = dotColor().cgColor
    }
}

/// Compact orange “Muted” capsule matching Preferences device status.
final class MuteBadgeView: PillBadgeView {
    init() {
        super.init(text: L10n.devicesStatusMuted)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func fillColor() -> NSColor { .systemOrange.withAlphaComponent(0.18) }
    override func dotColor() -> NSColor { .systemOrange }
}

/// Bluetooth headset is in HFP because its microphone is open.
final class CallQualityBadgeView: PillBadgeView {
    init() {
        super.init(
            text: L10n.recordingBadgeCallQuality,
            tooltip: L10n.recordingBadgeCallQualityTooltip,
            accessibilityLabel: L10n.recordingBadgeCallQualityTooltip
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func fillColor() -> NSColor { .systemYellow.withAlphaComponent(0.22) }
    override func dotColor() -> NSColor { .systemYellow }
}

/// Warning triangle when an unselected source has audio that is not in the mix.
final class NoSignalBadgeView: NSView {
    private let iconView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        toolTip = L10n.recordingNoSignal
        setAccessibilityLabel(L10n.recordingNoSignal)

        iconView.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: L10n.recordingNoSignal
        )
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .systemYellow
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            iconView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),
            heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 18) }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.22).cgColor
        iconView.contentTintColor = .systemYellow
    }

    func setBlinking(_ on: Bool) {
        layer?.removeAnimation(forKey: "blink")
        if on {
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = 1
            anim.toValue = 0.28
            anim.duration = 0.55
            anim.autoreverses = true
            anim.repeatCount = .infinity
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(anim, forKey: "blink")
        } else {
            layer?.opacity = 1
        }
    }
}
