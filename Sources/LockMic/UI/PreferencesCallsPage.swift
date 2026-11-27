import SwiftUI

struct PreferencesCallsPage: View {
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: PreferencesChrome.pageSpacing) {
            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader(L10n.callsHeader)
                PreferencesChrome.caption(L10n.callsIntro)
            }
            PreferencesChrome.sectionCard {
                Toggle(L10n.callsMeet, isOn: $preferences.callSyncMeetEnabled)
                PreferencesChrome.caption(L10n.callsMeetCaption)
            }
            PreferencesChrome.sectionCard {
                Toggle(L10n.callsTeams, isOn: $preferences.callSyncTeamsEnabled)
                PreferencesChrome.caption(L10n.callsTeamsCaption)
            }
            PreferencesChrome.sectionCard {
                Toggle(L10n.callsZoom, isOn: $preferences.callSyncZoomEnabled)
                PreferencesChrome.caption(L10n.callsZoomCaption)
                if preferences.callSyncZoomEnabled, !ZoomBridge.hasAccess {
                    Text(L10n.callsZoomAccess)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
