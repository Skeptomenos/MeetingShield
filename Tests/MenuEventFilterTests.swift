import Foundation
import Testing
@testable import MeetingShield

@Suite("Menu event filter")
struct MenuEventFilterTests {
    @Test("Menu shows in-progress and future events from selected calendars")
    func inProgressAndFutureSelectedCalendarEventsOnly() {
        let now = TestDates.now
        var settings = AppSettingsSnapshot.defaults
        settings.selectedCalendarIDs = ["primary"]
        settings.disabledGoogleAccountIDs = ["disabled-account"]

        // Started but not over: stays visible so the user can rejoin.
        let inProgress = CalendarEventOccurrence.sample(
            eventID: "in-progress",
            title: "In Progress",
            startDate: now.addingTimeInterval(-60),
            endDate: now.addingTimeInterval(30),
            calendarID: "primary"
        )
        let ended = CalendarEventOccurrence.sample(
            eventID: "ended",
            title: "Ended",
            startDate: now.addingTimeInterval(-3600),
            endDate: now.addingTimeInterval(-1800),
            calendarID: "primary"
        )
        let unchecked = CalendarEventOccurrence.sample(
            eventID: "unchecked",
            title: "Unchecked",
            startDate: now.addingTimeInterval(60),
            calendarID: "secondary"
        )
        var disabled = CalendarEventOccurrence.sample(
            eventID: "disabled",
            title: "Disabled Account",
            startDate: now.addingTimeInterval(90),
            calendarID: "primary"
        )
        disabled.accountID = "disabled-account"
        let later = CalendarEventOccurrence.sample(
            eventID: "later",
            title: "Later",
            startDate: now.addingTimeInterval(120),
            calendarID: "primary"
        )
        let next = CalendarEventOccurrence.sample(
            eventID: "next",
            title: "Next",
            startDate: now.addingTimeInterval(30),
            calendarID: "primary"
        )

        let visible = MenuEventFilter.visibleEvents(
            from: [inProgress, ended, unchecked, disabled, later, next],
            settings: settings,
            now: now
        )

        #expect(visible.map(\.title) == ["In Progress", "Next", "Later"])
    }

    @Test("Today stops at the next local midnight")
    func todayStopsAtLocalMidnight() throws {
        let calendar = try berlinCalendar()
        let now = try date(2026, 3, 29, 23, 30, calendar: calendar)
        var settings = selectedSettings(window: .today)
        settings.visibilityWindow.kind = .today
        let beforeMidnight = CalendarEventOccurrence.sample(
            eventID: "before-midnight",
            title: "Before midnight",
            startDate: try date(2026, 3, 29, 23, 59, calendar: calendar)
        )
        let atMidnight = CalendarEventOccurrence.sample(
            eventID: "at-midnight",
            title: "At midnight",
            startDate: try date(2026, 3, 30, 0, 0, calendar: calendar)
        )
        let tomorrow = CalendarEventOccurrence.sample(
            eventID: "tomorrow",
            title: "Tomorrow",
            startDate: try date(2026, 3, 30, 0, 30, calendar: calendar)
        )

        let visible = MenuEventFilter.visibleEvents(
            from: [tomorrow, atMidnight, beforeMidnight], settings: settings, now: now, calendar: calendar
        )

        #expect(visible.map(\.eventID) == ["before-midnight"])
    }

    @Test("Next hours uses a half-open start-time boundary")
    func nextHoursUsesHalfOpenBoundary() {
        let now = TestDates.now
        let settings = selectedSettings(
            window: MenuVisibilityWindow(kind: .nextHours, hours: 2, days: 1)
        )
        let inProgress = CalendarEventOccurrence.sample(
            eventID: "in-progress",
            title: "In progress",
            startDate: now.addingTimeInterval(-60),
            endDate: now.addingTimeInterval(60)
        )
        let inside = CalendarEventOccurrence.sample(
            eventID: "inside",
            title: "Inside",
            startDate: now.addingTimeInterval(2 * 60 * 60 - 1)
        )
        let boundary = CalendarEventOccurrence.sample(
            eventID: "boundary",
            title: "Boundary",
            startDate: now.addingTimeInterval(2 * 60 * 60)
        )

        let visible = MenuEventFilter.visibleEvents(
            from: [boundary, inside, inProgress], settings: settings, now: now
        )

        #expect(visible.map(\.eventID) == ["in-progress", "inside"])
    }

