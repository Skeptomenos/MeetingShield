import Foundation
import Testing
@testable import MeetingShield

@Suite("Stable demo calendar")
struct MockCalendarProviderTests {
    private let anchor = TestDates.now

    @Test("Refresh never moves existing demo occurrences", arguments: MockCalendarFixtureMode.allCases)
    func refreshPreservesOccurrenceDates(mode: MockCalendarFixtureMode) async throws {
        let clock = AdvancingTestClock(anchor)
        let provider = MockCalendarProvider(fixtureMode: mode, now: { clock.read() })
        let window = CalendarFetchWindow(start: anchor.addingTimeInterval(-3600), end: anchor.addingTimeInterval(172800))
        let before = try await provider.refresh(in: window)

        clock.advance(by: 60)
        let after = try await provider.refresh(in: window)

        #expect(!before.isEmpty)
        #expect(after.map(\.occurrenceKey) == before.map(\.occurrenceKey))
        #expect(after.map(\.startDate) == before.map(\.startDate))
        #expect(after.map(\.endDate) == before.map(\.endDate))
        #expect(after == before)
    }

    @Test("Dismissal survives refresh and reload when fixture time advances")
    func refreshPreservesPersistedDismissal() async throws {
        let clock = AdvancingTestClock(anchor)
        let provider = MockCalendarProvider(fixtureMode: .single, now: { clock.read() })
        let window = CalendarFetchWindow(start: anchor.addingTimeInterval(-3600), end: anchor.addingTimeInterval(86400))
        let event = try #require(try await provider.refresh(in: window).first)
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appending(path: "reminder-state.json")
        let state = ReminderStateStore(fileURL: stateURL)
        let extractor = MeetingLinkExtractor()
        state.dismiss(event.occurrenceKey, fingerprint: event.materialFingerprint(detectedLinks: extractor.extractLinks(from: event)), now: anchor)

        clock.advance(by: 60)
        let refreshed = try await provider.refresh(in: window)
        let restoredState = ReminderStateStore(fileURL: stateURL)
        let result = ReminderPipeline().compute(events: refreshed, settings: .defaults, stateStore: restoredState, now: clock.read())

        #expect(result.due.isEmpty)
        #expect(result.scheduled.isEmpty)
    }

    @Test("Changing the query window still removes old fixture events")
    func queryWindowStillFiltersFixedEvents() async throws {
        let provider = MockCalendarProvider(fixtureMode: .single, now: { anchor })
        let events = try await provider.refresh(in: CalendarFetchWindow(
            start: anchor.addingTimeInterval(86400),
            end: anchor.addingTimeInterval(172800)
        ))
        #expect(events.isEmpty)
    }
}
