import AppKit
import Carbon
import Foundation

struct HotkeyChord: Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    var displayString: String {
        HotkeyManager.displayString(keyCode: keyCode, modifiers: modifiers)
    }
}

/// Global hotkey registration for one or more chords (same action).
///
/// Primary: Carbon `RegisterEventHotKey` (works without Accessibility).
/// Fallback: `NSEvent` local + global monitors.
final class HotkeyManager {
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var carbonIDs: [UInt32] = []
    private var onPressed: (() -> Void)?

    private var localMonitor: Any?
    private var globalMonitor: Any?

    private var chords: [HotkeyChord] = []
    /// Debounce so Carbon + NSEvent monitors don't double-toggle one keypress.
    private var lastFireTime: CFAbsoluteTime = 0

    private static let signature = OSType(0x4C4D4831) // 'LMH1'
    private static var nextID: UInt32 = 1
    private static var carbonHandlers: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private static var handlerRef: EventHandlerRef?

    deinit {
        unregister()
    }

    func register(chords: [HotkeyChord], onPressed: @escaping () -> Void) {
        unregister()
        self.chords = chords

        self.onPressed = { [weak self] in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if now - self.lastFireTime < 0.25 { return }
            self.lastFireTime = now
            NSLog("LockMic: hotkey fired")
            onPressed()
        }

        for chord in chords {
            installCarbonHotKey(chord)
        }
        installEventMonitors()
    }

    /// Convenience for a single chord.
    func register(keyCode: UInt32, modifiers: UInt32, onPressed: @escaping () -> Void) {
        register(
            chords: [HotkeyChord(keyCode: keyCode, modifiers: modifiers)],
            onPressed: onPressed
        )
    }

    func unregister() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()

        for id in carbonIDs {
            HotkeyManager.carbonHandlers.removeValue(forKey: id)
        }
        carbonIDs.removeAll()

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }

        chords = []
        onPressed = nil
    }

    // MARK: - Carbon

    private func installCarbonHotKey(_ chord: HotkeyChord) {
        HotkeyManager.installSharedHandlerIfNeeded()

        let id = HotkeyManager.nextID
        HotkeyManager.nextID += 1

        var eventHotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            chord.keyCode,
            chord.modifiers,
            eventHotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        if status == noErr, let ref {
            hotKeyRefs.append(ref)
            carbonIDs.append(id)
            HotkeyManager.carbonHandlers[id] = { [weak self] in
                self?.onPressed?()
            }
            NSLog(
                "LockMic: Carbon hotkey OK id=%u %@ (0x%X)",
                id,
                chord.displayString,
                chord.modifiers
            )
        } else {
            NSLog(
                "LockMic: Carbon RegisterEventHotKey failed for %@ status=%d (−9878 = already taken)",
                chord.displayString,
                status
            )
        }
    }

    private static func installSharedHandlerIfNeeded() {
        guard !handlerInstalled else { return }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
        ]

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            lockMicHotKeyEventHandler,
            1,
            &eventTypes,
            nil,
            &handlerRef
        )

        if status == noErr {
            handlerInstalled = true
            NSLog("LockMic: Carbon event handler installed")
        } else {
            NSLog("LockMic: InstallEventHandler failed status=%d", status)
        }
    }

    fileprivate static func handleCarbonEvent(_ event: EventRef?) -> OSStatus {
        guard let event else { return OSStatus(eventNotHandledErr) }

        var hkID = EventHotKeyID()
        let err = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hkID
        )
        guard err == noErr, hkID.signature == signature else {
            return OSStatus(eventNotHandledErr)
        }
        guard let handler = carbonHandlers[hkID.id] else {
            return OSStatus(eventNotHandledErr)
        }

        if Thread.isMainThread {
            handler()
        } else {
            DispatchQueue.main.async(execute: handler)
        }
        return noErr
    }

    // MARK: - NSEvent monitors (backup)

    private func installEventMonitors() {
        let chords = self.chords

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if Self.eventMatchesAny(event, chords: chords) {
                self.onPressed?()
                return nil
            }
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            if Self.eventMatchesAny(event, chords: chords) {
                DispatchQueue.main.async {
                    self.onPressed?()
                }
            }
        }

        if globalMonitor == nil {
            NSLog(
                "LockMic: NSEvent global monitor unavailable (Carbon should still work). If shortcut fails, grant Accessibility or Input Monitoring to LockMic in System Settings."
            )
        } else {
            NSLog("LockMic: NSEvent global monitor installed (%d chords)", chords.count)
        }
    }

    private static func eventMatchesAny(_ event: NSEvent, chords: [HotkeyChord]) -> Bool {
        for chord in chords {
            let nsMods = nsEventModifiers(fromCarbon: chord.modifiers)
            if eventMatches(event, keyCode: UInt16(chord.keyCode), modifiers: nsMods) {
                return true
            }
        }
        return false
    }

    private static func eventMatches(_ event: NSEvent, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard event.keyCode == keyCode else { return false }
        let relevant: NSEvent.ModifierFlags = [.control, .option, .command, .shift]
        return event.modifierFlags.intersection(relevant) == modifiers.intersection(relevant)
    }

    private static func nsEventModifiers(fromCarbon carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    // MARK: - Display

    static func displayString(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }

    private static func keyCodeToString(_ keyCode: UInt32) -> String {
        // HIToolbox key codes
        let map: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M",
            49: "Space",
            96: "F5", // kVK_F5
            97: "F6",
            98: "F7",
            99: "F3",
            100: "F8",
            101: "F9",
            103: "F11",
            109: "F10",
            111: "F12",
            118: "F4",
            120: "F2",
            122: "F1",
        ]
        return map[keyCode] ?? "Key\(keyCode)"
    }
}

private func lockMicHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    HotkeyManager.handleCarbonEvent(event)
}
