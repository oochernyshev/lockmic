// Compile the meeting-card timing helpers without EventKit or AppKit windows.
// Run from the repository root:
// mkdir -p build
// xcrun swiftc -parse-as-library Sources/LockMic/Core/MeetingAlertLogic.swift \
//     Tests/MeetingAlertLogicRegression.swift -o build/meeting-alert-logic-regression
// build/meeting-alert-logic-regression
import Foundation

@main
enum MeetingAlertLogicRegression {
    static func main() {
        var failures = 0

        func expect(_ cond: Bool, _ message: String) {
            if !cond {
                fputs("FAIL: \(message)\n", stderr)
                failures += 1
            }
        }

        expect(MeetingAlertLogic.snoozeSeconds(remaining: 80) == 40, "snooze half of remaining")
        expect(MeetingAlertLogic.snoozeSeconds(remaining: 0) == 30, "snooze after start is 30s")
        expect(MeetingAlertLogic.snoozeSeconds(remaining: -12) == 30, "snooze when overdue is 30s")
        expect(MeetingAlertLogic.snoozeSeconds(remaining: 1.4) == 1, "snooze under 2s is 1s")

        expect(MeetingAlertLogic.phase(remaining: 90) == .upcoming, "upcoming phase")
        expect(MeetingAlertLogic.phase(remaining: 30) == .soon, "soon at 30s")
        expect(MeetingAlertLogic.phase(remaining: 0) == .now, "now at start")
        expect(MeetingAlertLogic.phase(remaining: -5) == .now, "now after start")

        expect(MeetingAlertLogic.phase(remaining: -1799, duration: 1800) == .now, "running meeting is now")
        expect(MeetingAlertLogic.phase(remaining: -1800, duration: 1800) == .finished, "finished at end")
        expect(MeetingAlertLogic.clampedRemaining(-5000, duration: 1800) == -1800, "clock stops at duration")
        expect(MeetingAlertLogic.clampedRemaining(-5, duration: nil) == -5, "no clamp without duration")

        expect(MeetingAlertLogic.countdownText(remaining: 75) == "01:15", "countdown before start")
        expect(MeetingAlertLogic.countdownText(remaining: 0) == "00:00", "clock at start")
        expect(MeetingAlertLogic.countdownText(remaining: -17) == "00:17", "elapsed clock without plus")

        expect(MeetingAlertLogic.ringFraction(remaining: 60, duration: 1800) == 0.5, "lookahead half")
        expect(MeetingAlertLogic.ringFraction(remaining: -900, duration: 1800) == 0.5, "elapsed half")
        let justStarted = MeetingAlertLogic.ringFraction(remaining: -1, duration: 1800)
        expect(abs(justStarted - (1.0 / 1800.0)) < 0.000001, "real elapsed fraction in the first second")
        expect(MeetingAlertLogic.beepInterval(remaining: 4) == 0.5, "fast beep")
        expect(MeetingAlertLogic.beepInterval(remaining: 8) == 1, "one-second beep")
        expect(MeetingAlertLogic.playsOnAllOutputs(remaining: 15), "all outputs at 15s")
        expect(!MeetingAlertLogic.playsOnAllOutputs(remaining: 16), "default output before 15s")

        let first = CalendarMeeting(id: "a|100", seriesID: "a", title: "Standup", start: 100, end: 400)
        let later = CalendarMeeting(id: "b|200", seriesID: "b", title: "Later", start: 200, end: 500)
        let picked = MeetingAlertLogic.selectUpcoming(
            events: [later, first],
            now: 0,
            pinned: nil,
            dismissed: [],
            snoozedUntil: [:],
            snoozeReturn: []
        )
        expect(picked?.id == first.id, "picks the sooner meeting inside lookahead")

        let snoozed = MeetingAlertLogic.selectUpcoming(
            events: [first],
            now: 0,
            pinned: nil,
            dismissed: [],
            snoozedUntil: ["a|100": 50],
            snoozeReturn: []
        )
        expect(snoozed == nil, "hides a snoozed meeting")

        let dismissed = MeetingAlertLogic.selectUpcoming(
            events: [first],
            now: 0,
            pinned: first,
            dismissed: ["a|100"],
            snoozedUntil: [:],
            snoozeReturn: []
        )
        expect(dismissed == nil, "dismissed pinned meeting is gone")

        if failures == 0 {
            print("MeetingAlertLogicRegression: all checks passed")
        } else {
            fputs("MeetingAlertLogicRegression: \(failures) failed\n", stderr)
            exit(1)
        }
    }
}
