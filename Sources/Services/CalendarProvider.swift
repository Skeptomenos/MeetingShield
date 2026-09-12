import Foundation

protocol CalendarProvider: Sendable {
    var providerID: String { get }
    var authState: CalendarProviderAuthState { get async }
    var credentialPersistenceFailures: Set<GoogleOAuthPersistenceFailure> { get async }
    func retryCredentialPersistence() async

    func accounts() async -> [ConnectedCalendarAccount]
    func calendars() async throws -> [UserCalendar]
    func calendarCatalog() async throws -> CalendarCatalog
    func events(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence]
    func refresh(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence]
    func refresh(in window: CalendarFetchWindow, calendars: [UserCalendar]) async throws -> [CalendarEventOccurrence]
    func refreshResult(
        in window: CalendarFetchWindow,
        calendars: [UserCalendar],
        accountIDs: Set<String>
    ) async throws -> CalendarRefreshResult
    func reconnect() async throws
    func removeAccount(id: String) async throws
}

extension CalendarProvider {
    var credentialPersistenceFailures: Set<GoogleOAuthPersistenceFailure> { [] }

    func retryCredentialPersistence() async {}

    func refreshResult(
        in window: CalendarFetchWindow,
        calendars: [UserCalendar],
        accountIDs: Set<String>
    ) async throws -> CalendarRefreshResult {
        .complete(try await refresh(in: window, calendars: calendars))
    }

    func calendarCatalog() async throws -> CalendarCatalog {
        CalendarCatalog(calendars: try await calendars(), isComplete: true)
    }
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
