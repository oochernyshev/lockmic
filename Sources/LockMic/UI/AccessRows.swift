import ApplicationServices
import SwiftUI

/// One look for every permission LockMic asks for: icon, state, what it is for, and a button.
/// Used by the setup wizard and by Preferences, so they never drift apart.
struct AccessRow: View {
    struct Action {
        let title: String
        let perform: () -> Void
    }

    let granted: Bool
    /// SF Symbol shown while access is missing (the granted state always shows a green check).
    let neededIcon: String
    let title: String
    let detail: String
    var action: Action?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : neededIcon)
                .foregroundStyle(granted ? Color.green : Color.orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted, let action {
                Button(action.title, action: action.perform)
                    .focusable(false)
                    .focusEffectDisabled()
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Accessibility: lets LockMic sync mute with call apps.
struct AccessibilityAccessRow: View {
    @State private var granted = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        AccessRow(
            granted: granted,
            neededIcon: "hand.raised.fill",
            title: granted ? "Accessibility access granted" : "Accessibility access needed",
            detail: "Lets LockMic sync mute with Meet, Teams and Zoom.",
            action: .init(title: "Allow Access…") { AccessibilityPrompt.requestNow() }
        )
        .onReceive(timer) { _ in granted = AXIsProcessTrusted() }
    }
}

/// Calendar: lets LockMic show the countdown before meetings.
struct CalendarAccessRow: View {
    @ObservedObject var meetings: MeetingAlertCoordinator
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        AccessRow(
            granted: meetings.access == .granted,
            neededIcon: "calendar.badge.exclamationmark",
            title: title,
            detail: "Lets LockMic show the countdown before your meetings.",
            action: action
        )
        .onAppear { meetings.refreshAccess() }
        .onReceive(timer) { _ in meetings.refreshAccess() }
    }

    private var title: String {
        switch meetings.access {
        case .granted: return "Calendar access granted"
        case .notDetermined: return "Calendar access needed"
        case .denied: return "Calendar access is off"
        case .restricted: return "Calendar access is restricted"
        }
    }

    private var action: AccessRow.Action? {
        switch meetings.access {
        case .granted: return nil
        case .notDetermined: return .init(title: "Allow Access…") { meetings.requestAccessAndEnable() }
        case .denied, .restricted: return .init(title: "Open Settings…") { meetings.openPrivacySettings() }
        }
    }
}
