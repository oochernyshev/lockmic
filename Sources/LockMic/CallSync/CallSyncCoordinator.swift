import Combine
import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "CallSync")

/// Keeps LockMic's mute and the active call service's mute identical in both directions.
///
/// Loop protection: every change we push gets a timestamp; service events arriving within
/// `echoWindow` of our own push are treated as the echo of that command and ignored.
/// A service-side change applied to LockMic is flagged so it is never pushed back.
@MainActor
final class CallSyncCoordinator: ObservableObject {
    @Published private(set) var statuses: [CallServiceID: CallServiceStatus] = [:]
    private var statusTimer: Timer?
    static let echoWindow: TimeInterval = 0.3
    /// Lets the service mute itself before HAL mute lands (avoids Meet's "muted by system").
    static let serviceHeadStart: TimeInterval = 0.15

    private let mic: MicController
    private let preferences: PreferencesStore
    private var services: [CallServiceID: CallService] = [:]
    private var inCall: [CallServiceID: Bool] = [:]
    private var lastPushAt: [CallServiceID: TimeInterval] = [:]
    private var applyingRemote = false
    private var cancellables = Set<AnyCancellable>()

    /// Called after a service changed LockMic's mute so UI (HUD, icon, sound) can refresh.
    var onRemoteMuteApplied: (() -> Void)?

    init(mic: MicController, preferences: PreferencesStore, services: [CallService]) {
        self.mic = mic
        self.preferences = preferences
        for service in services {
            self.services[service.id] = service
            service.onEvent = { [weak self, weak service] event in
                guard let service else { return }
                self?.handle(event, from: service)
            }
        }
        mic.muteInterceptor = { [weak self] muted in self?.localMuteRequested(muted) ?? 0 }
        mic.shouldEnforceMute = { [weak self] in self.map { !$0.hasSyncedCall } ?? true }
    }

    func start() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatuses() }
        }
        RunLoop.main.add(t, forMode: .common)
        statusTimer = t
        preferences.$callSyncMeetEnabled.sink { [weak self] in self?.apply(.meet, enabled: $0) }.store(in: &cancellables)
        preferences.$callSyncTeamsEnabled.sink { [weak self] in self?.apply(.teams, enabled: $0) }.store(in: &cancellables)
        preferences.$callSyncZoomEnabled.sink { [weak self] in self?.apply(.zoom, enabled: $0) }.store(in: &cancellables)
    }

    func refreshStatuses() {
        let next = services.mapValues(\.status)
        if next != statuses { statuses = next }
    }

    func stop() {
        statusTimer?.invalidate()
        cancellables.removeAll()
        services.values.forEach { $0.stop() }
    }

    /// A call service is connected to a live call: do not fight its unmute.
    private var hasSyncedCall: Bool {
        services.values.contains { $0.hasActiveCall }
    }

    private func apply(_ id: CallServiceID, enabled: Bool) {
        guard let service = services[id] else { return }
        if enabled {
            service.start()
            refreshStatuses()
        } else {
            service.stop()
            inCall[id] = false
            refreshStatuses()
        }
    }

    /// LockMic changed (hotkey, menu bar, HUD, push-to-talk). Returns the HAL write delay.
    private func localMuteRequested(_ muted: Bool) -> TimeInterval {
        guard !applyingRemote else { return 0 }
        var pushed = false
        for service in services.values where service.hasActiveCall {
            lastPushAt[service.id] = now
            service.push(muted: muted)
            pushed = true
        }
        return (pushed && muted) ? Self.serviceHeadStart : 0
    }

    private func handle(_ event: CallServiceEvent, from service: CallService) {
        let id = service.id
        let wasInCall = inCall[id] ?? false
        inCall[id] = event.inCall
        guard event.inCall else { return }

        if !wasInCall {
            // Joining: LockMic is the source of truth, so a call joined while muted stays muted.
            if event.muted != mic.effectiveMuted {
                lastPushAt[id] = now
                service.push(muted: mic.effectiveMuted)
            }
            return
        }
        guard let muted = event.muted, muted != mic.effectiveMuted else { return }
        if now - (lastPushAt[id] ?? 0) < Self.echoWindow { return }

        log.debug("remote \(id.rawValue, privacy: .public) muted=\(muted, privacy: .public)")
        applyingRemote = true
        mic.setMuted(muted)
        applyingRemote = false
        // Mirror to any other synced service (the active call may be on another app).
        for other in services.values where other.id != id && other.hasActiveCall {
            lastPushAt[other.id] = now
            other.push(muted: muted)
        }
        onRemoteMuteApplied?()
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
