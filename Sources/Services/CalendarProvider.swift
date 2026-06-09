import Foundation

protocol CalendarProvider: Sendable {
    var providerID: String { get }
    var authState: CalendarProviderAuthState { get async }

    func accounts() async -> [ConnectedCalendarAccount]
    func calendars() async throws -> [UserCalendar]
    func events(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence]
    func refresh(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence]
    func refresh(in window: CalendarFetchWindow, calendars: [UserCalendar]) async throws -> [CalendarEventOccurrence]
    func reconnect() async throws
    func removeAccount(id: String) async throws
}

enum CalendarProviderError: Error, LocalizedError, Sendable {
    case notConfigured
    case disconnected
    case authExpired(String)
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Google Calendar is not configured."
        case .disconnected:
            "Calendar account is disconnected."
        case .authExpired(let reason):
            "Calendar authorization expired: \(reason)"
        case .invalidResponse:
            "Calendar returned an invalid response."
        case .requestFailed(let statusCode):
            "Calendar request failed with HTTP \(statusCode)."
        }
    }
}
