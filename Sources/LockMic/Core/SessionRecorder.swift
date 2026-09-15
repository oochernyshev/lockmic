import AVFoundation
import Combine
import CoreAudio
import Foundation
import os.log
import QuartzCore

let sessionRecorderLog = Logger(subsystem: "com.lockmic.app", category: "SessionRecorder")

/// Records selected mic plus playback, mixed live to a dated `LockMic yyyy-MM-dd HH.mm.aac`.
///
/// Playback is either the system mix of the default output, or per-device Core Audio
/// process taps (macOS 14.2+). Mic is a HAL IO capture
/// that can move mid-session. Mixed PCM is held in RAM for up to 10 seconds,
/// then checkpointed through one continuous AAC encoder (a crash only loses
/// the current slice).
///
/// All session mutation and HAL run on `queue` so mute on the main thread
/// never waits for recording.
///
/// This is the single orchestrator: it owns collaborator objects for
/// permission requests (`SessionPermissions`, stateless), device selection
/// (`DeviceSelectionState`), HAL capture/tap/mixer lifecycle (`CaptureRig`),
/// and mute gating (`MuteGate`), and coordinates them from its own
/// queue-confined methods. None of those collaborators are thread-safe on
/// their own — they are plain storage + logic, touched exclusively from here.
final class SessionRecorder: ObservableObject, @unchecked Sendable {
    @Published private(set) var isRecording = false
    /// Starting, recording, or tearing down HAL / wrapping the mix. Any-thread.
    var isBusy: Bool {
        flagLock.lock()
        defer { flagLock.unlock() }
        return flagPhase != .idle
    }
    @Published var lastError: String?
    @Published var devices: [RecordingDeviceRow] = []
    @Published private(set) var recordingStartedAt: Date?
    @Published var microphoneAccess: CaptureAccess = .unknown
    @Published var playbackAccess: CaptureAccess = .unknown

    /// When true, the selected input tracks the system default microphone.
    @Published var followDefaultInput = true
    /// When true, playback is the system mix of the current default output.
    @Published var followDefaultOutput = true
    /// When true, every live output is in the mix.
    @Published var recordsAllPlayback = false

    /// Follow-default plus the current input UID. Set by `RecordingCoordinator` to persist prefs.
    var persistInputSelection: ((Bool, String) -> Void)?
    /// Follow-default, current output UIDs, and whether every live output is selected.
    var persistOutputSelection: ((Bool, Set<String>, Bool) -> Void)?

    let audio: AudioDeviceService
    let mic: MicController

    private let deviceSelection = DeviceSelectionState()
    private let captureRig = CaptureRig()
    private var muteGate = MuteGate()

    private var devicesToken: UUID?
    private var outputChangeWork: DispatchWorkItem?
    /// HAL fires many device-list notices while an output switches; coalesce before recreating meter taps.
    static let deviceListCoalesce: TimeInterval = 0.3
    private var micCancellables = Set<AnyCancellable>()
    private var stopWaiters: [CheckedContinuation<URL, Error>] = []
    let queue: DispatchQueue
    private static let queueKey = DispatchSpecificKey<UInt8>()
    private let flagLock = NSLock()
    private enum Phase { case idle, starting, recording, stopping }
    private var phase: Phase = .idle
    private var flagPhase: Phase = .idle
    /// Bumped to cancel an in-flight start when the user hits stop.
    private var startGeneration = 0
    let levelMetering = LevelMetering()
    private var sessionLive = false

    init(audio: AudioDeviceService = AudioDeviceService(), mic: MicController) {
        self.audio = audio
        self.mic = mic
        let queue = DispatchQueue(label: "com.lockmic.recording", qos: .userInitiated)
        queue.setSpecific(key: Self.queueKey, value: 1)
        self.queue = queue
        devicesToken = audio.onDevicesChanged { [weak self] in
            self?.perform {
                self?.restartPlaybackIO()
                self?.scheduleDeviceRefresh()
            }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            Publishers.CombineLatest(self.mic.$state, self.mic.$inputDevices)
                .sink { [weak self] _, _ in
                    guard let self else { return }
                    let muted = self.mic.effectiveMuted
                    let devices = self.mic.inputDevices
                    self.gateMixMute(effectiveMuted: muted, devices: devices)
                }
                .store(in: &self.micCancellables)
        }
    }

    deinit {
        outputChangeWork?.cancel()
        if let devicesToken {
            audio.removeDevicesChangedHandler(devicesToken)
        }
        let mixer = captureRig.stopAllForTeardown()
        DispatchQueue.global(qos: .utility).async {
            mixer?.stop()
        }
    }

    var onRecordingQueue: Bool {
        DispatchQueue.getSpecific(key: Self.queueKey) != nil
    }

    func perform(_ work: @escaping () -> Void) {
        if onRecordingQueue {
            work()
        } else {
            queue.async(execute: work)
        }
    }

