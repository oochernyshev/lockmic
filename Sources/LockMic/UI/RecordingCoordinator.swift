import AppKit

/// Start/stop session capture, TCC retry, recording monitor.
@MainActor
final class RecordingCoordinator {
    private let recorder: SessionRecorder
    private let preferences: PreferencesStore
    private let mic: MicController
    private let monitor = RecordingMonitorController()
    private var silenceWatch: Timer?
    private var silenceBegan: Date?
    private var speechTicks = 0
    private var smoothedEnergy: Float?
    private var watchedSilenceTimeout: TimeInterval?
    /// After the user dismisses the countdown, wait for real audio before starting a new silence period.
    private var skipUntilSpeech = false

    var onSessionChanged: (() -> Void)?
    var onToggleMute: (() -> Void)?
    var onPresentError: ((Error) -> Void)?
    var onSilenceStopWarningChanged: ((Bool) -> Void)?

    var isMonitorVisible: Bool { monitor.isVisible }

    init(recorder: SessionRecorder, preferences: PreferencesStore, mic: MicController) {
        self.recorder = recorder
        self.preferences = preferences
        self.mic = mic
        recorder.persistInputSelection = { [weak self] follow, uid in
            guard let self else { return }
            if self.preferences.followDefaultMic != follow {
                self.preferences.followDefaultMic = follow
            }
            if !follow, !uid.isEmpty, self.preferences.recordingInputUID != uid {
                self.preferences.recordingInputUID = uid
            }
        }
        recorder.persistOutputSelection = { [weak self] follow, uids, recordAll in
            guard let self else { return }
            if self.preferences.followDefaultOutput != follow {
                self.preferences.followDefaultOutput = follow
            }
            if recordAll {
                if !self.preferences.recordAllPlayback {
                    self.preferences.recordAllPlayback = true
                }
                return
            }
            if self.preferences.recordAllPlayback {
                self.preferences.recordAllPlayback = false
            }
            if !follow {
                let list = uids.sorted()
                if self.preferences.recordingOutputUIDs != list {
                    self.preferences.recordingOutputUIDs = list
                }
            }
        }
    }

    func toggle(source: UsageReporter.ActivationSource) {
        if recorder.isRecording || recorder.isBusy {
            stop(source: source)
            return
        }
        guard preferences.featuresEnabled else { return }
        Task { await start(source: source) }
    }

    func startIfIdle(source: UsageReporter.ActivationSource) {
        if recorder.isRecording {
            if isMonitorVisible {
                monitor.hide()
            } else {
                showMonitor()
            }
            return
        }
        guard preferences.featuresEnabled else { return }
        Task { await start(source: source) }
    }

    func start(source: UsageReporter.ActivationSource) async {
        if recorder.isRecording { return }
        let scope = currentPlaybackScope()
        recorder.previewSession(
            playback: scope,
            followInput: preferences.followDefaultMic,
            followOutput: preferences.followDefaultOutput,
            preferredInputUID: preferences.recordingInputUID,
            preferredOutputUIDs: preferences.recordingOutputUIDs
        )
        showMonitor()
        await beginCapture(scope: scope, source: source)
    }

    func stop(source: UsageReporter.ActivationSource) {
        stopSilenceWatch()
        monitor.hide()
        if !recorder.isRecording, !recorder.isBusy {
            recorder.cancelPreview()
            onSessionChanged?()
            return
        }
        Task {
            let file: URL
            do {
                file = try await recorder.stopCaptures { [weak self] in
                    self?.onSessionChanged?()
                }
            } catch SessionRecorderError.notRecording {
                recorder.cancelPreview()
                onSessionChanged?()
                return
            } catch {
                onSessionChanged?()
                onPresentError?(error)
                return
            }
            UsageReporter.record(.stopRecording, source: source)
            onSessionChanged?()
            if !FileManager.default.fileExists(atPath: file.path) {
                UsageReporter.record(.mixFailed, source: source)
            }
        }
    }

    func finalizeForQuit() async {
        stopSilenceWatch()
        let wasActive = recorder.isBusy
        if recorder.isRecording {
            monitor.hide()
        }
        let mixed = await recorder.finalizeAndMix()
        if wasActive {
            UsageReporter.record(.stopRecording, source: .menu)
        }
        onSessionChanged?()
        if !mixed {
            UsageReporter.record(.mixFailed, source: .menu)
        }
    }

    func showMonitor() {
        monitor.show(
            recorder: recorder,
            preferences: preferences,
            mic: mic,
            onStop: { [weak self] in
                self?.stop(source: .monitor)
            },
            onAllowAccess: { [weak self] in
                self?.retryAccessFromMonitor()
            },
            onToggleMute: { [weak self] in
                self?.onToggleMute?()
            },
            onShowRecordings: { [weak self] in
                self?.showRecordingsFolder(source: .monitor)
            },
            onCancelSilence: { [weak self] in
                self?.cancelSilenceAutoStop()
            }
        )
        setSilenceCountdown(silenceBadgeRemaining())
    }

