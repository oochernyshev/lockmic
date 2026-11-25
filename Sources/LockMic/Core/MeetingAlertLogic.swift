import CoreGraphics
import Foundation

struct CalendarMeeting: Equatable, Sendable {
    var id: String
    var seriesID: String
    var title: String
    var start: TimeInterval
    var end: TimeInterval

    var duration: TimeInterval? {
        end > start ? end - start : nil
    }
}

enum MeetingAlertPhase: Equatable, Sendable {
    case upcoming
    case soon
    case now
    case finished
}

enum MeetingAlertLogic {
    static let lookahead: TimeInterval = 120
    static let urgent: TimeInterval = 30
    static let alarmAfter: TimeInterval = 60
    static let beepStart: TimeInterval = 30
    static let beepMid: TimeInterval = 20
    static let alertAll: TimeInterval = 15
    static let alertSecond: TimeInterval = 10
    static let alertFast: TimeInterval = 5
    static let fastEvery: TimeInterval = 0.5
    static let fetchInterval: TimeInterval = 30
    static let sourceRefreshInterval: TimeInterval = 30 * 60
    static let tick: TimeInterval = 0.1
    static let appearDuration: TimeInterval = 0.34
    static let scaleMin: CGFloat = 0.7
    static let scaleMax: CGFloat = 2.5
    static let cardWidth: CGFloat = 490
    static let cardHeight: CGFloat = 220

    static func phase(remaining: TimeInterval, duration: TimeInterval? = nil) -> MeetingAlertPhase {
        if let duration, duration > 0, -remaining >= duration { return .finished }
        if remaining <= 0 { return .now }
        if remaining <= urgent { return .soon }
        return .upcoming
    }

    /// Stops the elapsed clock at the meeting length once the meeting is over.
    static func clampedRemaining(_ remaining: TimeInterval, duration: TimeInterval?) -> TimeInterval {
        guard let duration, duration > 0 else { return remaining }
        return max(remaining, -duration)
    }

    static func snoozeSeconds(remaining: TimeInterval) -> Int {
        let left = Int(remaining.rounded(.towardZero))
        if left <= 0 { return 30 }
        if left < 2 { return 1 }
        return left / 2
    }

    static func countdownText(remaining: TimeInterval) -> String {
        // Elapsed time stays on the ring without a leading +. The status line says the meeting started.
        let whole = Int(remaining.rounded(.towardZero).magnitude)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }

    static func meetingTimeText(start: TimeInterval, calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: start)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    static func headline(timeText: String, title: String) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = name.isEmpty ? "Calendar Meeting" : name
        if timeText.isEmpty { return display }
        return "\(timeText) \(display)"
    }

    /// Remaining fraction of the 2-minute lookahead, or elapsed fraction of the meeting.
    static func ringFraction(remaining: TimeInterval, duration: TimeInterval?) -> CGFloat {
        if remaining > 0 {
            return CGFloat(max(0, min(1, remaining / lookahead)))
        }
        if let duration, duration > 0 {
            return CGFloat(max(0, min(1, -remaining / duration)))
        }
        return 1
    }

    static func shouldPlayAlert(remaining: TimeInterval) -> Bool {
        remaining <= beepStart && remaining >= -alarmAfter
    }

    static func playsOnAllOutputs(remaining: TimeInterval) -> Bool {
        remaining <= alertAll
    }

    static func beepInterval(remaining: TimeInterval) -> TimeInterval {
        if remaining >= 0 && remaining <= alertFast { return fastEvery }
        if remaining >= 0 && remaining <= alertSecond { return 1 }
        if remaining <= alertAll { return 2 }
        if remaining <= beepMid { return 3 }
        return 5
    }

    static func isSnoozed(id: String, now: TimeInterval, until: [String: TimeInterval]) -> Bool {
        guard let end = until[id] else { return false }
        return now < end
    }

    static func selectUpcoming(
        events: [CalendarMeeting],
        now: TimeInterval,
        pinned: CalendarMeeting?,
        dismissed: Set<String>,
        snoozedUntil: [String: TimeInterval],
        snoozeReturn: Set<String>
    ) -> CalendarMeeting? {
        if var pinned, !dismissed.contains(pinned.id), !isSnoozed(id: pinned.id, now: now, until: snoozedUntil) {
            let exact = events.first { $0.id == pinned.id }
            let moved = events
                .filter { $0.seriesID == pinned.seriesID }
                .min { abs($0.start - pinned.start) < abs($1.start - pinned.start) }
            if let fresh = exact ?? moved {
                pinned.id = fresh.id
                pinned.seriesID = fresh.seriesID
                pinned.title = fresh.title
                pinned.start = fresh.start
                pinned.end = fresh.end
            }
            return pinned
        }

        var upcoming: CalendarMeeting?
        for event in events {
            guard !dismissed.contains(event.id) else { continue }
            guard !isSnoozed(id: event.id, now: now, until: snoozedUntil) else { continue }
            let remaining = event.start - now
            let bringBack = snoozeReturn.contains(event.id)
            guard bringBack || (remaining <= lookahead && remaining >= -alarmAfter) else { continue }
            if upcoming == nil || event.start < upcoming!.start {
                upcoming = event
            }
        }
        return upcoming
    }
}
