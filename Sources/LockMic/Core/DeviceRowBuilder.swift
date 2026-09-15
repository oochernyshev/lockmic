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
        playbackDeviceUID: String,
        usesSystemMix: Bool
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
        let defaultOutName = audio.listOutputDevices().first(where: { $0.uid == defaultOut })?.name ?? ""
        rows.append(systemMixRow(enabled: usesSystemMix, callQuality: false, defaultName: defaultOutName))
        for device in audio.listOutputDevices() where !device.isVirtual {
            let selected = !usesSystemMix && selectedOutputUIDs.contains(device.uid)
            rows.append(
                RecordingDeviceRow(
                    id: "out.\(device.uid)",
                    name: device.name,
                    kind: .output,
                    isDefault: false,
                    isVirtual: false,
                    canCapture: true,
                    isEnabled: selected,
                    level: 0,
                    detail: selected ? L10n.recordingSourceIncluded : L10n.recordingSourceOutside,
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

        let usesSystemMix = deviceSelection.usesSystemMix
        let defaultOutName = defaultOutUID.flatMap { outputsByUID[$0]?.name } ?? ""
        rows.append(
            systemMixRow(
                enabled: usesSystemMix,
                callQuality: usesSystemMix && (captureRig.systemPlaybackTap?.isMixNarrowband == true),
                defaultName: defaultOutName
            )
        )
        for uid in deviceSelection.outputOrder {
            guard let device = outputsByUID[uid] else { continue }
            let id = "out.\(uid)"
            let selected = !usesSystemMix && deviceSelection.selectedOutputUIDs.contains(uid)
            rows.append(
                RecordingDeviceRow(
                    id: id,
                    name: device.name,
                    kind: .output,
                    isDefault: false,
                    isVirtual: false,
                    canCapture: true,
                    isEnabled: selected,
                    level: 0,
                    detail: selected ? L10n.recordingSourceIncluded : L10n.recordingSourceOutside,
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
        if !deviceSelection.usesSystemMix {
            for uid in deviceSelection.selectedOutputUIDs {
                if captureRig.playbackTaps[uid]?.isMixNarrowband == true {
                    flaggedOut.insert(uid)
                }
            }
        }
        return (flaggedIn, flaggedOut)
    }

    private static func systemMixRow(enabled: Bool, callQuality: Bool, defaultName: String) -> RecordingDeviceRow {
        RecordingDeviceRow(
            id: PlaybackMix.rowID,
            name: L10n.recordingSystemMixName(device: defaultName),
            kind: .output,
            isDefault: false,
            isVirtual: false,
            canCapture: true,
            isEnabled: enabled,
            level: 0,
            detail: enabled ? L10n.recordingSystemMixDetail : L10n.recordingSourceOutside,
            isCallQuality: callQuality
        )
    }
}
