import AppKit
import SwiftUI

/// Click to record a new global shortcut; Esc cancels; Delete clears.
struct HotkeyRecorderButton: View {
    @Binding var chord: HotkeyChord
    var isEnabled: Bool = true

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            guard isEnabled else { return }
            if isRecording {
                stopRecording(keep: true)
            } else {
                startRecording()
            }
        } label: {
            Text(isRecording ? L10n.keyboardTypeShortcut : chord.displayString)
                .font(.body.monospaced())
                .frame(minWidth: 110, alignment: .center)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isRecording ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isRecording ? Color.accentColor : Color.secondary.opacity(0.25),
                            lineWidth: isRecording ? 1.5 : 1
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .focusable(false)
        .focusEffectDisabled()
        .help(isRecording ? L10n.keyboardHelpRecording : L10n.keyboardHelpClick)
        .onDisappear {
            stopRecording(keep: true)
        }
    }

    private func startRecording() {
        stopRecording(keep: true)
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc — cancel
            if event.keyCode == 53 {
                DispatchQueue.main.async { stopRecording(keep: true) }
                return nil
            }
            // Delete / Forward delete — clear
            if event.keyCode == 51 || event.keyCode == 117 {
                DispatchQueue.main.async {
                    chord = HotkeyChord(keyCode: 0, modifiers: 0)
                    stopRecording(keep: true)
                }
                return nil
            }

            let mods = HotkeyManager.carbonModifiers(from: event.modifierFlags)
            // Require at least one modifier for safety (except function keys F1–F12).
            let isFunctionKey = (96...113).contains(event.keyCode) || [118, 120, 122].contains(event.keyCode)
            if mods == 0 && !isFunctionKey {
                return nil
            }

            let newChord = HotkeyChord(keyCode: UInt32(event.keyCode), modifiers: mods)
            DispatchQueue.main.async {
                chord = newChord
                stopRecording(keep: true)
            }
            return nil
        }
    }

    private func stopRecording(keep: Bool) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
        _ = keep
    }
}
