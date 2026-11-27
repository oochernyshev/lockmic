import Foundation

/// One service reachable in several ways (e.g. Teams app + Teams in a browser). Events from every
/// child are merged: in a call while any child is, muted state from whichever child reported it.
@MainActor
final class CompositeCallService: CallService {
    let id: CallServiceID
    var onEvent: ((CallServiceEvent) -> Void)?
    private let children: [CallService]

    init(id: CallServiceID, children: [CallService]) {
        self.id = id
        self.children = children
        for child in children {
            child.onEvent = { [weak self] event in self?.forward(event) }
        }
    }

    var hasActiveCall: Bool { children.contains { $0.hasActiveCall } }
    var appDetected: Bool { children.contains { $0.appDetected } }

    var status: CallServiceStatus {
        let all = children.map(\.status)
        for wanted in [CallServiceStatus.inCall, .connected, .needsAccess, .waiting] where all.contains(wanted) {
            return wanted
        }
        return .off
    }

    func start() { children.forEach { $0.start() } }
    func stop() { children.forEach { $0.stop() } }
    func push(muted: Bool) { children.forEach { $0.push(muted: muted) } }

    private func forward(_ event: CallServiceEvent) {
        // A child leaving a call must not end the call while another child is still in one.
        onEvent?(CallServiceEvent(muted: event.muted, inCall: event.inCall || hasActiveCall))
    }
}
