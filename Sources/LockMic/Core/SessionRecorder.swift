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
///
/// All session mutation and HAL run on `queue` so mute on the main thread
/// never waits for recording.
final class SessionRecorder: ObservableObject, @unchecked Sendable {
    @Published private(set) var isRecording = false
    /// Starting, recording, or tearing down HAL / wrapping the mix. Any-thread.
    var isBusy: Bool {
        flagLock.lock()
        defer { flagLock.unlock() }
        return flagPhase != .idle
    }
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
    /// Follow-default, current output UIDs, and whether every live output is selected.
    var persistOutputSelection: ((Bool, Set<String>, Bool) -> Void)?

    private let audio: AudioDeviceService
    private let mic: MicController
    private var inputCaptures: [String: InputDeviceCapture] = [:]
    private var playbackTaps: [String: PlaybackCapturing] = [:]
    /// System process mix — not bound to a hardware output, so device switches stay continuous.
    private var systemPlaybackTap: PlaybackCapturing?
    private var playbackTapSync = 0
    private var sessionStart: CFTimeInterval = 0
    private var playbackScope: PlaybackRecordScope = .default
    private var selectedInputUID = ""
    private var selectedOutputUIDs: Set<String> = []
    private var recordsAllPlayback = false
    private var inputOrder: [String] = []
    private var outputOrder: [String] = []
    private var playbackDeviceUID = ""
    private var devicesToken: UUID?
    private var outputChangeWork: DispatchWorkItem?
    /// HAL fires many device-list notices while an output switches; coalesce before recreating meter taps.
    private static let deviceListCoalesce: TimeInterval = 0.3
    private var sessionBitRate: Int = RecordingBitRate.default.bitsPerSecond
    private var monitorUnselectedDevices = true
    private var micCancellables = Set<AnyCancellable>()
    private var liveMixer: LiveMixer?
    private var sessionFile: URL?
    private var stopWaiters: [CheckedContinuation<URL, Error>] = []
    private let queue: DispatchQueue
    private static let queueKey = DispatchSpecificKey<UInt8>()
    private let flagLock = NSLock()
    private enum Phase { case idle, starting, recording, stopping }
    private var phase: Phase = .idle
    private var flagPhase: Phase = .idle
    /// Bumped to cancel an in-flight start when the user hits stop.
    private var startGeneration = 0
    private let levelLock = NSLock()
    private var levelSnapshot = LevelSnapshot()
    private var mixInputMuted = false
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
        for capture in inputCaptures.values { capture.stop() }
        for tap in playbackTaps.values { tap.stop() }
        systemPlaybackTap?.stop()
        let mixer = liveMixer
        DispatchQueue.global(qos: .utility).async {
            mixer?.stop()
        }
    }

    private var onRecordingQueue: Bool {
        DispatchQueue.getSpecific(key: Self.queueKey) != nil
    }

    private func perform(_ work: @escaping () -> Void) {
        if onRecordingQueue {
            work()
        } else {
            queue.async(execute: work)
        }
    }

    private func publishUI(_ update: @escaping (SessionRecorder) -> Void) {
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

    private func mutate<T>(_ work: @escaping () -> T) async -> T {
        if onRecordingQueue { return work() }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    private func publishLevels() {
        levelLock.lock()
        levelSnapshot = LevelSnapshot(
            inputs: inputCaptures,
            taps: playbackTaps,
            system: systemPlaybackTap,
            playbackDeviceUID: playbackDeviceUID,
            defaultOutputUID: currentDefaultOutputUID() ?? playbackDeviceUID,
            selectedInputUID: selectedInputUID,
            selectedOutputUIDs: selectedOutputUIDs,
            mixMuted: mixInputMuted,
            mixer: liveMixer,
            sessionFile: sessionFile,
            sessionBitRate: sessionBitRate,
            startedAt: recordingStartedAt
        )
        levelLock.unlock()
    }

    private struct LevelSnapshot {
        var inputs: [String: InputDeviceCapture] = [:]
        var taps: [String: PlaybackCapturing] = [:]
        var system: PlaybackCapturing?
        var playbackDeviceUID = ""
        var defaultOutputUID = ""
        var selectedInputUID = ""
        var selectedOutputUIDs: Set<String> = []
        var mixMuted = false
        var mixer: LiveMixer?
        var sessionFile: URL?
        var sessionBitRate = 0
        var startedAt: Date?
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
            refreshCaptureAccess()
            let defaultOut = currentDefaultOutputUID() ?? ""
            devices = Self.previewDeviceRows(
                audio: audio,
                selectedInputUID: resolvedInputUID(followInput: followInput, preferred: preferredInputUID),
                selectedOutputUIDs: resolvedOutputUIDs(
                    followOutput: followOutput && scope != .all,
                    preferred: preferredOutputUIDs,
                    scope: scope,
                    fallbackUID: defaultOut
                ),
                playbackDeviceUID: defaultOut
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
            try await Self.ensureMicrophonePermission()
            publishUI { $0.microphoneAccess = .granted }
        } catch {
            publishUI {
                $0.microphoneAccess = .denied
                $0.lastError = error.localizedDescription
            }
            throw error
        }
        do {
            try await Self.ensureSystemAudioPermission()
            publishUI { $0.playbackAccess = .granted }
        } catch {
            publishUI {
                $0.playbackAccess = .denied
                $0.lastError = error.localizedDescription
            }
            throw error
        }
        SessionMix.prepareArtwork()

        let mixURL = try Self.makeSessionFile(in: baseDirectory)
        let generation = await mutate { () -> Int in
            guard self.phase == .idle else { return 0 }
            self.startGeneration += 1
            self.monitorUnselectedDevices = monitorUnselected
            self.applySessionSelection(
                scope: scope,
                followInput: followInput,
                followOutput: followOutput,
                preferredInputUID: preferredInputUID,
                preferredOutputUIDs: preferredOutputUIDs
            )
            self.refreshCaptureAccess()
            self.refreshDeviceRows()
            self.sessionBitRate = bitRate.bitsPerSecond
            self.sessionStart = CACurrentMediaTime()
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
            throw Self.wrapStartError(error)
        }
    }

    @available(macOS 14.2, *)
    private func startHardware(
        generation: Int,
        bitRate: RecordingBitRate,
        mixURL: URL
    ) async throws {
        publishUI { $0.lastError = nil }
        let mixer = LiveMixer(url: mixURL, bitRate: bitRate.bitsPerSecond, sessionStart: sessionStart)
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
            self.inputDevice(uid: self.selectedInputUID) ?? self.defaultInputDevice()
        }
        guard let micDevice else {
            mixer.stop()
            throw SessionRecorderError.micStartFailed
        }

        let capture = try await InputDeviceCapture(
            deviceID: micDevice.id,
            fileURL: nil,
            sessionStart: sessionStart,
            bitRate: bitRate.bitsPerSecond,
            startIO: true
        )
        capture.mixer = mixer
        guard await stillStarting(generation) else {
            capture.stop()
            mixer.stop()
            throw SessionRecorderError.notRecording
        }

        let systemTap = try await PlaybackTap(audio: audio, deviceUID: nil)
        systemTap.mixer = mixer
        guard await stillStarting(generation) else {
            systemTap.stop()
            capture.stop()
            mixer.stop()
            throw SessionRecorderError.notRecording
        }

        let wentLive = await mutate { () -> Bool in
            guard self.stillStartingLocked(generation) else { return false }
            self.selectedInputUID = micDevice.uid
            if let outID = try? self.audio.defaultOutputDeviceID(), !self.audio.isLockMicRecorder(outID) {
                self.playbackDeviceUID = self.audio.deviceUID(outID) ?? ""
            }
            self.liveMixer = mixer
            self.inputCaptures[micDevice.uid] = capture
            self.attachPlaybackTap(systemTap)
            self.systemPlaybackTap = systemTap
            log.info("Playback mix tap (system)")
            self.sessionFile = mixURL
            self.recordingStartedAt = Date()
            self.setPhase(.recording)
            self.applyPlaybackMixGate()
            self.syncInputMuteToCapture()
            self.refreshDeviceRows()
            self.publishLevels()
            return true
        }
        guard wentLive else {
            systemTap.stop()
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
        log.info("Recording started \(mixURL.lastPathComponent, privacy: .public)")
        Task { await self.attachBackgroundTaps(generation: generation) }
    }

    private func stillStarting(_ generation: Int) async -> Bool {
        await mutate { self.stillStartingLocked(generation) }
    }

    private func stillStartingLocked(_ generation: Int) -> Bool {
        phase == .starting && startGeneration == generation
    }

    private func abortStart(generation: Int, mixURL: URL, error: Error) async {
        let wrapped = Self.wrapStartError(error)
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
        let snapshot = await mutate { () -> HardwareSnapshot? in
            guard self.phase == .starting, self.startGeneration == generation else { return nil }
            return self.takeHardwareSnapshot(clearDevices: false)
        }
        if let snapshot {
            _ = await Self.stopHardware(snapshot)
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

    private func reassertSystemMute() {
        Task { @MainActor [weak mic] in
            mic?.reassertMuteIfNeeded()
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
            }
            self.refreshCaptureAccess()
            self.selectedInputUID = ""
            self.selectedOutputUIDs = []
            self.followDefaultInput = true
            self.followDefaultOutput = true
            self.recordsAllPlayback = false
            self.inputOrder = []
            self.outputOrder = []
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
            log.error("Stop for quit failed: \(error.localizedDescription, privacy: .public)")
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
        if sessionFile == nil {
            setPhase(.idle)
            continuation.resume(throwing: SessionRecorderError.notRecording)
            return
        }
        guard let file = sessionFile else {
            continuation.resume(throwing: SessionRecorderError.notRecording)
            return
        }
        outputChangeWork?.cancel()
        playbackTapSync += 1
        let snapshot = takeHardwareSnapshot(clearDevices: false)
        setPhase(.stopping)
        recordingStartedAt = nil
        publishUI { $0.recordingStartedAt = nil }
        publishLevels()
        if let onIdle {
            DispatchQueue.main.async { onIdle() }
        }

        Task { [weak self] in
            let finalFile = await Self.stopHardware(snapshot) ?? file
            guard let self else {
                continuation.resume(returning: finalFile)
                return
            }
            self.perform {
                self.sessionFile = finalFile
                self.clearSessionSelection()
                self.setPhase(.idle)
                self.publishUI {
                    $0.devices = []
                    $0.followDefaultInput = true
                    $0.followDefaultOutput = true
                }
                self.publishLevels()
                log.info("Recording stopped: \(finalFile.lastPathComponent, privacy: .public)")
                RecordingSessionLock.release()
                let waiters = self.stopWaiters
                self.stopWaiters.removeAll()
                continuation.resume(returning: finalFile)
                for waiter in waiters { waiter.resume(returning: finalFile) }
            }
        }
    }

    private struct HardwareSnapshot {
        var inputs: [InputDeviceCapture]
        var taps: [PlaybackCapturing]
        var mixer: LiveMixer?
    }

    private func takeHardwareSnapshot(clearDevices: Bool) -> HardwareSnapshot {
        let inputs = Array(inputCaptures.values)
        inputCaptures.removeAll()
        let taps: [PlaybackCapturing] = Array(playbackTaps.values) + [systemPlaybackTap].compactMap { $0 }
        playbackTaps.removeAll()
        systemPlaybackTap = nil
        let mixer = liveMixer
        liveMixer = nil
        mixer?.removeAllPlaybackSources()
        playbackDeviceUID = ""
        if clearDevices {
            clearSessionSelection()
        }
        return HardwareSnapshot(inputs: inputs, taps: taps, mixer: mixer)
    }

    private func clearSessionSelection() {
        selectedInputUID = ""
        followDefaultInput = true
        followDefaultOutput = true
        recordsAllPlayback = false
        selectedOutputUIDs = []
        inputOrder = []
        outputOrder = []
    }

    nonisolated private static func stopHardware(_ snapshot: HardwareSnapshot) async -> URL? {
        for capture in snapshot.inputs { capture.stop() }
        for tap in snapshot.taps { tap.stop() }
        await withTaskGroup(of: Void.self) { group in
            for capture in snapshot.inputs {
                group.addTask { await capture.waitUntilStopped() }
            }
            for tap in snapshot.taps {
                group.addTask { await tap.waitUntilStopped() }
            }
            await group.waitForAll()
        }
        guard let mixer = snapshot.mixer else { return nil }
        let mixQueue = DispatchQueue(label: "com.lockmic.mix-halt")
        return await AudioHAL.run(on: mixQueue, timeout: 20) {
            mixer.stop()
            return mixer.url
        } ?? mixer.url
    }

    private func restartPlaybackIO() {
        guard sessionLive else { return }
        applyPlaybackMixGate()
        systemPlaybackTap?.ensureRunning()
        for tap in playbackTaps.values {
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
        if followDefaultInput, let uid = currentDefaultInputUID() {
            selectMic(uid)
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
        let previousOutputUID = playbackDeviceUID
        let defaultMoved = uid != previousOutputUID
        if defaultMoved {
            playbackDeviceUID = uid
            if followDefaultOutput {
                selectedOutputUIDs = [uid]
            }
        }
        applyPlaybackMixGate()
        if followDefaultOutput {
            if defaultMoved {
                applyOutputSelection()
            } else {
                scheduleSyncPlaybackTaps()
            }
        } else if recordsAllPlayback {
            let live = liveOutputUIDs()
            if !live.isSubset(of: selectedOutputUIDs) {
                selectedOutputUIDs.formUnion(live)
                applyOutputSelection()
            } else {
                scheduleSyncPlaybackTaps()
            }
        } else {
            scheduleSyncPlaybackTaps()
        }
        refreshDeviceRows()
    }

    func setDeviceEnabled(_ id: String, enabled: Bool) {
        perform { self.setDeviceEnabledOnQueue(id, enabled: enabled) }
    }

    private func setDeviceEnabledOnQueue(_ id: String, enabled: Bool) {
        guard sessionLive else { return }
        if id.hasPrefix("out.") {
            followDefaultOutput = false
            recordsAllPlayback = false
            let uid = String(id.dropFirst(4))
            if enabled {
                selectedOutputUIDs.insert(uid)
            } else {
                selectedOutputUIDs.remove(uid)
            }
            applyOutputSelection()
            rememberOutputSelection()
            refreshDeviceRows()
            publishUI { $0.followDefaultOutput = false }
            return
        }
        if enabled {
            followDefaultInput = false
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
        followDefaultInput = follow
        if follow, let uid = currentDefaultInputUID() {
            selectMic(uid)
        }
        rememberInputSelection()
        refreshDeviceRows()
        publishUI { $0.followDefaultInput = follow }
    }

    func setMonitorUnselectedDevices(_ on: Bool) {
        perform {
            self.monitorUnselectedDevices = on
            guard self.sessionLive else { return }
            self.syncInputCapturesInBackground()
            self.scheduleSyncPlaybackTaps()
            self.refreshDeviceRows()
        }
    }

    func setFollowDefaultOutput(_ follow: Bool) {
        perform { self.setFollowDefaultOutputOnQueue(follow) }
    }

    private func setFollowDefaultOutputOnQueue(_ follow: Bool) {
        guard sessionLive else { return }
        followDefaultOutput = follow
        if follow {
            recordsAllPlayback = false
            if !playbackDeviceUID.isEmpty {
                selectedOutputUIDs = [playbackDeviceUID]
            }
        }
        applyOutputSelection()
        rememberOutputSelection()
        refreshDeviceRows()
        publishUI { $0.followDefaultOutput = follow }
    }

    func setRecordAllPlayback(_ on: Bool) {
        perform { self.setRecordAllPlaybackOnQueue(on) }
    }

    private func setRecordAllPlaybackOnQueue(_ on: Bool) {
        guard sessionLive else { return }
        recordsAllPlayback = on
        if on {
            followDefaultOutput = false
            selectedOutputUIDs = liveOutputUIDs()
        }
        applyOutputSelection()
        rememberOutputSelection()
        refreshDeviceRows()
        if on {
            publishUI { $0.followDefaultOutput = false }
        }
    }

    private func applyOutputSelection() {
        playbackScope = selectedOutputUIDs.contains(where: { $0 != playbackDeviceUID }) ? .all : .default
        applyPlaybackMixGate()
        scheduleSyncPlaybackTaps()
    }

    /// Mix every selected output. The current default uses the system tap (stable
    /// across device switches). If that tap is pulled to 16 kHz (voice-processing)
    /// while the hardware output is still wideband, mix the device tap instead.
    private func applyPlaybackMixGate() {
        let defaultUID = currentDefaultOutputUID() ?? playbackDeviceUID
        let recordDefault = !defaultUID.isEmpty && selectedOutputUIDs.contains(defaultUID)
        let systemNarrow = systemPlaybackTap?.isNarrowband == true
        let defaultDeviceTap = defaultUID.isEmpty ? nil : playbackTaps[defaultUID]
        let deviceWide = defaultDeviceTap.map { !$0.isNarrowband } ?? false
        let useDeviceForDefault = recordDefault && systemNarrow && deviceWide
        if useDeviceForDefault {
            let deviceRate = Int(defaultDeviceTap?.sourceSampleRate ?? 0)
            let systemRate = Int(systemPlaybackTap?.sourceSampleRate ?? 0)
            log.info(
                "Mix default output from device tap \(deviceRate, privacy: .public) Hz; system tap \(systemRate, privacy: .public) Hz"
            )
        }
        systemPlaybackTap?.setMixEnabled(recordDefault && !useDeviceForDefault)
        if !recordDefault || useDeviceForDefault {
            liveMixer?.removePlaybackSource(PlaybackMix.systemSourceID)
        }
        for (uid, tap) in playbackTaps {
            let on: Bool
            if uid == defaultUID {
                on = useDeviceForDefault
            } else {
                on = selectedOutputUIDs.contains(uid)
            }
            tap.setMixEnabled(on)
            if !on {
                liveMixer?.removePlaybackSource(uid)
            }
        }
    }

    @available(macOS 14.2, *)
    private func attachPlaybackTap(_ tap: PlaybackTap) {
        tap.mixer = liveMixer
        tap.onFormatChange = { [weak self] in
            self?.perform { self?.handlePlaybackTapFormatChange() }
        }
    }

    @available(macOS 14.2, *)
    private func handlePlaybackTapFormatChange() {
        guard sessionLive else { return }
        var toStop: [PlaybackCapturing] = []
        for uid in Array(playbackTaps.keys) {
            guard let tap = playbackTaps[uid], tap.isNarrowband else { continue }
            guard let device = audio.listOutputDevices().first(where: { $0.uid == uid }) else { continue }
            let preferred = PlaybackTap.preferredOutputStreamIndex(device.id)
            guard preferred != tap.streamIndex else { continue }
            log.info(
                "Retarget playback tap \(uid, privacy: .public) stream \(tap.streamIndex, privacy: .public) → \(preferred, privacy: .public)"
            )
            playbackTaps.removeValue(forKey: uid)
            liveMixer?.removePlaybackSource(uid)
            toStop.append(tap)
        }
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
        playbackTapSync += 1
        let token = playbackTapSync
        Task { [weak self] in
            guard let self else { return }
            if #available(macOS 14.2, *) {
                await self.syncPlaybackTaps(token: token)
            }
        }
    }

    /// System mix of the current default output. Other selected outputs use
    /// device taps so they can be summed without doubling the default.
    @available(macOS 14.2, *)
    private func makePlaybackTap(deviceUID: String?) async throws -> PlaybackTap {
        let tap = try await PlaybackTap(audio: audio, deviceUID: deviceUID)
        tap.mixer = liveMixer
        return tap
    }

    private func syncInputCapturesInBackground() {
        Task { [weak self] in
            await self?.syncInputCaptures()
        }
    }

    /// Peak-meter selected input, plus others when `monitorUnselectedDevices`.
    private func syncInputCaptures() async {
        struct Wanted {
            var devices: [AudioInputDevice]
            var uids: Set<String>
            var selected: String
            var mixer: LiveMixer?
            var start: CFTimeInterval
            var rate: Int
            var muted: Bool
        }
        let wanted = await mutate { () -> Wanted in
            let devices = self.audio.listInputDevices().filter { !$0.isVirtual }
            var uids: Set<String>
            if self.monitorUnselectedDevices {
                uids = Set(devices.map(\.uid))
            } else {
                uids = self.selectedInputUID.isEmpty ? [] : [self.selectedInputUID]
            }
            let outputUIDs = (self.monitorUnselectedDevices ? self.liveOutputUIDs() : self.selectedOutputUIDs)
                .union(self.playbackTaps.keys)
            let blockedFamilies = Set(outputUIDs.compactMap { AudioDeviceService.usbAudioFamily(uid: $0) })
            if !blockedFamilies.isEmpty {
                for device in devices where device.uid != self.selectedInputUID {
                    guard let family = AudioDeviceService.usbAudioFamily(uid: device.uid),
                          blockedFamilies.contains(family)
                    else { continue }
                    if uids.remove(device.uid) != nil {
                        log.info(
                            "Skip input meter on \(device.name, privacy: .public) while tapping its USB output"
                        )
                    }
                }
            }
            var stale: [InputDeviceCapture] = []
            for uid in self.inputCaptures.keys where !uids.contains(uid) {
                if let capture = self.inputCaptures.removeValue(forKey: uid) {
                    stale.append(capture)
                }
            }
            for capture in stale { capture.stop() }
            return Wanted(
                devices: devices,
                uids: uids,
                selected: self.selectedInputUID,
                mixer: self.liveMixer,
                start: self.sessionStart,
                rate: self.sessionBitRate,
                muted: self.mixInputMuted
            )
        }

        for device in wanted.devices where wanted.uids.contains(device.uid) {
            let exists = await mutate { self.inputCaptures[device.uid] != nil }
            guard !exists else { continue }
            do {
                let capture = try await InputDeviceCapture(
                    deviceID: device.id,
                    fileURL: nil,
                    sessionStart: wanted.start,
                    bitRate: wanted.rate,
                    startIO: !wanted.muted
                )
                capture.mixer = wanted.mixer
                let kept = await mutate { () -> Bool in
                    guard self.sessionLive, self.inputCaptures[device.uid] == nil,
                          wanted.uids.contains(device.uid) || device.uid == self.selectedInputUID
                    else { return false }
                    self.inputCaptures[device.uid] = capture
                    capture.mixer = self.liveMixer
                    return true
                }
                if !kept { capture.stop() }
            } catch {
                log.error("Input meter failed for \(device.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if device.uid == wanted.selected {
                    publishUI { $0.lastError = error.localizedDescription }
                }
            }
        }

        await mutate {
            self.syncInputMuteToCapture()
            for capture in self.inputCaptures.values {
                capture.setIORunning(!self.mixInputMuted)
            }
            self.publishLevels()
        }
        reassertSystemMute()
    }

    /// Peak-meter selected outputs, plus others when `monitorUnselectedDevices`.
    @available(macOS 14.2, *)
    private func syncPlaybackTaps(token: Int? = nil) async {
        let plan = await mutate { () -> (listed: [String], keep: Set<String>, missing: [String])? in
            if let token, token != self.playbackTapSync { return nil }
            guard self.sessionLive else { return nil }
            let listed = self.audio.listOutputDevices().filter { !$0.isVirtual }.map(\.uid)
            let listedSet = Set(listed)
            let keep = self.monitorUnselectedDevices ? listedSet : self.selectedOutputUIDs
            var staleTaps: [PlaybackCapturing] = []
            for uid in self.playbackTaps.keys where !keep.contains(uid) {
                if let tap = self.playbackTaps.removeValue(forKey: uid) {
                    staleTaps.append(tap)
                }
                self.liveMixer?.removePlaybackSource(uid)
                if !listedSet.contains(uid) {
                    self.selectedOutputUIDs.remove(uid)
                }
            }
            for tap in staleTaps { tap.stop() }
            let missing = listed.filter { keep.contains($0) && self.playbackTaps[$0] == nil }
            return (listed, keep, missing)
        }
        guard let plan else { return }

        for uid in plan.missing {
            let stillNeeded = await mutate {
                self.sessionLive && (self.monitorUnselectedDevices || self.selectedOutputUIDs.contains(uid))
                    && self.playbackTaps[uid] == nil
            }
            guard stillNeeded else { continue }
            do {
                let tap = try await makePlaybackTap(deviceUID: uid)
                let kept = await mutate { () -> Bool in
                    guard self.sessionLive, self.playbackTaps[uid] == nil else { return false }
                    self.attachPlaybackTap(tap)
                    self.playbackTaps[uid] = tap
                    return true
                }
                if kept {
                    log.info("Playback tap on \(uid, privacy: .public)")
                } else {
                    tap.stop()
                }
            } catch {
                log.error("Playback tap failed for \(uid, privacy: .public): \(error.localizedDescription, privacy: .public)")
                await mutate {
                    if self.selectedOutputUIDs.contains(uid) {
                        self.selectedOutputUIDs.remove(uid)
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

    private func applySessionSelection(
        scope: PlaybackRecordScope,
        followInput: Bool,
        followOutput: Bool,
        preferredInputUID: String = "",
        preferredOutputUIDs: [String] = []
    ) {
        playbackScope = scope
        if let outID = try? audio.defaultOutputDeviceID(), !audio.isLockMicRecorder(outID) {
            playbackDeviceUID = audio.deviceUID(outID) ?? ""
        }
        followDefaultInput = followInput
        selectedInputUID = resolvedInputUID(followInput: followInput, preferred: preferredInputUID)
        followDefaultOutput = followOutput && scope != .all
        recordsAllPlayback = scope == .all
        selectedOutputUIDs = resolvedOutputUIDs(
            followOutput: followDefaultOutput,
            preferred: preferredOutputUIDs,
            scope: scope,
            fallbackUID: playbackDeviceUID
        )
        rememberDeviceOrder()
        publishUI {
            $0.followDefaultInput = followInput
            $0.followDefaultOutput = followOutput && scope != .all
        }
    }

    private func rememberInputSelection() {
        let follow = followDefaultInput
        let uid = selectedInputUID
        DispatchQueue.main.async { [weak self] in
            self?.persistInputSelection?(follow, uid)
        }
    }

    private func rememberOutputSelection() {
        let follow = followDefaultOutput
        let uids = selectedOutputUIDs
        let recordAll = recordsAllPlayback
        DispatchQueue.main.async { [weak self] in
            self?.persistOutputSelection?(follow, uids, recordAll)
        }
    }

    private func liveOutputUIDs() -> Set<String> {
        Set(audio.listOutputDevices().filter { !$0.isVirtual }.map(\.uid))
    }

    private func resolvedOutputUIDs(
        followOutput: Bool,
        preferred: [String],
        scope: PlaybackRecordScope,
        fallbackUID: String
    ) -> Set<String> {
        let fallback: Set<String> = fallbackUID.isEmpty ? [] : [fallbackUID]
        if followOutput { return fallback }
        let live = liveOutputUIDs()
        if scope == .all { return live }
        let kept = Set(preferred.filter { live.contains($0) })
        if !kept.isEmpty { return kept }
        return fallback
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
        guard inputDevice(uid: uid) != nil else { return }
        selectedInputUID = uid
        if inputCaptures[uid] == nil {
            syncInputCapturesInBackground()
        }
        syncInputMuteToCapture()
    }

    /// HAL mute does not always zero this process's IO proc. Gate the mix explicitly.
    private func syncInputMuteToCapture() {
        applyCaptureEnabled(selected: selectedInputUID, mixMuted: mixInputMuted, captures: inputCaptures)
    }

    /// Apply mix gate without waiting for the recording queue (mute must not stall).
    private func gateMixMute(effectiveMuted: Bool, devices: [InputDeviceRow]) {
        levelLock.lock()
        let selected = levelSnapshot.selectedInputUID
        let captures = levelSnapshot.inputs
        levelLock.unlock()
        let muted = Self.mixMuted(effectiveMuted: effectiveMuted, selectedUID: selected, devices: devices)
        applyCaptureEnabled(selected: selected, mixMuted: muted, captures: captures)
        levelLock.lock()
        let already = levelSnapshot.mixMuted
        levelSnapshot.mixMuted = muted
        levelLock.unlock()
        guard muted != already else { return }
        for capture in captures.values {
            capture.setIORunning(!muted)
        }
        perform {
            self.mixInputMuted = muted
            self.syncInputMuteToCapture()
            for capture in self.inputCaptures.values {
                capture.setIORunning(!self.mixInputMuted)
            }
            self.publishLevels()
        }
    }

    private static func mixMuted(
        effectiveMuted: Bool,
        selectedUID: String,
        devices: [InputDeviceRow]
    ) -> Bool {
        guard effectiveMuted else { return false }
        if selectedUID.isEmpty { return true }
        guard let row = devices.first(where: { $0.uid == selectedUID }) else { return true }
        return row.isInScope && !row.isVirtual
    }

    private func applyCaptureEnabled(
        selected: String,
        mixMuted: Bool,
        captures: [String: InputDeviceCapture]
    ) {
        for (uid, capture) in captures {
            capture.captureEnabled = uid == selected && !mixMuted
        }
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

    private static func previewDeviceRows(
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

    private func refreshDeviceRows() {
        rememberDeviceOrder()
        let defaultInUID = currentDefaultInputUID()
        let defaultOutUID = currentDefaultOutputUID()
        let inputsByUID = Dictionary(uniqueKeysWithValues: audio.listInputDevices().map { ($0.uid, $0) })
        let outputsByUID = Dictionary(uniqueKeysWithValues: audio.listOutputDevices().map { ($0.uid, $0) })
        let callQuality = callQualityHeadsetUIDs(inputs: inputsByUID, outputs: outputsByUID)
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
                    detail: nil,
                    isCallQuality: callQuality.inputs.contains(uid)
                )
            )
        }

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
                    ),
                    isCallQuality: callQuality.outputs.contains(uid)
                )
            )
        }
        publishUI { $0.devices = rows }
        publishLevels()
    }

    /// Bluetooth headset whose mic HAL is running — that forces HFP on the matching output.
    private func callQualityHeadsetUIDs(
        inputs: [String: AudioInputDevice],
        outputs: [String: AudioOutputDevice]
    ) -> (inputs: Set<String>, outputs: Set<String>) {
        let openMics = Set(inputCaptures.keys.filter { inputs[$0]?.isBluetooth == true })
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
        let defaultUID = currentDefaultOutputUID() ?? playbackDeviceUID
        if !defaultUID.isEmpty, selectedOutputUIDs.contains(defaultUID) {
            let deviceTap = playbackTaps[defaultUID]
            let mixingDevice = systemPlaybackTap?.isNarrowband == true
                && (deviceTap.map { !$0.isNarrowband } ?? false)
            let mixTap: PlaybackCapturing? = mixingDevice ? deviceTap : systemPlaybackTap
            if mixTap?.isMixNarrowband == true {
                flaggedOut.insert(defaultUID)
            }
        }
        return (flaggedIn, flaggedOut)
    }

    /// Live meter for the monitor. Does not publish `devices` (that rebuilt SwiftUI).
    func meterLevel(for row: RecordingDeviceRow) -> Float {
        levelLock.lock()
        let snap = levelSnapshot
        levelLock.unlock()
        switch row.kind {
        case .input:
            return snap.inputs[row.id]?.level ?? 0
        case .output:
            let uid = String(row.id.dropFirst(4))
            let device = snap.taps[uid]?.level ?? 0
            if uid == snap.playbackDeviceUID || uid == snap.defaultOutputUID {
                return max(device, snap.system?.level ?? 0)
            }
            return device
        }
    }

    func meterLinearPeak(for row: RecordingDeviceRow) -> Float {
        guard row.kind == .input else { return 0 }
        levelLock.lock()
        let capture = levelSnapshot.inputs[row.id]
        levelLock.unlock()
        return capture?.linearPeak ?? 0
    }

    /// Real file size plus a bitrate guess for PCM not yet on disk (current RAM chunk).
    /// Elapsed audio in the current mix file (resets if the file is recreated).
    func recordedElapsedSeconds() -> Int {
        levelLock.lock()
        let mixer = levelSnapshot.mixer
        let started = levelSnapshot.startedAt
        levelLock.unlock()
        if let mixer {
            return max(0, Int(mixer.recordedDuration()))
        }
        guard let start = started else { return 0 }
        return max(0, Int(Date().timeIntervalSince(start)))
    }

    func mixSizeChipText() -> String {
        levelLock.lock()
        let url = levelSnapshot.sessionFile
        let extra = levelSnapshot.mixer?.unflushedDuration() ?? 0
        let rate = levelSnapshot.sessionBitRate
        levelLock.unlock()
        let bytes: Int64
        if let url,
           FileManager.default.fileExists(atPath: url.path),
           let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        {
            bytes = size.int64Value
        } else {
            bytes = 0
        }
        return RecordingBitRate.resolved(rate / 1_000).sizeChipText(onDisk: bytes, extra: extra)
    }

    /// Peak of mic + playback — for the monitor waveform.
    func liveWaveformLevel() -> Float {
        levelLock.lock()
        let snap = levelSnapshot
        levelLock.unlock()
        let mic = snap.mixMuted ? 0 : (snap.inputs[snap.selectedInputUID]?.level ?? 0)
        let defaultUID = snap.defaultOutputUID
        var play: Float = 0
        if !defaultUID.isEmpty, snap.selectedOutputUIDs.contains(defaultUID) {
            play = max(play, snap.system?.level ?? 0)
        }
        for uid in snap.selectedOutputUIDs where uid != defaultUID {
            play = max(play, snap.taps[uid]?.level ?? 0)
        }
        return min(1, max(mic, play))
    }

    func refreshCaptureAccess() {
        let micAccess = Self.liveMicrophoneAccess()
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
