import Foundation
import Testing
@testable import MeetingShield

@Suite("Legacy cache integrity")
@MainActor
struct LegacyCacheIntegrityTests {
    @Test("Exact repeated legacy occurrences collapse once without rewriting the file")
    func identicalRecordsCollapseOnce() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let event = fixture.event()
        let original = try fixture.writeLegacyCache([event, event, event])

        let unfiltered = try #require(try fixture.cache.loadUnfiltered())
        let retained = try #require(try fixture.cache.load(now: TestDates.now, settings: fixture.settings))

        #expect(unfiltered.events == [event])
        #expect(retained.events == [event])
        #expect(unfiltered.accounts.isEmpty)
        #expect(unfiltered.cachedAt == fixture.cachedAt)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == original)
    }

    @Test("A conflicting full record rejects a legacy cache in either order", arguments: Conflict.allCases, [false, true])
    func conflictingRecordsAreRejected(conflict: Conflict, reversed: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let originalEvent = fixture.event()
        let changedEvent = conflict.changed(originalEvent)
        try #require(originalEvent.occurrenceKey == changedEvent.occurrenceKey)
        try #require(originalEvent != changedEvent)
        let events = reversed ? [changedEvent, originalEvent] : [originalEvent, changedEvent]
        let original = try fixture.writeLegacyCache(events)

        #expect(throws: (any Error).self) { try fixture.cache.loadUnfiltered() }
        #expect(throws: (any Error).self) {
            try fixture.cache.load(now: TestDates.now, settings: fixture.settings)
        }
        #expect(try Data(contentsOf: fixture.cache.fileURL) == original)
    }

    @Test("Filtering cannot conceal a conflicting legacy occurrence", arguments: Visibility.allCases, [false, true])
    func conflictsAreRejectedBeforeFilters(visibility: Visibility, reversed: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let event = visibility.event(fixture.event())
        var conflict = event
        conflict.title = "Synthetic conflicting legacy meeting"
        let settings = visibility.settings(fixture.settings)
        let original = try fixture.writeLegacyCache(reversed ? [conflict, event] : [event, conflict])

        #expect(throws: (any Error).self) {
            try fixture.cache.load(now: TestDates.now, retentionDays: 1, settings: settings)
        }
        #expect(try Data(contentsOf: fixture.cache.fileURL) == original)
    }

    @Test("Account, calendar, and recurrence scopes stay distinct in a legacy file")
    func distinctScopedOccurrencesSurvive() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let event = fixture.event()
        var otherAccount = event
        otherAccount.accountID = "synthetic-other-account"
        var otherCalendar = event
        otherCalendar.calendarID = "synthetic-other-calendar"
        var otherRecurrence = event
        otherRecurrence.originalStartDate = TestDates.start.addingTimeInterval(24 * 60 * 60)
        let events = [event, otherAccount, otherCalendar, otherRecurrence]
        try #require(Set(events.map(\.occurrenceKey)).count == events.count)
        let original = try fixture.writeLegacyCache(events)
        var settings = fixture.settings
        settings.selectedCalendarIDs = Set(events.map(\.calendarID))

        let unfiltered = try #require(try fixture.cache.loadUnfiltered())
        let retained = try #require(try fixture.cache.load(now: TestDates.now, settings: settings))

        #expect(Set(unfiltered.events) == Set(events))
        #expect(unfiltered.events.count == events.count)
        #expect(Set(retained.events) == Set(events))
        #expect(retained.events.count == events.count)
        #expect(unfiltered.accounts.isEmpty)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == original)
    }

    @Test("Unique and valid empty legacy files remain usable across failure and restart", arguments: [false, true])
    func validLegacyFallbackSurvivesRestart(empty: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let events = empty ? [] : [fixture.event()]
        let original = try fixture.writeLegacyCache(events)
        let loaded = try #require(try fixture.cache.loadUnfiltered())
        #expect(loaded.events == events)
        #expect(loaded.accounts.isEmpty)
        #expect(loaded.cachedAt == fixture.cachedAt)

        for _ in 0..<2 {
            let coordinator = fixture.coordinator(settings: fixture.settings)
            for reason in ["launch", "timer"] {
                let outcome = try #require(await coordinator.refresh(reason: reason))
                #expect(!outcome.didSucceed)
                #expect(outcome.events == events)
                #expect(outcome.events?.allSatisfy { $0.isFromCache } == true)
                if reason == "timer" {
                    #expect(outcome.statusMessage?.localizedCaseInsensitiveContains("using local cache") == true)
                }
                #expect(try Data(contentsOf: fixture.cache.fileURL) == original)
            }
        }
    }

    @Test("Repeated failures and restart never claim conflicting legacy data as usable fallback", arguments: Visibility.allCases, [false, true])
    func rejectedLegacyCacheCannotBecomeFallback(visibility: Visibility, reversed: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let event = visibility.event(fixture.event())
        var conflict = event
        conflict.endDate = event.endDate.addingTimeInterval(60)
        let original = try fixture.writeLegacyCache(reversed ? [conflict, event] : [event, conflict])
        let settings = visibility.settings(fixture.settings)

        for _ in 0..<2 {
            let coordinator = fixture.coordinator(settings: settings)
            for reason in ["launch", "timer", "timer"] {
                let outcome = try #require(await coordinator.refresh(reason: reason))
                #expect(!outcome.didSucceed)
                #expect(outcome.events == nil)
                let message = try #require(outcome.statusMessage)
                #expect(!message.isEmpty)
                #expect(!message.localizedCaseInsensitiveContains("using local cache"))
                #expect(coordinator.currentStatusMessage == message)
                #expect(try Data(contentsOf: fixture.cache.fileURL) == original)
            }
        }
    }

    enum Conflict: CaseIterable, Sendable {
        case title, endDate, status, rsvp, busyState, description, link, updatedAt, calendarName, accountName, cacheFlag

        func changed(_ event: CalendarEventOccurrence) -> CalendarEventOccurrence {
            var changed = event
            switch self {
            case .title: changed.title = "Synthetic changed title"
            case .endDate: changed.endDate = event.endDate.addingTimeInterval(60)
            case .status: changed.status = .cancelled
            case .rsvp: changed.rsvpStatus = .declined
            case .busyState: changed.busyState = .free
            case .description: changed.eventDescription = "Synthetic changed description"
            case .link: changed.conferenceLinks = []
            case .updatedAt: changed.updatedAt = TestDates.now.addingTimeInterval(1)
            case .calendarName: changed.calendarDisplayName = "Synthetic changed calendar"
            case .accountName: changed.accountDisplayName = "Synthetic changed account"
            case .cacheFlag: changed.isFromCache = false
            }
            return changed
        }
    }

    enum Visibility: CaseIterable, Sendable {
        case retained, disabledAccount, deselectedCalendar, expired, distant

        func event(_ value: CalendarEventOccurrence) -> CalendarEventOccurrence {
            var event = value
            switch self {
            case .expired:
                event.startDate = TestDates.now.addingTimeInterval(-5 * 60 * 60)
                event.endDate = TestDates.now.addingTimeInterval(-4 * 60 * 60)
            case .distant:
                event.startDate = TestDates.now.addingTimeInterval(10 * 24 * 60 * 60)
                event.endDate = event.startDate.addingTimeInterval(30 * 60)
            case .retained, .disabledAccount, .deselectedCalendar: break
            }
            return event
        }

        func settings(_ value: AppSettingsSnapshot) -> AppSettingsSnapshot {
            var settings = value
            switch self {
            case .disabledAccount: settings.disabledGoogleAccountIDs = ["synthetic-legacy-account"]
            case .deselectedCalendar: settings.selectedCalendarIDs = ["synthetic-selected-other-calendar"]
            case .retained, .expired, .distant: break
            }
            return settings
        }
    }

    private struct Fixture {
        let directory: URL
        let cache: EventCacheStore
        let cachedAt = TestDates.now.addingTimeInterval(-120)

        var settings: AppSettingsSnapshot {
            var settings = AppSettingsSnapshot.defaults
            settings.selectedCalendarIDs = ["synthetic-legacy-calendar"]
            return settings
        }

        init() throws {
            directory = try TestTempDirectory.make()
            cache = EventCacheStore(fileURL: directory.appending(path: "legacy-cache.json"))
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }

        func event() -> CalendarEventOccurrence {
            var event = CalendarEventOccurrence.sample(
                eventID: "synthetic-legacy-occurrence", title: "Synthetic legacy meeting",
                startDate: TestDates.start, calendarID: "synthetic-legacy-calendar", htmlLink: nil
            )
            event.accountID = "synthetic-legacy-account"
            event.recurringEventID = "synthetic-legacy-series"
            event.originalStartDate = TestDates.start
            event.conferenceLinks = [MeetingLink(
                url: URL(string: "https://meet.google.com/synthetic-legacy-link")!,
                kind: .googleMeet, source: .conferenceMetadata
            )]
            event.updatedAt = TestDates.now
            event.isFromCache = true
            return event
        }

        func writeLegacyCache(_ events: [CalendarEventOccurrence]) throws -> Data {
            let encoded = try JSONEncoder().encode(EventCacheEnvelope(cachedAt: cachedAt, events: events))
            var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object.removeValue(forKey: "accounts")
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: cache.fileURL)
            let diskObject = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: cache.fileURL)) as? [String: Any])
            try #require(diskObject["accounts"] == nil)
            return data
        }

        @MainActor
        func coordinator(settings: AppSettingsSnapshot) -> RefreshCoordinator {
            let provider = FakeCalendarProvider()
            provider.refreshError = CalendarProviderError.requestFailed(503)
            return RefreshCoordinator(
                provider: provider, cacheStore: cache, settings: { settings }, now: { TestDates.now },
                diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "diagnostics"), nativeSink: { _, _ in })
            )
        }
    }
}
