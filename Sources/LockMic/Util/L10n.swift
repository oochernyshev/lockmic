import Foundation

/// Typed accessors for `Localizable.xcstrings`.
/// macOS picks the system language automatically from available localizations.
enum L10n {
    static func tr(_ key: String.LocalizationValue) -> String {
        String(localized: key)
    }

    static func format(_ key: String, _ args: CVarArg...) -> String {
        let template = String(localized: String.LocalizationValue(key))
        return String(format: template, locale: .current, arguments: args)
    }

    // MARK: - Tabs

    static var tabGeneral: String { tr("tab.general") }
    static var tabDevices: String { tr("tab.devices") }
    static var tabRecording: String { tr("tab.recording") }
    static var tabKeyboard: String { tr("tab.keyboard") }
    static var tabAbout: String { tr("tab.about") }

    // MARK: - Preferences shell

    static var preferencesTitle: String { tr("prefs.title") }

    // MARK: - General

    static var generalAnonymousHeader: String { tr("general.anonymous.header") }
    static var generalAnonymousToggle: String { tr("general.anonymous.toggle") }
    static var generalAnonymousCaption: String { tr("general.anonymous.caption") }
    static var generalAnonymousDisabled: String { tr("general.anonymous.disabled") }
    static var generalStatusHeader: String { tr("general.status.header") }
    static var generalStatusMicrophone: String { tr("general.status.microphone") }
    static var generalStatusDevice: String { tr("general.status.device") }
    static var generalStatusDisabled: String { tr("general.status.disabled") }
    static var generalStatusMuted: String { tr("general.status.muted") }
    static var generalStatusUnmuted: String { tr("general.status.unmuted") }
    static var generalStatusUnknown: String { tr("general.status.unknown") }
    static var generalStatusUnsupported: String { tr("general.status.unsupported") }
    static var generalOptionsHeader: String { tr("general.options.header") }
    static var generalOptionsHUD: String { tr("general.options.hud") }
    static var generalOptionsHUDCaption: String { tr("general.options.hud.caption") }
    static var generalOptionsFloating: String { tr("general.options.floating") }
    static var generalOptionsFloatingCaption: String { tr("general.options.floating.caption") }
    static var generalOptionsSound: String { tr("general.options.sound") }
    static var generalOptionsLogin: String { tr("general.options.login") }
    static var generalOptionsDock: String { tr("general.options.dock") }
    static var generalOptionsDockCaption: String { tr("general.options.dock.caption") }
    static var generalOptionsAppearance: String { tr("general.options.appearance") }
    static var generalOptionsAppearanceSystem: String { tr("general.options.appearance.system") }
    static var generalOptionsAppearanceLight: String { tr("general.options.appearance.light") }
    static var generalOptionsAppearanceDark: String { tr("general.options.appearance.dark") }

    // MARK: - Devices

    static var devicesScopeHeader: String { tr("devices.scope.header") }
    static var devicesScopeToggle: String { tr("devices.scope.toggle") }
    static var devicesScopeCaptionAll: String { tr("devices.scope.caption.all") }
    static var devicesScopeCaptionDefault: String { tr("devices.scope.caption.default") }
    static var devicesListHeader: String { tr("devices.list.header") }
    static var devicesListRefresh: String { tr("devices.list.refresh") }
    static var devicesListEmpty: String { tr("devices.list.empty") }
    static var devicesBadgeDefault: String { tr("devices.badge.default") }
    static var devicesBadgeVirtual: String { tr("devices.badge.virtual") }
    static var devicesSubtitleVirtual: String { tr("devices.subtitle.virtual") }
    static var devicesSubtitleNotControllable: String { tr("devices.subtitle.not_controllable") }
    static var devicesSubtitleOutsideScope: String { tr("devices.subtitle.outside_scope") }
    static var devicesSubtitleControlled: String { tr("devices.subtitle.controlled") }
    static var devicesSubtitleUnknown: String { tr("devices.subtitle.unknown") }
    static var devicesStatusMuted: String { tr("devices.status.muted") }
    static var devicesStatusUnmuted: String { tr("devices.status.unmuted") }
    static var devicesStatusIgnored: String { tr("devices.status.ignored") }
    static var devicesStatusDash: String { tr("devices.status.dash") }
    static var devicesStatusQuestion: String { tr("devices.status.question") }

    // MARK: - Recording

