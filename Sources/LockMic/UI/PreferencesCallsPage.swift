import ApplicationServices
import SwiftUI

struct PreferencesCallsPage: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var callSync: CallSyncCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: PreferencesChrome.pageSpacing) {
            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader(L10n.callsHeader)
                PreferencesChrome.caption(L10n.callsIntro)
            }
            service(L10n.callsMeet, .meet, $preferences.callSyncMeetEnabled, L10n.callsMeetCaption)
            service(L10n.callsTeams, .teams, $preferences.callSyncTeamsEnabled, nil)
            service(L10n.callsZoom, .zoom, $preferences.callSyncZoomEnabled, nil)
        }
        .onAppear { callSync.refreshStatuses() }
    }

    private func service(
        _ title: String, _ id: CallServiceID, _ binding: Binding<Bool>, _ caption: String?
    ) -> some View {
        PreferencesChrome.sectionCard {
            Toggle(title, isOn: binding)
            if binding.wrappedValue {
                let (text, color) = display(callSync.statuses[id] ?? .waiting, id, found: callSync.detected[id] ?? false)
                PreferencesChrome.statusRow(title: L10n.callsStatus, text: text, color: color)
            }
            if let caption {
                PreferencesChrome.caption(caption)
            }
            if binding.wrappedValue, id != .meet, !AXIsProcessTrusted() {
                Text(L10n.callsZoomAccess)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func display(_ status: CallServiceStatus, _ id: CallServiceID, found: Bool) -> (String, Color) {
        switch status {
        case .off: return (L10n.callsStatusOff, .secondary)
        case .waiting: return (id == .meet ? L10n.callsStatusWaitingMeet : L10n.callsStatusWaiting, .orange)
        // The warning below explains the missing permission; here only say what was found.
        case .needsAccess: return (found ? L10n.callsDetected : L10n.callsNotDetected, .orange)
        case .connected: return (L10n.callsStatusConnected, .green)
        case .inCall: return (L10n.callsStatusInCall, .green)
        }
    }
}
