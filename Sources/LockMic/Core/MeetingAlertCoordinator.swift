import AppKit
import Combine
import EventKit
import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "Meetings")

@MainActor
final class MeetingAlertCoordinator: ObservableObject {
    @Published private(set) var access: MeetingCalendarAccess = .notDetermined
    @Published private(set) var isShowing = false
    /// True while the real card is shown with sample data so the user can place it.
    @Published private(set) var isPositioning = false

    private let preferences: PreferencesStore
    private let calendar = MeetingCalendarService()
    private let sound: MeetingAlertSound
    private let window = MeetingAlertWindowController()

    private var events: [CalendarMeeting] = []
    private var pinned: CalendarMeeting?
    private var dismissed: Set<String> = []
    private var snoozedUntil: [String: TimeInterval] = [:]
    private var snoozeReturn: Set<String> = []
    private var lastBeep: [String: TimeInterval] = [:]
    private var shownSecond: Int?
    private var shownTitle: String?
    private var cardSoundEnabled = true
    private var beepEvery: TimeInterval?
    private var tickTimer: Timer?
    private var tickInterval: TimeInterval = MeetingAlertLogic.tick
    private var fetchTimer: Timer?
    private var sourceTimer: Timer?
    private var storeObserver: NSObjectProtocol?
    private var enabled = false
    private var cancellables = Set<AnyCancellable>()

