import Combine
import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "CallSync")

/// Keeps LockMic's mute and the active call service's mute identical in both directions.
///
/// Loop protection: every change we push gets a timestamp; service events arriving within
/// `echoWindow` of our own push are treated as the echo of that command and ignored.
/// A service-side change applied to LockMic is flagged so it is never pushed back.
/// One independently switchable way of reaching a call service.
enum SyncSourceID: String, CaseIterable, Sendable {
    case webMeet, webTeams, webZoom, teamsApp, zoomApp
}

struct SyncSource {
    let id: SyncSourceID
    let service: CallService
    let enabled: AnyPublisher<Bool, Never>
}

struct SyncSourceSnapshot: Equatable {
    var status: CallServiceStatus = .off
    var detected = false
    var calls = 0
    var backgroundTabs = 0
}

@MainActor
final class CallSyncCoordinator: ObservableObject {
    @Published private(set) var snapshots: [SyncSourceID: SyncSourceSnapshot] = [:]
    private let sources: [SyncSource]
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
    /// Mute values we applied (as consequences of operations), newest last. Services follow the
    /// system mute with a lag, so a late echo of an older write must not override a newer operation.
    private var writes: [(value: Bool, at: TimeInterval)] = []
    static let echoLag: TimeInterval = 2.5
    /// Reconciliation runs once the state has been quiet for this long.
    static let settleTime: TimeInterval = 2.5
    private var lastChangeAt: TimeInterval = 0
    private var observedBefore: [CallServiceID: Bool] = [:]
    private var observedChangedAt: [CallServiceID: TimeInterval] = [:]
    private var cancellables = Set<AnyCancellable>()

    /// Called after a service changed LockMic's mute so UI (HUD, icon, sound) can refresh.
    var onRemoteMuteApplied: (() -> Void)?

    /// - Parameters:
    ///   - services: the merged per-service views that carry events (Meet, Teams, Zoom).
    ///   - sources: the individually switchable ways of reaching them (web, Teams app, Zoom app).
    init(mic: MicController, preferences: PreferencesStore, services: [CallService], sources: [SyncSource]) {
        self.sources = sources
        self.mic = mic
        self.preferences = preferences
        for service in services {
            self.services[service.id] = service
            service.onEvent = { [weak self, weak service] event in
                guard let service else { return }
                self?.handle(event, from: service)
            }
        }
        for service in services { (service as? CompositeCallService)?.isStaleEcho = { [weak self] in self?.isStaleEcho($0) ?? false } }
        mic.muteInterceptor = { [weak self] muted in self?.localMuteRequested(muted) ?? 0 }
        mic.shouldEnforceMute = { [weak self] in self.map { !$0.hasSyncedCall || $0.preferences.muteMethod == .volume } ?? true }
    }

    func start() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatuses() }
        }
        RunLoop.main.add(t, forMode: .common)
        statusTimer = t
        for source in sources {
            source.enabled.removeDuplicates().sink { [weak self] enabled in
                if enabled { source.service.start() } else { source.service.stop() }
                if !enabled { self?.sourceStopped(source) }
                self?.refreshStatuses()
            }.store(in: &cancellables)
        }
    }

    func refreshStatuses() {
        var next: [SyncSourceID: SyncSourceSnapshot] = [:]
        for source in sources {
            let service = source.service
            next[source.id] = SyncSourceSnapshot(
                status: service.status,
                detected: service.appDetected,
                calls: service.callCount,
                backgroundTabs: service.backgroundCallTabs
            )
        }
        if next != snapshots { snapshots = next }
        reconcile()
    }

    private func sourceStopped(_ source: SyncSource) {
        // A service whose last source went away is no longer in a call.
        inCall[source.service.id] = services[source.service.id]?.hasActiveCall ?? false
    }

    func stop() {
        statusTimer?.invalidate()
        cancellables.removeAll()
        sources.forEach { $0.service.stop() }
    }

    /// A call service is connected to a live call: do not fight its unmute.
    private var hasSyncedCall: Bool {
        services.values.contains { $0.hasActiveCall }
    }

    /// LockMic changed (hotkey, menu bar, HUD, push-to-talk). Returns the HAL write delay.
    private func localMuteRequested(_ muted: Bool) -> TimeInterval {
        guard !applyingRemote else { return 0 }
        noteWrite(muted)
        var pushed = false
        log.info("local muted=\(muted, privacy: .public) remote=\(self.applyingRemote, privacy: .public) activeCalls=\(self.services.values.filter(\.hasActiveCall).map { $0.id.rawValue }.joined(separator: ","), privacy: .public)")
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
        if isStaleEcho(muted) {
            log.info("\(id.rawValue, privacy: .public) event muted=\(muted, privacy: .public) ignored as stale echo")
            return
        }
        if now - (lastPushAt[id] ?? 0) < Self.echoWindow {
            log.info("\(id.rawValue, privacy: .public) event muted=\(muted, privacy: .public) ignored as echo")
            return
        }

        log.info("remote \(id.rawValue, privacy: .public) muted=\(muted, privacy: .public)")
        adopt(muted, from: id)
    }

    /// A service made the latest change: LockMic and every other synced service follow it.
    private func adopt(_ muted: Bool, from id: CallServiceID) {
        noteWrite(muted)
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

    /// Regular check: a quick click can leave a service out of step when its event was dropped as an
    /// echo. Once things are quiet, the latest actor wins: a service that changed after LockMic's
    /// last change is adopted; otherwise LockMic's state is pushed to the service.
    private func reconcile() {
        let truth = mic.effectiveMuted
        let quiet = now - lastChangeAt > Self.settleTime
        for service in services.values where service.hasActiveCall {
            let id = service.id
            guard let observed = service.observedMuted(truth: truth) else { continue }
            if let before = observedBefore[id], before != observed { observedChangedAt[id] = now }
            observedBefore[id] = observed
            guard quiet, observed != truth else { continue }
            if (observedChangedAt[id] ?? 0) > lastChangeAt {
                log.info("reconcile: \(id.rawValue, privacy: .public) changed last, adopting muted=\(observed, privacy: .public)")
                adopt(observed, from: id)
            } else {
                log.info("reconcile: pushing muted=\(truth, privacy: .public) to \(id.rawValue, privacy: .public)")
                lastPushAt[id] = now
                service.push(muted: truth)
            }
        }
    }

    private func noteWrite(_ value: Bool) {
        writes.append((value, now))
        lastChangeAt = now
        writes.removeAll { now - $0.at > Self.echoLag * 2 }
    }

    /// A state that contradicts our latest write but equals an earlier, superseded one that is
    /// still within the services' follow-up lag: the service is catching up with the past.
    private func isStaleEcho(_ muted: Bool) -> Bool {
        let recent = writes.filter { now - $0.at < Self.echoLag }
        guard let latest = recent.last, latest.value != muted else { return false }
        return recent.dropLast().contains { $0.value == muted }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
