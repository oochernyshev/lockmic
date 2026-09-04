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
    private let preferences: PreferencesStore
    private var devicesToken: UUID?
    private var deviceChangeWorkItem: DispatchWorkItem?

    /// While user intent is muted, rewrite HAL mute every 2s (device switch, Meet, drivers).
    private var muteEnforceTimer: Timer?
    private static let muteEnforceInterval: TimeInterval = 2.0
    /// Default input last written by mute/enforce — used to detect a switch on the 2s tick.
    private var lastEnforcedDefaultID: AudioDeviceID = 0

    init(audio: AudioDeviceService = AudioDeviceService(), preferences: PreferencesStore) {
        self.audio = audio
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
        do {
            let id = try audio.defaultInputDeviceID()
            deviceName = audio.deviceName(id)
            if audio.supportsMute(id) {
                let muted = try audio.isMuted(id)
                state = muted ? .muted : .unmuted
                desiredMuted = muted
                lastError = nil
            } else {
                state = .unsupported(deviceName: deviceName)
            }
        } catch {
            lastError = error.localizedDescription
            state = .unknown
        }
        refreshDeviceList()
        syncMuteEnforcementTimer()
    }

    /// Rebuild the Preferences device table from Core Audio.
    func refreshDeviceList() {
        let defaultID = try? audio.defaultInputDeviceID()
        inputDevices = audio.listInputDevices().map { device in
            let isDefault = device.id == defaultID
            // Virtual-transport devices are listed but never controlled.
            let inScope = !device.isVirtual && (preferences.muteAllInputs || isDefault)
            let muted: Bool? = device.supportsMute ? (try? audio.isMuted(device.id)) : nil
            return InputDeviceRow(
                id: device.id,
                uid: device.uid,
                name: device.name,
                isDefault: isDefault,
                supportsMute: device.supportsMute,
                isMuted: muted,
                isVirtual: device.isVirtual,
                isInScope: inScope
            )
        }
    }

    // MARK: - Private

    private func applyMute(_ muted: Bool) {
        let defaultID = try? audio.defaultInputDeviceID()
        if let defaultID {
            deviceName = audio.deviceName(defaultID)
            // USB drivers often ignore mute=1 unless they see unmute→mute (device switch).
            if muted, lastEnforcedDefaultID != 0, defaultID != lastEnforcedDefaultID {
                try? audio.setMuted(false, deviceID: defaultID)
            }
        }

        if preferences.muteAllInputs {
            let result = audio.setAllInputsMuted(muted)
            applyMuteAllResult(result, desiredMuted: muted)
        } else {
            do {
                guard let defaultID else { throw AudioDeviceServiceError.noDefaultInput }
                try audio.setMuted(muted, deviceID: defaultID)
                state = muted ? .muted : .unmuted
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                if muted {
                    state = .unsupported(deviceName: deviceName)
                } else {
                    state = .unknown
                }
            }
        }
        if muted, let defaultID {
            lastEnforcedDefaultID = defaultID
        }
        log.debug("\(muted ? "Muted" : "Unmuted", privacy: .public)")
        refreshDeviceList()
        syncMuteEnforcementTimer()
    }

    /// Mute and unmute share the same batch outcome. Unmute must not claim success
    /// when every in-scope device failed — otherwise the icon/HUD lie and toggle mutes again.
    private func applyMuteAllResult(_ result: AudioDeviceService.MuteBatchResult, desiredMuted: Bool) {
        let failedDetail = result.failed.map { "\($0.name): \($0.message)" }.joined(separator: "; ")
        let failedNames = result.failed.map(\.name).joined(separator: ", ")

        if result.allFailed {
            lastError = failedDetail
            if desiredMuted {
                state = .unsupported(deviceName: deviceName)
            } else {
                // Unmute did not take: keep HAL-truthful state and sticky mute intent.
                self.desiredMuted = true
                if let hardwareMuted = defaultInputMute() {
                    state = hardwareMuted ? .muted : .unmuted
                }
            }
            return
        }

        if let hardwareMuted = defaultInputMute() {
            state = hardwareMuted ? .muted : .unmuted
        } else {
            state = desiredMuted ? .muted : .unmuted
        }
        lastError = result.failed.isEmpty
            ? nil
            : (desiredMuted ? "No system mute on: \(failedNames)" : "Could not unmute: \(failedNames)")
    }

    private func defaultInputMute() -> Bool? {
        guard let id = try? audio.defaultInputDeviceID(), audio.supportsMute(id) else { return nil }
        return try? audio.isMuted(id)
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
