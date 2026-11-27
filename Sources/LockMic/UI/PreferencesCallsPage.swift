import ApplicationServices
import SwiftUI

/// Preferences → Sync: three independent switches (web calls, Teams app, Zoom app).
struct PreferencesCallsPage: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var callSync: CallSyncCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: PreferencesChrome.pageSpacing) {
            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader(L10n.callsHeader)
                PreferencesChrome.caption(L10n.callsIntro)
                if preferences.syncWebEnabled || preferences.syncTeamsAppEnabled || preferences.syncZoomAppEnabled {
                    Divider()
                    AccessibilityAccessRow(boxed: false)
                }
            }

            PreferencesChrome.sectionCard {
                Toggle(L10n.syncWeb, isOn: $preferences.syncWebEnabled)
                PreferencesChrome.caption(L10n.syncWebCaption)
                if preferences.syncWebEnabled {
                    webRow(L10n.callsMeet, .webMeet)
                    webRow(L10n.callsTeams, .webTeams)
                    webRow(L10n.callsZoom, .webZoom)
                }
            }

            PreferencesChrome.sectionCard {
                Toggle(L10n.syncTeamsApp, isOn: $preferences.syncTeamsAppEnabled)
                if preferences.syncTeamsAppEnabled {
                    appRow(.teamsApp)
                }
            }

            PreferencesChrome.sectionCard {
                Toggle(L10n.syncZoomApp, isOn: $preferences.syncZoomAppEnabled)
                if preferences.syncZoomAppEnabled {
                    appRow(.zoomApp)
                }
            }
        }
        .onAppear { callSync.refreshStatuses() }
    }

    private func appRow(_ id: SyncSourceID) -> some View {
        let snapshot = callSync.snapshots[id] ?? SyncSourceSnapshot()
        let (text, color) = display(snapshot)
        return PreferencesChrome.statusRow(title: L10n.callsStatus, text: text, color: color)
    }

    private func webRow(_ name: String, _ id: SyncSourceID) -> some View {
        let snapshot = callSync.snapshots[id] ?? SyncSourceSnapshot()
        let (text, color) = display(snapshot, web: true)
        return VStack(alignment: .leading, spacing: 2) {
            PreferencesChrome.statusRow(title: name, text: text, color: color)
            if snapshot.backgroundTabs > 0 {
                Text(L10n.callsBackgroundTabs(snapshot.backgroundTabs))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func display(_ snapshot: SyncSourceSnapshot, web: Bool = false) -> (String, Color) {
        if web { return displayWeb(snapshot) }
        switch snapshot.status {
        case .off: return (L10n.callsStatusOff, .secondary)
        case .waiting: return (L10n.callsStatusWaiting, .orange)
        // The warning below explains the missing permission; here only say what was found.
        case .needsAccess:
            return (snapshot.detected ? L10n.callsDetected : L10n.callsNotDetected, .orange)
        case .connected: return (L10n.callsStatusConnected, .green)
        case .inCall:
            return (L10n.callsStatusInCall, .green)
        }
    }

    /// Web calls live in browser tabs, so say "tab", not "app".
    private func displayWeb(_ snapshot: SyncSourceSnapshot) -> (String, Color) {
        switch snapshot.status {
        case .off: return (L10n.callsStatusOff, .secondary)
        case .waiting: return (L10n.syncWebNoTab, .orange)
        // The warning below explains the missing permission; here only say what was found.
        case .needsAccess: return (snapshot.detected ? L10n.syncWebTabFound : L10n.syncWebNoTab, .orange)
        case .connected: return (L10n.syncWebTabNoCall, .green)
        case .inCall: return (L10n.syncWebSyncing, .green)
        }
    }
}
