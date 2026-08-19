import AVFoundation
import CoreAudio
import Foundation
import os.log
import QuartzCore

private let log = Logger(subsystem: "com.lockmic.app", category: "SessionRecorder")

/// Which playback to capture. Mic is always the system default input only.
enum PlaybackRecordScope: Sendable {
    /// Audio routed to the default output device.
    case `default`
    /// Mix of every app's playback, regardless of output device.
    case all
}

enum CaptureAccess: Equatable, Sendable {
    case unknown
    case denied
    case granted
}

enum SessionRecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case needsMacOS142
    case microphoneDenied
    case playbackDenied
    case micStartFailed
    case tapFailed(OSStatus)
    case aggregateFailed(OSStatus)
    case ioFailed(OSStatus)
    case invalidTapFormat
    case mixFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return L10n.recordingErrorAlready
        case .notRecording: return L10n.recordingErrorNotRecording
        case .needsMacOS142: return L10n.recordingErrorNeedsMacOS
        case .microphoneDenied: return L10n.recordingErrorMicDenied
        case .playbackDenied: return L10n.recordingErrorPlaybackDenied
        case .micStartFailed: return L10n.recordingErrorMicStart
        case .tapFailed(let status): return L10n.recordingErrorTap(Int(status))
        case .aggregateFailed(let status): return L10n.recordingErrorAggregate(Int(status))
        case .ioFailed(let status): return L10n.recordingErrorIO(Int(status))
        case .invalidTapFormat: return L10n.recordingErrorInvalidFormat
        case .mixFailed: return L10n.recordingErrorMix
        }
    }

}

