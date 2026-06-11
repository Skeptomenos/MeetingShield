import Foundation
import Testing
@testable import MeetingShield

@Suite("Calendar fetch window")
struct CalendarFetchWindowTests {
    // 2026-06-11 23:00:00 UTC
    private let lateEvening = Date(timeIntervalSince1970: 1_781_218_800)
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test("Window always covers at least 24 hours of offline protection")
    func windowCoversTwentyFourHoursMinimum() {
        let today = MenuVisibilityWindow(kind: .today, hours: 4, days: 1)
        let window = CalendarFetchWindow.protective(
            now: lateEvening,
            visibilityWindow: today,
            calendar: utcCalendar
        )

        // At 23:00, "today" visibility ends at midnight (1h away) — fetch must still cover 24h.
        #expect(window.end >= lateEvening.addingTimeInterval(24 * 60 * 60))
        #expect(window.start == lateEvening.addingTimeInterval(-2 * 60 * 60))
    }

    @Test("Next-hours visibility never shrinks the protective window")
    func nextHoursDoesNotShrinkWindow() {
        let oneHour = MenuVisibilityWindow(kind: .nextHours, hours: 1, days: 1)
        let window = CalendarFetchWindow.protective(
            now: lateEvening,
            visibilityWindow: oneHour,
            calendar: utcCalendar
        )

        #expect(window.end >= lateEvening.addingTimeInterval(24 * 60 * 60))
    }

    @Test("Visibility windows beyond 24 hours extend the fetch window")
    func longVisibilityExtendsWindow() {
        let week = MenuVisibilityWindow(kind: .nextDays, hours: 4, days: 7)
        let window = CalendarFetchWindow.protective(
            now: lateEvening,
            visibilityWindow: week,
            calendar: utcCalendar
        )

        #expect(window.end == week.endDate(from: lateEvening, calendar: utcCalendar))
        #expect(window.end > lateEvening.addingTimeInterval(6 * 24 * 60 * 60))
    }
}