    @Test("Next days follows the local calendar across daylight saving time")
    func nextDaysFollowsLocalCalendarAcrossDST() throws {
        let calendar = try berlinCalendar()
        let now = try date(2026, 3, 28, 12, 0, calendar: calendar)
        let settings = selectedSettings(
            window: MenuVisibilityWindow(kind: .nextDays, hours: 4, days: 1)
        )
        let inside = CalendarEventOccurrence.sample(
            eventID: "inside",
            title: "Inside",
            startDate: try date(2026, 3, 29, 11, 59, calendar: calendar)
        )
        let boundary = CalendarEventOccurrence.sample(
            eventID: "boundary",
            title: "Boundary",
            startDate: try date(2026, 3, 29, 12, 0, calendar: calendar)
        )

        let visible = MenuEventFilter.visibleEvents(
            from: [boundary, inside], settings: settings, now: now, calendar: calendar
        )

        #expect(visible.map(\.eventID) == ["inside"])
    }

    @Test("Next meeting shows the first future event while broader agendas retain in-progress events")
    func nextMeetingShowsFirstFutureEvent() {
        let now = TestDates.now
        let settings = selectedSettings(
            window: MenuVisibilityWindow(kind: .nextMeetingOnly, hours: 4, days: 1)
        )
        let ended = CalendarEventOccurrence.sample(
            eventID: "ended",
            title: "Ended",
            startDate: now.addingTimeInterval(-600),
            endDate: now.addingTimeInterval(-1)
        )
        let inProgress = CalendarEventOccurrence.sample(
            eventID: "in-progress",
            title: "In progress",
            startDate: now.addingTimeInterval(-60),
            endDate: now.addingTimeInterval(60)
        )
        let later = CalendarEventOccurrence.sample(
            eventID: "later",
            title: "Later",
            startDate: now.addingTimeInterval(120)
        )

        let visible = MenuEventFilter.visibleEvents(
            from: [later, ended, inProgress], settings: settings, now: now
        )
        let next = MenuEventFilter.nextMeeting(
            from: [later, ended, inProgress], settings: settings, now: now
        )

        #expect(visible.map(\.eventID) == ["later"])
        #expect(next?.eventID == "later")
    }

    @Test("Next meeting ignores a long-running excluded event")
    func nextMeetingIgnoresLongRunningExcludedEvent() {
        let now = TestDates.now
        let settings = selectedSettings(
            window: MenuVisibilityWindow(kind: .nextMeetingOnly, hours: 4, days: 1)
        )
        let longRunningAllDay = CalendarEventOccurrence.sample(
            eventID: "long-running-all-day",
            title: "Long-running all-day event",
            startDate: now.addingTimeInterval(-3 * 24 * 60 * 60),
            endDate: now.addingTimeInterval(27 * 24 * 60 * 60),
            isAllDay: true
        )
        let nextTimedMeeting = CalendarEventOccurrence.sample(
            eventID: "next-timed-meeting",
            title: "Next timed meeting",
            startDate: now.addingTimeInterval(60 * 60)
        )

        let next = MenuEventFilter.nextMeeting(
            from: [longRunningAllDay, nextTimedMeeting],
            settings: settings,
            now: now
        )

        #expect(next?.eventID == "next-timed-meeting")
    }

    private func selectedSettings(window: MenuVisibilityWindow) -> AppSettingsSnapshot {
        var settings = AppSettingsSnapshot.defaults
        settings.visibilityWindow = window
        settings.selectedCalendarIDs = ["primary"]
        return settings
    }

    private func berlinCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar
    ) throws -> Date {
        try #require(calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        )))
    }
}