    static var recordingStatusHeader: String { tr("recording.status.header") }
    static var recordingStatusSession: String { tr("recording.status.session") }
    static var recordingStatusIdle: String { tr("recording.status.idle") }
    static var recordingStatusRecording: String { tr("recording.status.recording") }
    static var recordingFolderHeader: String { tr("recording.folder.header") }
    static var recordingFolderChoose: String { tr("recording.folder.choose") }
    static var recordingFolderReveal: String { tr("recording.folder.reveal") }
    static var recordingFolderReset: String { tr("recording.folder.reset") }
    static var recordingFolderCaption: String { tr("recording.folder.caption") }
    static var recordingPlaybackHeader: String { tr("recording.playback.header") }
    static var recordingPlaybackToggle: String { tr("recording.playback.toggle") }
    static var recordingPlaybackCaptionAll: String { tr("recording.playback.caption.all") }
    static var recordingPlaybackCaptionDefault: String { tr("recording.playback.caption.default") }
    static var recordingQualityHeader: String { tr("recording.quality.header") }
    static var recordingQualityCaption: String { tr("recording.quality.caption") }
    static var recordingQualityUnit: String { tr("recording.quality.unit") }
    static func recordingQualitySize(tenMinutes: String, hour: String) -> String {
        format("recording.quality.size", tenMinutes, hour)
    }
    static var recordingMicCaption: String { tr("recording.mic.caption") }
    static var recordingSourcesHeader: String { tr("recording.sources.header") }
    static var recordingSourcesCaption: String { tr("recording.sources.caption") }
    static var recordingSourceVirtual: String { tr("recording.source.virtual") }
    static var recordingSourceUnavailable: String { tr("recording.source.unavailable") }
    static var recordingSourceSystemPlayback: String { tr("recording.source.system_playback") }
    static var recordingSourceIncluded: String { tr("recording.source.included") }
    static var recordingSourceOutside: String { tr("recording.source.outside") }
    static var recordingInputsHeader: String { tr("recording.inputs.header") }
    static var recordingOutputsHeader: String { tr("recording.outputs.header") }
    static var recordingMonitorTitle: String { tr("recording.monitor.title") }
    static var recordingFollowDefaultMic: String { tr("recording.monitor.follow_default") }
    static var recordingFollowDefaultOutput: String { tr("recording.monitor.follow_default_output") }
    static var recordingFollowDefaultMicCaption: String { tr("recording.follow.mic.caption") }
    static var recordingFollowDefaultOutputCaption: String { tr("recording.follow.output.caption") }
    static var recordingMonitorHint: String { tr("recording.monitor.hint") }
    static var recordingPermissionMicTitle: String { tr("recording.permission.mic.title") }
    static var recordingPermissionMicCaption: String { tr("recording.permission.mic.caption") }
    static var recordingPermissionMicButton: String { tr("recording.permission.mic.button") }
    static var recordingPermissionPlaybackTitle: String { tr("recording.permission.playback.title") }
    static var recordingPermissionPlaybackCaption: String { tr("recording.permission.playback.caption") }
    static var recordingPermissionPlaybackButton: String { tr("recording.permission.playback.button") }
    static var recordingAlertTitle: String { tr("recording.alert.title") }
    static var recordingAlertOK: String { tr("recording.alert.ok") }
    static var recordingErrorAlready: String { tr("recording.error.already") }
    static var recordingErrorNotRecording: String { tr("recording.error.not_recording") }
    static var recordingErrorNeedsMacOS: String { tr("recording.error.needs_macos") }
    static var recordingErrorMicDenied: String { tr("recording.error.mic_denied") }
    static var recordingErrorPlaybackDenied: String { tr("recording.error.playback_denied") }
    static var recordingErrorMicStart: String { tr("recording.error.mic_start") }
    static func recordingErrorTap(_ status: Int) -> String {
        format("recording.error.tap", status)
    }
    static func recordingErrorAggregate(_ status: Int) -> String {
        format("recording.error.aggregate", status)
    }
    static func recordingErrorIO(_ status: Int) -> String {
        format("recording.error.io", status)
    }
    static var recordingErrorInvalidFormat: String { tr("recording.error.invalid_format") }
    static var recordingErrorFile: String { tr("recording.error.file") }
    static var recordingErrorMix: String { tr("recording.error.mix") }

    // MARK: - Keyboard

    static var keyboardShortcutsHeader: String { tr("keyboard.shortcuts.header") }
    static var keyboardShortcutsCaption: String { tr("keyboard.shortcuts.caption") }
    static var keyboardConflicts: String { tr("keyboard.conflicts") }
    static func keyboardConflict(chord: String, titles: String) -> String {
        format("keyboard.conflict.format", chord, titles)
    }
    static var keyboardToggle: String { tr("keyboard.toggle") }
    static var keyboardF5Toggle: String { tr("keyboard.f5_toggle") }
    static var keyboardMute: String { tr("keyboard.mute") }
    static var keyboardUnmute: String { tr("keyboard.unmute") }
    static var keyboardStartRecording: String { tr("keyboard.start_recording") }
    static var keyboardStopRecording: String { tr("keyboard.stop_recording") }
    static var keyboardRecordingHeader: String { tr("keyboard.recording.header") }
    static var keyboardF5: String { tr("keyboard.f5") }
    static var keyboardMomentaryHeader: String { tr("keyboard.momentary.header") }
    static var keyboardMomentaryCaption: String { tr("keyboard.momentary.caption") }
    static var keyboardPushFlip: String { tr("keyboard.push_flip") }
    static var keyboardPushTalk: String { tr("keyboard.push_talk") }
    static var keyboardPushMute: String { tr("keyboard.push_mute") }
    static var keyboardReset: String { tr("keyboard.reset") }
    static var keyboardTypeShortcut: String { tr("keyboard.type_shortcut") }
    static var keyboardHelpRecording: String { tr("keyboard.help.recording") }
    static var keyboardHelpClick: String { tr("keyboard.help.click") }

