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

        if preferences.hudFloating {
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

        if floating {
            overlay.showFloating(muted: muted, hold: hold, recording: recording)
        } else if lastHudFloating == true {
            overlay.hide()
        }
        lastHudFloating = floating
    }

    func hide() {
        overlay.hide()
        lastHudFloating = false
    }

    func refreshUpdateBadge() {
        overlay.refreshUpdateBadge()
    }
}
