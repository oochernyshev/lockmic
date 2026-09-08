import CoreAudio
import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "MicController")

enum MicState: Equatable, Sendable {
    case muted
    case unmuted
    case unknown
    case unsupported(deviceName: String)
}

/// Snapshot of an input device for the Preferences → Devices list.
struct InputDeviceRow: Identifiable, Equatable, Sendable {
    let id: UInt32
    let uid: String
    let name: String
    let isDefault: Bool
    let supportsMute: Bool
    let isMuted: Bool?
    let isVirtual: Bool
    /// Controlled by LockMic under the current mute-all / default scope.
    let isInScope: Bool

    enum ControlStatus: Equatable, Sendable {
        case muted
        case unmuted
        case notControllable
        case virtualIgnored
        case outsideScope
        case unknown
    }

    var controlStatus: ControlStatus {
        if isVirtual { return .virtualIgnored }
        if !supportsMute { return .notControllable }
        if !isInScope { return .outsideScope }
        switch isMuted {
        case true?: return .muted
        case false?: return .unmuted
        case nil: return .unknown
        }
    }
}

/// Runs blocking Core Audio discovery and mute operations away from the main thread.
private actor MicHardwareWorker {
    struct Snapshot: Sendable {
        let defaultID: AudioDeviceID?
        let deviceName: String
        let defaultMuted: Bool?
        let defaultSupportsMute: Bool
        let devices: [InputDeviceRow]
        let error: String?
    }

    struct MuteResult: Sendable {
        let snapshot: Snapshot
        let batch: AudioDeviceService.MuteBatchResult?
        let error: String?
    }

    private let audio: AudioDeviceService

    init(audio: AudioDeviceService) {
        self.audio = audio
    }

    func snapshot(muteAllInputs: Bool) -> Snapshot {
        makeSnapshot(muteAllInputs: muteAllInputs)
    }

    func setMuted(
        _ muted: Bool,
        muteAllInputs: Bool,
        lastEnforcedDefaultID: AudioDeviceID
    ) -> MuteResult {
        let defaultID = try? audio.defaultInputDeviceID()
        if muted, let defaultID, lastEnforcedDefaultID != 0,
           defaultID != lastEnforcedDefaultID
        {
            // USB drivers often need an unmute→mute transition after a device switch.
            try? audio.setMuted(false, deviceID: defaultID)
        }

        let batch: AudioDeviceService.MuteBatchResult?
        let error: String?
        if muteAllInputs {
            batch = audio.setAllInputsMuted(muted)
            error = nil
        } else {
            batch = nil
            do {
                guard let defaultID else { throw AudioDeviceServiceError.noDefaultInput }
                try audio.setMuted(muted, deviceID: defaultID)
                error = nil
            } catch let caught {
                error = caught.localizedDescription
            }
        }

        return MuteResult(
            snapshot: makeSnapshot(muteAllInputs: muteAllInputs),
            batch: batch,
            error: error
        )
    }

    private func makeSnapshot(muteAllInputs: Bool) -> Snapshot {
        do {
            let defaultID = try audio.defaultInputDeviceID()
            let name = audio.deviceName(defaultID)
            let supportsMute = audio.supportsMute(defaultID)
            let muted: Bool?
            let error: String?
            if supportsMute {
                do {
                    muted = try audio.isMuted(defaultID)
                    error = nil
                } catch let caught {
                    muted = nil
                    error = caught.localizedDescription
                }
            } else {
                muted = nil
                error = nil
            }
            return Snapshot(
                defaultID: defaultID,
                deviceName: name,
                defaultMuted: muted,
                defaultSupportsMute: supportsMute,
                devices: deviceRows(defaultID: defaultID, muteAllInputs: muteAllInputs),
                error: error
            )
        } catch {
            return Snapshot(
                defaultID: nil,
                deviceName: "—",
                defaultMuted: nil,
                defaultSupportsMute: false,
                devices: deviceRows(defaultID: nil, muteAllInputs: muteAllInputs),
                error: error.localizedDescription
            )
        }
    }

    private func deviceRows(defaultID: AudioDeviceID?, muteAllInputs: Bool) -> [InputDeviceRow] {
        audio.listInputDevices().map { device in
            let isDefault = device.id == defaultID
            return InputDeviceRow(
                id: device.id,
                uid: device.uid,
                name: device.name,
                isDefault: isDefault,
                supportsMute: device.supportsMute,
                isMuted: device.supportsMute ? try? audio.isMuted(device.id) : nil,
                isVirtual: device.isVirtual,
                isInScope: !device.isVirtual && (muteAllInputs || isDefault)
            )
        }
    }
}

