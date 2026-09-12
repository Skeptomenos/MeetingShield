import Foundation

actor DisconnectedCalendarProvider: CalendarProvider {
    let providerID = "disconnected"
    private let credentialSource: (any CalendarProvider)?

    init(credentialSource: (any CalendarProvider)? = nil) {
        self.credentialSource = credentialSource
    }

    var credentialPersistenceFailures: Set<GoogleOAuthPersistenceFailure> {
        get async { await credentialSource?.credentialPersistenceFailures ?? [] }
    }

    func retryCredentialPersistence() async {
        await credentialSource?.retryCredentialPersistence()
    }

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
