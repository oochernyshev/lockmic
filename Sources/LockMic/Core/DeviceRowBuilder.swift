import Foundation

/// Builds the `RecordingDeviceRow` view models shown in the monitor/preferences UI,
/// plus the Bluetooth call-quality heuristic used to badge rows. Pure transformation
/// logic: takes the state it needs as explicit parameters and returns a view model,
/// with no dependency on `SessionRecorder`'s threading.
enum DeviceRowBuilder {
    /// Rows for a preview, before any session state (input/output order, capture rig) exists.
    static func previewRows(
        audio: AudioDeviceService,
        selectedInputUID: String,
        selectedOutputUIDs: Set<String>,
        playbackDeviceUID: String
    ) -> [RecordingDeviceRow] {
        let defaultIn = (try? audio.defaultInputDeviceID()).flatMap { id -> String? in
            guard !audio.isLockMicRecorder(id) else { return nil }
            return audio.deviceUID(id)
        }
        let defaultOut = (try? audio.defaultOutputDeviceID()).flatMap { id -> String? in
            guard !audio.isLockMicRecorder(id) else { return nil }
            return audio.deviceUID(id)
        } ?? playbackDeviceUID
        var rows: [RecordingDeviceRow] = []
        for device in audio.listInputDevices() where !device.isVirtual {
            rows.append(
                RecordingDeviceRow(
                    id: device.uid,
                    name: device.name,
                    kind: .input,
                    isDefault: device.uid == defaultIn,
                    isVirtual: false,
                    canCapture: true,
                    isEnabled: device.uid == selectedInputUID,
                    level: 0,
                    detail: nil,
                    isCallQuality: false
                )
            )
        }
        for device in audio.listOutputDevices() where !device.isVirtual {
            let selected = selectedOutputUIDs.contains(device.uid)
            let isDefault = device.uid == defaultOut
            rows.append(
                RecordingDeviceRow(
                    id: "out.\(device.uid)",
                    name: device.name,
                    kind: .output,
                    isDefault: isDefault,
                    isVirtual: false,
                    canCapture: true,
                    isEnabled: selected,
                    level: 0,
                    detail: isDefault ? L10n.recordingSourceSystemPlayback : (
                        selected ? L10n.recordingSourceIncluded : L10n.recordingSourceOutside
                    ),
                    isCallQuality: false
                )
            )
        }
        return rows
    }

    /// Rows for a live/starting session, ordered by the remembered device order.
    static func rows(
        audio: AudioDeviceService,
        deviceSelection: DeviceSelectionState,
        captureRig: CaptureRig
    ) -> [RecordingDeviceRow] {
        let defaultInUID = deviceSelection.currentDefaultInputUID(audio: audio)
        let defaultOutUID = deviceSelection.currentDefaultOutputUID(audio: audio)
        let inputsByUID = Dictionary(uniqueKeysWithValues: audio.listInputDevices().map { ($0.uid, $0) })
        let outputsByUID = Dictionary(uniqueKeysWithValues: audio.listOutputDevices().map { ($0.uid, $0) })
        let callQuality = callQualityHeadsetUIDs(
            audio: audio,
            deviceSelection: deviceSelection,
            captureRig: captureRig,
            inputs: inputsByUID,
            outputs: outputsByUID
        )
        var rows: [RecordingDeviceRow] = []

        for uid in deviceSelection.inputOrder {
            guard let device = inputsByUID[uid] else { continue }
            let isDefault = uid == defaultInUID
            let selected = uid == deviceSelection.selectedInputUID
            rows.append(
                RecordingDeviceRow(
                    id: uid,
                    name: device.name,
                    kind: .input,
                    isDefault: isDefault,
                    isVirtual: false,
                    canCapture: true,
                    isEnabled: selected,
                    level: 0,
                    detail: nil,
                    isCallQuality: callQuality.inputs.contains(uid)
                )
            )
        }

        for uid in deviceSelection.outputOrder {
            guard let device = outputsByUID[uid] else { continue }
            let id = "out.\(uid)"
            let isDefault = uid == defaultOutUID
            let selected = deviceSelection.selectedOutputUIDs.contains(uid)
            rows.append(
                RecordingDeviceRow(
                    id: id,
                    name: device.name,
                    kind: .output,
                    isDefault: isDefault,
                    isVirtual: false,
                    canCapture: true,
                    isEnabled: selected,
                    level: 0,
                    detail: isDefault ? L10n.recordingSourceSystemPlayback : (
                        selected ? L10n.recordingSourceIncluded : L10n.recordingSourceOutside
                    ),
                    isCallQuality: callQuality.outputs.contains(uid)
                )
            )
        }
        return rows
    }

    /// Bluetooth headset whose mic HAL is running — that forces HFP on the matching output.
    static func callQualityHeadsetUIDs(
        audio: AudioDeviceService,
        deviceSelection: DeviceSelectionState,
        captureRig: CaptureRig,
        inputs: [String: AudioInputDevice],
        outputs: [String: AudioOutputDevice]
    ) -> (inputs: Set<String>, outputs: Set<String>) {
        let openMics = Set(captureRig.inputCaptures.keys.filter { inputs[$0]?.isBluetooth == true })
        var flaggedIn = Set<String>()
        var flaggedOut = Set<String>()
        for inUID in openMics {
            flaggedIn.insert(inUID)
            let inName = inputs[inUID]?.name
            for (outUID, outDev) in outputs where outDev.isBluetooth {
                if AudioDeviceService.sameBluetoothHeadset(inputUID: inUID, outputUID: outUID)
                    || outDev.name == inName
                {
                    flaggedOut.insert(outUID)
                }
            }
        }
        // Badge the output we actually mix, using IO rate — not an unused
        // device tap whose kAudioTapPropertyFormat can sit at 16 kHz while
        // speakers and the mix stay at 48 kHz.
        let defaultUID = deviceSelection.currentDefaultOutputUID(audio: audio) ?? deviceSelection.playbackDeviceUID
        if !defaultUID.isEmpty, deviceSelection.selectedOutputUIDs.contains(defaultUID) {
            let deviceTap = captureRig.playbackTaps[defaultUID]
            let mixingDevice = captureRig.systemPlaybackTap?.isNarrowband == true
                && (deviceTap.map { !$0.isNarrowband } ?? false)
            let mixTap: PlaybackCapturing? = mixingDevice ? deviceTap : captureRig.systemPlaybackTap
            if mixTap?.isMixNarrowband == true {
                flaggedOut.insert(defaultUID)
            }
        }
        return (flaggedIn, flaggedOut)
    }
}