@MainActor
final class MicController: ObservableObject {
    @Published private(set) var state: MicState = .unknown
    @Published private(set) var deviceName: String = "—"
    @Published private(set) var lastError: String?
    @Published private(set) var inputDevices: [InputDeviceRow] = []

    /// Sticky user intent, re-applied every 2s while muted.
    private(set) var desiredMuted: Bool = false

    /// When true (push-to-talk held), skip the 2s mute re-apply.
    var suppressDeviceResync = false

    private let audio: AudioDeviceService
    private let hardware: MicHardwareWorker
    private let preferences: PreferencesStore
    private var devicesToken: UUID?
    private var deviceChangeWorkItem: DispatchWorkItem?
    private var stateRequest = 0
    private var devicesRequest = 0

    /// While user intent is muted, rewrite HAL mute every 2s (device switch, Meet, drivers).
    private var muteEnforceTimer: Timer?
    private static let muteEnforceInterval: TimeInterval = 2.0
    /// Default input last written by mute/enforce — used to detect a switch on the 2s tick.
    private var lastEnforcedDefaultID: AudioDeviceID = 0

    init(audio: AudioDeviceService = AudioDeviceService(), preferences: PreferencesStore) {
        self.audio = audio
        self.hardware = MicHardwareWorker(audio: audio)
        self.preferences = preferences
        devicesToken = audio.onDevicesChanged { [weak self] in
            Task { @MainActor in
                self?.scheduleHandleDevicesChanged()
            }
        }
        refreshFromHardware(applyDesired: false)
        // refreshFromHardware already rebuilds the list and starts mute enforcement if needed.
    }

    deinit {
        muteEnforceTimer?.invalidate()
        if let devicesToken {
            audio.removeDevicesChangedHandler(devicesToken)
        }
    }

    /// Single source of truth for “is the mic muted?” for UI, hotkeys, and HUD.
    /// Uses HAL state when known; falls back to `desiredMuted` when unknown/unsupported.
    var effectiveMuted: Bool {
        switch state {
        case .muted: return true
        case .unmuted: return false
        case .unknown, .unsupported: return desiredMuted
        }
    }

    /// Alias of `effectiveMuted` for call sites that read “is muted?”.
    var isMuted: Bool { effectiveMuted }

    func toggle() {
        setMuted(!effectiveMuted)
    }

    func setMuted(_ muted: Bool) {
        desiredMuted = muted
        // Keep hotkeys, HUD, and recording gates responsive while HAL works in the background.
        state = muted ? .muted : .unmuted
        syncMuteEnforcementTimer()
        applyMute(muted)
    }

    func preferenceMuteScopeChanged() {
        if desiredMuted {
            applyMute(true) // includes refreshDeviceList
        } else {
            refreshFromHardware(applyDesired: false) // includes refreshDeviceList
        }
    }

    /// - Parameter applyDesired: `true` re-writes HAL from sticky intent (device change,
    ///   app activation). `false` seeds intent from HAL — only safe at launch or when
    ///   the user is not holding a mute.
    func refreshFromHardware(applyDesired: Bool) {
        if applyDesired {
            applyMute(desiredMuted)
            return
        }
        let stateRequest = nextStateRequest()
        let devicesRequest = nextDevicesRequest()
        let muteAllInputs = preferences.muteAllInputs
        Task { [weak self, hardware] in
            let snapshot = await hardware.snapshot(muteAllInputs: muteAllInputs)
            guard let self else { return }
            if stateRequest == self.stateRequest {
                self.applyHardwareState(snapshot, seedDesiredMuted: true)
            }
            if devicesRequest == self.devicesRequest {
                self.inputDevices = snapshot.devices
            }
        }
    }

    /// Rebuild the Preferences device table from Core Audio.
    func refreshDeviceList() {
        let request = nextDevicesRequest()
        let muteAllInputs = preferences.muteAllInputs
        Task { [weak self, hardware] in
            let snapshot = await hardware.snapshot(muteAllInputs: muteAllInputs)
            guard let self, request == self.devicesRequest else { return }
            self.inputDevices = snapshot.devices
        }
    }

    // MARK: - Private

