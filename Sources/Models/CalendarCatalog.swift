import Foundation

struct CalendarCatalog: Sendable {
    struct Account: Sendable {
        var account: ConnectedCalendarAccount
        var result: Result<[UserCalendar], CalendarAccountFailure>
    }

    var calendars: [UserCalendar]
    var isComplete: Bool
    var accountResults: [Account]? = nil
    var inventoryFailure: CalendarAccountFailure? = nil
}
