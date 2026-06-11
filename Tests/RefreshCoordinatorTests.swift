import Foundation
import Testing
@testable import MeetingShield

/// Controllable fake provider for refresh state-machine tests.
final class FakeCalendarProvider: CalendarProvider, @unchecked Sendable {
    let providerID = "fake"
    private let lock = NSLock()

    var authStateValue: CalendarProviderAuthState = .connected(accountEmail: "fake@example.com")
    var calendarsValue: [UserCalendar] = []
    var eventsValue: [CalendarEventOccurrence] = []
    var refreshError: Error?
    private var _refreshCallCount = 0
    private var _inFlightCount = 0
    private var _maxConcurrentRefreshes = 0
    /// Set to make refresh suspend until resumed, for re-entrancy tests.
    var refreshDelayNanoseconds: UInt64 = 0

    var refreshCallCount: Int { lock.withLock { _refreshCallCount } }
    var maxConcurrentRefreshes: Int { lock.withLock { _maxConcurrentRefreshes } }

    var authState: CalendarProviderAuthState {
        get async { lock.withLock { authStateValue } }
    }

    func accounts() async -> [ConnectedCalendarAccount] {
        [ConnectedCalendarAccount(id: "fake@example.com", displayName: "Fake")]
    }

    func calendars() async throws -> [UserCalendar] {
        if let refreshError { throw refreshError }
        return lock.withLock { calendarsValue }
    }

    func events(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        try await refresh(in: window)
    }

    func refresh(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        try await refresh(in: window, calendars: lock.withLock { calendarsValue })
    }

    func refresh(in window: CalendarFetchWindow, calendars: [UserCalendar]) async throws -> [CalendarEventOccurrence] {
        lock.withLock {
            _refreshCallCount += 1
            _inFlightCount += 1
            _maxConcurrentRefreshes = max(_maxConcurrentRefreshes, _inFlightCount)
        }
        defer { lock.withLock { _inFlightCount -= 1 } }
        if refreshDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: refreshDelayNanoseconds)
        }
        if let refreshError { throw refreshError }
        return lock.withLock { eventsValue }
    }

    func reconnect() async throws {}
    func removeAccount(id: String) async throws {}
}

@Suite("Refresh coordinator")
@MainActor
struct RefreshCoordinatorTests {
    private func makeCalendar(id: String = "fake::cal") -> UserCalendar {
        UserCalendar(
            id: id,
            sourceCalendarID: "cal",
            accountID: "fake@example.com",
            accountDisplayName: "Fake",
            displayName: "Cal",
            isPrimary: true,
            isSelected: true,
            colorHex: nil
        )
    }

    private func makeEvent(_ id: String, calendarID: String = "fake::cal") -> CalendarEventOccurrence {
        var event = CalendarEventOccurrence.sample(eventID: id, title: "Event \(id)", startDate: TestDates.start)
        event.calendarID = calendarID
        return event
    }

    private func makeCoordinator(
        provider: FakeCalendarProvider,
        cacheDirectory: URL,
        now: Date = TestDates.now
    ) -> RefreshCoordinator {
        RefreshCoordinator(
            provider: provider,
            cacheStore: EventCacheStore(fileURL: cacheDirectory.appending(path: "event-cache.json")),
            settings: { .defaults },
            now: { now }
        )
    }

    @Test("Successful refresh returns calendars, events, and saves cache")
    func successfulRefresh() async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = FakeCalendarProvider()
        provider.calendarsValue = [makeCalendar()]
        provider.eventsValue = [makeEvent("a"), makeEvent("b")]
        let coordinator = makeCoordinator(provider: provider, cacheDirectory: directory)

        let outcome = await coordinator.refresh(reason: "test")

        #expect(outcome?.didSucceed == true)
        #expect(outcome?.events?.map(\.eventID).sorted() == ["a", "b"])
        #expect(outcome?.statusMessage == nil)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "event-cache.json").path))
    }

    @Test("Failed refresh falls back to cache and reports failure message after repeated failures")
    func failureFallsBackToCache() async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = FakeCalendarProvider()
        provider.calendarsValue = [makeCalendar()]
        provider.eventsValue = [makeEvent("cached")]
        let coordinator = makeCoordinator(provider: provider, cacheDirectory: directory)

        _ = await coordinator.refresh(reason: "seed-cache")
        provider.refreshError = CalendarProviderError.requestFailed(500)
        let first = await coordinator.refresh(reason: "fail-1")
        let second = await coordinator.refresh(reason: "fail-2")

        #expect(first?.didSucceed == false)
        #expect(first?.events?.map(\.eventID) == ["cached"])
        #expect(first?.events?.allSatisfy(\.isFromCache) == true)
        #expect(second?.statusMessage == "Calendar refresh is failing; using local cache.")
    }

    @Test("Auth expiry sets expired state and keeps protecting from cache")
    func authExpiryKeepsCache() async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = FakeCalendarProvider()
        provider.calendarsValue = [makeCalendar()]
        provider.eventsValue = [makeEvent("protected")]
        let coordinator = makeCoordinator(provider: provider, cacheDirectory: directory)
        _ = await coordinator.refresh(reason: "seed-cache")

        provider.refreshError = CalendarProviderError.authExpired("token revoked")
        let outcome = await coordinator.refresh(reason: "auth-fail")

        #expect(outcome?.authState == .expired(reason: "token revoked"))
        #expect(outcome?.statusMessage == "Calendar authorization expired: token revoked")
        #expect(outcome?.events?.map(\.eventID) == ["protected"])
    }

    @Test("Disconnected provider skips fetch but loads cache")
    func disconnectedSkipsButLoadsCache() async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = FakeCalendarProvider()
        provider.calendarsValue = [makeCalendar()]
        provider.eventsValue = [makeEvent("cached")]
        let coordinator = makeCoordinator(provider: provider, cacheDirectory: directory)
        _ = await coordinator.refresh(reason: "seed-cache")

        provider.authStateValue = .disconnected
        let outcome = await coordinator.refresh(reason: "disconnected")

        #expect(outcome?.skipped == true)
        #expect(provider.refreshCallCount == 1, "skipped refresh must not hit the provider")
        #expect(outcome?.events?.map(\.eventID) == ["cached"])
        #expect(outcome?.statusMessage == "Connect Google Calendar to start protecting meetings.")
    }

    @Test("Concurrent refresh requests coalesce: one in flight plus one trailing")
    func concurrentRefreshesCoalesce() async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = FakeCalendarProvider()
        provider.calendarsValue = [makeCalendar()]
        provider.eventsValue = [makeEvent("a")]
        provider.refreshDelayNanoseconds = 100_000_000
        let coordinator = makeCoordinator(provider: provider, cacheDirectory: directory)

        async let first = coordinator.refresh(reason: "first")
        async let second = coordinator.refresh(reason: "second")
        async let third = coordinator.refresh(reason: "third")
        let outcomes = await [first, second, third]

        #expect(provider.maxConcurrentRefreshes == 1, "provider must never see overlapping refreshes")
        #expect(provider.refreshCallCount <= 2, "burst of requests coalesces into at most one trailing refresh")
        #expect(outcomes.compactMap { $0 }.count >= 1)
    }
}

