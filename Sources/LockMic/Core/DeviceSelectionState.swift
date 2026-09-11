import Foundation

/// Owns device-selection state (follow-default flags, selected UIDs, remembered
/// order) and the pure resolution logic around it. Not thread-safe on its own —
/// `SessionRecorder` touches this exclusively from its own queue-confined methods,
/// exactly as it did when these were loose stored properties.
final class DeviceSelectionState {
    var followDefaultInput = true
    var followDefaultOutput = true
    var selectedInputUID = ""
    var selectedOutputUIDs: Set<String> = []
    var recordsAllPlayback = false
    var playbackScope: PlaybackRecordScope = .default
    var inputOrder: [String] = []
    var outputOrder: [String] = []
    var playbackDeviceUID = ""
    var monitorUnselectedDevices = true

    /// Reset to the "no session" state used both after a stop and when a preview is dropped.
    func reset() {
        selectedInputUID = ""
        followDefaultInput = true
        followDefaultOutput = true
        recordsAllPlayback = false
        selectedOutputUIDs = []
        inputOrder = []
        outputOrder = []
    }

    /// Resolve the initial selection for a preview or a session start.
    func apply(
        scope: PlaybackRecordScope,
        followInput: Bool,
        followOutput: Bool,
        preferredInputUID: String = "",
        preferredOutputUIDs: [String] = [],
        audio: AudioDeviceService
    ) {
        playbackScope = scope
        if let outID = try? audio.defaultOutputDeviceID(), !audio.isLockMicRecorder(outID) {
            playbackDeviceUID = audio.deviceUID(outID) ?? ""
        }
        followDefaultInput = followInput
        selectedInputUID = resolvedInputUID(followInput: followInput, preferred: preferredInputUID, audio: audio)
        followDefaultOutput = followOutput && scope != .all
        recordsAllPlayback = scope == .all
        selectedOutputUIDs = resolvedOutputUIDs(
            followOutput: followDefaultOutput,
            preferred: preferredOutputUIDs,
            scope: scope,
            fallbackUID: playbackDeviceUID,
            audio: audio
        )
        rememberDeviceOrder(audio: audio)
    }

    func rememberDeviceOrder(audio: AudioDeviceService) {
        let inputs = audio.listInputDevices().filter { !$0.isVirtual }.map(\.uid)
        for uid in inputs where !inputOrder.contains(uid) {
            inputOrder.append(uid)
        }
        inputOrder.removeAll { !inputs.contains($0) }

        let outputs = audio.listOutputDevices().filter { !$0.isVirtual }.map(\.uid)
        for uid in outputs where !outputOrder.contains(uid) {
            outputOrder.append(uid)
        }
        outputOrder.removeAll { !outputs.contains($0) }
    }

    func liveOutputUIDs(audio: AudioDeviceService) -> Set<String> {
        Set(audio.listOutputDevices().filter { !$0.isVirtual }.map(\.uid))
    }

    func resolvedOutputUIDs(
        followOutput: Bool,
        preferred: [String],
        scope: PlaybackRecordScope,
        fallbackUID: String,
        audio: AudioDeviceService
    ) -> Set<String> {
        let fallback: Set<String> = fallbackUID.isEmpty ? [] : [fallbackUID]
        if followOutput { return fallback }
        let live = liveOutputUIDs(audio: audio)
        if scope == .all { return live }
        let kept = Set(preferred.filter { live.contains($0) })
        if !kept.isEmpty { return kept }
        return fallback
    }

    func resolvedInputUID(followInput: Bool, preferred: String, audio: AudioDeviceService) -> String {
        let fallback = currentDefaultInputUID(audio: audio) ?? ""
        guard !followInput else { return fallback }
        let uid = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty, Self.inputDevice(uid: uid, audio: audio) != nil else { return fallback }
        return uid
    }

    func currentDefaultInputUID(audio: AudioDeviceService) -> String? {
        Self.defaultInputDevice(audio: audio)?.uid
    }

    func currentDefaultOutputUID(audio: AudioDeviceService) -> String? {
        Self.currentDefaultOutputUID(audio: audio)
    }

    static func currentDefaultOutputUID(audio: AudioDeviceService) -> String? {
        guard let id = try? audio.defaultOutputDeviceID(), !audio.isLockMicRecorder(id) else { return nil }
        return audio.deviceUID(id)
    }

    static func defaultInputDevice(audio: AudioDeviceService) -> AudioInputDevice? {
        guard let id = try? audio.defaultInputDeviceID(), !audio.isLockMicRecorder(id) else { return nil }
        return audio.listInputDevices().first { $0.id == id && !$0.isVirtual }
    }

    static func fallbackInputDevice(audio: AudioDeviceService) -> AudioInputDevice? {
        defaultInputDevice(audio: audio) ?? audio.listInputDevices().first { !$0.isVirtual }
    }

    static func fallbackOutputDevice(audio: AudioDeviceService) -> AudioOutputDevice? {
        if let uid = currentDefaultOutputUID(audio: audio),
           let device = audio.listOutputDevices().first(where: { $0.uid == uid && !$0.isVirtual })
        {
            return device
        }
        return audio.listOutputDevices().first { !$0.isVirtual }
    }

    static func inputDevice(uid: String, audio: AudioDeviceService) -> AudioInputDevice? {
        audio.listInputDevices().first { $0.uid == uid && !$0.isVirtual }
    }

    /// Select a mic by UID if it exists and differs from the current selection.
    /// Returns whether the selection actually changed.
    @discardableResult
    func selectMic(_ uid: String, audio: AudioDeviceService) -> Bool {
        guard uid != selectedInputUID else { return false }
        guard Self.inputDevice(uid: uid, audio: audio) != nil else { return false }
        selectedInputUID = uid
        return true
    }

    /// Recompute `playbackScope` from the current output selection vs. the default output.
    func refreshOutputScope() {
        playbackScope = selectedOutputUIDs.contains(where: { $0 != playbackDeviceUID }) ? .all : .default
    }
}
