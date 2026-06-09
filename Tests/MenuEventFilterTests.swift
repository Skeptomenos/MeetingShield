import Foundation
import Testing
@testable import MeetingShield

@Suite("Menu event filter")
struct MenuEventFilterTests {
    @Test("Menu shows only future events from selected calendars")
    func futureSelectedCalendarEventsOnly() {
        let now = TestDates.now
        var settings = AppSettingsSnapshot.defaults
        settings.selectedCalendarIDs = ["primary"]
        settings.disabledGoogleAccountIDs = ["disabled-account"]

        let past = CalendarEventOccurrence.sample(
            eventID: "past",
            title: "Past",
            startDate: now.addingTimeInterval(-60),
            endDate: now.addingTimeInterval(30),
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
            from: [past, unchecked, disabled, later, next],
            settings: settings,
            now: now
        )

        #expect(visible.map(\.title) == ["Next", "Later"])
    }
}