    private func applyMute(_ muted: Bool) {
        let stateRequest = nextStateRequest()
        let devicesRequest = nextDevicesRequest()
        let muteAllInputs = preferences.muteAllInputs
        let lastDefaultID = lastEnforcedDefaultID
        Task { [weak self, hardware] in
            let result = await hardware.setMuted(
                muted,
                muteAllInputs: muteAllInputs,
                lastEnforcedDefaultID: lastDefaultID
            )
            guard let self else { return }
            if stateRequest == self.stateRequest {
                self.applyMuteResult(result, desiredMuted: muted, muteAllInputs: muteAllInputs)
            }
            if devicesRequest == self.devicesRequest {
                self.inputDevices = result.snapshot.devices
            }
        }
    }

    /// Mute and unmute share the same batch outcome. Unmute must not claim success
    /// when every in-scope device failed — otherwise the icon/HUD lie and toggle mutes again.
    private func applyMuteAllResult(
        _ result: AudioDeviceService.MuteBatchResult,
        desiredMuted: Bool,
        hardwareMuted: Bool?
    ) {
        let failedDetail = result.failed.map { "\($0.name): \($0.message)" }.joined(separator: "; ")
        let failedNames = result.failed.map(\.name).joined(separator: ", ")

        if result.allFailed {
            lastError = failedDetail
            if desiredMuted {
                state = .unsupported(deviceName: deviceName)
            } else {
                // Unmute did not take: keep HAL-truthful state and sticky mute intent.
                self.desiredMuted = true
                if let hardwareMuted {
                    state = hardwareMuted ? .muted : .unmuted
                }
            }
            return
        }

        if let hardwareMuted {
            state = hardwareMuted ? .muted : .unmuted
        } else {
            state = desiredMuted ? .muted : .unmuted
        }
        lastError = result.failed.isEmpty
            ? nil
            : (desiredMuted ? "No system mute on: \(failedNames)" : "Could not unmute: \(failedNames)")
    }

    private func applyMuteResult(
        _ result: MicHardwareWorker.MuteResult,
        desiredMuted: Bool,
        muteAllInputs: Bool
    ) {
        deviceName = result.snapshot.deviceName
        if desiredMuted, let defaultID = result.snapshot.defaultID {
            lastEnforcedDefaultID = defaultID
        }
        if muteAllInputs, let batch = result.batch {
            applyMuteAllResult(
                batch,
                desiredMuted: desiredMuted,
                hardwareMuted: result.snapshot.defaultMuted
            )
        } else if let error = result.error {
            lastError = error
            state = desiredMuted ? .unsupported(deviceName: deviceName) : .unknown
        } else {
            state = desiredMuted ? .muted : .unmuted
            lastError = nil
        }
        log.debug("\(desiredMuted ? "Muted" : "Unmuted", privacy: .public)")
        syncMuteEnforcementTimer()
    }

    private func applyHardwareState(
        _ snapshot: MicHardwareWorker.Snapshot,
        seedDesiredMuted: Bool
    ) {
        deviceName = snapshot.deviceName
        lastError = snapshot.error
        if let muted = snapshot.defaultMuted {
            state = muted ? .muted : .unmuted
            if seedDesiredMuted { desiredMuted = muted }
        } else if snapshot.defaultSupportsMute {
            state = .unknown
        } else if snapshot.error == nil {
            state = .unsupported(deviceName: deviceName)
        } else {
            state = .unknown
        }
        syncMuteEnforcementTimer()
    }

    private func nextStateRequest() -> Int {
        stateRequest += 1
        return stateRequest
    }

    private func nextDevicesRequest() -> Int {
        devicesRequest += 1
        return devicesRequest
    }

    /// Start/stop the 2s re-apply timer from `desiredMuted`.
    private func syncMuteEnforcementTimer() {
        if desiredMuted {
            guard muteEnforceTimer == nil else { return }
            let timer = Timer(timeInterval: Self.muteEnforceInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.reassertMuteIfNeeded()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            muteEnforceTimer = timer
        } else {
            muteEnforceTimer?.invalidate()
            muteEnforceTimer = nil
            lastEnforcedDefaultID = 0
        }
    }

    /// 2s timer and recording start: write mute again on the current default.
    func reassertMuteIfNeeded() {
        guard desiredMuted, !suppressDeviceResync else { return }
        applyMute(true)
    }

    private func scheduleHandleDevicesChanged() {
        deviceChangeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshDeviceList()
        }
        deviceChangeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
