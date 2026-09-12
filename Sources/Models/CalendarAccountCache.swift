import Foundation

struct CalendarAccountCache: Codable, Equatable, Sendable {
    struct Coverage: Codable, Equatable, Sendable {
        var calendarIDs: Set<String>
        var window: CalendarFetchWindow
    }

    var account: ConnectedCalendarAccount
    var calendars: [UserCalendar]
    var fetchedAt: Date?
    var coverage: Coverage?
}
