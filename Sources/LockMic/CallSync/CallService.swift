import Foundation

/// One call app LockMic keeps in two-way mute sync with.
@MainActor
protocol CallService: AnyObject {
    var id: CallServiceID { get }
    /// True while there is a live link AND an active call to sync with.
    var hasActiveCall: Bool { get }
    /// Called with every observed service-side state change.
    var onEvent: ((CallServiceEvent) -> Void)? { get set }
    func start()
    func stop()
    /// Apply LockMic's mute state in the service. Must be a no-op when there is no call.
    func push(muted: Bool)
}

enum CallServiceID: String, CaseIterable, Sendable {
    case meet, teams, zoom
}

struct CallServiceEvent: Sendable {
    /// Mute state as shown by the service, `nil` when unknown.
    let muted: Bool?
    let inCall: Bool
}
