import Foundation

enum MockCalendarFixtureMode: String, CaseIterable, Identifiable, Sendable {
    case quiet
    case single
    case overlap
    case linkless
    case fallback

    var id: String { rawValue }

    static let defaultMode: MockCalendarFixtureMode = .overlap

    static func selected(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MockCalendarFixtureMode? {
        if let value = environment["MEETING_SHIELD_DEMO_CALENDAR"] {
            if value == "1" || value.lowercased() == "true" {
                return .defaultMode
            }
            return MockCalendarFixtureMode(rawValue: value)
        }

        guard let index = arguments.firstIndex(of: "--demo-calendar") else {
            return nil
        }
        let nextIndex = arguments.index(after: index)
        guard nextIndex < arguments.endIndex else {
            return .defaultMode
        }
        return MockCalendarFixtureMode(rawValue: arguments[nextIndex]) ?? .defaultMode
    }
}

actor MockCalendarProvider: CalendarProvider {
    let providerID = "mock"
    private let fixtureMode: MockCalendarFixtureMode
    private let now: @Sendable () -> Date

    init(
        fixtureMode: MockCalendarFixtureMode = .defaultMode,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fixtureMode = fixtureMode
        self.now = now
    }

    var authState: CalendarProviderAuthState {
        get async { .connected(accountEmail: "mock@example.com") }
    }

    func accounts() async -> [ConnectedCalendarAccount] {
        [ConnectedCalendarAccount(id: "mock-account", displayName: "Mock Account")]
    }

    func calendars() async throws -> [UserCalendar] {
        [
            UserCalendar(
                id: "primary",
                accountID: "mock-account",
                accountDisplayName: "Mock Account",
                displayName: "Work",
                isPrimary: true,
                isSelected: true,
                colorHex: "#0A84FF"
            ),
            UserCalendar(
                id: "personal",
                accountID: "mock-account",
                accountDisplayName: "Mock Account",
                displayName: "Personal",
                isPrimary: false,
                isSelected: true,
                colorHex: "#34C759"
            )
        ]
    }

    func events(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        sampleEvents(now: now())
            .filter { $0.endDate >= window.start && $0.startDate <= window.end }
    }

    func refresh(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        try await events(in: window)
    }

    func refresh(in window: CalendarFetchWindow, calendars: [UserCalendar]) async throws -> [CalendarEventOccurrence] {
        let protectedCalendarIDs = Set(calendars.map(\.id))
        return try await events(in: window)
            .filter { protectedCalendarIDs.contains($0.calendarID) }
    }

    func reconnect() async throws {}

    func removeAccount(id: String) async throws {}

    private func sampleEvents(now: Date) -> [CalendarEventOccurrence] {
        switch fixtureMode {
        case .quiet:
            quietEvents(now: now)
        case .single:
            singleEvent(now: now)
        case .overlap:
            overlapEvents(now: now)
        case .linkless:
            linklessEvent(now: now)
        case .fallback:
            fallbackEvent(now: now)
        }
    }

    private func quietEvents(now: Date) -> [CalendarEventOccurrence] {
        let later = now.addingTimeInterval(45 * 60)
        let tomorrow = now.addingTimeInterval(24 * 60 * 60)

        return [
            .sample(
                eventID: "quiet-later",
                title: "Later planning session",
                startDate: later,
                location: "https://example.com/meeting-shield-demo/later"
            ),
            .sample(
                eventID: "quiet-recurring",
                title: "Tomorrow recurring planning",
                startDate: tomorrow,
                description: "Demo link: https://example.com/meeting-shield-demo/tomorrow"
            )
        ]
    }

    private func singleEvent(now: Date) -> [CalendarEventOccurrence] {
        [
            .sample(
                eventID: "standup",
                title: "Design standup",
                startDate: now.addingTimeInterval(95),
                location: "https://example.com/meeting-shield-demo/single"
            )
        ]
    }

    private func overlapEvents(now: Date) -> [CalendarEventOccurrence] {
        [
            .sample(
                eventID: "standup",
                title: "Design standup",
                startDate: now.addingTimeInterval(95),
                location: "https://example.com/meeting-shield-demo/standup"
            ),
            .sample(
                eventID: "overlap-zoom",
                title: "Customer escalation",
                startDate: now.addingTimeInterval(120),
                description: "Demo join link: https://example.com/meeting-shield-demo/escalation"
            )
        ]
    }

    private func linklessEvent(now: Date) -> [CalendarEventOccurrence] {
        [
            .sample(
                eventID: "linkless",
                title: "Walk to office room 4A",
                startDate: now.addingTimeInterval(95),
                location: "Room 4A"
            )
        ]
    }

    private func fallbackEvent(now: Date) -> [CalendarEventOccurrence] {
        [
            .sample(
                eventID: "fallback",
                title: "Fallback browser check",
                startDate: now.addingTimeInterval(95),
                location: "https://example.com/meeting-shield-demo/fallback"
            )
        ]
    }
}
