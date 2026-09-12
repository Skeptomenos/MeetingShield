import Foundation
import Testing
@testable import MeetingShield

@Suite("Refresh cache coverage")
@MainActor
struct RefreshCacheCoverageTests {
    @Test("Spring DST cannot shorten the fetched 24-hour protection window during cache fallback")
    func springDSTPreservesFetchedEvents() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let nextLocalDay = try #require(fixture.cache.calendar.date(byAdding: .day, value: 1, to: fixture.anchor))
        #expect(nextLocalDay == fixture.anchor.addingTimeInterval(23 * 60 * 60))
        #expect(fixture.settings.visibilityWindow == MenuVisibilityWindow(kind: .nextHours, hours: 1, days: 1))
        let event = fixture.event("inside-protection-window", start: 23.5 * 60 * 60, end: 23.75 * 60 * 60)
        let provider = fixture.provider(events: [event])
        let coordinator = fixture.coordinator(provider: provider)

        let success = try #require(await coordinator.refresh(reason: "timer"))

        let requests = await provider.windows
        let requested = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(requested.start == fixture.anchor.addingTimeInterval(-2 * 60 * 60))
        #expect(requested.end == fixture.anchor.addingTimeInterval(24 * 60 * 60))
        #expect(success.didSucceed)
        #expect(success.events?.map(\.eventID) == [event.eventID])
        let saved = try #require(try fixture.cache.loadUnfiltered())
        #expect(saved.events.map(\.eventID) == [event.eventID])
        #expect(saved.cachedAt == fixture.anchor)
        let savedBytes = try Data(contentsOf: fixture.cache.fileURL)

        await provider.failRefreshes()
        let memoryFallback = try #require(await coordinator.refresh(reason: "timer"))
        let restarted = fixture.coordinator(provider: fixture.provider(events: [], failing: true))
        let diskFallback = try #require(await restarted.refresh(reason: "timer"))

