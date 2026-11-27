import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "CompositeCall")

/// One service reachable in several ways (e.g. Teams app + Teams in a browser), kept in one mute
/// state: LockMic's pushes go to every child; a change the user makes in one child is mirrored to
/// the others; a child that enters a call while another is already in one adopts the current state
/// instead of being taken for a user change.
@MainActor
final class CompositeCallService: CallService {
    let id: CallServiceID
    var onEvent: ((CallServiceEvent) -> Void)?
    private let children: [CallService]
    /// Mute state all children are supposed to share (last pushed or last user change).
    private var synced: Bool?
    private var wasInCall: [ObjectIdentifier: Bool] = [:]
    /// Set by the coordinator: true when a state is a late echo of an older, superseded write.
    var isStaleEcho: ((Bool) -> Bool)?

    init(id: CallServiceID, children: [CallService]) {
        self.id = id
        self.children = children
        for child in children {
            child.onEvent = { [weak self, weak child] event in
                guard let child else { return }
                self?.handle(event, from: child)
            }
        }
    }

    var hasActiveCall: Bool { children.contains { $0.hasActiveCall } }
    var appDetected: Bool { children.contains { $0.appDetected } }
    var callCount: Int { children.reduce(0) { $0 + $1.callCount } }
    var backgroundCallTabs: Int { children.reduce(0) { $0 + $1.backgroundCallTabs } }

    var status: CallServiceStatus {
        let all = children.map(\.status)
        for wanted in [CallServiceStatus.inCall, .connected, .needsAccess, .waiting] where all.contains(wanted) {
            return wanted
        }
        return .off
    }

    func start() { children.forEach { $0.start() } }

    func stop() {
        children.forEach { $0.stop() }
        wasInCall = [:]
        synced = nil
    }

    func push(muted: Bool) {
        synced = muted
        children.forEach { $0.push(muted: muted) }
    }

    private func handle(_ event: CallServiceEvent, from child: CallService) {
        let key = ObjectIdentifier(child)
        let before = wasInCall[key] ?? false
        wasInCall[key] = event.inCall
        let others = children.filter { $0 !== child && $0.hasActiveCall }
        if before, event.inCall, let muted = event.muted, isStaleEcho?(muted) == true { return }
        log.info("\(self.id.rawValue, privacy: .public) child=\(String(describing: type(of: child)), privacy: .public) inCall=\(event.inCall, privacy: .public) muted=\(event.muted.map { String($0) } ?? "nil", privacy: .public) wasInCall=\(before, privacy: .public) others=\(others.count, privacy: .public) synced=\(self.synced.map { String($0) } ?? "nil", privacy: .public)")

        if event.inCall, !before, !others.isEmpty, let synced {
            // Joined while another child is already in a call: adopt the shared state.
            if event.muted != synced { child.push(muted: synced) }
            return
        }

        if event.inCall, let muted = event.muted, muted != synced {
            synced = muted
            for other in others { other.push(muted: muted) }
        }
        // A child leaving must not end the service's call while another child is still in one.
        onEvent?(CallServiceEvent(muted: event.muted, inCall: event.inCall || !others.isEmpty))
    }
}
