import Foundation
import Testing
@testable import MeetingShield

@Suite("Scoped occurrence identity")
struct OccurrenceIdentityTests {
    @Test("Accounts and calendars with the same raw event ID keep independent actions")
    func sourceActionsAreIndependent() throws {
        let first = event(account: "account-a", calendar: "calendar-a")
        let second = event(account: "account-b", calendar: "calendar-a")
        let third = event(account: "account-a", calendar: "calendar-b")
        #expect(Set([first, second, third].map(\.occurrenceKey)).count == 3)
        #expect(Set([first, second, third].map(\.id)).count == 3)
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "state.json")
        let state = ReminderStateStore(fileURL: file)
        state.snooze(first.occurrenceKey, until: TestDates.now.addingTimeInterval(20), now: TestDates.now)
        state.muteUntilEventEnd(second.occurrenceKey, now: TestDates.now)
        state.dismiss(third.occurrenceKey, fingerprint: third.materialFingerprint(detectedLinks: []), now: TestDates.now)
        let restored = ReminderStateStore(fileURL: file)
        #expect(restored.state(for: first.occurrenceKey)?.snoozedUntil == TestDates.now.addingTimeInterval(20))
        #expect(restored.state(for: first.occurrenceKey)?.mutedUntilEventEnd == false)
        #expect(restored.state(for: second.occurrenceKey)?.mutedUntilEventEnd == true)
        #expect(restored.state(for: second.occurrenceKey)?.dismissedFingerprint == nil)
        #expect(restored.state(for: third.occurrenceKey)?.mutedUntilEventEnd == false)
        #expect(restored.isDismissed(third.occurrenceKey, currentFingerprint: third.materialFingerprint(detectedLinks: [])))
    }

    @Test("Moving calendars changes source identity without changing the raw provider ID")
    func calendarMoveChangesIdentity() {
        let first = event(account: "account-a", calendar: "calendar-a")
        var moved = first
        moved.calendarID = "calendar-b"
        #expect(first.eventID == moved.eventID)
        #expect(first.occurrenceKey != moved.occurrenceKey)
        #expect(first.id != moved.id)
    }

    @Test("Component separators and sub-millisecond dates cannot collide")
    func serializedIdentityPreservesTypedIdentity() {
        var first = event(account: "account-a", calendar: "calendar-a")
        first.providerID = "provider:part"
        first.eventID = "event"
        var second = first
        second.providerID = "provider"
        second.eventID = "part:event"
        #expect(first.occurrenceKey != second.occurrenceKey)
        #expect(first.id != second.id)
        first.originalStartDate = Date(timeIntervalSinceReferenceDate: 800_000_000.0001)
        second = first
        second.originalStartDate = Date(timeIntervalSinceReferenceDate: 800_000_000.0002)
        #expect(first.occurrenceKey != second.occurrenceKey)
        #expect(first.id != second.id)
    }

    @Test("Scoped IDs are stable across Codable and do not expose account text")
    func roundTripHasOpaqueIdentity() throws {
        var original = event(account: "private-account@example.invalid", calendar: "private-calendar@example.invalid")
        original.originalStartDate = Date(timeIntervalSinceReferenceDate: 800_000_000.0001)
        let decoded = try JSONDecoder().decode(CalendarEventOccurrence.self, from: JSONEncoder().encode(original))
        #expect(decoded.occurrenceKey == original.occurrenceKey)
        #expect(decoded.id == original.id)
        #expect(original.id.hasPrefix("occ-v2:"))
        #expect(!original.id.contains("example.invalid"))
    }

    @Test("Equal Unicode and zero-date keys always produce equal IDs")
    func equalKeysHaveEqualIdentifiers() {
        var first = event(account: "caf\u{00e9}", calendar: "calendar-a")
        var second = event(account: "cafe\u{0301}", calendar: "calendar-a")
        first.originalStartDate = Date(timeIntervalSinceReferenceDate: -0.0)
        second.originalStartDate = Date(timeIntervalSinceReferenceDate: 0.0)
        #expect(first.occurrenceKey == second.occurrenceKey)
        #expect(first.id == second.id)
        second.originalStartDate = nil
        #expect(first.occurrenceKey != second.occurrenceKey)
        #expect(first.id != second.id)
    }

    @Test("Cache extraction cannot substitute another source's link")
    func cacheRetainsEachSourceLink() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        var first = event(account: "account-a", calendar: "calendar-a")
        var second = event(account: "account-b", calendar: "calendar-b")
        first.eventDescription = "https://meet.google.com/aaa-bbbb-ccc"
        second.eventDescription = "https://meet.google.com/ddd-eeee-fff"
        let events = [first, second]
        let extractor = MeetingLinkExtractor()
        let links = Dictionary(events.map { ($0.id, extractor.extractLinks(from: $0)) }, uniquingKeysWith: { first, _ in first })
        let cache = EventCacheStore(fileURL: directory.appending(path: "cache.json"))
        try cache.save(events: events, detectedLinks: links, now: TestDates.now)
        let loaded = try #require(try cache.load(now: TestDates.now))
        #expect(loaded.events.count == 2)
        let firstCached = try #require(loaded.events.first { $0.accountID == first.accountID })
        let secondCached = try #require(loaded.events.first { $0.accountID == second.accountID })
        #expect(firstCached.conferenceLinks == extractor.extractLinks(from: first))
        #expect(secondCached.conferenceLinks == extractor.extractLinks(from: second))
        #expect(loaded.events.allSatisfy { $0.eventDescription == nil })
    }

    @Test("Keyboard selection keeps the chosen source when raw IDs match")
    @MainActor
    func selectionUsesScopedIdentity() {
        let events = [event(account: "account-a", calendar: "calendar-a"), event(account: "account-b", calendar: "calendar-b")]
        let reminders = ReminderScheduler().schedule(candidates: events.map {
            ReminderCandidate(event: $0, detectedLinks: [], leadTime: 120, browserSelection: .systemDefault)
        }, stateStore: ReminderStateStore(), now: TestDates.now)
        let target = AlertKeyTarget(reminders: reminders)
        target.selectedID = reminders[1].id
        #expect(target.selectedReminder?.event.accountID == reminders[1].event.accountID)
        target.update(reminders: reminders.reversed())
        #expect(target.selectedReminder?.event.accountID == reminders[1].event.accountID)
    }

    private func event(account: String, calendar: String) -> CalendarEventOccurrence {
        var event = CalendarEventOccurrence.sample(eventID: "shared-raw-id", title: "Synthetic identity test", startDate: TestDates.now.addingTimeInterval(30), calendarID: calendar)
        event.accountID = account
        return event
    }
}