        #expect(!memoryFallback.didSucceed)
        #expect(!diskFallback.didSucceed)
        #expect(memoryFallback.events?.map(\.eventID) == [event.eventID])
        #expect(diskFallback.events?.map(\.eventID) == [event.eventID])
        #expect(try Data(contentsOf: fixture.cache.fileURL) == savedBytes)
    }

    @Test("Repeated failed refreshes and a later restart do not renew the saved timestamp")
    func failuresDoNotRenewCachedAt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let event = fixture.event("persisted-timestamp")
        let provider = fixture.provider(events: [event])
        let coordinator = fixture.coordinator(provider: provider)
        let success = try #require(await coordinator.refresh(reason: "timer"))
        #expect(success.didSucceed)
        let savedBytes = try Data(contentsOf: fixture.cache.fileURL)
        await provider.failRefreshes()

        let firstFailure = try #require(await coordinator.refresh(reason: "timer"))
        let secondFailure = try #require(await coordinator.refresh(reason: "timer"))
        let restarted = fixture.coordinator(
            provider: fixture.provider(events: [], failing: true),
            now: fixture.anchor.addingTimeInterval(10 * 60)
        )
        let restartedFailure = try #require(await restarted.refresh(reason: "timer"))
        let repeatedRestartFailure = try #require(await restarted.refresh(reason: "timer"))

        for outcome in [firstFailure, secondFailure, restartedFailure, repeatedRestartFailure] {
            #expect(!outcome.didSucceed)
            #expect(outcome.events?.map(\.eventID) == [event.eventID])
        }
        let retained = try #require(try fixture.cache.load(
            now: fixture.anchor.addingTimeInterval(10 * 60), settings: fixture.settings
        ))
        #expect(retained.cachedAt == fixture.anchor)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == savedBytes)
    }

    @Test("Offline restart returns only covered cache and network recovery replaces it once")
    func offlineRestartRecoversWithoutDuplicateOrStaleEvents() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let cached = fixture.event("offline-recovery")
        let online = fixture.provider(events: [cached])
        let initial = try #require(await fixture.coordinator(provider: online).refresh(reason: "timer"))
        #expect(initial.didSucceed)
        #expect(initial.events?.map(\.eventID) == [cached.eventID])

        let recovering = fixture.provider(events: [cached], failing: true)
        let restarted = fixture.coordinator(provider: recovering)
        let offline = try #require(await restarted.refresh(reason: "startup"))
        #expect(!offline.didSucceed)
        #expect(offline.events?.map(\.eventID) == [cached.eventID])
        #expect(offline.events?.allSatisfy(\.isFromCache) == true)

        var current = cached
        current.title = "Synthetic recovered meeting"
        current.updatedAt = fixture.anchor.addingTimeInterval(60)
        await recovering.recover(with: [current])

        let recovered = try #require(await restarted.refresh(reason: "timer"))
        #expect(recovered.didSucceed)
        #expect(recovered.events?.map(\.eventID) == [current.eventID])
        #expect(recovered.events?.map(\.title) == [current.title])
        #expect(recovered.events?.allSatisfy { !$0.isFromCache } == true)
        let persisted = try #require(try fixture.cache.loadUnfiltered())
        #expect(persisted.events.map(\.eventID) == [current.eventID])
        #expect(persisted.events.map(\.title) == [current.title])
    }

    @Test("Cache fallback retains an event at the exact two-hour end boundary and retires one before it")
    func endRetentionBoundaryIsInclusive() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let boundary: TimeInterval = -2 * 60 * 60
        let expired = fixture.event("before-boundary", start: boundary - 1800, end: boundary - 0.001)
        let exact = fixture.event("at-boundary", start: boundary - 1800, end: boundary)
        let retained = fixture.event("after-boundary", start: boundary - 1800, end: boundary + 0.001)
        let cachedAt = fixture.anchor.addingTimeInterval(-3 * 60 * 60)
        try fixture.cache.save(
            events: [expired, exact, retained], detectedLinks: [:], settings: fixture.settings, now: cachedAt
        )
        let savedBytes = try Data(contentsOf: fixture.cache.fileURL)
        let coordinator = fixture.coordinator(provider: fixture.provider(events: [], failing: true))

        let outcome = try #require(await coordinator.refresh(reason: "timer"))

        #expect(!outcome.didSucceed)
        #expect(outcome.events?.map(\.eventID) == [exact.eventID, retained.eventID])
        #expect(try fixture.cache.loadUnfiltered()?.cachedAt == cachedAt)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == savedBytes)
    }

    @Test("Newest memory obeys later calendar and account choices", arguments: SelectionChange.allCases)
    func newestMemoryUsesCurrentSelection(change: SelectionChange) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let latestA = fixture.event("latest-a", calendar: fixture.calendarA)
        let latestB = fixture.event("latest-b", calendar: fixture.calendarB)
        let provider = fixture.provider(events: [latestA, latestB])
        let coordinator = fixture.coordinator(provider: provider)
        let success = try #require(await coordinator.refresh(reason: "timer"))
        #expect(success.didSucceed)
        #expect(success.events?.map(\.eventID) == [latestA.eventID, latestB.eventID])
        try fixture.cache.save(
            events: [fixture.event("older-a", calendar: fixture.calendarA), fixture.event("older-b", calendar: fixture.calendarB)],
            detectedLinks: [:], settings: fixture.settings, now: fixture.anchor.addingTimeInterval(-60)
        )
        let olderBytes = try Data(contentsOf: fixture.cache.fileURL)
        let expectedIDs: [String]
        switch change {
        case .deselectCalendar:
            fixture.settings.selectedCalendarIDs = [fixture.calendarB.id]
            expectedIDs = [latestB.eventID]
        case .disableAccount:
            fixture.settings.disabledGoogleAccountIDs = [fixture.calendarA.accountID]
            expectedIDs = [latestB.eventID]
        case .explicitNone:
            fixture.settings.selectedCalendarIDs = []
            #expect(fixture.settings.hasExplicitCalendarSelection)
            expectedIDs = []
        }
        await provider.failRefreshes()

        let firstFailure = try #require(await coordinator.refresh(reason: "timer"))
        let secondFailure = try #require(await coordinator.refresh(reason: "timer"))

        #expect(!firstFailure.didSucceed)
        #expect(!secondFailure.didSucceed)
        #expect(firstFailure.events?.map(\.eventID) == expectedIDs)
        #expect(secondFailure.events?.map(\.eventID) == expectedIDs)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == olderBytes)
    }

    enum SelectionChange: CaseIterable, Sendable {
        case deselectCalendar, disableAccount, explicitNone
    }

    @MainActor
    private final class Fixture {
        let anchor: Date
        let directory: URL
        let cache: EventCacheStore
        let calendarA = UserCalendar(
            id: "synthetic-coverage-a::calendar", accountID: "synthetic-coverage-a",
            displayName: "Synthetic coverage A", isPrimary: true, isSelected: true
        )
        let calendarB = UserCalendar(
            id: "synthetic-coverage-b::calendar", accountID: "synthetic-coverage-b",
            displayName: "Synthetic coverage B", isPrimary: true, isSelected: true
        )
        var settings = AppSettingsSnapshot.defaults

        init() throws {
            anchor = try #require(ISO8601DateFormatter().date(from: "2026-03-28T11:00:00Z"))
            var berlin = Calendar(identifier: .gregorian)
            berlin.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
            directory = try TestTempDirectory.make()
            cache = EventCacheStore(fileURL: directory.appending(path: "event-cache.json"), calendar: berlin)
            settings.visibilityWindow = MenuVisibilityWindow(kind: .nextHours, hours: 1, days: 1)
            settings.selectedCalendarIDs = [calendarA.id, calendarB.id]
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }

        func event(
            _ id: String, calendar: UserCalendar? = nil, start: TimeInterval = 600, end: TimeInterval = 2400
        ) -> CalendarEventOccurrence {
            let calendar = calendar ?? calendarA
            var event = CalendarEventOccurrence.sample(
                eventID: id, title: "Synthetic coverage meeting", startDate: anchor.addingTimeInterval(start),
                endDate: anchor.addingTimeInterval(end), calendarID: calendar.id, htmlLink: nil
            )
            event.providerID = "synthetic-coverage"
            event.accountID = calendar.accountID
            event.timeZoneIdentifier = "Europe/Berlin"
            event.updatedAt = anchor
            return event
        }

        func provider(events: [CalendarEventOccurrence], failing: Bool = false) -> RefreshCacheCoverageProvider {
            RefreshCacheCoverageProvider(calendars: [calendarA, calendarB], events: events, failing: failing)
        }

        func coordinator(provider: RefreshCacheCoverageProvider, now: Date? = nil) -> RefreshCoordinator {
            let fixedNow = now ?? anchor
            return RefreshCoordinator(
                provider: provider, cacheStore: cache, settings: { self.settings }, now: { fixedNow },
                diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "diagnostics"), nativeSink: { _, _ in })
            )
        }
    }
}