/// Records default-mic + system playback as AAC, then mixes them into a dated `LockMic yyyy-MM-dd HH.mm.m4a`.
///
/// Playback uses a Core Audio process tap (macOS 14.2+). Mic uses `AVAudioRecorder`
/// on the default input — other input devices are left alone.
@MainActor
final class SessionRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var sessionDirectory: URL?
    @Published private(set) var lastError: String?
    @Published private(set) var devices: [RecordingDeviceRow] = []
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var microphoneAccess: CaptureAccess = .unknown
    @Published private(set) var playbackAccess: CaptureAccess = .unknown
    @Published var defaultMicEnabled = true {
        didSet { recordDefaultMicToggle() }
    }
    @Published var playbackEnabled = true {
        didSet { recordPlaybackToggle() }
    }

    /// When true, the selected input tracks the system default microphone.
    @Published private(set) var followDefaultInput = true
    /// When true, playback selection tracks the system default output.
    @Published private(set) var followDefaultOutput = true

    private let audio: AudioDeviceService
    private var micRecorder: AVAudioRecorder?
    private var playback: PlaybackCapturing?
    private var extraCaptures: [String: InputDeviceCapture] = [:]
    private var failedExtraUIDs: Set<String> = []
    private var sessionStart: CFTimeInterval = 0
    private var defaultMicGate = StemGate(events: [])
    private var playbackGate = StemGate(events: [])
    private var extraGates: [String: StemGate] = [:]
    private var lastMeterTime: CFTimeInterval = 0
    private var playbackScope: PlaybackRecordScope = .default
    private var selectedInputUID = ""
    private var selectedOutputUIDs: Set<String> = []
    private var inputOrder: [String] = []
    private var outputOrder: [String] = []
    private var playbackDeviceName = ""
    private var playbackDeviceUID = ""
    private var devicesToken: UUID?
    private var outputChangeWork: DispatchWorkItem?
    private var sessionBitRate: Int = RecordingBitRate.default.bitsPerSecond

    init(audio: AudioDeviceService = AudioDeviceService()) {
        self.audio = audio
        devicesToken = audio.onDevicesChanged { [weak self] in
            Task { @MainActor in
                self?.scheduleOutputRetarget()
            }
        }
    }

    deinit {
        outputChangeWork?.cancel()
        if let devicesToken {
            audio.removeDevicesChangedHandler(devicesToken)
        }
        micRecorder?.stop()
        playback?.stop()
        extraCaptures.values.forEach { $0.stop() }
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
        followInput: Bool = true,
        followOutput: Bool = true,
        in baseDirectory: URL
    ) async throws {
        guard !isRecording else { throw SessionRecorderError.alreadyRecording }
        guard #available(macOS 14.2, *) else { throw SessionRecorderError.needsMacOS142 }

        lastError = nil
        applySessionSelection(scope: scope, followInput: followInput, followOutput: followOutput)
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
            let mic = try Self.makeMicRecorder(url: micURL, bitRate: sessionBitRate)
            guard mic.record() else {
                throw SessionRecorderError.micStartFailed
            }
            mic.isMeteringEnabled = true
            sessionStart = CACurrentMediaTime()
            defaultMicEnabled = true
            playbackEnabled = true
            defaultMicGate = StemGate(events: [(0, true)])
            playbackGate = StemGate(events: [(0, true)])
            extraGates = [:]

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
            extraCaptures = [:]
            failedExtraUIDs = []
            micRecorder = mic
            playback = tap
            sessionDirectory = folder
            recordingStartedAt = Date()
            isRecording = true
            microphoneAccess = .granted
            playbackAccess = .granted
            refreshDeviceRows()
            log.info("Recording started in \(folder.path, privacy: .public)")
        } catch {
            micRecorder?.stop()
            micRecorder = nil
            playback?.stop()
            playback = nil
            extraCaptures.values.forEach { $0.stop() }
            extraCaptures = [:]
            try? FileManager.default.removeItem(at: folder)
            if case .playbackDenied? = error as? SessionRecorderError {
                playbackAccess = .denied
            }
            lastError = error.localizedDescription
            throw error
        }
    }

    struct PendingMix: Sendable {
        let folder: URL
        let extraUIDs: [String]
        let gates: MixGates
        let bitRate: Int
        let mixFileName: String
        let keepDeviceRecordings: Bool
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

    /// Stop capture immediately and return what the mixer needs.
    func stopAndPrepareMix(keepDeviceRecordings: Bool = false) throws -> PendingMix {
        let extras = extraGates.compactMap { $0.value.wasEverEnabled ? $0.key : nil }
        let gates = MixGates(microphone: defaultMicGate, playback: playbackGate, extras: extraGates)
        let bitRate = sessionBitRate
        let folder = try stopCaptures()
        return PendingMix(
            folder: folder,
            extraUIDs: extras,
            gates: gates,
            bitRate: bitRate,
            mixFileName: "\(folder.lastPathComponent).m4a",
            keepDeviceRecordings: keepDeviceRecordings
        )
    }

    @discardableResult
    func completeMix(_ pending: PendingMix) async -> Bool {
        do {
            let destination = pending.keepDeviceRecordings
                ? pending.folder
                : pending.folder.deletingLastPathComponent()
            try await SessionMix.mix(
                in: pending.folder,
                extraUIDs: pending.extraUIDs,
                gates: pending.gates,
                bitRate: pending.bitRate,
                mixFileName: pending.mixFileName,
                destinationFolder: destination
            )
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

    /// Stop hardware only (no mix). Used on quit.
    @discardableResult
    func stopCaptures() throws -> URL {
        guard isRecording, let folder = sessionDirectory else {
            throw SessionRecorderError.notRecording
        }
        micRecorder?.stop()
        micRecorder = nil
        playback?.stop()
        playback = nil
        extraCaptures.values.forEach { $0.stop() }
        extraCaptures = [:]
        failedExtraUIDs = []
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
        remountInputIfNeeded()
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
            if #available(macOS 14.2, *), let tap = playback as? PlaybackTap {
                do {
                    try tap.retarget(using: audio, scope: playbackScope)
                    playbackDeviceUID = uid
                    playbackDeviceName = audio.deviceName(outID)
                    applyOutputSelection()
                    log.info("Playback tap moved to \(self.playbackDeviceName, privacy: .public)")
                } catch {
                    lastError = error.localizedDescription
                    log.error("Playback retarget failed: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                playbackDeviceUID = uid
                playbackDeviceName = audio.deviceName(outID)
                applyOutputSelection()
            }
        }
        rememberDeviceOrder()
        refreshDeviceRows()
    }

    func setDeviceEnabled(_ id: String, enabled: Bool) {
        guard isRecording else { return }
        let now = CACurrentMediaTime() - sessionStart
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
            selectOnlyMic(id, at: now)
        }
        refreshDeviceRows()
    }

    func setFollowDefaultInput(_ follow: Bool) {
        guard isRecording else { return }
        followDefaultInput = follow
        if follow, let uid = currentDefaultInputUID() {
            selectOnlyMic(uid, at: CACurrentMediaTime() - sessionStart)
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
        if playbackEnabled != anySelected {
            playbackEnabled = anySelected
        }
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

    private func remountInputIfNeeded() {
        guard isRecording else { return }
        let now = CACurrentMediaTime() - sessionStart
        if followDefaultInput, let uid = currentDefaultInputUID() {
            selectOnlyMic(uid, at: now)
        } else if !selectedInputUID.isEmpty {
            selectOnlyMic(selectedInputUID, at: now)
        }
    }

    private func selectOnlyMic(_ id: String, at now: TimeInterval) {
        let defaultUID = currentDefaultInputUID()
        let uid = id == Self.defaultMicID ? (defaultUID ?? id) : id
        let wantDefault = uid == defaultUID
        if !wantDefault {
            startExtraMicIfNeeded(uid: uid)
            guard extraCaptures[uid] != nil else { return }
        }
        selectedInputUID = uid
        if defaultMicEnabled != wantDefault {
            defaultMicEnabled = wantDefault
        }
        for (extraUID, capture) in extraCaptures {
            let on = extraUID == uid
            if capture.captureEnabled != on {
                capture.captureEnabled = on
            }
            var gate = extraGates[extraUID] ?? StemGate(events: [(0, false)])
            if gate.enabled(at: now) != on {
                gate.append(on, at: now)
                extraGates[extraUID] = gate
            }
        }
    }

    private func applySessionSelection(
        scope: PlaybackRecordScope,
        followInput: Bool,
        followOutput: Bool
    ) {
        playbackScope = scope
        if let outID = try? audio.defaultOutputDeviceID(), !audio.isLockMicRecorder(outID) {
            playbackDeviceName = audio.deviceName(outID)
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
        guard let id = try? audio.defaultInputDeviceID(), !audio.isLockMicRecorder(id) else { return nil }
        return audio.deviceUID(id)
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

    static let defaultMicID = "mic.default"
    static let playbackID = "playback"

    static let micFileName = "microphone.m4a"
    static let playbackFileName = "playback.m4a"

    private func recordDefaultMicToggle() {
        guard isRecording else { return }
        defaultMicGate.append(defaultMicEnabled, at: CACurrentMediaTime() - sessionStart)
        refreshDeviceRows()
    }

    private func recordPlaybackToggle() {
        guard isRecording else { return }
        playback?.captureEnabled = playbackEnabled
        playbackGate.append(playbackEnabled, at: CACurrentMediaTime() - sessionStart)
        refreshDeviceRows()
    }

    private func startExtraMicIfNeeded(uid: String) {
        guard extraCaptures[uid] == nil, let folder = sessionDirectory else { return }
        guard uid != currentDefaultInputUID(),
              let device = audio.listInputDevices().first(where: { $0.uid == uid }),
              !device.isVirtual
        else { return }
        let url = folder.appendingPathComponent(Self.extraMicFileName(uid: device.uid))
        do {
            extraCaptures[uid] = try InputDeviceCapture(
                deviceID: device.id,
                fileURL: url,
                sessionStart: sessionStart,
                bitRate: sessionBitRate
            )
            extraGates[uid] = StemGate(events: [(0, false)])
            failedExtraUIDs.remove(uid)
        } catch {
            failedExtraUIDs.insert(uid)
            lastError = error.localizedDescription
            log.error("Could not capture \(device.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func extraMicFileName(uid: String) -> String {
        let safe = uid.replacingOccurrences(of: "/", with: "-")
        return "mic-\(safe).m4a"
    }

    private func refreshDeviceRows() {
        rememberDeviceOrder()
        let defaultInUID = currentDefaultInputUID()
        let inputsByUID = Dictionary(uniqueKeysWithValues: audio.listInputDevices().map { ($0.uid, $0) })
        var rows: [RecordingDeviceRow] = []

        for uid in inputOrder {
            guard let device = inputsByUID[uid] else { continue }
            let isDefault = uid == defaultInUID
            let selected = uid == selectedInputUID
            let failed = failedExtraUIDs.contains(uid)
            rows.append(
                RecordingDeviceRow(
                    id: uid,
                    name: device.name,
                    kind: .input,
                    isDefault: isDefault,
                    isVirtual: false,
                    canCapture: !failed,
                    isEnabled: selected,
                    level: 0,
                    detail: failed ? L10n.recordingSourceUnavailable : nil
                )
            )
        }

        let outputsByUID = Dictionary(uniqueKeysWithValues: audio.listOutputDevices().map { ($0.uid, $0) })
        for uid in outputOrder {
            guard let device = outputsByUID[uid] else { continue }
            let id = "out.\(uid)"
            let isDefault = uid == playbackDeviceUID
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
            return row.isDefault ? defaultMicMeterLevel() : (extraCaptures[row.id]?.level ?? 0)
        case .output:
            return playback?.level ?? 0
        }
    }

    /// Peak of every source currently armed — for the monitor waveform.
    func liveWaveformLevel() -> Float {
        var peak: Float = 0
        if defaultMicEnabled {
            peak = max(peak, defaultMicMeterLevel())
        }
        if playbackEnabled {
            peak = max(peak, playback?.level ?? 0)
        }
        for capture in extraCaptures.values where capture.captureEnabled {
            peak = max(peak, capture.level)
        }
        return min(1, peak)
    }

    private func defaultMicMeterLevel() -> Float {
        guard let mic = micRecorder, defaultMicEnabled else { return 0 }
        let now = CACurrentMediaTime()
        if now - lastMeterTime > 0.04 {
            mic.updateMeters()
            lastMeterTime = now
        }
        // averagePower is dBFS (0 = full scale). Laptop room noise sits around
        // -45…-35 dB; mapping from -50 made hiss look like speech.
        return RecordingLevelDisplay.fromAverageDB(mic.averagePower(forChannel: 0))
    }

    // MARK: - Mic (default input only)

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

    private static func makeMicRecorder(url: URL, bitRate: Int) throws -> AVAudioRecorder {
        let recorder = try AVAudioRecorder(
            url: url,
            settings: RecordingCodec.aacSettings(channels: 1, bitRate: bitRate)
        )
        recorder.prepareToRecord()
        return recorder
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
