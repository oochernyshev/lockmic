import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PreferencesRecordingPage: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var recorder: SessionRecorder
    @State private var pickingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: PreferencesChrome.pageSpacing) {
            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader(L10n.recordingStatusHeader)
                PreferencesChrome.statusRow(
                    title: L10n.recordingStatusSession,
                    text: recorder.isRecording ? L10n.recordingStatusRecording : L10n.recordingStatusIdle,
                    color: recorder.isRecording ? .red : .secondary
                )
                if let error = recorder.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                PreferencesChrome.caption(L10n.recordingMicCaption)
            }

            if recorder.isRecording {
                PreferencesChrome.sectionCard {
                    PreferencesChrome.caption(L10n.recordingMonitorHint)
                }
            }

            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader(L10n.recordingFolderHeader)
                Text(preferences.recordingsFolderDisplayPath)
                    .font(.body.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    prefsTextButton(L10n.recordingFolderChoose) { pickingFolder = true }
                    prefsTextButton(L10n.recordingFolderReveal) { revealRecordingsFolder() }
                    if !preferences.usesDefaultRecordingsFolder {
                        prefsTextButton(L10n.recordingFolderReset) {
                            preferences.resetRecordingsFolder()
                        }
                    }
                }
                PreferencesChrome.caption(L10n.recordingFolderCaption)
            }

            PreferencesChrome.sectionCard {
                HStack(alignment: .firstTextBaseline) {
                    PreferencesChrome.sectionHeader(L10n.recordingQualityHeader)
                    Spacer(minLength: 8)
                    Text(L10n.recordingQualityUnit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                qualityPicker
                Text(qualitySizeEstimate)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                PreferencesChrome.caption(L10n.recordingQualityCaption)
            }

            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader(L10n.recordingInputsHeader)
                prefsCheckRow(L10n.recordingFollowDefaultMic, isOn: preferences.followDefaultMic) {
                    preferences.followDefaultMic.toggle()
                    if recorder.isRecording {
                        recorder.setFollowDefaultInput(preferences.followDefaultMic)
                    }
                }
                PreferencesChrome.caption(L10n.recordingFollowDefaultMicCaption)
            }

            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader(L10n.recordingPlaybackHeader)
                prefsCheckRow(L10n.recordingFollowDefaultOutput, isOn: preferences.followDefaultOutput) {
                    preferences.followDefaultOutput.toggle()
                    if preferences.followDefaultOutput {
                        preferences.recordAllPlayback = false
                    }
                    if recorder.isRecording {
                        recorder.setFollowDefaultOutput(preferences.followDefaultOutput)
                    }
                }
                PreferencesChrome.caption(L10n.recordingFollowDefaultOutputCaption)
                prefsCheckRow(L10n.recordingPlaybackToggle, isOn: preferences.recordAllPlayback) {
                    preferences.recordAllPlayback.toggle()
                    if preferences.recordAllPlayback {
                        preferences.followDefaultOutput = false
                        if recorder.isRecording {
                            recorder.setFollowDefaultOutput(false)
                        }
                    }
                }
                PreferencesChrome.caption(
                    preferences.recordAllPlayback
                        ? L10n.recordingPlaybackCaptionAll
                        : L10n.recordingPlaybackCaptionDefault
                )
            }

            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader(L10n.recordingMonitorTitle)
                prefsCheckRow(L10n.recordingMonitorUnselected, isOn: preferences.monitorUnselectedDevices) {
                    preferences.monitorUnselectedDevices.toggle()
                    recorder.setMonitorUnselectedDevices(preferences.monitorUnselectedDevices)
                }
                PreferencesChrome.caption(L10n.recordingMonitorUnselectedCaption)
            }
        }
        .fileImporter(
            isPresented: $pickingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            preferences.setRecordingsFolder(url)
        }
    }

    private var qualityPicker: some View {
        HStack(spacing: 0) {
            ForEach(RecordingBitRate.allCases, id: \.self) { rate in
                let selected = preferences.recordingBitRate == rate
                Text(verbatim: "\(rate.rawValue)")
                    .font(.callout.monospacedDigit().weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(selected ? Color.accentColor.opacity(0.22) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { preferences.recordingBitRate = rate }
            }
        }
        .background(Color.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var qualitySizeEstimate: String {
        let rate = preferences.recordingBitRate
        return L10n.recordingQualitySize(
            tenMinutes: rate.formattedSessionSize(duration: 10 * 60),
            hour: rate.formattedSessionSize(duration: 60 * 60)
        )
    }

    private func prefsCheckRow(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { _ in action() }))
            .toggleStyle(.checkbox)
    }

    private func prefsTextButton(_ title: String, action: @escaping () -> Void) -> some View {
        Text(title)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    private func revealRecordingsFolder() {
        let folder = preferences.recordingsDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
