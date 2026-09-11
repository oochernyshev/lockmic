import AppKit
import QuartzCore

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
    private var silenceBars: [CALayer] = []
    private var silencePool: [CALayer] = []
    private var silenceMarkers: [CALayer] = []
    private var silenceMarkerPool: [CALayer] = []
    private var smoothedEnergy: Float?
    private var silenceVisualizationEnabled = false
    private var silenceCounting = false
    private var nextSilenceMarkerAt: Date?
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
        for bar in silenceBars {
            bar.removeFromSuperlayer()
            silencePool.append(bar)
        }
        for marker in silenceMarkers {
            marker.removeFromSuperlayer()
            silenceMarkerPool.append(marker)
        }
        bars.removeAll(keepingCapacity: true)
        silenceBars.removeAll(keepingCapacity: true)
        silenceMarkers.removeAll(keepingCapacity: true)
        smoothedEnergy = nil
        nextSilenceMarkerAt = nil
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
        appendSilenceMarkerIfNeeded(at: now)
        pendingPeak = 0
        lastCommit = now
        recycleOffscreenBars()
        compactIfNeeded()
        layoutStrip()
        CATransaction.commit()
    }

    func setSilenceVisualizationEnabled(_ enabled: Bool) {
        guard enabled != silenceVisualizationEnabled else { return }
        silenceVisualizationEnabled = enabled
        smoothedEnergy = nil
        if !enabled {
            for bar in silenceBars { bar.isHidden = true }
        }
    }

    func setSilenceCounting(_ active: Bool) {
        guard active != silenceCounting else { return }
        silenceCounting = active
        nextSilenceMarkerAt = active ? Date().addingTimeInterval(1) : nil
        if !active {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for marker in silenceMarkers {
                marker.removeFromSuperlayer()
                silenceMarkerPool.append(marker)
            }
            silenceMarkers.removeAll(keepingCapacity: true)
            CATransaction.commit()
        }
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
            let green = NSColor.systemGreen.withAlphaComponent(0.3).cgColor
            for bar in silenceBars { bar.backgroundColor = green }
            for bar in silencePool { bar.backgroundColor = green }
            let markerColor = NSColor.systemOrange.withAlphaComponent(0.55).cgColor
            for marker in silenceMarkers { marker.backgroundColor = markerColor }
            for marker in silenceMarkerPool { marker.backgroundColor = markerColor }
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
        bar.zPosition = 1
        strip.addSublayer(bar)
        bars.append(bar)

        let silenceBar = silencePool.popLast() ?? CALayer()
        silenceBar.actions = Self.noAnim
        silenceBar.zPosition = 0
        silenceBar.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.3).cgColor
        silenceBar.isHidden = !silenceVisualizationEnabled
        let silence: Float
        if silenceVisualizationEnabled {
            smoothedEnergy = SilenceEnergyDetector.smoothed(
                previous: smoothedEnergy,
                current: amplitude,
                interval: secondsPerBar
            )
            silence = SilenceEnergyDetector.silenceProbability(smoothedEnergy ?? amplitude)
        } else {
            silence = 0
        }
        let silenceHeight = max(pixel, CGFloat(silence) * maxBar)
        silenceBar.frame = CGRect(
            x: nextBarX,
            y: bounds.midY - silenceHeight,
            width: pixel,
            height: silenceHeight * 2
        )
        strip.addSublayer(silenceBar)
        silenceBars.append(silenceBar)
        nextBarX += step
    }

    private func recycleOffscreenBars() {
        let cutoff = -strip.frame.minX - step
        while let first = bars.first, first.frame.maxX < cutoff {
            first.removeFromSuperlayer()
            pool.append(first)
            bars.removeFirst()
            let silenceBar = silenceBars.removeFirst()
            silenceBar.removeFromSuperlayer()
            silencePool.append(silenceBar)
        }
        while let first = silenceMarkers.first, first.frame.maxX < cutoff {
            first.removeFromSuperlayer()
            silenceMarkerPool.append(first)
            silenceMarkers.removeFirst()
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
        for bar in silenceBars {
            var frame = bar.frame
            frame.origin.x -= origin
            bar.frame = frame
        }
        for marker in silenceMarkers {
            var frame = marker.frame
            frame.origin.x -= origin
            marker.frame = frame
        }
        nextBarX -= origin
    }

    private func appendSilenceMarkerIfNeeded(at now: Date) {
        guard silenceCounting, let next = nextSilenceMarkerAt, now >= next else { return }
        let marker = silenceMarkerPool.popLast() ?? CALayer()
        marker.actions = Self.noAnim
        marker.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.55).cgColor
        marker.zPosition = 2
        let diameter = pixel * 7
        marker.cornerRadius = diameter / 2
        marker.frame = CGRect(
            x: nextBarX - step - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        strip.addSublayer(marker)
        silenceMarkers.append(marker)
        nextSilenceMarkerAt = next.addingTimeInterval(1)
    }
}
