import AppKit

/// Chooses toast vs floating HUD and owns the overlay.
@MainActor
final class HUDPresenter {
    let overlay = HUDOverlay()
    private let preferences: PreferencesStore
    private var lastHudFloating: Bool?

    init(preferences: PreferencesStore) {
        self.preferences = preferences
    }

    func present(
        muted: Bool,
        userInitiated: Bool,
        hold: HUDHoldKind,
        recording: Bool,
        featuresEnabled: Bool
    ) {
        guard featuresEnabled else {
            overlay.hide()
            return
        }

        // Floating wins only while at least one display still shows it. If the user
        // hid every screen, mute/hold/recording fall back to the appearing toast HUD.
        if preferences.hudFloating, overlay.hasAnyVisibleDisplay() {
            overlay.showFloating(muted: muted, hold: hold, recording: recording)
            return
        }

        if recording {
            overlay.showToast(muted: muted, hold: hold, recording: true, persistent: true)
            return
        }

        guard preferences.hudEnabled, userInitiated || hold != .none else {
            overlay.hide()
            return
        }

        overlay.showToast(
            muted: muted,
            hold: hold,
            recording: false,
            persistent: hold != .none
        )
    }

    func syncFloating(
        muted: Bool,
        hold: HUDHoldKind,
        recording: Bool,
        featuresEnabled: Bool,
        force: Bool = false
    ) {
        guard featuresEnabled else {
            if lastHudFloating != false {
                overlay.hide()
                lastHudFloating = false
            }
            return
        }

        let floating = preferences.hudFloating
        guard force || floating != lastHudFloating else { return }

        // Turning the preference back on is an explicit “show it” — restore every display.
        let turningFloatingOn = floating && lastHudFloating == false
        lastHudFloating = floating
        if turningFloatingOn {
            overlay.restoreAllDisplays()
        }

        present(
            muted: muted,
            userInitiated: false,
            hold: hold,
            recording: recording,
            featuresEnabled: true
        )
    }

    func hide() {
        overlay.hide()
        lastHudFloating = false
    }

    func refreshUpdateBadge() {
        overlay.refreshUpdateBadge()
    }
}