private actor RefreshCacheCoverageProvider: CalendarProvider {
    nonisolated let providerID = "synthetic-coverage"
    private let calendarValues: [UserCalendar]
    private var eventValues: [CalendarEventOccurrence]
    private var failing: Bool
    private(set) var windows: [CalendarFetchWindow] = []

    init(calendars: [UserCalendar], events: [CalendarEventOccurrence], failing: Bool) {
        calendarValues = calendars
        eventValues = events
        self.failing = failing
    }

    var authState: CalendarProviderAuthState {
        get async { .connected(accountEmail: "synthetic-coverage@example.invalid") }
    }

    func accounts() async -> [ConnectedCalendarAccount] {
        calendarValues.map { ConnectedCalendarAccount(id: $0.accountID, displayName: $0.displayName) }
    }

    func calendars() async throws -> [UserCalendar] { calendarValues }

    func events(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        try await refresh(in: window)
    }

    func refresh(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        try await refresh(in: window, calendars: calendarValues)
    }

    func refresh(in window: CalendarFetchWindow, calendars: [UserCalendar]) async throws -> [CalendarEventOccurrence] {
        windows.append(window)
        if failing { throw CalendarProviderError.requestFailed(503) }
        let selected = Set(calendars.map(\.id))
        return eventValues.filter {
            selected.contains($0.calendarID) && $0.endDate >= window.start && $0.startDate <= window.end
        }
    }

    func failRefreshes() { failing = true }
    func recover(with events: [CalendarEventOccurrence]) {
        eventValues = events
        failing = false
    }
    func reconnect() async throws {}
    func removeAccount(id: String) async throws {}
}
