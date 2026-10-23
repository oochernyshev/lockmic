// Compile the real presenter against lightweight overlay/preferences spies, without
// opening windows, modifying saved preferences, or accessing microphone hardware.
// Run from the repository root:
// mkdir -p build
// xcrun swiftc -parse-as-library Sources/LockMic/UI/HUDPresenter.swift \
//     Tests/HUDPresenterRegression.swift -o build/hud-presenter-regression
// build/hud-presenter-regression
import AppKit

enum HUDHoldKind: Equatable { case none, talk, mute, flip }

@MainActor
final class PreferencesStore {
    var hudEnabled = false
    var hudFloating = false
}

@MainActor
final class HUDOverlay {
    enum State: Equatable {
        case hidden
        case toast(recording: Bool, persistent: Bool)
        case floating(recording: Bool)
    }
    var state: State = .hidden
    var visibleDisplay = true
    var restores = 0
    func hide() { state = .hidden }
    func hasAnyVisibleDisplay() -> Bool { visibleDisplay }
    func restoreAllDisplays() { visibleDisplay = true; restores += 1 }
    func refreshUpdateBadge() {}
    func showFloating(muted: Bool, hold: HUDHoldKind, recording: Bool) {
        state = .floating(recording: recording)
    }
    func showToast(muted: Bool, hold: HUDHoldKind, recording: Bool, persistent: Bool) {
        state = .toast(recording: recording, persistent: persistent)
    }
}

@main
struct HUDPresenterRegression {
    @MainActor
    static func main() {
        var checks = 0
        func expect(_ actual: HUDOverlay.State, _ expected: HUDOverlay.State, _ label: String) {
            guard actual == expected else {
                print("FAIL: \(label): expected \(expected), got \(actual)")
                exit(1)
            }
            checks += 1
        }
        let prefs = PreferencesStore()
        let hud = HUDPresenter(preferences: prefs)
        func present(recording: Bool = true, user: Bool = false, hold: HUDHoldKind = .none, features: Bool = true) {
            hud.present(muted: false, userInitiated: user, hold: hold, recording: recording, featuresEnabled: features)
        }
        func sync(recording: Bool = true, features: Bool = true) {
            hud.syncPersistentState(muted: false, hold: .none, recording: recording, featuresEnabled: features)
        }
        func syncSettings() {
            hud.syncFloating(muted: false, hold: .none, recording: true, featuresEnabled: true)
        }

        // Recording start, mute/hold events, and background refresh must all stay hidden.
        present()
        expect(hud.overlay.state, .hidden, "recording start with HUD off")
        for hold in [HUDHoldKind.none, .talk, .mute, .flip] {
            present(user: true, hold: hold)
            expect(hud.overlay.state, .hidden, "mute/hold event with HUD off")
        }
        sync()
        expect(hud.overlay.state, .hidden, "background state refresh with HUD off")

        // Preference changes take effect without changing the floating preference.
        syncSettings()
        prefs.hudEnabled = true
        syncSettings()
        expect(hud.overlay.state, .toast(recording: true, persistent: true), "enable while recording")
        prefs.hudEnabled = false
        syncSettings()
        expect(hud.overlay.state, .hidden, "disable while recording")

        // Background refresh also removes an already-visible recording HUD.
        prefs.hudEnabled = true
        present()
        prefs.hudEnabled = false
        sync()
        expect(hud.overlay.state, .hidden, "refresh hides stale recording HUD")

        // Explicitly enabled floating HUD remains independent of the toast preference.
        prefs.hudFloating = true
        present()
        expect(hud.overlay.state, .floating(recording: true), "floating HUD with toast off")
        sync()
        expect(hud.overlay.state, .floating(recording: true), "floating state refresh")
        hud.overlay.visibleDisplay = false
        present()
        expect(hud.overlay.state, .hidden, "all displays hidden and toast off")
        sync()
        expect(hud.overlay.state, .hidden, "all displays hidden during refresh")
        prefs.hudEnabled = true
        present()
        expect(hud.overlay.state, .toast(recording: true, persistent: true), "toast fallback when enabled")

        // Unchanged mute/hold behavior and feature gating.
        prefs.hudFloating = false
        present(recording: false, user: true)
        expect(hud.overlay.state, .toast(recording: false, persistent: false), "mute toast")
        present(recording: false, hold: .talk)
        expect(hud.overlay.state, .toast(recording: false, persistent: true), "hold HUD")
        present(recording: false)
        expect(hud.overlay.state, .hidden, "recording stopped")
        present(features: false)
        expect(hud.overlay.state, .hidden, "features disabled")
        prefs.hudFloating = true
        sync(features: false)
        expect(hud.overlay.state, .hidden, "features disabled during refresh")

        // Restoring floating displays only follows an explicit floating off/on change.
        prefs.hudFloating = false
        syncSettings()
        hud.overlay.visibleDisplay = false
        prefs.hudFloating = true
        syncSettings()
        precondition(hud.overlay.restores == 1)
        expect(hud.overlay.state, .floating(recording: true), "enable floating restores displays")
        prefs.hudEnabled = false
        syncSettings()
        precondition(hud.overlay.restores == 1)
        expect(hud.overlay.state, .floating(recording: true), "toast setting preserves floating HUD")
        print("PASS: \(checks) HUD presenter regression checks")
    }
}
