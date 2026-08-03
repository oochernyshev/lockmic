import AppKit

/// Translucent HUD-like Dock tile reflecting mute state.
enum DockIconRenderer {
    enum Style: Equatable {
        case muted
        case unmuted
        case unknown
        case unsupported
        case disabled
    }

    static func image(style: Style, updateAvailable: Bool = false) -> NSImage {
        let pixel = 256
        let size = NSSize(width: pixel, height: pixel)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixel,
            pixelsHigh: pixel,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: size)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let rect = NSRect(origin: .zero, size: size)
        NSColor.clear.setFill()
        rect.fill()

        let card = rect.insetBy(dx: 22, dy: 22)
        let path = NSBezierPath(roundedRect: card, xRadius: card.width * 0.28, yRadius: card.width * 0.28)
        fillColor(for: style).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.22).setStroke()
        path.lineWidth = 2
        path.stroke()

        let symbolName: String = {
            switch style {
            case .muted: return "mic.slash.fill"
            case .unmuted: return "mic.fill"
            case .unknown: return "mic"
            case .unsupported: return "exclamationmark.triangle.fill"
            case .disabled: return "hand.raised.fill"
            }
        }()
        let config = NSImage.SymbolConfiguration(pointSize: style == .disabled ? 100 : 112, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        {
            let maxSide = card.width * 0.52
            let scale = min(maxSide / max(symbol.size.width, 1), maxSide / max(symbol.size.height, 1))
            let drawSize = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            let drawRect = NSRect(
                x: rect.midX - drawSize.width / 2,
                y: rect.midY - drawSize.height / 2 + 4,
                width: drawSize.width,
                height: drawSize.height
            )
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
            shadow.set()
            symbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        if updateAvailable {
            // Solid red badge fully inside the rounded tile (top-right).
            let diameter: CGFloat = 40
            let inset: CGFloat = 22
            let badgeRect = NSRect(
                x: card.maxX - diameter - inset,
                y: card.maxY - diameter - inset,
                width: diameter,
                height: diameter
            )
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()
        }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }

    static func style(featuresEnabled: Bool, state: MicState, effectiveMuted: Bool) -> Style {
        guard featuresEnabled else { return .disabled }
        switch state {
        case .muted: return .muted
        case .unmuted: return .unmuted
        case .unknown: return effectiveMuted ? .muted : .unknown
        case .unsupported: return .unsupported
        }
    }

    private static func fillColor(for style: Style) -> NSColor {
        switch style {
        case .muted: return NSColor.black.withAlphaComponent(0.42)
        case .unmuted: return NSColor.black.withAlphaComponent(0.28)
        case .unknown: return NSColor.black.withAlphaComponent(0.34)
        case .unsupported: return NSColor(calibratedRed: 0.55, green: 0.28, blue: 0.10, alpha: 0.45)
        case .disabled: return NSColor.black.withAlphaComponent(0.36)
        }
    }
}
