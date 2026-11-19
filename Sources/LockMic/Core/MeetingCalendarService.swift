import EventKit
import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "Meetings")

enum MeetingCalendarAccess: Equatable {
    case notDetermined
    case denied
    case restricted
    case granted
}

/// EventKit reads of timed calendar events. Titles and times stay on this Mac.
final class MeetingCalendarService: @unchecked Sendable {
    private let store = EKEventStore()

    var access: MeetingCalendarAccess {
        Self.access(from: EKEventStore.authorizationStatus(for: .event))
    }

    static func access(from status: EKAuthorizationStatus) -> MeetingCalendarAccess {
        switch status {
        case .fullAccess:
            return .granted
        case .writeOnly, .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    func requestAccess() async -> MeetingCalendarAccess {
        if access == .granted { return .granted }
        do {
            let granted = try await store.requestFullAccessToEvents()
            return granted ? .granted : .denied
        } catch {
            log.error("Calendar access request failed: \(error.localizedDescription, privacy: .public)")
            return access
        }
    }

    func fetchMeetings(now: Date = Date()) -> [CalendarMeeting] {
        guard access == .granted else { return [] }
        let from = now.addingTimeInterval(-90)
        let to = now.addingTimeInterval(7200)
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        let matches = store.events(matching: predicate)
        return matches.compactMap { event in
            guard !event.isAllDay else { return nil }
            guard let start = event.startDate, let end = event.endDate else { return nil }
            let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let ident = event.eventIdentifier ?? event.calendarItemIdentifier
            let startUnix = start.timeIntervalSince1970
            let series = ident.isEmpty ? title : ident
            return CalendarMeeting(
                id: "\(series)|\(Int(startUnix))",
                seriesID: series,
                title: title,
                start: startUnix,
                end: end.timeIntervalSince1970
            )
        }
        .sorted { $0.start < $1.start }
    }

    func refreshSources() {
        guard access == .granted else { return }
        store.refreshSourcesIfNecessary()
    }
}
