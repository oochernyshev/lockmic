import ApplicationServices
import Foundation

/// Cheap "did anything change?" probe for an app: hashes its windows' titles, sizes and minimized
/// state (a few AX calls) so the costly full tree scan can be skipped while nothing moved.
enum AXWindowFingerprint {
    struct Result {
        var hash: Int
        var titles: [String]
    }

    static func probe(_ root: AXUIElement) -> Result {
        var hasher = Hasher()
        var titles: [String] = []
        var value: CFTypeRef?
        let windows: [AXUIElement]
        if AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value) == .success {
            windows = value as? [AXUIElement] ?? []
        } else {
            windows = []
        }
        hasher.combine(windows.count)
        for window in windows {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            let text = title as? String ?? ""
            titles.append(text)
            hasher.combine(text)
            var minimized: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
            hasher.combine((minimized as? Bool) ?? false)
            var size: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
               let size, CFGetTypeID(size) == AXValueGetTypeID() {
                var cgSize = CGSize.zero
                if AXValueGetValue(size as! AXValue, .cgSize, &cgSize) {
                    hasher.combine(Int(cgSize.width))
                    hasher.combine(Int(cgSize.height))
                }
            }
        }
        return Result(hash: hasher.finalize(), titles: titles)
    }
}