    init(preferences: PreferencesStore, audio: AudioDeviceService) {
        self.preferences = preferences
        self.sound = MeetingAlertSound(audio: audio)
        access = calendar.access
        window.onSnooze = { [weak self] in self?.dismissOrClosePositioning(snooze: true) }
        window.onDismiss = { [weak self] in self?.dismissOrClosePositioning(snooze: false) }
        window.onToggleSound = { [weak self] in self?.toggleSound() }

        preferences.$meetingAlertsEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncEnabled()
            }
            .store(in: &cancellables)
        preferences.$shareAnonymousUsage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncEnabled()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshAccess()
            }
            .store(in: &cancellables)
    }

    func start() {
        syncEnabled()
    }

    func stop() {
        setRunning(false)
    }

    func syncEnabled() {
        let on = preferences.featuresEnabled && preferences.meetingAlertsEnabled
        setRunning(on)
    }

    func requestAccessAndEnable() {
        Task { @MainActor in
            preferences.meetingAlertsEnabled = true
            access = await calendar.requestAccess()
            if access == .granted {
                refreshEvents()
                syncEnabled()
            }
        }
    }

    func openPrivacySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    /// Show the real alert window with sample data so it can be dragged and resized.
    /// A genuine upcoming meeting takes over the card as soon as one appears.
    func showPositioningCard() {
        guard pinned == nil else { return }
        isPositioning = true
        cardSoundEnabled = preferences.meetingAlertSoundEnabled
        showPositioningSnapshot()
    }

    private func showPositioningSnapshot() {
        window.show(MeetingAlertSnapshot(
            title: L10n.meetingUntitled,
            start: Date().timeIntervalSince1970 + MeetingAlertLogic.lookahead,
            remaining: MeetingAlertLogic.lookahead,
            duration: MeetingAlertLogic.lookahead,
            soundEnabled: cardSoundEnabled
        ))
        isShowing = true
    }

    private func dismissOrClosePositioning(snooze: Bool) {
        if isPositioning, pinned == nil {
            closeCard()
        } else if snooze {
            snoozeCurrent()
        } else {
            dismissCurrent()
        }
    }

    func dismissCurrent() {
        if let id = pinned?.id {
            dismissed.insert(id)
            UsageReporter.record(.meetingAlertDismissed, source: .hud)
        }
        closeCard()
    }

    func refreshAccess() {
        access = calendar.access
        if enabled, access == .granted {
            refreshEvents()
        }
    }

    private func setRunning(_ on: Bool) {
        guard enabled != on else {
            if on { refreshAccess() }
            return
        }
        enabled = on
        if on {
            access = calendar.access
            startTimers()
            refreshEvents()
        } else {
            stopTimers()
            closeCard()
        }
    }

    private func startTimers() {
        stopTimers()
        scheduleTick(MeetingAlertLogic.tick)

        let fetch = Timer(timeInterval: MeetingAlertLogic.fetchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshEvents() }
        }
        RunLoop.main.add(fetch, forMode: .common)
        fetchTimer = fetch

        let sources = Timer(timeInterval: MeetingAlertLogic.sourceRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.calendar.refreshSources()
                self?.refreshEvents()
            }
        }
        RunLoop.main.add(sources, forMode: .common)
        sourceTimer = sources

        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshEvents() }
        }
    }

    /// The timer is already on the main run loop. Reschedule only when the cadence changes.
    private func scheduleTick(_ interval: TimeInterval) {
        tickTimer?.invalidate()
        tickInterval = interval
        let tick = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        tickTimer = tick
    }

    private func stopTimers() {
        tickTimer?.invalidate()
        fetchTimer?.invalidate()
        sourceTimer?.invalidate()
        tickTimer = nil
        fetchTimer = nil
        sourceTimer = nil
        tickInterval = MeetingAlertLogic.tick
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
            self.storeObserver = nil
        }
    }

    private func refreshEvents() {
        access = calendar.access
        guard access == .granted else {
            events = []
            return
        }
        events = calendar.fetchMeetings()
    }

    private func tick() {
        guard enabled else { return }
        let now = Date().timeIntervalSince1970
        let upcoming = MeetingAlertLogic.selectUpcoming(
            events: events,
            now: now,
            pinned: pinned,
            dismissed: dismissed,
            snoozedUntil: snoozedUntil,
            snoozeReturn: snoozeReturn
        )
        guard let upcoming else {
            if tickInterval != MeetingAlertLogic.tick {
                scheduleTick(MeetingAlertLogic.tick)
            }
            if !isPositioning { closeCard() }
            return
        }
        isPositioning = false
        if snoozeReturn.contains(upcoming.id) {
            snoozeReturn.remove(upcoming.id)
        }
        pinned = upcoming
        let remaining = MeetingAlertLogic.clampedRemaining(upcoming.start - now, duration: upcoming.duration)
        let title = upcoming.title.isEmpty ? L10n.meetingUntitled : upcoming.title
        let second = Int(remaining.rounded(.towardZero))
        if shownSecond != second || shownTitle != title || !window.isVisible {
            shownSecond = second
            shownTitle = title
            if !window.isVisible {
                cardSoundEnabled = preferences.meetingAlertSoundEnabled
                UsageReporter.record(.meetingAlertShown, source: .hud)
            }
            window.show(MeetingAlertSnapshot(
                title: title,
                start: upcoming.start,
                remaining: remaining,
                duration: upcoming.duration,
                soundEnabled: cardSoundEnabled
            ))
            isShowing = true
        }
        updateSound(id: upcoming.id, remaining: remaining)
        let nextTick = MeetingAlertLogic.tickInterval(remaining: remaining)
        if nextTick != tickInterval {
            scheduleTick(nextTick)
        }
    }

    private func updateSound(id: String, remaining: TimeInterval) {
        guard cardSoundEnabled else {
            sound.stop()
            return
        }
        guard MeetingAlertLogic.shouldPlayAlert(remaining: remaining) else {
            sound.stop()
            beepEvery = nil
            return
        }
        let interval = MeetingAlertLogic.beepInterval(remaining: remaining)
        let now = ProcessInfo.processInfo.systemUptime
        let last = lastBeep[id]
        if last == nil
            || MeetingAlertLogic.beepIsDue(elapsed: now - last!, interval: interval, tick: tickInterval)
            || beepEvery != interval {
            let allOutputs = preferences.meetingAlertSoundAllOutputs
                && MeetingAlertLogic.playsOnAllOutputs(remaining: remaining)
            sound.play(allPhysical: allOutputs)
            lastBeep[id] = now
            beepEvery = interval
        }
    }

    private func snoozeCurrent() {
        guard let pinned else { return }
        let remaining = pinned.start - Date().timeIntervalSince1970
        let seconds = MeetingAlertLogic.snoozeSeconds(remaining: remaining)
        snoozedUntil[pinned.id] = Date().timeIntervalSince1970 + TimeInterval(seconds)
        snoozeReturn.insert(pinned.id)
        UsageReporter.record(.meetingAlertSnoozed, source: .hud)
        closeCard()
    }

    private func toggleSound() {
        cardSoundEnabled.toggle()
        if isPositioning, pinned == nil {
            showPositioningSnapshot()
            return
        }
        if !cardSoundEnabled {
            sound.stop()
        } else if let pinned {
            lastBeep[pinned.id] = nil
        }
        shownSecond = nil
    }

    private func closeCard() {
        sound.stop()
        window.hide()
        pinned = nil
        shownSecond = nil
        shownTitle = nil
        beepEvery = nil
        isShowing = false
        isPositioning = false
    }
}
