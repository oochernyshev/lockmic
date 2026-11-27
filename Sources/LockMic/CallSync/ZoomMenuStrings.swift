import AppKit

/// Zoom's own localized titles for the mute menu item, read from the running app's bundle so
/// every language Zoom ships is recognised without hardcoding translations.
enum ZoomMenuStrings {
    struct Titles {
        var mute: Set<String> = ["Mute audio"]      // shown while unmuted
        var unmute: Set<String> = ["Unmute audio"]  // shown while muted
    }

    private static var cache: [String: Titles] = [:]

    static func titles(for app: NSRunningApplication) -> Titles {
        guard let bundleURL = app.bundleURL else { return Titles() }
        if let hit = cache[bundleURL.path] { return hit }
        var titles = Titles()
        let resources = bundleURL.appendingPathComponent("Contents/Resources")
        let lprojs = (try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? []
        for dir in lprojs where dir.hasSuffix(".lproj") {
            let file = resources.appendingPathComponent("\(dir)/Localizable.strings")
            guard let table = NSDictionary(contentsOf: file) as? [String: String] else { continue }
            if let mute = table["Mute Audio"] { titles.mute.insert(mute) }
            if let unmute = table["Unmute Audio"] { titles.unmute.insert(unmute) }
        }
        cache[bundleURL.path] = titles
        return titles
    }
}
