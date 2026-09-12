import Foundation

struct RuntimeCalendarProvider: CalendarProvider {
    let providerID = "mock"
    private let fixtures: MockCalendarProvider
    private let laterEvent: CalendarEventOccurrence

    init(mode: MockCalendarFixtureMode, anchor: Date, laterDelay: TimeInterval) {
        fixtures = MockCalendarProvider(fixtureMode: mode, now: { anchor })
        laterEvent = .sample(
            eventID: "runtime-later",
            title: "Runtime later reminder",
            startDate: anchor.addingTimeInterval(120 + laterDelay),
            location: "https://example.com/meeting-shield-demo/later"
        )
    }

    var authState: CalendarProviderAuthState { get async { await fixtures.authState } }

    func accounts() async -> [ConnectedCalendarAccount] { await fixtures.accounts() }
    func calendars() async throws -> [UserCalendar] { try await fixtures.calendars() }

    func events(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        var events = try await fixtures.events(in: window)
        if laterEvent.endDate >= window.start, laterEvent.startDate <= window.end {
            events.append(laterEvent)
        }
        return events
    }

    func refresh(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        try await events(in: window)
    }

    func refresh(in window: CalendarFetchWindow, calendars: [UserCalendar]) async throws -> [CalendarEventOccurrence] {
        let ids = Set(calendars.map(\.id))
        return try await events(in: window).filter { ids.contains($0.calendarID) }
    }

    func reconnect() async throws {}
    func removeAccount(id: String) async throws {}
}
