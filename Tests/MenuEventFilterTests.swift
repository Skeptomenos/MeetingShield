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
}
