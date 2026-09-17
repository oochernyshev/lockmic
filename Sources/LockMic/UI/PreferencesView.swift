import SwiftUI

struct PreferencesAppIcon: View {
    let size: CGFloat
    let muted: Bool

    var body: some View {
        Image("AppLogo")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: size * 0.06, y: size * 0.02)
            .overlay(alignment: .topTrailing) {
                if muted {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: size * 0.15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: size * 0.34, height: size * 0.34)
                        .background(Color.red, in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.92), lineWidth: max(1, size * 0.015)))
                        .shadow(color: .black.opacity(0.25), radius: size * 0.025, y: size * 0.015)
                        .offset(x: size * 0.04, y: -size * 0.04)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.16), value: muted)
    }
}

/// System Settings–style preferences: sidebar + detail, resizable frosted window.
struct PreferencesView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var mic: MicController
    /// Not `@ObservedObject` — live meter ticks would rebuild this whole window
    /// and crash SwiftUI buttons (`MainActor.assumeIsolated`) while recording.
    let recorder: SessionRecorder
    @State private var selection: PreferencesTab
    @State private var updateAvailable = UpdateChecker.shared.availableUpdate != nil

    init(
        preferences: PreferencesStore,
        mic: MicController,
        recorder: SessionRecorder,
        initialTab: PreferencesTab = .general
    ) {
        self.preferences = preferences
        self.mic = mic
        self.recorder = recorder
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 160, ideal: 168, max: 220)
        } detail: {
            detailPane
        }
        .frame(
            minWidth: PreferencesChrome.windowMinSize.width,
            idealWidth: PreferencesChrome.windowIdealSize.width,
            minHeight: PreferencesChrome.windowMinSize.height,
            idealHeight: PreferencesChrome.windowIdealSize.height
        )
        .background(.ultraThinMaterial)
        .onReceive(NotificationCenter.default.publisher(for: .lockMicOpenPreferencesTab)) { note in
            if let raw = note.object as? String, let tab = PreferencesTab(rawValue: raw) {
                selection = tab
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lockMicUpdatesDidChange)) { _ in
            updateAvailable = UpdateChecker.shared.availableUpdate != nil
        }
        .onAppear {
            updateAvailable = UpdateChecker.shared.availableUpdate != nil
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                sidebarBrand
                    .listRowSeparator(.hidden)
            }
            ForEach(PreferencesTab.allCases) { tab in
                HStack {
                    Label(tab.title, systemImage: tab.systemImage)
                        .symbolRenderingMode(.hierarchical)
                    if tab == .about && updateAvailable {
                        Spacer(minLength: 4)
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                    }
                }
                .tag(tab)
            }
        }
        .listStyle(.sidebar)
    }

    private var sidebarBrand: some View {
        HStack(spacing: 10) {
            PreferencesAppIcon(size: 28, muted: mic.effectiveMuted)

            VStack(alignment: .leading, spacing: 1) {
                Text("LockMic")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(L10n.preferencesTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var detailPane: some View {
        ScrollView(.vertical, showsIndicators: true) {
            Group {
                switch selection {
                case .general:
                    PreferencesGeneralPage(preferences: preferences, mic: mic)
                case .devices:
                    PreferencesDevicesPage(preferences: preferences, mic: mic)
                        .disabled(!preferences.featuresEnabled)
                        .opacity(preferences.featuresEnabled ? 1 : 0.45)
                case .recording:
                    PreferencesRecordingPage(preferences: preferences, recorder: recorder)
                        .disabled(!preferences.featuresEnabled)
                        .opacity(preferences.featuresEnabled ? 1 : 0.45)
                case .keyboard:
                    PreferencesKeyboardPage(preferences: preferences)
                        .disabled(!preferences.featuresEnabled)
                        .opacity(preferences.featuresEnabled ? 1 : 0.45)
                case .about:
                    PreferencesAboutPage(mic: mic)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .thinScrollIndicators()
        }
    }
}
