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
            }
            .opacity(preferences.featuresEnabled ? 1 : 0.45)

            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader(L10n.meetingsAccessHeader)
                PreferencesChrome.statusRow(
                    title: L10n.meetingsAccessStatus,
                    text: accessText,
                    color: accessColor
                )
                PreferencesChrome.caption(L10n.meetingsAccessCaption)

                if meetings.access != .granted {
                    Button(accessButtonTitle) {
                        if meetings.access == .notDetermined {
                            meetings.requestAccessAndEnable()
                        } else {
                            meetings.openPrivacySettings()
                        }
                    }
                    .focusable(false)
                    .focusEffectDisabled()
                }
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

    private var accessText: String {
        switch meetings.access {
        case .granted: return L10n.meetingsAccessGranted
        case .denied: return L10n.meetingsAccessDenied
        case .restricted: return L10n.meetingsAccessRestricted
        case .notDetermined: return L10n.meetingsAccessNotDetermined
        }
    }

    private var accessColor: Color {
        switch meetings.access {
        case .granted: return .green
        case .denied, .restricted: return .orange
        case .notDetermined: return .secondary
        }
    }

    private var accessButtonTitle: String {
        meetings.access == .notDetermined ? L10n.meetingsAccessButton : L10n.meetingsAccessOpenSettings
    }
}
