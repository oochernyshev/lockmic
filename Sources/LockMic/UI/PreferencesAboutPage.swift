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

    private static let brewUpdateCommand = """
    brew update
    brew reinstall --cask --yes lockmic
    xattr -dr com.apple.quarantine /Applications/LockMic.app
    open /Applications/LockMic.app
    """

    @State private var availableUpdate: AppUpdateInfo?
    @State private var checkStatus: UpdateCheckStatus = .idle
    @State private var brewCopied = false

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var preferHomebrew: Bool {
        AppInstallMethod.detect() == .homebrew
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
                        Text(L10n.aboutVersion(currentVersion))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(L10n.aboutBy)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                PreferencesChrome.caption(L10n.aboutCaption)

                if availableUpdate == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            UpdateChecker.shared.checkNow(userInitiated: true)
                        } label: {
                            Label(
                                checkStatus == .checking ? L10n.aboutUpdateChecking : L10n.menuCheckForUpdates,
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(checkStatus == .checking)

                        if let message = statusMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(checkStatus == .failed ? Color.red.opacity(0.9) : Color.secondary)
                        }
                    }
                    .padding(.top, 4)
                }
            }

            if let update = availableUpdate {
                updateCard(update)
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
        .onAppear(perform: syncFromChecker)
        .onReceive(NotificationCenter.default.publisher(for: .lockMicUpdatesDidChange)) { _ in
            syncFromChecker()
        }
    }

    private var statusMessage: String? {
        switch checkStatus {
        case .idle: return nil
        case .checking: return L10n.aboutUpdateChecking
        case .upToDate: return L10n.aboutUpdateUpToDate
        case .failed: return L10n.aboutUpdateFailed
        }
    }

    private func syncFromChecker() {
        availableUpdate = UpdateChecker.shared.availableUpdate
        checkStatus = UpdateChecker.shared.checkStatus
    }

    // MARK: - Update available

    private func updateCard(_ update: AppUpdateInfo) -> some View {
        PreferencesChrome.sectionCard {
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                PreferencesChrome.sectionHeader(L10n.aboutUpdateHeader)
                Spacer(minLength: 0)
            }

            Text(L10n.aboutUpdateAvailable(update.version, currentVersion))
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            PreferencesChrome.caption(detectedCaption)

            if preferHomebrew {
                brewBlock
                dmgAndSkip(prominentDMG: false)
                    .padding(.top, 6)
                PreferencesChrome.caption(L10n.aboutUpdateDmgAlternate)
            } else {
                dmgAndSkip(prominentDMG: true)
                    .padding(.top, 2)
                PreferencesChrome.sectionHeader(L10n.aboutUpdateHomebrewHeader)
                    .padding(.top, 8)
                PreferencesChrome.caption(
                    AppInstallMethod.detect() == .direct
                        ? L10n.aboutUpdateHomebrewAlternate
                        : L10n.aboutUpdateHomebrewCaption
                )
                brewBlock
            }
        }
    }

    private var detectedCaption: String {
        switch AppInstallMethod.detect() {
        case .homebrew: return L10n.aboutUpdateDetectedHomebrew
        case .direct: return L10n.aboutUpdateDetectedDirect
        case .unknown: return L10n.aboutUpdateDetectedUnknown
        }
    }

    private func dmgAndSkip(prominentDMG: Bool) -> some View {
        HStack(spacing: 10) {
            if prominentDMG {
                Button {
                    UpdateChecker.shared.openUpdate()
                } label: {
                    Label(L10n.aboutUpdateDownloadDMG, systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            } else {
                Button {
                    UpdateChecker.shared.openUpdate()
                } label: {
                    Label(L10n.aboutUpdateDownloadDMG, systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            Button {
                UpdateChecker.shared.skipAvailableUpdate()
            } label: {
                Text(L10n.menuSkipUpdate)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var brewBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if preferHomebrew {
                PreferencesChrome.sectionHeader(L10n.aboutUpdateHomebrewHeader)
                PreferencesChrome.caption(L10n.aboutUpdateHomebrewCaption)
            }
            HStack {
                Text(L10n.aboutUpdateHomebrewLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(brewCopied ? L10n.aboutUpdateCopied : L10n.aboutUpdateCopy) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        Self.brewUpdateCommand.trimmingCharacters(in: .whitespacesAndNewlines),
                        forType: .string
                    )
                    brewCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { brewCopied = false }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            Text(Self.brewUpdateCommand.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        }
    }

    private func feedbackButton(title: String, systemImage: String, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
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
