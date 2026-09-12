import Foundation

enum CalendarRefreshResult: Sendable {
    struct Snapshot: Sendable {
        var events: [CalendarEventOccurrence]
        var fetchedCalendarIDs: Set<String>
        var window: CalendarFetchWindow
    }

    struct Account: Sendable {
        var accountID: String
        var result: Result<Snapshot, CalendarAccountFailure>
    }

    case complete([CalendarEventOccurrence])
    case accounts([Account])
}
