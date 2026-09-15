import Foundation

/// Owns the mixer mute-gating state (`mixInputMuted`) and the logic that keeps the
/// live mix's input gain and per-capture `captureEnabled` in sync with the app's
/// effective mute state. Reads the mic capture / selection it needs to act on as
/// explicit parameters rather than holding references to those collaborators.
/// Not thread-safe on its own — `SessionRecorder` touches this exclusively from its
/// own queue-confined methods.
final class MuteGate {
    var mixInputMuted = false

    /// Default/follow-output: mix the system tap. All/selection: mix each device tap.
    func applyPlaybackMixGate(captureRig: CaptureRig, deviceSelection: DeviceSelectionState) {
        let systemMix = deviceSelection.usesSystemMix
        captureRig.systemPlaybackTap?.setMixEnabled(systemMix)
        if !systemMix {
            captureRig.liveMixer?.removePlaybackSource(PlaybackMix.systemSourceID)
        }
        for (uid, tap) in captureRig.playbackTaps {
            let on = !systemMix && deviceSelection.selectedOutputUIDs.contains(uid)
            tap.setMixEnabled(on)
            if !on {
                captureRig.liveMixer?.removePlaybackSource(uid)
            }
        }
    }

    /// HAL mute does not always zero this process's IO proc. Gate the mix explicitly.
    func syncInputMuteToCapture(captureRig: CaptureRig, selectedInputUID: String) {
        applyCaptureEnabled(selected: selectedInputUID, mixMuted: mixInputMuted, captures: captureRig.inputCaptures)
    }

    static func mixMuted(
        effectiveMuted: Bool,
        selectedUID: String,
        devices: [InputDeviceRow]
    ) -> Bool {
        guard effectiveMuted else { return false }
        if selectedUID.isEmpty { return true }
        guard let row = devices.first(where: { $0.uid == selectedUID }) else { return true }
        return row.isInScope && !row.isVirtual
    }

    func applyCaptureEnabled(
        selected: String,
        mixMuted: Bool,
        captures: [String: InputDeviceCapture]
    ) {
        for (uid, capture) in captures {
            capture.captureEnabled = uid == selected && !mixMuted
        }
    }
}
