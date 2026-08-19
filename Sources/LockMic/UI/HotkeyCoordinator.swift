import AppKit

/// Registers global hotkeys and owns the momentary hold/restore state machine.
@MainActor
final class HotkeyCoordinator {
    private let mic: MicController
    private let preferences: PreferencesStore
    private let hotkeys = HotkeyManager()
    private var lastRegisteredBindings: [HotkeyBinding] = []

    /// `playSound` nil means “same as showHUD”.
    var onMuteChanged: ((_ showHUD: Bool, _ playSound: Bool?) -> Void)?
    var onStartRecording: (() -> Void)?
    var onStopRecording: (() -> Void)?

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

    private enum MomentaryMode {
        case talk
        case mute
        case toggle
    }

    private var momentaryHold: MomentaryHold = .none

    var isHoldActive: Bool { momentaryHold.isActive }
    var hudHold: HUDHoldKind { momentaryHold.hudHold }

    init(mic: MicController, preferences: PreferencesStore) {
        self.mic = mic
        self.preferences = preferences
    }

    func registerIfNeeded(force: Bool = false, enabled: Bool) {
        let bindings = enabled ? preferences.activeBindings : []
        guard force || bindings != lastRegisteredBindings else { return }
        lastRegisteredBindings = bindings
        hotkeys.register(bindings: bindings) { [weak self] action, phase in
            DispatchQueue.main.async {
                self?.handle(action, phase: phase)
            }
        }
    }

    func disable() {
        cancelHold(restore: true)
        lastRegisteredBindings = []
        hotkeys.register(bindings: []) { _, _ in }
    }

    func handle(_ action: HotkeyAction, phase: HotkeyPhase) {
        guard preferences.featuresEnabled else { return }
        switch action {
        case .toggle:
            guard phase == .pressed, !momentaryHold.isActive else { return }
            UsageReporter.record(.toggle, source: .keyboard)
            mic.toggle()
            onMuteChanged?(true, nil)
        case .mute:
            guard phase == .pressed, !momentaryHold.isActive else { return }
            guard !mic.effectiveMuted else { return }
            UsageReporter.record(.mute, source: .keyboard)
            mic.setMuted(true)
            onMuteChanged?(true, nil)
        case .unmute:
            guard phase == .pressed, !momentaryHold.isActive else { return }
            guard mic.effectiveMuted else { return }
            UsageReporter.record(.unmute, source: .keyboard)
            mic.setMuted(false)
            onMuteChanged?(true, nil)
        case .startRecording:
            guard phase == .pressed else { return }
            onStartRecording?()
        case .stopRecording:
            guard phase == .pressed else { return }
            onStopRecording?()
        case .pushToTalk:
            handleMomentary(phase: phase, mode: .talk)
        case .pushToMute:
            handleMomentary(phase: phase, mode: .mute)
        case .pushToToggle:
            handleMomentary(phase: phase, mode: .toggle)
        }
    }

    private func handleMomentary(phase: HotkeyPhase, mode: MomentaryMode) {
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
            onMuteChanged?(true, changed)
        case .released:
            let matches: Bool
            switch (mode, momentaryHold) {
            case (.talk, .pushToTalk), (.mute, .pushToMute), (.toggle, .pushToToggle):
                matches = true
            default:
                matches = false
            }
            guard matches else { return }
            cancelHold(restore: true)
        }
    }

    /// Ends a momentary hold. `restore` writes the pre-hold mute back (key-up and disable).
    private func cancelHold(restore: Bool) {
        let wasMuted: Bool
        switch momentaryHold {
        case .none:
            return
        case .pushToTalk(let w), .pushToMute(let w), .pushToToggle(let w):
            wasMuted = w
        }
        momentaryHold = .none
        mic.suppressDeviceResync = false
        guard restore else { return }
        if mic.effectiveMuted != wasMuted {
            mic.setMuted(wasMuted)
            onMuteChanged?(true, true)
        } else {
            onMuteChanged?(true, false)
        }
        mic.refreshFromHardware(applyDesired: true)
    }
}
