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
