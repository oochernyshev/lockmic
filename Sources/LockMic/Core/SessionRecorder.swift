import AVFoundation
import Combine
import CoreAudio
import Foundation
import os.log
import QuartzCore

private let log = Logger(subsystem: "com.lockmic.app", category: "SessionRecorder")

/// Records selected mic + system playback, mixed live to a dated `LockMic yyyy-MM-dd HH.mm.aac`.
///
/// Playback is a Core Audio process tap (macOS 14.2+). Mic is a HAL IO capture
/// that can move mid-session. Mixed PCM is held in RAM for up to 10 seconds,
/// then checkpointed through one continuous AAC encoder (a crash only loses
/// the current slice).
@MainActor
final class SessionRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var lastError: String?
    @Published private(set) var devices: [RecordingDeviceRow] = []
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var microphoneAccess: CaptureAccess = .unknown
    @Published private(set) var playbackAccess: CaptureAccess = .unknown

    /// When true, the selected input tracks the system default microphone.
    @Published private(set) var followDefaultInput = true
    /// When true, playback selection tracks the system default output.
    @Published private(set) var followDefaultOutput = true

    /// Follow-default plus the current input UID. Set by `RecordingCoordinator` to persist prefs.
    var persistInputSelection: ((Bool, String) -> Void)?

    private let audio: AudioDeviceService
    private let mic: MicController
    private var micCapture: InputDeviceCapture?
    private var playbackTaps: [String: PlaybackCapturing] = [:]
    private var playbackTapSync = 0
    private var sessionStart: CFTimeInterval = 0
    private var playbackScope: PlaybackRecordScope = .default
    private var selectedInputUID = ""
    private var selectedOutputUIDs: Set<String> = []
    private var inputOrder: [String] = []
    private var outputOrder: [String] = []
    private var playbackDeviceUID = ""
    private var devicesToken: UUID?
    private var outputChangeWork: DispatchWorkItem?
    private var sessionBitRate: Int = RecordingBitRate.default.bitsPerSecond
    private var micCancellables = Set<AnyCancellable>()
    private var liveMixer: LiveMixer?
    private var sessionFile: URL?

    init(audio: AudioDeviceService = AudioDeviceService(), mic: MicController) {
        self.audio = audio
        self.mic = mic
        devicesToken = audio.onDevicesChanged { [weak self] in
            Task { @MainActor in
                self?.scheduleOutputRetarget()
            }
        }
        Publishers.CombineLatest(mic.$state, mic.$inputDevices)
            .sink { [weak self] _, _ in
                self?.syncInputMuteToCapture()
            }
            .store(in: &micCancellables)
    }

    deinit {
        outputChangeWork?.cancel()
        if let devicesToken {
            audio.removeDevicesChangedHandler(devicesToken)
        }
        micCapture?.stop()
        for tap in playbackTaps.values { tap.stop() }
        liveMixer?.stop()
    }

    /// Fill the device list so the monitor can appear before TCC prompts.
    func previewSession(
        playback scope: PlaybackRecordScope = .default,
        followInput: Bool = true,
        followOutput: Bool = true,
        preferredInputUID: String = ""
    ) {
        lastError = nil
        applySessionSelection(
            scope: scope,
            followInput: followInput,
            followOutput: followOutput,
            preferredInputUID: preferredInputUID
        )
        refreshCaptureAccess()
        refreshDeviceRows()
    }

    /// Start capturing default mic + playback into `baseDirectory/LockMic yyyy-MM-dd HH.mm.aac`.
    func start(
        playback scope: PlaybackRecordScope = .default,
        bitRate: RecordingBitRate = .default,
        in baseDirectory: URL,
        followInput: Bool = true,
        followOutput: Bool = true,
        preferredInputUID: String = ""
    ) async throws {
        guard !isRecording else { throw SessionRecorderError.alreadyRecording }
        guard #available(macOS 14.2, *) else { throw SessionRecorderError.needsMacOS142 }

        lastError = nil
        applySessionSelection(
            scope: scope,
            followInput: followInput,
            followOutput: followOutput,
            preferredInputUID: preferredInputUID
        )
        refreshCaptureAccess()
        refreshDeviceRows()
        do {
            try await Self.ensureMicrophonePermission()
            microphoneAccess = .granted
        } catch {
            microphoneAccess = .denied
            lastError = error.localizedDescription
            throw error
        }
        do {
            try await Self.ensureSystemAudioPermission()
            playbackAccess = .granted
        } catch {
            playbackAccess = .denied
            lastError = error.localizedDescription
            throw error
        }

        let mixURL = try Self.makeSessionFile(in: baseDirectory)

        do {
            sessionBitRate = bitRate.bitsPerSecond
            sessionStart = CACurrentMediaTime()
            let mixer = LiveMixer(url: mixURL, bitRate: sessionBitRate, sessionStart: sessionStart)
            try mixer.start()
            liveMixer = mixer
            guard let micDevice = inputDevice(uid: selectedInputUID) ?? defaultInputDevice() else {
                throw SessionRecorderError.micStartFailed
            }
            selectedInputUID = micDevice.uid
            let mic = try InputDeviceCapture(
                deviceID: micDevice.id,
                fileURL: nil,
                sessionStart: sessionStart,
                bitRate: sessionBitRate
            )
            mic.mixer = mixer

            micCapture = mic
            syncInputMuteToCapture()
            do {
                try await syncPlaybackTaps()
            } catch {
                mic.stop()
                mixer.stop()
                throw error
            }
            if let outID = try? audio.defaultOutputDeviceID(), !audio.isLockMicRecorder(outID) {
                playbackDeviceUID = audio.deviceUID(outID) ?? ""
            }
            sessionFile = mixURL
            recordingStartedAt = Date()
            isRecording = true
            microphoneAccess = .granted
            playbackAccess = .granted
            refreshDeviceRows()
            log.info("Recording started \(mixURL.lastPathComponent, privacy: .public)")
        } catch {
            liveMixer?.stop()
            liveMixer = nil
            micCapture?.stop()
            micCapture = nil
            stopPlaybackTaps()
            sessionFile = nil
            try? FileManager.default.removeItem(at: mixURL)
            if case .playbackDenied? = error as? SessionRecorderError {
                playbackAccess = .denied
            }
            let wrapped = Self.wrapStartError(error)
            lastError = wrapped.localizedDescription
            throw wrapped
        }
    }

    /// Drop a preview / denied-start so the monitor can close cleanly.
    func cancelPreview() {
        guard !isRecording else { return }
        lastError = nil
        refreshCaptureAccess()
        devices = []
        selectedInputUID = ""
        selectedOutputUIDs = []
        followDefaultInput = true
        followDefaultOutput = true
        inputOrder = []
        outputOrder = []
    }

    /// Used on Quit: stop if a session is running. The mix is already on disk.
    @discardableResult
    func finalizeAndMix() async -> Bool {
        guard isRecording else { return true }
        do {
            let file = try stopCaptures()
            return FileManager.default.fileExists(atPath: file.path)
        } catch {
            lastError = error.localizedDescription
            log.error("Stop for quit failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Stop hardware and wrap the live mix. Quit uses `finalizeAndMix`.
    @discardableResult
    func stopCaptures() throws -> URL {
        guard isRecording, let file = sessionFile else {
            throw SessionRecorderError.notRecording
        }
        micCapture?.stop()
        micCapture = nil
        stopPlaybackTaps()
        liveMixer?.stop()
        let finalFile = liveMixer?.url ?? file
        liveMixer = nil
        sessionFile = finalFile
        playbackDeviceUID = ""
        refreshCaptureAccess()
        selectedInputUID = ""
        followDefaultInput = true
        followDefaultOutput = true
        selectedOutputUIDs = []
        inputOrder = []
        outputOrder = []
        isRecording = false
        recordingStartedAt = nil
        devices = []
        outputChangeWork?.cancel()
        log.info("Recording stopped: \(finalFile.lastPathComponent, privacy: .public)")
        return finalFile
    }

    private func scheduleOutputRetarget() {
        guard isRecording else { return }
        outputChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.retargetPlaybackIfNeeded()
            }
        }
        outputChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func retargetPlaybackIfNeeded() {
        guard isRecording else { return }
        if followDefaultInput, let uid = currentDefaultInputUID() {
            selectMic(uid)
        }
        guard let outID = try? audio.defaultOutputDeviceID(), !audio.isLockMicRecorder(outID),
              let uid = audio.deviceUID(outID)
        else {
            rememberDeviceOrder()
            refreshDeviceRows()
            return
        }
        if uid != playbackDeviceUID {
            playbackDeviceUID = uid
            if followDefaultOutput {
                selectedOutputUIDs = [uid]
            }
            applyOutputSelection()
        }
        rememberDeviceOrder()
        refreshDeviceRows()
    }

    func setDeviceEnabled(_ id: String, enabled: Bool) {
        guard isRecording else { return }
        if id.hasPrefix("out.") {
            followDefaultOutput = false
            let uid = String(id.dropFirst(4))
            if enabled {
                selectedOutputUIDs.insert(uid)
            } else {
                selectedOutputUIDs.remove(uid)
            }
            applyOutputSelection()
            refreshDeviceRows()
            return
        }
        if enabled {
            followDefaultInput = false
            selectMic(id)
            rememberInputSelection()
        }
        refreshDeviceRows()
    }

    func setFollowDefaultInput(_ follow: Bool) {
        guard isRecording else { return }
        followDefaultInput = follow
        if follow, let uid = currentDefaultInputUID() {
            selectMic(uid)
        }
        rememberInputSelection()
        refreshDeviceRows()
    }

    func setFollowDefaultOutput(_ follow: Bool) {
        guard isRecording else { return }
        followDefaultOutput = follow
        if follow, !playbackDeviceUID.isEmpty {
            selectedOutputUIDs = [playbackDeviceUID]
        }
        applyOutputSelection()
        refreshDeviceRows()
    }

    private func applyOutputSelection() {
        playbackScope = selectedOutputUIDs.contains(where: { $0 != playbackDeviceUID }) ? .all : .default
        scheduleSyncPlaybackTaps()
    }

    private func scheduleSyncPlaybackTaps() {
        guard isRecording else { return }
        playbackTapSync += 1
        let token = playbackTapSync
        Task { @MainActor in
            guard token == self.playbackTapSync, self.isRecording else { return }
            do {
                try await self.syncPlaybackTaps()
            } catch {
                self.lastError = error.localizedDescription
                log.error("Playback tap sync failed: \(error.localizedDescription, privacy: .public)")
            }
            self.refreshDeviceRows()
        }
    }

    private func stopPlaybackTaps() {
        for tap in playbackTaps.values { tap.stop() }
        playbackTaps.removeAll()
        liveMixer?.removeAllPlaybackSources()
    }

    /// One device-bound process tap per selected output so each row has its own meter.
    private func syncPlaybackTaps() async throws {
        guard #available(macOS 14.2, *) else { return }
        let wanted = selectedOutputUIDs
        for uid in playbackTaps.keys where !wanted.contains(uid) {
            playbackTaps[uid]?.stop()
            playbackTaps.removeValue(forKey: uid)
            liveMixer?.removePlaybackSource(uid)
        }
        var failed: Error?
        for uid in wanted where playbackTaps[uid] == nil {
            do {
                let tap = try await PlaybackTap(
                    audio: audio,
                    deviceUID: uid,
                    fileURL: nil,
                    sessionStart: sessionStart,
                    bitRate: sessionBitRate
                )
                tap.mixer = liveMixer
                playbackTaps[uid] = tap
                log.info("Playback tap on \(uid, privacy: .public)")
            } catch {
                selectedOutputUIDs.remove(uid)
                failed = error
                log.error("Playback tap failed for \(uid, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if !wanted.isEmpty, playbackTaps.isEmpty, let failed {
            throw failed
        }
    }

    private func applySessionSelection(
        scope: PlaybackRecordScope,
        followInput: Bool,
        followOutput: Bool,
        preferredInputUID: String = ""
    ) {
        playbackScope = scope
        if let outID = try? audio.defaultOutputDeviceID(), !audio.isLockMicRecorder(outID) {
            playbackDeviceUID = audio.deviceUID(outID) ?? ""
        }
        followDefaultInput = followInput
        selectedInputUID = resolvedInputUID(followInput: followInput, preferred: preferredInputUID)
        followDefaultOutput = followOutput && scope != .all
        selectedOutputUIDs = playbackDeviceUID.isEmpty ? [] : [playbackDeviceUID]
        if scope == .all, !followDefaultOutput {
            for device in audio.listOutputDevices() where !device.isVirtual {
                selectedOutputUIDs.insert(device.uid)
            }
        }
        rememberDeviceOrder()
    }

    private func rememberInputSelection() {
        persistInputSelection?(followDefaultInput, selectedInputUID)
    }

    private func resolvedInputUID(followInput: Bool, preferred: String) -> String {
        let fallback = currentDefaultInputUID() ?? ""
        guard !followInput else { return fallback }
        let uid = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty, inputDevice(uid: uid) != nil else { return fallback }
        return uid
    }

    private func currentDefaultInputUID() -> String? {
        defaultInputDevice()?.uid
    }

    private func currentDefaultOutputUID() -> String? {
        guard let id = try? audio.defaultOutputDeviceID(), !audio.isLockMicRecorder(id) else { return nil }
        return audio.deviceUID(id)
    }

    private func defaultInputDevice() -> AudioInputDevice? {
        guard let id = try? audio.defaultInputDeviceID(), !audio.isLockMicRecorder(id) else { return nil }
        return audio.listInputDevices().first { $0.id == id && !$0.isVirtual }
    }

    private func inputDevice(uid: String) -> AudioInputDevice? {
        audio.listInputDevices().first { $0.uid == uid && !$0.isVirtual }
    }

    private func selectMic(_ uid: String) {
        guard uid != selectedInputUID else { return }
        guard let device = inputDevice(uid: uid) else { return }
        if let micCapture {
            do {
                try micCapture.retarget(deviceID: device.id)
                selectedInputUID = uid
                syncInputMuteToCapture()
            } catch {
                lastError = error.localizedDescription
                log.error("Mic retarget failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        selectedInputUID = uid
        syncInputMuteToCapture()
    }

    /// HAL mute does not always zero this process's IO proc. Gate the stem explicitly.
    private func syncInputMuteToCapture() {
        micCapture?.captureEnabled = !isRecordedInputMuted()
    }

    private func isRecordedInputMuted() -> Bool {
        guard mic.effectiveMuted else { return false }
        if selectedInputUID.isEmpty { return true }
        guard let row = mic.inputDevices.first(where: { $0.uid == selectedInputUID }) else {
            return true
        }
        return row.isInScope && !row.isVirtual
    }

    private func rememberDeviceOrder() {
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

    private func refreshDeviceRows() {
        rememberDeviceOrder()
        let defaultInUID = currentDefaultInputUID()
        let defaultOutUID = currentDefaultOutputUID()
        let inputsByUID = Dictionary(uniqueKeysWithValues: audio.listInputDevices().map { ($0.uid, $0) })
        var rows: [RecordingDeviceRow] = []

        for uid in inputOrder {
            guard let device = inputsByUID[uid] else { continue }
            let isDefault = uid == defaultInUID
            let selected = uid == selectedInputUID
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
                    detail: nil
                )
            )
        }

        let outputsByUID = Dictionary(uniqueKeysWithValues: audio.listOutputDevices().map { ($0.uid, $0) })
        for uid in outputOrder {
            guard let device = outputsByUID[uid] else { continue }
            let id = "out.\(uid)"
            let isDefault = uid == defaultOutUID
            let selected = selectedOutputUIDs.contains(uid)
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
                    )
                )
            )
        }
        devices = rows
    }

    /// Live meter for the monitor. Does not publish `devices` (that rebuilt SwiftUI).
    func meterLevel(for row: RecordingDeviceRow) -> Float {
        guard row.isEnabled else { return 0 }
        switch row.kind {
        case .input:
            return micCapture?.level ?? 0
        case .output:
            let uid = String(row.id.dropFirst(4))
            return playbackTaps[uid]?.level ?? 0
        }
    }

    /// Real file size plus a bitrate guess for PCM not yet on disk (current RAM chunk).
    func mixSizeChipText() -> String {
        let bytes: Int64
        if let url = sessionFile,
           FileManager.default.fileExists(atPath: url.path),
           let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        {
            bytes = size.int64Value
        } else {
            bytes = 0
        }
        let extra = liveMixer?.unflushedDuration() ?? 0
        return RecordingBitRate.resolved(sessionBitRate / 1_000).sizeChipText(onDisk: bytes, extra: extra)
    }

    /// Peak of mic + playback — for the monitor waveform.
    func liveWaveformLevel() -> Float {
        let mic = devices.contains(where: { $0.kind == .input && $0.isEnabled }) ? (micCapture?.level ?? 0) : 0
        let play = playbackTaps.values.map(\.level).max() ?? 0
        return min(1, max(mic, play))
    }

    func refreshCaptureAccess() {
        microphoneAccess = Self.liveMicrophoneAccess()
        switch SystemAudioAccess.current {
        case .granted:
            playbackAccess = .granted
        case .denied:
            playbackAccess = .denied
        case .unknown:
            break
        }
    }

    static func liveMicrophoneAccess() -> CaptureAccess {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .unknown
        }
    }

    static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// `!dat` (560226676) and similar AVAudioFile failures arrive as raw OSStatus NSErrors.
    private static func wrapStartError(_ error: Error) -> Error {
        if error is SessionRecorderError { return error }
        let ns = error as NSError
        if ns.domain == "com.apple.coreaudio.avfaudio" || ns.domain == NSOSStatusErrorDomain {
            return SessionRecorderError.fileFailed
        }
        return error
    }

    private static func ensureMicrophonePermission() async throws {
        let granted = await requestMicrophoneAccess()
        guard granted else { throw SessionRecorderError.microphoneDenied }
    }

    private static func ensureSystemAudioPermission() async throws {
        switch SystemAudioAccess.current {
        case .granted:
            return
        case .denied:
            throw SessionRecorderError.playbackDenied
        case .unknown:
            let granted = await SystemAudioAccess.request()
            guard granted else { throw SessionRecorderError.playbackDenied }
        }
    }

    private static func makeSessionFile(in base: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let stamp = formatter.string(from: Date())
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        var file = base.appendingPathComponent("LockMic \(stamp).aac")
        var n = 2
        while fm.fileExists(atPath: file.path) {
            file = base.appendingPathComponent("LockMic \(stamp) \(n).aac")
            n += 1
        }
        return file
    }
}
