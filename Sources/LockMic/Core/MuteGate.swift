import Foundation

/// Owns the mixer mute-gating state (`mixInputMuted`) and the logic that keeps the
/// live mix's input gain and per-capture `captureEnabled` in sync with the app's
/// effective mute state. Reads the mic capture / selection it needs to act on as
/// explicit parameters rather than holding references to those collaborators.
/// Not thread-safe on its own — `SessionRecorder` touches this exclusively from its
/// own queue-confined methods.
final class MuteGate {
    var mixInputMuted = false

    /// Mix every selected output. The current default uses the system tap (stable
    /// across device switches). If that tap is pulled to 16 kHz (voice-processing)
    /// while the hardware output is still wideband, mix the device tap instead.
    func applyPlaybackMixGate(captureRig: CaptureRig, deviceSelection: DeviceSelectionState, audio: AudioDeviceService) {
        let defaultUID = deviceSelection.currentDefaultOutputUID(audio: audio) ?? deviceSelection.playbackDeviceUID
        let recordDefault = !defaultUID.isEmpty && deviceSelection.selectedOutputUIDs.contains(defaultUID)
        let systemNarrow = captureRig.systemPlaybackTap?.isNarrowband == true
        let defaultDeviceTap = defaultUID.isEmpty ? nil : captureRig.playbackTaps[defaultUID]
        let deviceWide = defaultDeviceTap.map { !$0.isNarrowband } ?? false
        let useDeviceForDefault = recordDefault && systemNarrow && deviceWide
        if useDeviceForDefault {
            let deviceRate = Int(defaultDeviceTap?.sourceSampleRate ?? 0)
            let systemRate = Int(captureRig.systemPlaybackTap?.sourceSampleRate ?? 0)
            sessionRecorderLog.info(
                "Mix default output from device tap \(deviceRate, privacy: .public) Hz; system tap \(systemRate, privacy: .public) Hz"
            )
        }
        captureRig.systemPlaybackTap?.setMixEnabled(recordDefault && !useDeviceForDefault)
        if !recordDefault || useDeviceForDefault {
            captureRig.liveMixer?.removePlaybackSource(PlaybackMix.systemSourceID)
        }
        for (uid, tap) in captureRig.playbackTaps {
            let on: Bool
            if uid == defaultUID {
                on = useDeviceForDefault
            } else {
                on = deviceSelection.selectedOutputUIDs.contains(uid)
            }
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
