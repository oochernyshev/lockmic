import SwiftUI

struct PreferencesAboutPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PreferencesChrome.pageSpacing) {
            PreferencesChrome.sectionCard {
                HStack(spacing: 14) {
                    Image("AppLogo")
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("LockMic")
                            .font(.title2.weight(.semibold))
                        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("by WIXEE.AI")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                PreferencesChrome.caption(
                    "LockMic mutes your input at the system level so it works in every app."
                )
            }

            PreferencesChrome.sectionCard {
                VStack(alignment: .leading, spacing: 8) {
                    aboutMetaRow(label: "Website") {
                        Link("wixee.ai", destination: URL(string: "https://wixee.ai")!)
                            .font(.body)
                            .focusable(false)
                            .focusEffectDisabled()
                    }
                    aboutMetaRow(label: "Owner") {
                        Text("WIXEE.AI")
                    }
                    aboutMetaRow(label: "License") {
                        Text("MIT License")
                    }
                    Text("Copyright © 2026 WIXEE.AI")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func aboutMetaRow<Content: View>(label: String, @ViewBuilder value: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            value()
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