    func showRecordingsFolder(source: UsageReporter.ActivationSource = .menu) {
        UsageReporter.record(.showRecordings, source: source)
        let folder = preferences.recordingsDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func retryCaptureIfAccessGranted() {
        guard !recorder.isBusy, monitor.isVisible else { return }
        let blocked = recorder.microphoneAccess == .denied || recorder.playbackAccess == .denied
        guard blocked else { return }
        recorder.refreshCaptureAccess()
        showMonitor()
        if recorder.microphoneAccess == .denied || recorder.playbackAccess == .denied { return }
        Task { await beginCapture(scope: currentPlaybackScope(), source: .monitor) }
    }

    private func currentPlaybackScope() -> PlaybackRecordScope {
        preferences.recordAllPlayback && !preferences.followDefaultOutput ? .all : .default
    }

    private func beginCapture(scope: PlaybackRecordScope, source: UsageReporter.ActivationSource) async {
        do {
            try await recorder.start(
                playback: scope,
                bitRate: preferences.recordingBitRate,
                in: preferences.recordingsDirectory,
                followInput: preferences.followDefaultMic,
                followOutput: preferences.followDefaultOutput,
                preferredInputUID: preferences.recordingInputUID,
                preferredOutputUIDs: preferences.recordingOutputUIDs,
                monitorUnselected: preferences.monitorUnselectedDevices
            )
            UsageReporter.record(.startRecording, source: source)
            onSessionChanged?()
            showMonitor()
            startSilenceWatch()
        } catch SessionRecorderError.alreadyRecording, SessionRecorderError.notRecording {
            return
        } catch SessionRecorderError.microphoneDenied, SessionRecorderError.playbackDenied {
            showMonitor()
        } catch {
            monitor.hide()
            recorder.cancelPreview()
            onPresentError?(error)
        }
    }

    private func retryAccessFromMonitor() {
        if recorder.microphoneAccess == .denied {
            Task { await retryMicrophoneAccess() }
        } else {
            Task { await retryPlaybackAccess() }
        }
    }

    private func retryMicrophoneAccess() async {
        if await SessionRecorder.requestMicrophoneAccess() {
            await beginCapture(scope: currentPlaybackScope(), source: .monitor)
            return
        }
        openSettings([
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        ])
    }

    private func retryPlaybackAccess() async {
        if await SystemAudioAccess.request() {
            await beginCapture(scope: currentPlaybackScope(), source: .monitor)
            return
        }
        openSettings([
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ])
    }

    private static let speechHoldTicks = 3
    private static let watchInterval: TimeInterval = 0.25
    /// Show the cancellable countdown after this much confirmed silence…
    private static let badgeDelay: TimeInterval = 10
    /// …and only once this little time remains until auto-stop.
    private static let badgeLead: TimeInterval = 30

    private func startSilenceWatch() {
        stopSilenceWatch()
        watchedSilenceTimeout = preferences.recordingSilenceTimeout.duration
        let timer = Timer(timeInterval: Self.watchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkSilence()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        silenceWatch = timer
        checkSilence()
    }

    private func stopSilenceWatch() {
        silenceWatch?.invalidate()
        silenceWatch = nil
        silenceBegan = nil
        speechTicks = 0
        smoothedEnergy = nil
        watchedSilenceTimeout = nil
        skipUntilSpeech = false
        setSilenceCountdown(nil)
    }

    private func cancelSilenceAutoStop() {
        skipUntilSpeech = true
        silenceBegan = nil
        speechTicks = 0
        setSilenceCountdown(nil)
    }

    private func checkSilence() {
        guard recorder.isRecording else {
            stopSilenceWatch()
            return
        }
        guard let timeout = preferences.recordingSilenceTimeout.duration else {
            watchedSilenceTimeout = nil
            silenceBegan = nil
            speechTicks = 0
            skipUntilSpeech = false
            setSilenceCountdown(nil)
            return
        }

        if watchedSilenceTimeout != timeout {
            watchedSilenceTimeout = timeout
            silenceBegan = Date()
            speechTicks = 0
            smoothedEnergy = nil
            setSilenceCountdown(nil)
            return
        }

        smoothedEnergy = SilenceEnergyDetector.smoothed(
            previous: smoothedEnergy,
            current: recorder.liveWaveformLevel(),
            interval: Self.watchInterval
        )
        if SilenceEnergyDetector.isActive(smoothedEnergy ?? 0) {
            speechTicks += 1
        } else {
            speechTicks = 0
        }

        if speechTicks >= Self.speechHoldTicks {
            skipUntilSpeech = false
            silenceBegan = nil
            setSilenceCountdown(nil)
            return
        }

        guard !skipUntilSpeech else { return }

        let started = silenceBegan ?? Date()
        silenceBegan = started
        let silentFor = Date().timeIntervalSince(started)
        if silentFor >= timeout {
            setSilenceCountdown(nil)
            stop(source: .silence)
            return
        }
        setSilenceCountdown(silenceBadgeRemaining(silentFor: silentFor, timeout: timeout))
    }

    private func setSilenceCountdown(_ remaining: TimeInterval?) {
        monitor.setSilenceCountdown(remaining)
        onSilenceStopWarningChanged?(remaining.map { $0 <= 10 } ?? false)
    }

    private func silenceBadgeRemaining(
        silentFor: TimeInterval? = nil,
        timeout: TimeInterval? = nil
    ) -> TimeInterval? {
        guard !skipUntilSpeech,
              let timeout = timeout ?? preferences.recordingSilenceTimeout.duration,
              let began = silenceBegan
        else { return nil }
        let elapsed = silentFor ?? Date().timeIntervalSince(began)
        let remaining = timeout - elapsed
        guard elapsed >= Self.badgeDelay, remaining <= Self.badgeLead else { return nil }
        return max(0, remaining)
    }

    private func openSettings(_ candidates: [String]) {
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

}
