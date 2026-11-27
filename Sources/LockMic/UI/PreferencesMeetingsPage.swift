import SwiftUI

struct PreferencesMeetingsPage: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var meetings: MeetingAlertCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: PreferencesChrome.pageSpacing) {
            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader(L10n.meetingsHeader)
                Toggle(L10n.meetingsEnable, isOn: enableBinding)
                    .disabled(!preferences.featuresEnabled)
                PreferencesChrome.caption(L10n.meetingsEnableCaption)
                Toggle(L10n.meetingsSound, isOn: $preferences.meetingAlertSoundEnabled)
                    .disabled(!preferences.featuresEnabled || !preferences.meetingAlertsEnabled)
                PreferencesChrome.caption(L10n.meetingsSoundCaption)
                Toggle(L10n.meetingsSoundAllOutputs, isOn: $preferences.meetingAlertSoundAllOutputs)
                    .disabled(!preferences.featuresEnabled || !preferences.meetingAlertsEnabled || !preferences.meetingAlertSoundEnabled)
                PreferencesChrome.caption(L10n.meetingsSoundAllOutputsCaption)
            }
            .opacity(preferences.featuresEnabled ? 1 : 0.45)

            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader(L10n.meetingsPreviewHeader)
                MeetingAlertPreview(soundEnabled: preferences.meetingAlertSoundEnabled)
                Button(L10n.meetingsPreviewPosition) {
                    meetings.showPositioningCard()
                }
                .focusable(false)
                .focusEffectDisabled()
                PreferencesChrome.caption(L10n.meetingsPreviewPositionCaption)
            }

            PreferencesChrome.sectionCard {
                CalendarAccessRow(meetings: meetings)
                PreferencesChrome.caption(L10n.meetingsAccessCaption)
            }
        }
        .onAppear {
            meetings.refreshAccess()
        }
    }

    private var enableBinding: Binding<Bool> {
        Binding(
            get: { preferences.meetingAlertsEnabled },
            set: { newValue in
                preferences.meetingAlertsEnabled = newValue
                if newValue {
                    meetings.requestAccessAndEnable()
                }
            }
        )
    }
}
