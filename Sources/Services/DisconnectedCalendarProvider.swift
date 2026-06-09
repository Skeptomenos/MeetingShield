import Foundation

actor DisconnectedCalendarProvider: CalendarProvider {
    let providerID = "disconnected"

    var authState: CalendarProviderAuthState {
        get async { .disconnected }
    }

    func accounts() async -> [ConnectedCalendarAccount] {
        []
    }

    func calendars() async throws -> [UserCalendar] {
        []
    }

    func events(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        []
    }

    func refresh(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        []
    }

    func refresh(in window: CalendarFetchWindow, calendars: [UserCalendar]) async throws -> [CalendarEventOccurrence] {
        []
    }

    func reconnect() async throws {
        throw CalendarProviderError.notConfigured
    }

    func removeAccount(id: String) async throws {}
}