    func publishUI(_ update: @escaping (SessionRecorder) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            update(self)
        }
    }

    private func setPhase(_ new: Phase) {
        phase = new
        sessionLive = new == .recording
        flagLock.lock()
        flagPhase = new
        flagLock.unlock()
        publishUI { $0.isRecording = new == .recording }
    }

    func mutate<T>(_ work: @escaping () -> T) async -> T {
        if onRecordingQueue { return work() }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    func publishLevels() {
        levelMetering.publishLevels(
            inputs: captureRig.inputCaptures,
            taps: captureRig.playbackTaps,
            system: captureRig.systemPlaybackTap,
            usesSystemMix: deviceSelection.usesSystemMix,
            selectedInputUID: deviceSelection.selectedInputUID,
            selectedOutputUIDs: deviceSelection.selectedOutputUIDs,
            mixMuted: muteGate.mixInputMuted,
            mixer: captureRig.liveMixer,
            sessionFile: captureRig.sessionFile,
            sessionBitRate: captureRig.sessionBitRate,
            startedAt: recordingStartedAt
        )
    }

    /// Fill the device list so the monitor can appear before TCC prompts.
    /// Safe on the main thread — does not wait for HAL.
    func previewSession(
        playback scope: PlaybackRecordScope = .default,
        followInput: Bool = true,
        followOutput: Bool = true,
        preferredInputUID: String = "",
        preferredOutputUIDs: [String] = []
    ) {
        let apply = { [self] in
            lastError = nil
            applySessionSelection(
                scope: scope,
                followInput: followInput,
                followOutput: followOutput,
                preferredInputUID: preferredInputUID,
                preferredOutputUIDs: preferredOutputUIDs
            )
            refreshCaptureAccess()
            refreshDeviceRows()
        }
        if Thread.isMainThread, !onRecordingQueue {
            // Show rows immediately even if a previous stop is still tearing down HAL.
            lastError = nil
            followDefaultInput = followInput
            followDefaultOutput = followOutput && scope != .all
            recordsAllPlayback = scope == .all
            refreshCaptureAccess()
            let defaultOut = currentDefaultOutputUID() ?? ""
            devices = DeviceRowBuilder.previewRows(
                audio: audio,
                selectedInputUID: deviceSelection.resolvedInputUID(followInput: followInput, preferred: preferredInputUID, audio: audio),
                selectedOutputUIDs: deviceSelection.resolvedOutputUIDs(
                    followOutput: followOutput && scope != .all,
                    preferred: preferredOutputUIDs,
                    scope: scope,
                    fallbackUID: defaultOut,
                    audio: audio
                ),
                playbackDeviceUID: defaultOut,
                usesSystemMix: followOutput && scope != .all
            )
        }
        perform(apply)
    }

    /// Start capturing default mic + playback into `baseDirectory/LockMic yyyy-MM-dd HH.mm.aac`.
    func start(
        playback scope: PlaybackRecordScope = .default,
        bitRate: RecordingBitRate = .default,
        in baseDirectory: URL,
        followInput: Bool = true,
        followOutput: Bool = true,
        preferredInputUID: String = "",
        preferredOutputUIDs: [String] = [],
        monitorUnselected: Bool = true
    ) async throws {
        if isBusy {
            _ = try? await stopCaptures()
        }
        guard !isBusy else { throw SessionRecorderError.alreadyRecording }
        guard #available(macOS 14.2, *) else { throw SessionRecorderError.needsMacOS142 }

        do {
            try await SessionPermissions.ensureMicrophonePermission()
            publishUI { $0.microphoneAccess = .granted }
        } catch {
            publishUI {
                $0.microphoneAccess = .denied
                $0.lastError = error.localizedDescription
            }
            throw error
        }
        do {
            try await SessionPermissions.ensureSystemAudioPermission()
            publishUI { $0.playbackAccess = .granted }
        } catch {
            publishUI {
                $0.playbackAccess = .denied
                $0.lastError = error.localizedDescription
            }
            throw error
        }
        SessionMix.prepareArtwork()

        let mixURL = try SessionPermissions.makeSessionFile(in: baseDirectory)
        let generation = await mutate { () -> Int in
            guard self.phase == .idle else { return 0 }
            self.startGeneration += 1
            self.deviceSelection.monitorUnselectedDevices = monitorUnselected
            self.applySessionSelection(
                scope: scope,
                followInput: followInput,
                followOutput: followOutput,
                preferredInputUID: preferredInputUID,
                preferredOutputUIDs: preferredOutputUIDs
            )
            self.refreshCaptureAccess()
            self.refreshDeviceRows()
            self.captureRig.sessionBitRate = bitRate.bitsPerSecond
            self.captureRig.sessionStart = CACurrentMediaTime()
            self.setPhase(.starting)
            return self.startGeneration
        }
        guard generation > 0 else { throw SessionRecorderError.alreadyRecording }

        do {
            try await startHardware(
                generation: generation,
                bitRate: bitRate,
                mixURL: mixURL
            )
        } catch {
            await abortStart(generation: generation, mixURL: mixURL, error: error)
            throw SessionPermissions.wrapStartError(error)
        }
    }

    @available(macOS 14.2, *)
    private func startHardware(
        generation: Int,
        bitRate: RecordingBitRate,
        mixURL: URL
    ) async throws {
        publishUI { $0.lastError = nil }
        let mixer = LiveMixer(url: mixURL, bitRate: bitRate.bitsPerSecond, sessionStart: captureRig.sessionStart)
        do {
            try mixer.start()
        } catch {
            mixer.stop()
            throw error
        }
        guard await stillStarting(generation) else {
            mixer.stop()
            throw SessionRecorderError.notRecording
        }

        let micDevice = await mutate {
            self.inputDevice(uid: self.deviceSelection.selectedInputUID) ?? self.defaultInputDevice()
        }
        guard let micDevice else {
            mixer.stop()
            throw SessionRecorderError.micStartFailed
        }

        let capture = try await InputDeviceCapture(
            deviceID: micDevice.id,
            fileURL: nil,
            sessionStart: captureRig.sessionStart,
            bitRate: bitRate.bitsPerSecond,
            startIO: true
        )
        capture.mixer = mixer
        guard await stillStarting(generation) else {
            capture.stop()
            mixer.stop()
            throw SessionRecorderError.notRecording
        }

        let useSystemMix = await mutate { self.deviceSelection.usesSystemMix }
        var systemTap: PlaybackTap?
        if useSystemMix {
            do {
                let tap = try await makePlaybackTap(deviceUID: nil)
                guard await stillStarting(generation) else {
                    tap.stop()
                    capture.stop()
                    mixer.stop()
                    throw SessionRecorderError.notRecording
                }
                systemTap = tap
            } catch {
                capture.stop()
                mixer.stop()
                throw error
            }
        }

        let selectedOutputs = useSystemMix ? [] : await mutate { Array(self.deviceSelection.selectedOutputUIDs) }
        var startedTaps: [(uid: String, tap: PlaybackTap)] = []
        for uid in selectedOutputs {
            do {
                let tap = try await makePlaybackTap(deviceUID: uid)
                guard await stillStarting(generation) else {
                    tap.stop()
                    for item in startedTaps { item.tap.stop() }
                    systemTap?.stop()
                    capture.stop()
                    mixer.stop()
                    throw SessionRecorderError.notRecording
                }
                startedTaps.append((uid, tap))
            } catch {
                sessionRecorderLog.error(
                    "Playback tap failed for \(uid, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        if systemTap == nil, startedTaps.isEmpty, !selectedOutputs.isEmpty {
            capture.stop()
            mixer.stop()
            throw SessionRecorderError.playbackDenied
        }
        if useSystemMix, systemTap == nil {
            capture.stop()
            mixer.stop()
            throw SessionRecorderError.playbackDenied
        }

        let wentLive = await mutate { () -> Bool in
            guard self.stillStartingLocked(generation) else { return false }
            self.deviceSelection.selectedInputUID = micDevice.uid
            if let outID = try? self.audio.defaultOutputDeviceID(), !self.audio.isLockMicRecorder(outID) {
                self.deviceSelection.playbackDeviceUID = self.audio.deviceUID(outID) ?? ""
            }
            self.captureRig.liveMixer = mixer
            self.captureRig.inputCaptures[micDevice.uid] = capture
            if let systemTap {
                self.attachPlaybackTap(systemTap)
                self.captureRig.systemPlaybackTap = systemTap
                sessionRecorderLog.info("Playback mix tap (system)")
            }
            for item in startedTaps {
                self.attachPlaybackTap(item.tap)
                self.captureRig.playbackTaps[item.uid] = item.tap
                sessionRecorderLog.info("Playback tap on \(item.uid, privacy: .public)")
            }
            self.captureRig.sessionFile = mixURL
            self.recordingStartedAt = Date()
            self.setPhase(.recording)
            self.applyPlaybackMixGate()
            self.syncInputMuteToCapture()
            self.refreshDeviceRows()
            self.publishLevels()
            return true
        }
        guard wentLive else {
            for item in startedTaps { item.tap.stop() }
            systemTap?.stop()
            capture.stop()
            mixer.stop()
            throw SessionRecorderError.notRecording
        }

        RecordingSessionLock.acquire()
        publishUI {
            $0.microphoneAccess = .granted
            $0.playbackAccess = .granted
            $0.recordingStartedAt = Date()
        }
        reassertSystemMute()
        sessionRecorderLog.info("Recording started \(mixURL.lastPathComponent, privacy: .public)")
        Task { await self.attachBackgroundTaps(generation: generation) }
    }

    private func stillStarting(_ generation: Int) async -> Bool {
        await mutate { self.stillStartingLocked(generation) }
    }

    private func stillStartingLocked(_ generation: Int) -> Bool {
        phase == .starting && startGeneration == generation
    }

    private func abortStart(generation: Int, mixURL: URL, error: Error) async {
        let wrapped = SessionPermissions.wrapStartError(error)
        switch wrapped as? SessionRecorderError {
        case .notRecording:
            break
        case .playbackDenied:
            publishUI {
                $0.playbackAccess = .denied
                $0.lastError = wrapped.localizedDescription
            }
        default:
            publishUI { $0.lastError = wrapped.localizedDescription }
        }
        let snapshot = await mutate { () -> CaptureRig.HardwareSnapshot? in
            guard self.phase == .starting, self.startGeneration == generation else { return nil }
            return self.takeHardwareSnapshot(clearDevices: false)
        }
        if let snapshot {
            _ = await CaptureRig.stopHardware(snapshot)
        }
        try? FileManager.default.removeItem(at: mixURL)
        await mutate {
            if self.phase == .starting, self.startGeneration == generation {
                self.setPhase(.idle)
            }
        }
    }

    @available(macOS 14.2, *)
    private func attachBackgroundTaps(generation: Int) async {
        guard await mutate({ self.sessionLive && self.startGeneration == generation }) else { return }
        await syncInputCaptures()
        guard await mutate({ self.sessionLive && self.startGeneration == generation }) else { return }
        await syncPlaybackTaps()
    }

    func reassertSystemMute() {
        Task { @MainActor [weak mic] in
            mic?.reassertMuteIfNeeded(forceWrite: true)
        }
    }

    /// Drop a preview / denied-start so the monitor can close cleanly.
    func cancelPreview() {
        perform {
            guard !self.sessionLive else { return }
            self.publishUI {
                $0.lastError = nil
                $0.devices = []
                $0.followDefaultInput = true
                $0.followDefaultOutput = true
                $0.recordsAllPlayback = false
            }
            self.refreshCaptureAccess()
            self.deviceSelection.reset()
            self.publishLevels()
        }
    }

    /// Used on Quit: stop if a session is running. The mix is already on disk.
    @discardableResult
    func finalizeAndMix() async -> Bool {
        guard isBusy else { return true }
        do {
            let file = try await stopCaptures()
            return FileManager.default.fileExists(atPath: file.path)
        } catch {
            publishUI { $0.lastError = error.localizedDescription }
            sessionRecorderLog.error("Stop for quit failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Stop hardware and wrap the live mix. Quit uses `finalizeAndMix`.
    ///
    /// HAL Stop/Destroy and the ADTS→m4a wrap never run on the recording queue
    /// or MainActor — those deadlocks Core Audio and freeze the monitor.
    @discardableResult
    func stopCaptures(onIdle: (() -> Void)? = nil) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.perform {
                self.beginStop(onIdle: onIdle, continuation: continuation)
            }
        }
    }

    private func beginStop(
        onIdle: (() -> Void)?,
        continuation: CheckedContinuation<URL, Error>
    ) {
        if phase == .stopping {
            stopWaiters.append(continuation)
            return
        }
        if phase == .idle {
            continuation.resume(throwing: SessionRecorderError.notRecording)
            return
        }
        startGeneration += 1
        if captureRig.sessionFile == nil {
            setPhase(.idle)
            continuation.resume(throwing: SessionRecorderError.notRecording)
            return
        }
        guard let file = captureRig.sessionFile else {
            continuation.resume(throwing: SessionRecorderError.notRecording)
            return
        }
        outputChangeWork?.cancel()
        captureRig.playbackTapSync += 1
        let snapshot = takeHardwareSnapshot(clearDevices: false)
        setPhase(.stopping)
        recordingStartedAt = nil
        publishUI { $0.recordingStartedAt = nil }
        publishLevels()
        if let onIdle {
            DispatchQueue.main.async { onIdle() }
        }

        Task { [weak self] in
            let finalFile = await CaptureRig.stopHardware(snapshot) ?? file
            guard let self else {
                continuation.resume(returning: finalFile)
                return
            }
            self.perform {
                self.captureRig.sessionFile = finalFile
                self.clearSessionSelection()
                self.setPhase(.idle)
                self.publishUI {
                    $0.devices = []
                    $0.followDefaultInput = true
                    $0.followDefaultOutput = true
                    $0.recordsAllPlayback = false
                }
                self.publishLevels()
                sessionRecorderLog.info("Recording stopped: \(finalFile.lastPathComponent, privacy: .public)")
                RecordingSessionLock.release()
                let waiters = self.stopWaiters
                self.stopWaiters.removeAll()
                continuation.resume(returning: finalFile)
                for waiter in waiters { waiter.resume(returning: finalFile) }
            }
        }
    }

    private func takeHardwareSnapshot(clearDevices: Bool) -> CaptureRig.HardwareSnapshot {
        let snapshot = captureRig.takeSnapshot()
        deviceSelection.playbackDeviceUID = ""
        if clearDevices {
            clearSessionSelection()
        }
        return snapshot
    }

    private func clearSessionSelection() {
        deviceSelection.reset()
    }

    // MARK: - Device selection (delegates to `DeviceSelectionState`)

    private func restartPlaybackIO() {
        guard sessionLive else { return }
        applyPlaybackMixGate()
        captureRig.systemPlaybackTap?.ensureRunning()
        for tap in captureRig.playbackTaps.values {
            tap.ensureRunning()
        }
    }

    private func scheduleDeviceRefresh() {
        guard sessionLive else { return }
        outputChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.perform { self?.refreshDevicesOnChange() }
        }
        outputChangeWork = work
        queue.asyncAfter(deadline: .now() + Self.deviceListCoalesce, execute: work)
    }

    private func refreshDevicesOnChange() {
        guard sessionLive else { return }
        if deviceSelection.followDefaultInput, let uid = currentDefaultInputUID() {
            selectMic(uid)
        } else if !deviceSelection.followDefaultInput, inputDevice(uid: deviceSelection.selectedInputUID) == nil,
                  let fallback = fallbackInputDevice()
        {
            sessionRecorderLog.info(
                "Selected input disconnected; switching to \(fallback.name, privacy: .public)"
            )
            selectMic(fallback.uid)
            rememberInputSelection()
        }
        rememberDeviceOrder()
        syncInputCapturesInBackground()
        guard let outID = try? audio.defaultOutputDeviceID(), !audio.isLockMicRecorder(outID),
              let uid = audio.deviceUID(outID)
        else {
            scheduleSyncPlaybackTaps()
            refreshDeviceRows()
            return
        }
        let previousOutputUID = deviceSelection.playbackDeviceUID
        let defaultMoved = uid != previousOutputUID
        if defaultMoved {
            deviceSelection.playbackDeviceUID = uid
            if deviceSelection.followDefaultOutput {
                deviceSelection.selectedOutputUIDs = [uid]
            }
        }
        if !deviceSelection.followDefaultOutput, !deviceSelection.recordsAllPlayback {
            let live = liveOutputUIDs()
            let selected = deviceSelection.selectedOutputUIDs
            if !selected.isEmpty, selected.isDisjoint(with: live), let fallback = fallbackOutputDevice() {
                sessionRecorderLog.info(
                    "Selected output disconnected; switching to \(fallback.name, privacy: .public)"
                )
                deviceSelection.selectedOutputUIDs = [fallback.uid]
                rememberOutputSelection()
            }
        }
        applyPlaybackMixGate()
        if deviceSelection.followDefaultOutput {
            if defaultMoved {
                applyOutputSelection()
            } else {
                scheduleSyncPlaybackTaps()
            }
        } else if deviceSelection.recordsAllPlayback {
            let live = liveOutputUIDs()
            if deviceSelection.selectedOutputUIDs != live {
                deviceSelection.selectedOutputUIDs = live
                applyOutputSelection()
            } else {
                scheduleSyncPlaybackTaps()
            }
        } else {
            scheduleSyncPlaybackTaps()
        }
        if #available(macOS 14.2, *) {
            handlePlaybackTapFormatChange()
        } else {
            refreshDeviceRows()
        }
    }

    func setDeviceEnabled(_ id: String, enabled: Bool) {
        perform { self.setDeviceEnabledOnQueue(id, enabled: enabled) }
    }

    private func setDeviceEnabledOnQueue(_ id: String, enabled: Bool) {
        guard sessionLive else { return }
        if id == PlaybackMix.rowID {
            setFollowDefaultOutputOnQueue(enabled)
            return
        }
        if id.hasPrefix("out.") {
            deviceSelection.followDefaultOutput = false
            let uid = String(id.dropFirst(4))
            if enabled {
                deviceSelection.selectedOutputUIDs.insert(uid)
            } else {
                deviceSelection.selectedOutputUIDs.remove(uid)
            }
            deviceSelection.recordsAllPlayback = deviceSelection.selectedOutputUIDs == liveOutputUIDs()
            let recordAll = deviceSelection.recordsAllPlayback
            applyOutputSelection()
            rememberOutputSelection()
            refreshDeviceRows()
            publishUI {
                $0.followDefaultOutput = false
                $0.recordsAllPlayback = recordAll
            }
            return
        }
        if enabled {
            deviceSelection.followDefaultInput = false
            selectMic(id)
            rememberInputSelection()
            publishUI { $0.followDefaultInput = false }
        }
        refreshDeviceRows()
    }

    func setFollowDefaultInput(_ follow: Bool) {
        perform { self.setFollowDefaultInputOnQueue(follow) }
    }

    private func setFollowDefaultInputOnQueue(_ follow: Bool) {
        guard sessionLive else { return }
        deviceSelection.followDefaultInput = follow
        if follow, let uid = currentDefaultInputUID() {
            selectMic(uid)
        }
        rememberInputSelection()
        publishUI { $0.followDefaultInput = follow }
        refreshDeviceRows()
    }

    func setMonitorUnselectedDevices(_ on: Bool) {
        perform {
            self.deviceSelection.monitorUnselectedDevices = on
            guard self.sessionLive else { return }
            self.syncInputCapturesInBackground()
            self.scheduleSyncPlaybackTaps()
            self.refreshDeviceRows()
        }
    }

    func setFollowDefaultOutput(_ follow: Bool) {
        publishUI {
            $0.followDefaultOutput = follow
            if follow { $0.recordsAllPlayback = false }
        }
        perform { self.setFollowDefaultOutputOnQueue(follow) }
    }

    private func setFollowDefaultOutputOnQueue(_ follow: Bool) {
        guard sessionLive else { return }
        deviceSelection.followDefaultOutput = follow
        if follow {
            deviceSelection.recordsAllPlayback = false
            if !deviceSelection.playbackDeviceUID.isEmpty {
                deviceSelection.selectedOutputUIDs = [deviceSelection.playbackDeviceUID]
            }
        } else {
            // Mix mode kept the default UID selected internally; do not surface it
            // as a hardware output when System mix is turned off.
            deviceSelection.selectedOutputUIDs.removeAll()
        }
        applyOutputSelection()
        rememberOutputSelection()
        refreshDeviceRows()
        publishUI {
            $0.followDefaultOutput = follow
            if follow { $0.recordsAllPlayback = false }
        }
    }

    func setRecordAllPlayback(_ on: Bool) {
        publishUI {
            $0.recordsAllPlayback = on
            if on { $0.followDefaultOutput = false }
        }
        perform { self.setRecordAllPlaybackOnQueue(on) }
    }

    private func setRecordAllPlaybackOnQueue(_ on: Bool) {
        guard sessionLive else { return }
        deviceSelection.recordsAllPlayback = on
        if on {
            deviceSelection.followDefaultOutput = false
            deviceSelection.selectedOutputUIDs = liveOutputUIDs()
        }
        applyOutputSelection()
        rememberOutputSelection()
        refreshDeviceRows()
        publishUI {
            $0.recordsAllPlayback = on
            if on { $0.followDefaultOutput = false }
        }
    }

    private func applyOutputSelection() {
        deviceSelection.refreshOutputScope()
        applyPlaybackMixGate()
        scheduleEnsureSystemMixTap()
        scheduleSyncPlaybackTaps()
        syncInputCapturesInBackground()
    }

    private func scheduleEnsureSystemMixTap() {
        guard sessionLive else { return }
        Task { [weak self] in
            guard let self else { return }
            if #available(macOS 14.2, *) {
                await self.ensureSystemMixTap()
            }
        }
    }

    /// Create or drop the global mix tap when switching Default vs All/Selection.
    @available(macOS 14.2, *)
    private func ensureSystemMixTap() async {
        let want = await mutate { self.sessionLive && self.deviceSelection.usesSystemMix }
        let have = await mutate { self.captureRig.systemPlaybackTap != nil }
        if want, !have {
            do {
                let tap = try await makePlaybackTap(deviceUID: nil)
                let kept = await mutate { () -> Bool in
                    guard self.sessionLive, self.deviceSelection.usesSystemMix,
                          self.captureRig.systemPlaybackTap == nil
                    else { return false }
                    self.attachPlaybackTap(tap)
                    self.captureRig.systemPlaybackTap = tap
                    self.applyPlaybackMixGate()
                    self.publishLevels()
                    self.refreshDeviceRows()
                    sessionRecorderLog.info("Playback mix tap (system)")
                    return true
                }
                if !kept { tap.stop() }
            } catch {
                sessionRecorderLog.error(
                    "System mix tap failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        } else if !want, have {
            let stale = await mutate { () -> PlaybackCapturing? in
                let tap = self.captureRig.systemPlaybackTap
                self.captureRig.systemPlaybackTap = nil
                self.captureRig.liveMixer?.removePlaybackSource(PlaybackMix.systemSourceID)
                self.applyPlaybackMixGate()
                return tap
            }
            stale?.stop()
            await mutate {
                self.publishLevels()
                self.refreshDeviceRows()
            }
        } else {
            await mutate { self.applyPlaybackMixGate() }
        }
    }

    private func applySessionSelection(
        scope: PlaybackRecordScope,
        followInput: Bool,
        followOutput: Bool,
        preferredInputUID: String = "",
        preferredOutputUIDs: [String] = []
    ) {
        deviceSelection.apply(
            scope: scope,
            followInput: followInput,
            followOutput: followOutput,
            preferredInputUID: preferredInputUID,
            preferredOutputUIDs: preferredOutputUIDs,
            audio: audio
        )
        publishUI {
            $0.followDefaultInput = followInput
            $0.followDefaultOutput = followOutput && scope != .all
            $0.recordsAllPlayback = scope == .all
        }
    }

    private func rememberInputSelection() {
        let follow = deviceSelection.followDefaultInput
        let uid = deviceSelection.selectedInputUID
        DispatchQueue.main.async { [weak self] in
            self?.persistInputSelection?(follow, uid)
        }
    }

    private func rememberOutputSelection() {
        let follow = deviceSelection.followDefaultOutput
        let uids = deviceSelection.selectedOutputUIDs
        let recordAll = deviceSelection.recordsAllPlayback
        DispatchQueue.main.async { [weak self] in
            self?.persistOutputSelection?(follow, uids, recordAll)
        }
    }

    private func liveOutputUIDs() -> Set<String> {
        deviceSelection.liveOutputUIDs(audio: audio)
    }

    private func currentDefaultInputUID() -> String? {
        deviceSelection.currentDefaultInputUID(audio: audio)
    }

    private func currentDefaultOutputUID() -> String? {
        deviceSelection.currentDefaultOutputUID(audio: audio)
    }

    private func fallbackOutputDevice() -> AudioOutputDevice? {
        DeviceSelectionState.fallbackOutputDevice(audio: audio)
    }

    private func defaultInputDevice() -> AudioInputDevice? {
        DeviceSelectionState.defaultInputDevice(audio: audio)
    }

    private func fallbackInputDevice() -> AudioInputDevice? {
        DeviceSelectionState.fallbackInputDevice(audio: audio)
    }

    private func inputDevice(uid: String) -> AudioInputDevice? {
        DeviceSelectionState.inputDevice(uid: uid, audio: audio)
    }

    private func selectMic(_ uid: String) {
        guard deviceSelection.selectMic(uid, audio: audio) else { return }
        syncInputCapturesInBackground()
        syncInputMuteToCapture()
    }

    private func rememberDeviceOrder() {
        deviceSelection.rememberDeviceOrder(audio: audio)
    }

    // MARK: - HAL capture lifecycle (delegates to `CaptureRig`)

    @available(macOS 14.2, *)
    private func attachPlaybackTap(_ tap: PlaybackTap) {
        captureRig.attachPlaybackTap(tap) { [weak self] in
            self?.perform { self?.handlePlaybackTapFormatChange() }
        }
    }

    @available(macOS 14.2, *)
    private func handlePlaybackTapFormatChange() {
        guard sessionLive else { return }
        let toStop = captureRig.detachRetargetedNarrowbandTaps(audio: audio)
        for tap in toStop { tap.stop() }
        guard sessionLive else { return }
        applyPlaybackMixGate()
        publishLevels()
        if !toStop.isEmpty {
            scheduleSyncPlaybackTaps()
        } else {
            refreshDeviceRows()
        }
    }

    private func scheduleSyncPlaybackTaps() {
        guard sessionLive else { return }
        captureRig.playbackTapSync += 1
        let token = captureRig.playbackTapSync
        Task { [weak self] in
            guard let self else { return }
            if #available(macOS 14.2, *) {
                await self.syncPlaybackTaps(token: token)
            }
        }
    }

    @available(macOS 14.2, *)
    private func makePlaybackTap(deviceUID: String?) async throws -> PlaybackTap {
        let tap = try await PlaybackTap(audio: audio, deviceUID: deviceUID)
        tap.mixer = captureRig.liveMixer
        return tap
    }

    private func syncInputCapturesInBackground() {
        Task { [weak self] in
            await self?.syncInputCaptures()
        }
    }

    /// Peak-meter selected input, plus others when `monitorUnselectedDevices`.
    /// Headset mics whose output is tapped are not opened unless they are the
    /// selected recording mic — that IO proc forces 16 kHz playback.
    private func syncInputCaptures() async {
        struct Wanted {
            var devices: [AudioInputDevice]
            var uids: Set<String>
            var selected: String
            var mixer: LiveMixer?
            var start: CFTimeInterval
            var rate: Int
            var stale: [InputDeviceCapture]
            var releasedOutputUIDs: Set<String>
        }
        let wanted = await mutate { () -> Wanted in
            let devices = self.audio.listInputDevices().filter { !$0.isVirtual }
            let outputs = self.audio.listOutputDevices().filter { !$0.isVirtual }
            var uids: Set<String>
            if self.deviceSelection.monitorUnselectedDevices {
                uids = Set(devices.map(\.uid))
            } else {
                uids = self.deviceSelection.selectedInputUID.isEmpty ? [] : [self.deviceSelection.selectedInputUID]
            }
            let outputUIDs = (
                self.deviceSelection.monitorUnselectedDevices
                    ? Set(outputs.map(\.uid))
                    : self.deviceSelection.selectedOutputUIDs
            ).union(self.captureRig.playbackTaps.keys)
            let tappedOutputs = outputs.filter { outputUIDs.contains($0.uid) }
            let selected = self.deviceSelection.selectedInputUID
            for device in devices where device.uid != selected {
                let shares = tappedOutputs.contains { AudioDeviceService.sharesHeadset(input: device, output: $0) }
                guard shares else { continue }
                if uids.remove(device.uid) != nil {
                    sessionRecorderLog.info(
                        "Skip input meter on \(device.name, privacy: .public) while tapping its headset output"
                    )
                }
            }
            var stale: [InputDeviceCapture] = []
            var releasedOutputUIDs: Set<String> = []
            for uid in self.captureRig.inputCaptures.keys where !uids.contains(uid) {
                guard let capture = self.captureRig.inputCaptures.removeValue(forKey: uid) else { continue }
                stale.append(capture)
                if let device = devices.first(where: { $0.uid == uid }) {
                    for output in tappedOutputs where AudioDeviceService.sharesHeadset(input: device, output: output) {
                        releasedOutputUIDs.insert(output.uid)
                    }
                }
            }
            return Wanted(
                devices: devices,
                uids: uids,
                selected: selected,
                mixer: self.captureRig.liveMixer,
                start: self.captureRig.sessionStart,
                rate: self.captureRig.sessionBitRate,
                stale: stale,
                releasedOutputUIDs: releasedOutputUIDs
            )
        }

        for capture in wanted.stale { capture.stop() }
        await withTaskGroup(of: Void.self) { group in
            for capture in wanted.stale {
                group.addTask { await capture.waitUntilStopped() }
            }
            await group.waitForAll()
        }

        for device in wanted.devices where wanted.uids.contains(device.uid) {
            let exists = await mutate { self.captureRig.inputCaptures[device.uid] != nil }
            guard !exists else { continue }
            do {
                let capture = try await InputDeviceCapture(
                    deviceID: device.id,
                    fileURL: nil,
                    sessionStart: wanted.start,
                    bitRate: wanted.rate,
                    startIO: true
                )
                capture.mixer = wanted.mixer
                let kept = await mutate { () -> Bool in
                    guard self.sessionLive, self.captureRig.inputCaptures[device.uid] == nil,
                          wanted.uids.contains(device.uid) || device.uid == self.deviceSelection.selectedInputUID
                    else { return false }
                    self.captureRig.inputCaptures[device.uid] = capture
                    capture.mixer = self.captureRig.liveMixer
                    return true
                }
                if !kept { capture.stop() }
            } catch {
                sessionRecorderLog.error("Input meter failed for \(device.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if device.uid == wanted.selected {
                    publishUI { $0.lastError = error.localizedDescription }
                }
            }
        }

        await mutate {
            self.syncInputMuteToCapture()
            self.publishLevels()
        }
        reassertSystemMute()

        if !wanted.releasedOutputUIDs.isEmpty {
            if #available(macOS 14.2, *) {
                await waitForHardwareWideband(uids: wanted.releasedOutputUIDs)
            }
            await rebuildNarrowbandPlaybackTaps()
        }
    }

    /// HFP/USB voice mode drops after mic IO stops; wait so the new tap sees 48 kHz streams.
    @available(macOS 14.2, *)
    private func waitForHardwareWideband(uids: Set<String>) async {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            let outputs = audio.listOutputDevices()
            let wide = uids.allSatisfy { uid in
                guard let device = outputs.first(where: { $0.uid == uid }) else { return true }
                return PlaybackTap.hardwareOutputIsWideband(device.id)
            }
            if wide { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    /// Recreate 16 kHz headset output taps after their mic IO has stopped so
    /// Core Audio can attach to the wideband stream again.
    private func rebuildNarrowbandPlaybackTaps() async {
        let toStop = await mutate { () -> [PlaybackCapturing] in
            guard self.sessionLive else { return [] }
            return self.captureRig.detachNarrowbandTaps()
        }
        guard !toStop.isEmpty else { return }
        for tap in toStop { tap.stop() }
        await withTaskGroup(of: Void.self) { group in
            for tap in toStop {
                group.addTask { await tap.waitUntilStopped() }
            }
            await group.waitForAll()
        }
        let token = await mutate { () -> Int in
            guard self.sessionLive else { return 0 }
            self.captureRig.playbackTapSync += 1
            return self.captureRig.playbackTapSync
        }
        guard token > 0 else { return }
        if #available(macOS 14.2, *) {
            await syncPlaybackTaps(token: token)
        }
    }

    /// Peak-meter selected outputs, plus others when `monitorUnselectedDevices`.
    @available(macOS 14.2, *)
    private func syncPlaybackTaps(token: Int? = nil) async {
        let plan = await mutate { () -> (listed: [String], keep: Set<String>, missing: [String])? in
            if let token, token != self.captureRig.playbackTapSync { return nil }
            guard self.sessionLive else { return nil }
            let listed = self.audio.listOutputDevices().filter { !$0.isVirtual }.map(\.uid)
            let listedSet = Set(listed)
            if self.deviceSelection.recordsAllPlayback {
                self.deviceSelection.selectedOutputUIDs = listedSet
            }
            let selectedLive = self.deviceSelection.selectedOutputUIDs.intersection(listedSet)
            var keep = self.deviceSelection.monitorUnselectedDevices ? listedSet : selectedLive
            // System mix already captures the default output. A device tap on that
            // headset would show a fake 16 kHz meter that is not in the mix.
            if self.deviceSelection.usesSystemMix,
               let defaultUID = self.currentDefaultOutputUID(),
               listedSet.contains(defaultUID)
            {
                keep.remove(defaultUID)
            }
            var staleTaps: [PlaybackCapturing] = []
            for uid in self.captureRig.playbackTaps.keys where !keep.contains(uid) {
                if let tap = self.captureRig.playbackTaps.removeValue(forKey: uid) {
                    staleTaps.append(tap)
                }
                self.captureRig.liveMixer?.removePlaybackSource(uid)
                if !listedSet.contains(uid) {
                    self.deviceSelection.selectedOutputUIDs.remove(uid)
                }
            }
            for tap in staleTaps { tap.stop() }
            let missing = listed.filter { keep.contains($0) && self.captureRig.playbackTaps[$0] == nil }
            return (listed, keep, missing)
        }
        guard let plan else { return }

        for uid in plan.missing {
            let stillNeeded = await mutate {
                guard self.sessionLive, self.captureRig.playbackTaps[uid] == nil else { return false }
                if self.deviceSelection.usesSystemMix, uid == self.currentDefaultOutputUID() {
                    return false
                }
                return self.deviceSelection.monitorUnselectedDevices
                    || self.deviceSelection.selectedOutputUIDs.contains(uid)
            }
            guard stillNeeded else { continue }
            do {
                let tap = try await makePlaybackTap(deviceUID: uid)
                let kept = await mutate { () -> Bool in
                    guard self.sessionLive, self.captureRig.playbackTaps[uid] == nil else { return false }
                    self.attachPlaybackTap(tap)
                    self.captureRig.playbackTaps[uid] = tap
                    return true
                }
                if kept {
                    sessionRecorderLog.info("Playback tap on \(uid, privacy: .public)")
                } else {
                    tap.stop()
                }
            } catch {
                sessionRecorderLog.error("Playback tap failed for \(uid, privacy: .public): \(error.localizedDescription, privacy: .public)")
                await mutate {
                    if self.deviceSelection.selectedOutputUIDs.contains(uid) {
                        self.deviceSelection.selectedOutputUIDs.remove(uid)
                    }
                }
            }
        }

        await mutate {
            self.applyPlaybackMixGate()
            self.refreshDeviceRows()
            self.publishLevels()
        }
    }

    // MARK: - Device rows (delegates to `DeviceRowBuilder`)

    private func refreshDeviceRows() {
        rememberDeviceOrder()
        let rows = DeviceRowBuilder.rows(audio: audio, deviceSelection: deviceSelection, captureRig: captureRig)
        publishUI { $0.devices = rows }
        publishLevels()
    }

    // MARK: - Mute gating (delegates to `MuteGate`)

    private func applyPlaybackMixGate() {
        muteGate.applyPlaybackMixGate(captureRig: captureRig, deviceSelection: deviceSelection)
    }

    private func syncInputMuteToCapture() {
        muteGate.syncInputMuteToCapture(captureRig: captureRig, selectedInputUID: deviceSelection.selectedInputUID)
    }

    /// Apply mix gate without waiting for the recording queue (mute must not stall).
    /// HAL mute plus `captureEnabled` only — do not Start/Stop mic IO (USB output glitches).
    private func gateMixMute(effectiveMuted: Bool, devices: [InputDeviceRow]) {
        let selected = levelMetering.selectedInputUID
        let captures = levelMetering.inputs
        let muted = MuteGate.mixMuted(effectiveMuted: effectiveMuted, selectedUID: selected, devices: devices)
        muteGate.applyCaptureEnabled(selected: selected, mixMuted: muted, captures: captures)
        let already = levelMetering.mixMuted
        levelMetering.setMixMuted(muted)
        guard muted != already else { return }
        perform {
            self.muteGate.mixInputMuted = muted
            self.syncInputMuteToCapture()
            self.publishLevels()
        }
    }

    func refreshCaptureAccess() {
        let micAccess = SessionPermissions.liveMicrophoneAccess()
        let playAccess: CaptureAccess?
        switch SystemAudioAccess.current {
        case .granted: playAccess = .granted
        case .denied: playAccess = .denied
        case .unknown: playAccess = nil
        }
        let apply = {
            self.microphoneAccess = micAccess
            if let playAccess {
                self.playbackAccess = playAccess
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

}
