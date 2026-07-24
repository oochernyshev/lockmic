import AppKit
import SwiftUI

struct PreferencesAboutPage: View {
    private enum Links {
        static let site = URL(string: "https://lockmic.com/")!
        static let github = URL(string: "https://github.com/oochernyshev/lockmic")!
        static let feedback = URL(string: "https://github.com/oochernyshev/lockmic/issues/new?template=feedback.yml")!
        static let bug = URL(string: "https://github.com/oochernyshev/lockmic/issues/new?template=bug.yml")!
        static let feature = URL(string: "https://github.com/oochernyshev/lockmic/issues/new?template=feature.yml")!
        static let rate = URL(string: "https://lockmic.com/#rate")!
    }

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
                        Text(L10n.aboutVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(L10n.aboutBy)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                PreferencesChrome.caption(L10n.aboutCaption)
            }

            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader(L10n.aboutFeedbackHeader)
                PreferencesChrome.caption(L10n.aboutFeedbackCaption)
                VStack(alignment: .leading, spacing: 8) {
                    feedbackButton(title: L10n.aboutFeedbackSend, systemImage: "bubble.left.and.bubble.right", url: Links.feedback)
                    feedbackButton(title: L10n.aboutFeedbackBug, systemImage: "ladybug", url: Links.bug)
                    feedbackButton(title: L10n.aboutFeedbackFeature, systemImage: "lightbulb", url: Links.feature)
                    feedbackButton(title: L10n.aboutRateOnWeb, systemImage: "hand.thumbsup", url: Links.rate)
                }
                .padding(.top, 2)
            }

            PreferencesChrome.sectionCard {
                VStack(alignment: .leading, spacing: 8) {
                    aboutMetaRow(label: L10n.aboutWebsite) {
                        Link("lockmic.com", destination: Links.site)
                            .font(.body)
                            .focusable(false)
                            .focusEffectDisabled()
                    }
                    aboutMetaRow(label: L10n.aboutGitHub) {
                        Link("oochernyshev/lockmic", destination: Links.github)
                            .font(.body)
                            .focusable(false)
                            .focusEffectDisabled()
                    }
                    aboutMetaRow(label: L10n.aboutOwner) {
                        Text("WIXEE.AI")
                    }
                    aboutMetaRow(label: L10n.aboutLicense) {
                        Text(L10n.aboutLicenseValue)
                    }
                    Text(L10n.aboutCopyright)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func feedbackButton(title: String, systemImage: String, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 16, alignment: .center)
                    .foregroundStyle(.secondary)
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .focusable(false)
        .focusEffectDisabled()
    }

    private func aboutMetaRow<Content: View>(label: String, @ViewBuilder value: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            value()
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
