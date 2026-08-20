import AVFoundation
import Combine
import CoreAudio
import Foundation
import os.log
import QuartzCore

private let log = Logger(subsystem: "com.lockmic.app", category: "SessionRecorder")

/// Records one selected mic + system playback as AAC, then mixes them into a dated `LockMic yyyy-MM-dd HH.mm.m4a`.
///
/// Playback uses a Core Audio process tap (macOS 14.2+). Mic uses a HAL IO capture
/// that can move to another input mid-session (still one `microphone.m4a`).
@MainActor
final class SessionRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var sessionDirectory: URL?
    @Published private(set) var lastError: String?
    @Published private(set) var devices: [RecordingDeviceRow] = []
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var microphoneAccess: CaptureAccess = .unknown
    @Published private(set) var playbackAccess: CaptureAccess = .unknown

    /// When true, the selected input tracks the system default microphone.
    @Published private(set) var followDefaultInput = true
    /// When true, playback selection tracks the system default output.
    @Published private(set) var followDefaultOutput = true

    private let audio: AudioDeviceService
    private let mic: MicController
    private var micCapture: InputDeviceCapture?
    private var playback: PlaybackCapturing?
    private var sessionStart: CFTimeInterval = 0
    private var playbackScope: PlaybackRecordScope = .default
    private var selectedInputUID = ""
    private var selectedOutputUIDs: Set<String> = []
    private var inputOrder: [String] = []
    private var outputOrder: [String] = []
    private var playbackDeviceUID = ""
    private var inFlightMix: Task<Bool, Never>?
    private var inFlightMixFolder: URL?
    private var mixGeneration = 0
    private var devicesToken: UUID?
    private var outputChangeWork: DispatchWorkItem?
    private var sessionBitRate: Int = RecordingBitRate.default.bitsPerSecond
    private var micCancellables = Set<AnyCancellable>()

    nonisolated static let micFileName = "microphone.m4a"
    nonisolated static let playbackFileName = "playback.m4a"
    nonisolated static let pendingMixFileName = "pending-mix.json"

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
        playback?.stop()
    }

    /// Fill the device list so the monitor can appear before TCC prompts.
    func previewSession(
        playback scope: PlaybackRecordScope = .default,
        followInput: Bool = true,
        followOutput: Bool = true
    ) {
        lastError = nil
        applySessionSelection(scope: scope, followInput: followInput, followOutput: followOutput)
        refreshCaptureAccess()
        refreshDeviceRows()
    }

    /// Start capturing default mic + playback into `baseDirectory/<timestamp>/`.
    func start(
        playback scope: PlaybackRecordScope = .default,
        bitRate: RecordingBitRate = .default,
        in baseDirectory: URL
    ) async throws {
        guard !isRecording else { throw SessionRecorderError.alreadyRecording }
        guard #available(macOS 14.2, *) else { throw SessionRecorderError.needsMacOS142 }

        lastError = nil
        applySessionSelection(scope: scope, followInput: followDefaultInput, followOutput: followDefaultOutput)
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

        let folder = try Self.makeSessionDirectory(in: baseDirectory)
        let micURL = folder.appendingPathComponent(Self.micFileName)
        let playbackURL = folder.appendingPathComponent(Self.playbackFileName)

        do {
            sessionBitRate = bitRate.bitsPerSecond
            sessionStart = CACurrentMediaTime()
            guard let micDevice = inputDevice(uid: selectedInputUID) ?? defaultInputDevice() else {
                throw SessionRecorderError.micStartFailed
            }
            selectedInputUID = micDevice.uid
            let mic = try InputDeviceCapture(
                deviceID: micDevice.id,
                fileURL: micURL,
                sessionStart: sessionStart,
                bitRate: sessionBitRate
            )

            let tap: PlaybackTap
            do {
                tap = try await PlaybackTap(
                    audio: audio,
                    scope: scope,
                    fileURL: playbackURL,
                    sessionStart: sessionStart,
                    bitRate: sessionBitRate
                )
            } catch {
                mic.stop()
                throw error
            }
            micCapture = mic
            syncInputMuteToCapture()
            playback = tap
            if let outID = try? audio.defaultOutputDeviceID(), !audio.isLockMicRecorder(outID) {
                playbackDeviceUID = audio.deviceUID(outID) ?? ""
            }
            sessionDirectory = folder
            recordingStartedAt = Date()
            isRecording = true
            microphoneAccess = .granted
            playbackAccess = .granted
            refreshDeviceRows()
            log.info("Recording started in \(folder.path, privacy: .public)")
        } catch {
            micCapture?.stop()
            micCapture = nil
            playback?.stop()
            playback = nil
            try? FileManager.default.removeItem(at: folder)
            if case .playbackDenied? = error as? SessionRecorderError {
                playbackAccess = .denied
            }
            let wrapped = Self.wrapStartError(error)
            lastError = wrapped.localizedDescription
            throw wrapped
        }
    }

    struct PendingMix: Sendable {
        let folder: URL
        let bitRate: Int
        let mixFileName: String
        let keepDeviceRecordings: Bool
    }

    private struct PendingMixRecord: Codable {
        var bitRate: Int
        var mixFileName: String
        var keepDeviceRecordings: Bool
    }

    var isMixing: Bool { inFlightMix != nil }

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

    /// Stop capture immediately and return what the mixer needs.
    func stopAndPrepareMix(keepDeviceRecordings: Bool = false) throws -> PendingMix {
        let bitRate = sessionBitRate
        let folder = try stopCaptures()
        let pending = PendingMix(
            folder: folder,
            bitRate: bitRate,
            mixFileName: "\(folder.lastPathComponent).m4a",
            keepDeviceRecordings: keepDeviceRecordings
        )
        persistPendingMix(pending)
        return pending
    }

    /// Finish an in-progress session (or wait for an already-running mix). Used on Quit.
    @discardableResult
    func finalizeAndMix(keepDeviceRecordings: Bool) async -> Bool {
        if isRecording {
            do {
                let pending = try stopAndPrepareMix(keepDeviceRecordings: keepDeviceRecordings)
                return await completeMix(pending)
            } catch {
                lastError = error.localizedDescription
                log.error("Stop for quit failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        if let inFlightMix {
            return await inFlightMix.value
        }
        if let folder = sessionDirectory, let pending = Self.loadPendingMix(in: folder) {
            return await completeMix(pending)
        }
        return true
    }

    /// Pick up session folders left with `pending-mix.json` after a crash or force-quit.
    func resumeInterruptedMixes(in directory: URL) async {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for item in items {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let pending = Self.loadPendingMix(in: item) else { continue }
            let micExists = fm.fileExists(atPath: item.appendingPathComponent(Self.micFileName).path)
            let playExists = fm.fileExists(atPath: item.appendingPathComponent(Self.playbackFileName).path)
            guard micExists || playExists else { continue }
            log.info("Resuming interrupted mix in \(item.path, privacy: .public)")
            _ = await completeMix(pending)
        }
    }

    @discardableResult
    func completeMix(_ pending: PendingMix) async -> Bool {
        persistPendingMix(pending)
        if let inFlightMix, inFlightMixFolder == pending.folder {
            return await inFlightMix.value
        }
        let previous = inFlightMix
        mixGeneration += 1
        let generation = mixGeneration
        let task = Task { @MainActor in
            _ = await previous?.value
            defer {
                if self.mixGeneration == generation {
                    self.inFlightMix = nil
                    self.inFlightMixFolder = nil
                }
            }
            return await self.performMix(pending)
        }
        inFlightMix = task
        inFlightMixFolder = pending.folder
        return await task.value
    }

    private func performMix(_ pending: PendingMix) async -> Bool {
        do {
            let destination = pending.keepDeviceRecordings
                ? pending.folder
                : pending.folder.deletingLastPathComponent()
            try await SessionMix.mix(
                in: pending.folder,
                bitRate: pending.bitRate,
                mixFileName: pending.mixFileName,
                destinationFolder: destination
            )
            Self.removePendingMix(in: pending.folder)
            if !pending.keepDeviceRecordings {
                SessionMix.discardDeviceRecordings(in: pending.folder)
            }
            log.info("Mixed file in \(pending.folder.path, privacy: .public)")
            return true
        } catch {
            lastError = error.localizedDescription
            log.error("Mix failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func persistPendingMix(_ pending: PendingMix) {
        let record = PendingMixRecord(
            bitRate: pending.bitRate,
            mixFileName: pending.mixFileName,
            keepDeviceRecordings: pending.keepDeviceRecordings
        )
        do {
            let data = try JSONEncoder().encode(record)
            try data.write(to: pending.folder.appendingPathComponent(Self.pendingMixFileName), options: .atomic)
        } catch {
            log.error("Could not persist pending mix: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func loadPendingMix(in folder: URL) -> PendingMix? {
        let url = folder.appendingPathComponent(pendingMixFileName)
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(PendingMixRecord.self, from: data)
        else { return nil }
        return PendingMix(
            folder: folder,
            bitRate: record.bitRate,
            mixFileName: record.mixFileName,
            keepDeviceRecordings: record.keepDeviceRecordings
        )
    }

    static func hasPendingMix(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(pendingMixFileName).path)
    }

    private static func removePendingMix(in folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(pendingMixFileName))
    }

    /// Stop hardware only (no mix). Quit uses `finalizeAndMix` so the mix still runs.
    @discardableResult
    func stopCaptures() throws -> URL {
        guard isRecording, let folder = sessionDirectory else {
            throw SessionRecorderError.notRecording
        }
        micCapture?.stop()
        micCapture = nil
        playback?.stop()
        playback = nil
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
        log.info("Recording stopped: \(folder.path, privacy: .public)")
        return folder
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
            if followDefaultOutput {
                selectedOutputUIDs = [uid]
            }
            if #available(macOS 14.2, *), let tap = playback as? PlaybackTap, followDefaultOutput {
                do {
                    try tap.retarget(using: audio, scope: playbackScope)
                    playbackDeviceUID = uid
                    applyOutputSelection()
                    log.info("Playback tap moved to \(self.audio.deviceName(outID), privacy: .public)")
                } catch {
                    lastError = error.localizedDescription
                    log.error("Playback retarget failed: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                playbackDeviceUID = uid
                applyOutputSelection()
            }
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
        }
        refreshDeviceRows()
    }

    func setFollowDefaultInput(_ follow: Bool) {
        guard isRecording else { return }
        followDefaultInput = follow
        if follow, let uid = currentDefaultInputUID() {
            selectMic(uid)
        }
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
        let anySelected = !selectedOutputUIDs.isEmpty
        playback?.captureEnabled = anySelected
        let nextScope: PlaybackRecordScope =
            selectedOutputUIDs.contains(where: { $0 != playbackDeviceUID }) ? .all : .default
        let scopeChanged = nextScope != playbackScope
        playbackScope = nextScope
        if scopeChanged {
            rebuildPlaybackTap()
        }
    }

    private func rebuildPlaybackTap() {
        guard #available(macOS 14.2, *), let tap = playback as? PlaybackTap else { return }
        do {
            try tap.retarget(using: audio, scope: playbackScope)
            log.info("Playback tap scope \(String(describing: self.playbackScope), privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            log.error("Playback retarget failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applySessionSelection(
        scope: PlaybackRecordScope,
        followInput: Bool,
        followOutput: Bool
    ) {
        playbackScope = scope
        if let outID = try? audio.defaultOutputDeviceID(), !audio.isLockMicRecorder(outID) {
            playbackDeviceUID = audio.deviceUID(outID) ?? ""
        }
        followDefaultInput = followInput
        selectedInputUID = currentDefaultInputUID() ?? ""
        followDefaultOutput = followOutput && scope != .all
        selectedOutputUIDs = playbackDeviceUID.isEmpty ? [] : [playbackDeviceUID]
        if scope == .all, !followDefaultOutput {
            for device in audio.listOutputDevices() where !device.isVirtual {
                selectedOutputUIDs.insert(device.uid)
            }
        }
        rememberDeviceOrder()
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
            return playback?.level ?? 0
        }
    }

    /// Peak of mic + playback — for the monitor waveform.
    func liveWaveformLevel() -> Float {
        let mic = devices.contains(where: { $0.kind == .input && $0.isEnabled }) ? (micCapture?.level ?? 0) : 0
        let play = selectedOutputUIDs.isEmpty ? 0 : (playback?.level ?? 0)
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

    private static func makeSessionDirectory(in base: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let stamp = formatter.string(from: Date())
        let fm = FileManager.default
        var folder = base.appendingPathComponent("LockMic \(stamp)", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = base.appendingPathComponent("LockMic \(stamp) \(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
