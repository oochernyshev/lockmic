import Foundation

/// One call app LockMic keeps in two-way mute sync with.
@MainActor
protocol CallService: AnyObject {
    var id: CallServiceID { get }
    /// True while there is a live link AND an active call to sync with.
    var hasActiveCall: Bool { get }
    var status: CallServiceStatus { get }
    /// The target app (or, for Meet, the browser extension) is reachable right now.
    var appDetected: Bool { get }
    /// Calls currently synced through this service (apps, tabs, windows).
    var callCount: Int { get }
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

enum CallServiceStatus: Equatable, Sendable {
    case off
    /// Enabled, but the service or its link is not reachable yet.
    case waiting
    /// Needs a system permission (Zoom: Accessibility).
    case needsAccess
    /// Linked; no call in progress.
    case connected
    /// Linked and syncing an active call.
    case inCall
}