@Suite("Reminder pipeline")
@MainActor
struct ReminderPipelineTests {
    @Test("Pipeline filters ineligible events and surfaces due reminders")
    func pipelineFiltersAndSchedules() {
        let pipeline = ReminderPipeline()
        let store = ReminderStateStore()
        let eligible = CalendarEventOccurrence.sample(eventID: "soon", title: "Soon", startDate: TestDates.now.addingTimeInterval(60))
        let declined = CalendarEventOccurrence.sample(eventID: "declined", title: "Declined", startDate: TestDates.start, rsvpStatus: .declined)
        let later = CalendarEventOccurrence.sample(eventID: "later", title: "Later", startDate: TestDates.now.addingTimeInterval(3600))

        let result = pipeline.compute(
            events: [eligible, declined, later],
            settings: .defaults,
            stateStore: store,
            now: TestDates.now
        )

        #expect(result.scheduled.map(\.id).sorted() == ["mock:later", "mock:soon"])
        #expect(result.due.map(\.id) == ["mock:soon"])
    }

    @Test("Snoozed reminders return at the snooze date, dismissed ones never")
    func pipelineHonorsSnoozeAndDismiss() {
        let pipeline = ReminderPipeline()
        let store = ReminderStateStore()
        let snoozed = CalendarEventOccurrence.sample(eventID: "snoozed", title: "Snoozed", startDate: TestDates.now.addingTimeInterval(120))
        let dismissed = CalendarEventOccurrence.sample(eventID: "dismissed", title: "Dismissed", startDate: TestDates.now.addingTimeInterval(120))
        store.snooze(snoozed.occurrenceKey, until: TestDates.now.addingTimeInterval(60), now: TestDates.now)
        store.dismiss(dismissed.occurrenceKey, fingerprint: dismissed.materialFingerprint(detectedLinks: []))

        let result = pipeline.compute(
            events: [snoozed, dismissed],
            settings: .defaults,
            stateStore: store,
            now: TestDates.now
        )

        #expect(result.scheduled.map(\.id) == ["mock:snoozed"])
        #expect(result.scheduled[0].isSnoozed)
        #expect(result.scheduled[0].fireDate == TestDates.now.addingTimeInterval(60))
        #expect(result.due.isEmpty)
    }
}

@Suite("Reminder presentation decision")
struct ReminderPresentationDecisionTests {
    private func reminder(_ id: String) -> ScheduledReminder {
        ScheduledReminder(
            event: .sample(eventID: id, title: id, startDate: TestDates.start),
            detectedLinks: [],
            fireDate: TestDates.now,
            browserSelection: .systemDefault,
            isSnoozed: false
        )
    }

    @Test("Full screen when active reminders and no quiet channel")
    func fullScreenByDefault() {
        let decision = ReminderPresentationDecision.decide(
            due: [reminder("a")],
            previousIDs: [],
            isPresentationMode: false,
            inWakeGrace: false,
            alertAlreadyShowing: false
        )

        #expect(decision == .presentFullScreen)
    }

    @Test("Notifications during presentation mode and wake grace")
    func notificationsInQuietModes() {
        for (presentation, grace) in [(true, false), (false, true), (true, true)] {
            let decision = ReminderPresentationDecision.decide(
                due: [reminder("a")],
                previousIDs: [],
                isPresentationMode: presentation,
                inWakeGrace: grace,
                alertAlreadyShowing: false
            )
            #expect(decision == .deliverNotifications)
        }
    }

    @Test("Unchanged due set with visible alert is a no-op")
    func unchangedDueSetSkips() {
        let due = [reminder("a")]
        let decision = ReminderPresentationDecision.decide(
            due: due,
            previousIDs: due.map(\.id),
            isPresentationMode: false,
            inWakeGrace: false,
            alertAlreadyShowing: true
        )

        #expect(decision == .keepCurrent)
    }

    @Test("Empty due set clears any alert")
    func emptyDueSetClears() {
        let decision = ReminderPresentationDecision.decide(
            due: [],
            previousIDs: ["mock:a"],
            isPresentationMode: false,
            inWakeGrace: false,
            alertAlreadyShowing: true
        )

        #expect(decision == .clear)
    }
}
