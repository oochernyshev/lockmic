import AppKit
import Carbon
import Foundation

struct HotkeyChord: Equatable, Sendable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32

    var displayString: String {
        HotkeyManager.displayString(keyCode: keyCode, modifiers: modifiers)
    }

    var isEmpty: Bool {
        keyCode == 0 && modifiers == 0
    }
}

enum HotkeyAction: String, Sendable {
    case toggle
    case mute
    case unmute
}

struct HotkeyBinding: Equatable, Sendable {
    var enabled: Bool
    var chord: HotkeyChord
    var action: HotkeyAction

    var isActive: Bool {
        enabled && !chord.isEmpty
    }
}

/// Global hotkeys via Carbon + NSEvent monitors.
final class HotkeyManager {
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var carbonIDs: [UInt32] = []
    private var bindings: [HotkeyBinding] = []
    private var actionHandler: ((HotkeyAction) -> Void)?

    private var localMonitor: Any?
    private var globalMonitor: Any?

    private var lastFireTime: CFAbsoluteTime = 0
    private var lastFireAction: HotkeyAction?

    private static let signature = OSType(0x4C4D4831) // 'LMH1'
    private static var nextID: UInt32 = 1
    private static var carbonHandlers: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private static var handlerRef: EventHandlerRef?

    deinit {
        unregister()
    }

    func register(bindings: [HotkeyBinding], onAction: @escaping (HotkeyAction) -> Void) {
        unregister()
        self.bindings = bindings.filter(\.isActive)
        self.actionHandler = { [weak self] action in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            // Debounce same action; allow mute then unmute quickly.
            if action == self.lastFireAction, now - self.lastFireTime < 0.2 { return }
            self.lastFireTime = now
            self.lastFireAction = action
            NSLog("LockMic: hotkey fired action=%@", action.rawValue)
            onAction(action)
        }

        for binding in self.bindings {
            installCarbonHotKey(binding)
        }
        installEventMonitors()
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

        bindings = []
        actionHandler = nil
    }

    // MARK: - Carbon

    private func installCarbonHotKey(_ binding: HotkeyBinding) {
        HotkeyManager.installSharedHandlerIfNeeded()

        let id = HotkeyManager.nextID
        HotkeyManager.nextID += 1
        let action = binding.action

        var eventHotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.chord.keyCode,
            binding.chord.modifiers,
            eventHotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        if status == noErr, let ref {
            hotKeyRefs.append(ref)
            carbonIDs.append(id)
            HotkeyManager.carbonHandlers[id] = { [weak self] in
                self?.actionHandler?(action)
            }
            NSLog(
                "LockMic: Carbon hotkey OK %@ → %@",
                binding.chord.displayString,
                action.rawValue
            )
        } else {
            NSLog(
                "LockMic: Carbon RegisterEventHotKey failed for %@ status=%d",
                binding.chord.displayString,
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

    // MARK: - NSEvent monitors

    private func installEventMonitors() {
        let bindings = self.bindings

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if let action = Self.action(for: event, bindings: bindings) {
                self.actionHandler?(action)
                return nil
            }
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            if let action = Self.action(for: event, bindings: bindings) {
                DispatchQueue.main.async {
                    self.actionHandler?(action)
                }
            }
        }
    }

    private static func action(for event: NSEvent, bindings: [HotkeyBinding]) -> HotkeyAction? {
        for binding in bindings {
            let nsMods = nsEventModifiers(fromCarbon: binding.chord.modifiers)
            if eventMatches(event, keyCode: UInt16(binding.chord.keyCode), modifiers: nsMods) {
                return binding.action
            }
        }
        return nil
    }

    private static func eventMatches(_ event: NSEvent, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard event.keyCode == keyCode else { return false }
        let relevant: NSEvent.ModifierFlags = [.control, .option, .command, .shift]
        return event.modifierFlags.intersection(relevant) == modifiers.intersection(relevant)
    }

    static func nsEventModifiers(fromCarbon carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static func displayString(keyCode: UInt32, modifiers: UInt32) -> String {
        if keyCode == 0 && modifiers == 0 { return "None" }
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }

    private static func keyCodeToString(_ keyCode: UInt32) -> String {
        let map: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M",
            49: "Space",
            51: "⌫", 53: "Esc",
            96: "F5", 97: "F6", 98: "F7", 99: "F3",
            100: "F8", 101: "F9", 103: "F11", 109: "F10",
            111: "F12", 118: "F4", 120: "F2", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑",
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
