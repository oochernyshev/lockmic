import AppKit
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "StatusItemVisibility")

/// Whether the menu bar status item is actually on-screen and clickable.
/// macOS has no “hidden under camera housing” API — we infer from window geometry.
@MainActor
enum StatusItemVisibility {
    static func isIconVisiblyPlaced(statusItem: NSStatusItem?) -> Bool {
        guard let statusItem, statusItem.isVisible, let button = statusItem.button else { return false }
        button.window?.layoutIfNeeded()
        guard let window = button.window else { return false }

        let frame = window.frame
        guard frame.width >= 2, frame.height >= 2 else { return false }

        let screen = window.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) })
            ?? NSScreen.main
        guard let screen else { return false }

        // Notched Macs: extras must sit in the top-right usable strip (not under the camera).
        if let usable = screen.auxiliaryTopRightArea, usable.width > 1, usable.height > 1 {
            let hit = usable.intersection(frame)
            let placed = hit.width >= frame.width * 0.5 && hit.height >= frame.height * 0.5
            if !placed {
                log.debug("status item outside usable menu bar")
            }
            return placed
        }

        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 22)
        let band = NSRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - menuBarHeight,
            width: screen.frame.width,
            height: menuBarHeight
        )
        let hit = band.intersection(frame)
        return hit.width >= 2 && hit.height >= 2
    }
}
