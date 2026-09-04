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
    /// Recording or still tearing down HAL / wrapping the mix file. Any-thread.
    var isBusy: Bool {
        flagLock.lock()
        defer { flagLock.unlock() }
        return flagRecording || flagStopping
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
    /// True between flipping `isRecording` off and finishing HAL/mix teardown.
    private var isStopping = false
    private var stopWaiters: [CheckedContinuation<URL, Error>] = []
    private let queue: DispatchQueue
    private static let queueKey = DispatchSpecificKey<UInt8>()
    private let flagLock = NSLock()
    private var flagRecording = false
    private var flagStopping = false
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
        let inputs = Array(inputCaptures.values)
        let taps = Array(playbackTaps.values) + [systemPlaybackTap].compactMap { $0 }
        let mixer = liveMixer
        queue.async {
            _ = Self.stopHardware(inputs: inputs, taps: taps, mixer: mixer)
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

    private func setSessionLive(_ on: Bool) {
        sessionLive = on
        flagLock.lock()
        flagRecording = on
        flagLock.unlock()
        publishUI { $0.isRecording = on }
    }

    private func setStopping(_ on: Bool) {
        isStopping = on
        flagLock.lock()
        flagStopping = on
        flagLock.unlock()
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
    func previewSession(
        playback scope: PlaybackRecordScope = .default,
        followInput: Bool = true,
        followOutput: Bool = true,
        preferredInputUID: String = "",
        preferredOutputUIDs: [String] = []
    ) {
        perform {
            self.publishUI { $0.lastError = nil }
            self.applySessionSelection(
                scope: scope,
                followInput: followInput,
                followOutput: followOutput,
                preferredInputUID: preferredInputUID,
                preferredOutputUIDs: preferredOutputUIDs
            )
            self.refreshCaptureAccess()
            self.refreshDeviceRows()
        }
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.queue.async {
                do {
                    try self.startHardwareOnQueue(
                        scope: scope,
                        bitRate: bitRate,
                        mixURL: mixURL,
                        followInput: followInput,
                        followOutput: followOutput,
                        preferredInputUID: preferredInputUID,
                        preferredOutputUIDs: preferredOutputUIDs,
                        monitorUnselected: monitorUnselected
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @available(macOS 14.2, *)
    private func startHardwareOnQueue(
        scope: PlaybackRecordScope,
        bitRate: RecordingBitRate,
        mixURL: URL,
        followInput: Bool,
        followOutput: Bool,
        preferredInputUID: String,
        preferredOutputUIDs: [String],
        monitorUnselected: Bool
    ) throws {
        publishUI { $0.lastError = nil }
        monitorUnselectedDevices = monitorUnselected
        applySessionSelection(
            scope: scope,
            followInput: followInput,
            followOutput: followOutput,
            preferredInputUID: preferredInputUID,
            preferredOutputUIDs: preferredOutputUIDs
        )
        refreshCaptureAccess()
        refreshDeviceRows()
        sessionBitRate = bitRate.bitsPerSecond
        sessionStart = CACurrentMediaTime()
        let mixer = LiveMixer(url: mixURL, bitRate: sessionBitRate, sessionStart: sessionStart)
        do {
            try mixer.start()
        } catch {
            mixer.stop()
            throw error
        }
        liveMixer = mixer
        if let outID = try? audio.defaultOutputDeviceID(), !audio.isLockMicRecorder(outID) {
            playbackDeviceUID = audio.deviceUID(outID) ?? ""
        }
        guard let micDevice = inputDevice(uid: selectedInputUID) ?? defaultInputDevice() else {
            teardownSessionHardwareSync()
            throw SessionRecorderError.micStartFailed
        }
        selectedInputUID = micDevice.uid
        do {
            try syncInputCapturesSync()
            try startSystemPlaybackTapSync(mixer: mixer)
            try syncPlaybackTapsSync()
        } catch {
            teardownSessionHardwareSync()
            try? FileManager.default.removeItem(at: mixURL)
            let wrapped = Self.wrapStartError(error)
            if case .playbackDenied? = wrapped as? SessionRecorderError {
                publishUI { $0.playbackAccess = .denied }
            }
            publishUI { $0.lastError = wrapped.localizedDescription }
            throw wrapped
        }
        sessionFile = mixURL
        recordingStartedAt = Date()
        setSessionLive(true)
        RecordingSessionLock.acquire()
        publishUI {
            $0.microphoneAccess = .granted
            $0.playbackAccess = .granted
            $0.recordingStartedAt = Date()
        }
        refreshDeviceRows()
        publishLevels()
        reassertSystemMute()
        log.info("Recording started \(mixURL.lastPathComponent, privacy: .public)")
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
    /// HAL Stop/Destroy and the ADTS→m4a wrap run off the main thread. Doing them
    /// on MainActor deadlocks Core Audio (listeners `dispatch_sync` onto main from
    /// inside Destroy) and beachballs the app for the duration of the wrap.
    @discardableResult
    func stopCaptures(onIdle: (() -> Void)? = nil) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.perform {
                self.stopCapturesOnQueue(onIdle: onIdle, continuation: continuation)
            }
        }
    }

    private func stopCapturesOnQueue(
        onIdle: (() -> Void)?,
        continuation: CheckedContinuation<URL, Error>
    ) {
        if isStopping {
            stopWaiters.append(continuation)
            return
        }
        guard sessionLive, let file = sessionFile else {
            continuation.resume(throwing: SessionRecorderError.notRecording)
            return
        }
        setStopping(true)
        outputChangeWork?.cancel()
        playbackTapSync += 1
        let inputs = Array(inputCaptures.values)
        inputCaptures.removeAll()
        let taps: [PlaybackCapturing] = Array(playbackTaps.values) + [systemPlaybackTap].compactMap { $0 }
        playbackTaps.removeAll()
        systemPlaybackTap = nil
        let mixer = liveMixer
        liveMixer = nil
        playbackDeviceUID = ""
        refreshCaptureAccess()
        selectedInputUID = ""
        followDefaultInput = true
        followDefaultOutput = true
        recordsAllPlayback = false
        selectedOutputUIDs = []
        inputOrder = []
        outputOrder = []
        setSessionLive(false)
        recordingStartedAt = nil
        publishUI {
            $0.recordingStartedAt = nil
            $0.devices = []
            $0.followDefaultInput = true
            $0.followDefaultOutput = true
        }
        publishLevels()
        if let onIdle {
            DispatchQueue.main.async { onIdle() }
        }

        let finalFile = Self.stopHardware(inputs: inputs, taps: taps, mixer: mixer) ?? file
        sessionFile = finalFile
        log.info("Recording stopped: \(finalFile.lastPathComponent, privacy: .public)")
        let waiters = stopWaiters
        stopWaiters.removeAll()
        setStopping(false)
        RecordingSessionLock.release()
        continuation.resume(returning: finalFile)
        for waiter in waiters { waiter.resume(returning: finalFile) }
    }

    nonisolated private static func stopHardware(
        inputs: [InputDeviceCapture],
        taps: [PlaybackCapturing],
        mixer: LiveMixer?
    ) -> URL? {
        for capture in inputs { capture.stop() }
        for tap in taps { tap.stop() }
        mixer?.stop()
        return mixer?.url
    }

    private func teardownSessionHardwareSync() {
        let inputs = Array(inputCaptures.values)
        inputCaptures.removeAll()
        let taps = Array(playbackTaps.values) + [systemPlaybackTap].compactMap { $0 }
        playbackTaps.removeAll()
        systemPlaybackTap = nil
        let mixer = liveMixer
        liveMixer = nil
        mixer?.removeAllPlaybackSources()
        _ = Self.stopHardware(inputs: inputs, taps: taps, mixer: mixer)
        publishLevels()
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
        perform {
            guard token == self.playbackTapSync, self.sessionLive else { return }
            do {
                if #available(macOS 14.2, *) {
                    try self.syncPlaybackTapsSync()
                }
            } catch {
                self.publishUI { $0.lastError = error.localizedDescription }
                log.error("Playback tap sync failed: \(error.localizedDescription, privacy: .public)")
            }
            self.refreshDeviceRows()
            self.publishLevels()
        }
    }

    @available(macOS 14.2, *)
    private func waitForPlaybackTap(deviceUID: String?) throws -> PlaybackTap {
        let box = TapWaitBox()
        let done = DispatchSemaphore(value: 0)
        let audio = self.audio
        Task {
            do {
                box.tap = try await PlaybackTap(audio: audio, deviceUID: deviceUID)
            } catch {
                box.error = error
            }
            done.signal()
        }
        done.wait()
        if let error = box.error { throw error }
        guard let tap = box.tap else { throw SessionRecorderError.tapFailed(-1) }
        return tap
    }

    /// System mix of the current default output. Other selected outputs use
    /// device taps so they can be summed without doubling the default.
    @available(macOS 14.2, *)
    private func startSystemPlaybackTapSync(mixer: LiveMixer) throws {
        if systemPlaybackTap != nil { return }
        let tap = try waitForPlaybackTap(deviceUID: nil)
        attachPlaybackTap(tap)
        systemPlaybackTap = tap
        applyPlaybackMixGate()
        log.info("Playback mix tap (system)")
    }

    private func syncInputCapturesInBackground() {
        perform {
            do {
                try self.syncInputCapturesSync()
                self.publishLevels()
            } catch {
                self.publishUI { $0.lastError = error.localizedDescription }
                log.error("Input capture sync failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Peak-meter selected input, plus others when `monitorUnselectedDevices`.
    private func syncInputCapturesSync() throws {
        let devices = audio.listInputDevices().filter { !$0.isVirtual }
        var wanted: Set<String>
        if monitorUnselectedDevices {
            wanted = Set(devices.map(\.uid))
        } else {
            wanted = selectedInputUID.isEmpty ? [] : [selectedInputUID]
        }
        // Meter HAL IO on a USB headset we are also tapping (Jabra input `:1`
        // + output `:2`) glitches the device's output tap.
        let outputUIDs = (monitorUnselectedDevices ? liveOutputUIDs() : selectedOutputUIDs)
            .union(playbackTaps.keys)
        let blockedFamilies = Set(outputUIDs.compactMap { AudioDeviceService.usbAudioFamily(uid: $0) })
        if !blockedFamilies.isEmpty {
            for device in devices where device.uid != selectedInputUID {
                guard let family = AudioDeviceService.usbAudioFamily(uid: device.uid),
                      blockedFamilies.contains(family)
                else { continue }
                if wanted.remove(device.uid) != nil {
                    log.info(
                        "Skip input meter on \(device.name, privacy: .public) while tapping its USB output"
                    )
                }
            }
        }
        var staleInputs: [InputDeviceCapture] = []
        for uid in inputCaptures.keys where !wanted.contains(uid) {
            if let capture = inputCaptures.removeValue(forKey: uid) {
                staleInputs.append(capture)
            }
        }
        for capture in staleInputs { capture.stop() }
        var selectedFailed: Error?
        let mixer = liveMixer
        let start = sessionStart
        let rate = sessionBitRate
        for device in devices where wanted.contains(device.uid) && inputCaptures[device.uid] == nil {
            do {
                let capture = try InputDeviceCapture(
                    deviceID: device.id,
                    fileURL: nil,
                    sessionStart: start,
                    bitRate: rate,
                    startIO: !mixInputMuted
                )
                capture.mixer = mixer
                inputCaptures[device.uid] = capture
            } catch {
                log.error("Input meter failed for \(device.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if device.uid == selectedInputUID {
                    selectedFailed = error
                }
            }
        }
        syncInputMuteToCapture()
        for capture in inputCaptures.values {
            capture.setIORunning(!mixInputMuted)
        }
        if inputCaptures[selectedInputUID] == nil {
            throw selectedFailed ?? SessionRecorderError.micStartFailed
        }
        reassertSystemMute()
    }

    /// Peak-meter selected outputs, plus others when `monitorUnselectedDevices`.
    @available(macOS 14.2, *)
    private func syncPlaybackTapsSync() throws {
        let listed = audio.listOutputDevices().filter { !$0.isVirtual }.map(\.uid)
        let listedSet = Set(listed)
        let keep = monitorUnselectedDevices ? listedSet : selectedOutputUIDs

        var selectedFailed: Error?
        for uid in listed where keep.contains(uid) && playbackTaps[uid] == nil {
            do {
                let tap = try waitForPlaybackTap(deviceUID: uid)
                attachPlaybackTap(tap)
                playbackTaps[uid] = tap
                log.info("Playback tap on \(uid, privacy: .public)")
            } catch {
                log.error("Playback tap failed for \(uid, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if selectedOutputUIDs.contains(uid) {
                    selectedOutputUIDs.remove(uid)
                    selectedFailed = error
                }
            }
        }
        let stale = playbackTaps.keys.filter { !keep.contains($0) }
        var staleTaps: [PlaybackCapturing] = []
        for uid in stale {
            if let tap = playbackTaps.removeValue(forKey: uid) {
                staleTaps.append(tap)
            }
            liveMixer?.removePlaybackSource(uid)
            if !listedSet.contains(uid) {
                selectedOutputUIDs.remove(uid)
            }
        }
        for tap in staleTaps { tap.stop() }
        applyPlaybackMixGate()
        if !selectedOutputUIDs.isEmpty,
           selectedOutputUIDs.allSatisfy({ playbackTaps[$0] == nil }),
           let selectedFailed
        {
            throw selectedFailed
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
            scope: scope
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
        scope: PlaybackRecordScope
    ) -> Set<String> {
        let fallback: Set<String> = playbackDeviceUID.isEmpty ? [] : [playbackDeviceUID]
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

@available(macOS 14.2, *)
private final class TapWaitBox: @unchecked Sendable {
    var tap: PlaybackTap?
    var error: Error?
}
