import AppKit
import Carbon
import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "Hotkey")

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
    /// Hold to unmute; release restores prior mute state.
    case pushToTalk
    /// Hold to mute; release restores prior mute state.
    case pushToMute
    /// Hold to invert mute; release restores prior mute state (UI: “Push to flip”).
    case pushToToggle

    var isMomentary: Bool {
        switch self {
        case .pushToTalk, .pushToMute, .pushToToggle: return true
        default: return false
        }
    }
}

enum HotkeyPhase: String, Sendable {
    case pressed
    case released
}

struct HotkeyBinding: Equatable, Sendable {
    var enabled: Bool
    var chord: HotkeyChord
    var action: HotkeyAction

    var isActive: Bool {
        enabled && !chord.isEmpty
    }
}

/// Global hotkeys: Carbon first; NSEvent only when Carbon registration fails.
/// Momentary actions (talk / mute / flip) get press and release.
final class HotkeyManager {
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var carbonIDs: [UInt32] = []
    private var bindings: [HotkeyBinding] = []
    /// Bindings that failed Carbon registration (NSEvent fallback only).
    private var fallbackBindings: [HotkeyBinding] = []
    private var actionHandler: ((HotkeyAction, HotkeyPhase) -> Void)?

    private var localMonitor: Any?
    private var globalMonitor: Any?

    private var lastFireTime: CFAbsoluteTime = 0
    private var lastFireAction: HotkeyAction?
    private var lastFirePhase: HotkeyPhase?

    private static let signature = OSType(0x4C4D4831) // 'LMH1'
    private static var nextID: UInt32 = 1
    /// id → (action, handlesRelease)
    private static var carbonHandlers: [UInt32: (HotkeyAction, Bool)] = [:]
    private static var sharedEventSink: ((HotkeyAction, HotkeyPhase) -> Void)?
    private static var handlerInstalled = false
    private static var handlerRef: EventHandlerRef?

    deinit {
        unregister()
    }

    func register(bindings: [HotkeyBinding], onAction: @escaping (HotkeyAction, HotkeyPhase) -> Void) {
        unregister()
        self.bindings = bindings.filter(\.isActive)
        self.actionHandler = { [weak self] action, phase in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            // Debounce same action+phase for latching shortcuts; momentary uses its own guards.
            if !action.isMomentary,
               action == self.lastFireAction,
               phase == self.lastFirePhase,
               now - self.lastFireTime < 0.2
            {
                return
            }
            self.lastFireTime = now
            self.lastFireAction = action
            self.lastFirePhase = phase
            log.debug("fired \(action.rawValue, privacy: .public) \(phase.rawValue, privacy: .public)")
            onAction(action, phase)
        }
        HotkeyManager.sharedEventSink = self.actionHandler

        var fallback: [HotkeyBinding] = []
        for binding in self.bindings {
            if !installCarbonHotKey(binding) {
                fallback.append(binding)
            }
        }
        fallbackBindings = fallback
        if !fallback.isEmpty {
            installEventMonitors(for: fallback)
            log.notice("NSEvent fallback for \(fallback.count) hotkey(s)")
        }
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
        fallbackBindings = []
        actionHandler = nil
        HotkeyManager.sharedEventSink = nil
    }

    // MARK: - Carbon

    @discardableResult
    private func installCarbonHotKey(_ binding: HotkeyBinding) -> Bool {
        HotkeyManager.installSharedHandlerIfNeeded()

        let id = HotkeyManager.nextID
        HotkeyManager.nextID += 1
        let action = binding.action
        let handlesRelease = action.isMomentary

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
            HotkeyManager.carbonHandlers[id] = (action, handlesRelease)
            log.debug(
                "Carbon OK \(binding.chord.displayString, privacy: .public) → \(action.rawValue, privacy: .public)"
            )
            return true
        }

        log.error(
            "Carbon RegisterEventHotKey failed for \(binding.chord.displayString, privacy: .public) status=\(status) — NSEvent fallback"
        )
        return false
    }

    private static func installSharedHandlerIfNeeded() {
        if handlerInstalled { return }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            lockMicHotKeyEventHandler,
            2,
            &eventTypes,
            nil,
            &handlerRef
        )

        if status == noErr {
            handlerInstalled = true
        } else {
            log.error("InstallEventHandler failed status=\(status)")
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
        guard let (action, handlesRelease) = carbonHandlers[hkID.id] else {
            return OSStatus(eventNotHandledErr)
        }

        let kind = GetEventKind(event)
        let phase: HotkeyPhase
        if kind == UInt32(kEventHotKeyPressed) {
            phase = .pressed
        } else if kind == UInt32(kEventHotKeyReleased) {
            guard handlesRelease else { return noErr }
            phase = .released
        } else {
            return OSStatus(eventNotHandledErr)
        }

        let deliver: () -> Void = {
            sharedEventSink?(action, phase)
        }
        if Thread.isMainThread {
            deliver()
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
        return noErr
    }

    // MARK: - NSEvent fallback (Carbon registration failed only)

    private func installEventMonitors(for bindings: [HotkeyBinding]) {
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp]

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            if let (action, phase) = Self.match(event: event, bindings: bindings) {
                self.actionHandler?(action, phase)
                if event.type == .keyDown {
                    return nil
                }
            }
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return }
            if let (action, phase) = Self.match(event: event, bindings: bindings) {
                DispatchQueue.main.async {
                    self.actionHandler?(action, phase)
                }
            }
        }
    }

    private static func match(event: NSEvent, bindings: [HotkeyBinding]) -> (HotkeyAction, HotkeyPhase)? {
        let phase: HotkeyPhase = (event.type == .keyUp) ? .released : .pressed

        for binding in bindings {
            if phase == .released, !binding.action.isMomentary {
                continue
            }
            if phase == .pressed, event.isARepeat, binding.action.isMomentary {
                continue
            }

            let nsMods = nsEventModifiers(fromCarbon: binding.chord.modifiers)
            if eventMatches(event, keyCode: UInt16(binding.chord.keyCode), modifiers: nsMods, phase: phase) {
                return (binding.action, phase)
            }
        }
        return nil
    }

    private static func eventMatches(
        _ event: NSEvent,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        phase: HotkeyPhase
    ) -> Bool {
        guard event.keyCode == keyCode else { return false }
        let relevant: NSEvent.ModifierFlags = [.control, .option, .command, .shift]
        // On key-up, modifiers may already be released — match key code only for release.
        if phase == .released {
            return true
        }
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
