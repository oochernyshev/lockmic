import SwiftUI

/// System Settings–style preferences: sidebar + detail, resizable frosted window.
struct PreferencesView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var mic: MicController
    @State private var selection: PreferencesTab = .general

    private let sidebarWidth: CGFloat = 168

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)

            Divider()

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(
            minWidth: PreferencesChrome.windowMinSize.width,
            idealWidth: PreferencesChrome.windowIdealSize.width,
            minHeight: PreferencesChrome.windowMinSize.height,
            idealHeight: PreferencesChrome.windowIdealSize.height
        )
        .background(.regularMaterial)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(PreferencesTab.allCases) { tab in
                sidebarRow(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    private func sidebarRow(_ tab: PreferencesTab) -> some View {
        let selected = selection == tab
        return Button {
            selection = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.systemImage)
                    .font(.body.weight(.medium))
                    .frame(width: 20, alignment: .center)
                    .symbolRenderingMode(.hierarchical)
                Text(tab.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
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
                case .keyboard:
                    PreferencesKeyboardPage(preferences: preferences)
                case .about:
                    PreferencesAboutPage()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
