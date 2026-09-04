import AppKit

/// Start/stop session capture, TCC retry, recording monitor.
@MainActor
final class RecordingCoordinator {
    private let recorder: SessionRecorder
    private let preferences: PreferencesStore
    private let mic: MicController
    private let monitor = RecordingMonitorController()

    var onSessionChanged: (() -> Void)?
    var onToggleMute: (() -> Void)?
    var onPresentError: ((Error) -> Void)?

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
        if recorder.isRecording {
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
        await nextMainRunLoopTurn()
        showMonitor()
        await beginCapture(scope: scope, source: source)
    }

    func stop(source: UsageReporter.ActivationSource) {
        if recorder.isBusy, !recorder.isRecording {
            return
        }
        if !recorder.isRecording {
            monitor.hide()
            recorder.cancelPreview()
            onSessionChanged?()
            return
        }
        monitor.hide()
        Task {
            let file: URL
            do {
                file = try await recorder.stopCaptures { [weak self] in
                    self?.onSessionChanged?()
                }
            } catch SessionRecorderError.notRecording {
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
            }
        )
    }

    func showRecordingsFolder() {
        UsageReporter.record(.showRecordings, source: .menu)
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
        } catch SessionRecorderError.alreadyRecording {
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

    private func openSettings(_ candidates: [String]) {
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    private func nextMainRunLoopTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
