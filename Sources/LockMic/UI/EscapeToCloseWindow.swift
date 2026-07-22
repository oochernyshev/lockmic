import AppKit

/// Window that closes on Esc (standard AppKit `cancelOperation`).
final class EscapeToCloseWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}
