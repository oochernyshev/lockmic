import Foundation

/// Google Meet's microphone button label per UI language. Meet has no stable id or attribute for
/// the mute state, so the (localized) label is the only readable signal.
enum MeetLabels {
    /// (label while the mic is live, label while muted); matched case-insensitively as substring,
    /// since Meet may append a shortcut such as "(ctrl + d)".
    private static let pairs: [(live: String, muted: String)] = [
        ("Turn off microphone", "Turn on microphone"),
        ("Выключить микрофон", "Включить микрофон"),
        ("Вимкнути мікрофон", "Увімкнути мікрофон"),
        ("Mikrofon ausschalten", "Mikrofon einschalten"),
        ("Désactiver le micro", "Activer le micro"),
        ("Desactivar el micrófono", "Activar el micrófono"),
        ("Disattiva microfono", "Attiva microfono"),
        ("Desativar o microfone", "Ativar o microfone"),
        ("Microfoon uitschakelen", "Microfoon inschakelen"),
        ("Wyłącz mikrofon", "Włącz mikrofon"),
        ("Mikrofonu kapat", "Mikrofonu aç"),
        ("マイクをオフにする", "マイクをオンにする"),
        ("마이크 끄기", "마이크 켜기"),
        ("关闭麦克风", "打开麦克风"),
        ("關閉麥克風", "開啟麥克風"),
        ("Vypnout mikrofon", "Zapnout mikrofon"),
        ("Stäng av mikrofonen", "Slå på mikrofonen"),
    ]

    /// `true` = muted, `false` = live, `nil` = not a mic label (or a language not in the table).
    static func muted(for label: String) -> Bool? {
        let text = label.lowercased()
        for pair in pairs {
            if text.contains(pair.muted.lowercased()) { return true }
            if text.contains(pair.live.lowercased()) { return false }
        }
        return nil
    }
}