    // MARK: - About

    static func aboutVersion(_ version: String) -> String {
        format("about.version", version)
    }
    static var aboutBy: String { tr("about.by") }
    static var aboutCaption: String { tr("about.caption") }
    static var aboutWebsite: String { tr("about.website") }
    static var aboutOwner: String { tr("about.owner") }
    static var aboutLicense: String { tr("about.license") }
    static var aboutLicenseValue: String { tr("about.license.value") }
    static var aboutCopyright: String { tr("about.copyright") }
    static var aboutFeedbackHeader: String { tr("about.feedback.header") }
    static var aboutFeedbackCaption: String { tr("about.feedback.caption") }
    static var aboutFeedbackSend: String { tr("about.feedback.send") }
    static var aboutFeedbackBug: String { tr("about.feedback.bug") }
    static var aboutFeedbackFeature: String { tr("about.feedback.feature") }
    static var aboutRateOnWeb: String { tr("about.feedback.rate_web") }
    static var aboutGitHub: String { tr("about.github") }
    static var aboutUpdateHeader: String { tr("about.update.header") }
    static func aboutUpdateAvailable(_ latest: String, _ current: String) -> String {
        format("about.update.available", latest, current)
    }
    static var aboutUpdateDownloadDMG: String { tr("about.update.download_dmg") }
    static var aboutUpdateUpToDate: String { tr("about.update.up_to_date") }
    static var aboutUpdateChecking: String { tr("about.update.checking") }
    static var aboutUpdateFailed: String { tr("about.update.failed") }
    static var aboutUpdateHomebrewHeader: String { tr("about.update.homebrew.header") }
    static var aboutUpdateHomebrewCaption: String { tr("about.update.homebrew.caption") }
    static var aboutUpdateHomebrewLabel: String { tr("about.update.homebrew.label") }
    static var aboutUpdateCopy: String { tr("about.update.copy") }
    static var aboutUpdateCopied: String { tr("about.update.copied") }
    static var aboutUpdateDetectedHomebrew: String { tr("about.update.detected.homebrew") }
    static var aboutUpdateDetectedDirect: String { tr("about.update.detected.direct") }
    static var aboutUpdateDetectedUnknown: String { tr("about.update.detected.unknown") }
    static var aboutUpdateHomebrewAlternate: String { tr("about.update.homebrew.alternate") }
    static var aboutUpdateDmgAlternate: String { tr("about.update.dmg.alternate") }

    // MARK: - Menu

    static var menuStatusDisabled: String { tr("menu.status.disabled") }
    static var menuAgreeHint: String { tr("menu.agree.hint") }
    static var menuAgreeEnable: String { tr("menu.agree.enable") }
    static var menuPreferences: String { tr("menu.preferences") }
    static var menuQuit: String { tr("menu.quit") }
    static var menuStatusMuted: String { tr("menu.status.muted") }
    static var menuStatusUnmuted: String { tr("menu.status.unmuted") }
    static var menuStatusUnknown: String { tr("menu.status.unknown") }
    static func menuStatusCantMute(_ name: String) -> String {
        format("menu.status.cant_mute", name)
    }
    static func menuDevice(_ name: String) -> String {
        format("menu.device", name)
    }
    static var menuScopeAll: String { tr("menu.scope.all") }
    static var menuScopeDefault: String { tr("menu.scope.default") }
    static var menuUnmuteMic: String { tr("menu.unmute_mic") }
    static var menuMuteMic: String { tr("menu.mute_mic") }
    static var menuMuteAll: String { tr("menu.mute_all") }
    static var menuStartRecording: String { tr("menu.start_recording") }
    static var menuStopRecording: String { tr("menu.stop_recording") }
    static var menuShowRecordings: String { tr("menu.show_recordings") }
    static var menuShowRecordingMonitor: String { tr("menu.show_recording_monitor") }
    static var menuFloatingHUD: String { tr("menu.floating_hud") }
    static var menuShowAllDisplays: String { tr("menu.show_all_displays") }
    static var menuHideThisDisplay: String { tr("menu.hide_this_display") }
    static func menuShowOnDisplay(_ name: String) -> String {
        format("menu.show_on_display", name)
    }
    static func menuUpdateAvailable(_ version: String) -> String {
        format("menu.update.available", version)
    }
    static var menuCheckForUpdates: String { tr("menu.update.check") }
    static var menuSkipUpdate: String { tr("menu.update.skip") }

    // MARK: - HUD

    static var hudMuted: String { tr("hud.muted") }
    static var hudUnmuted: String { tr("hud.unmuted") }
    static var hudTalking: String { tr("hud.talking") }
    static var hudHoldMute: String { tr("hud.hold_mute") }
    static var hudHolding: String { tr("hud.holding") }
    static var hudTooltipInteractive: String { tr("hud.tooltip.interactive") }
    static var hudTooltipHolding: String { tr("hud.tooltip.holding") }
}
