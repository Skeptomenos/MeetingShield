import Foundation
import Testing
@testable import MeetingShield

@Suite("Legacy cache evidence")
struct LegacyCacheEvidenceTests {
    @Test("Migration reads every cached source while protection retains its filters")
    func unfilteredReadPreservesSourceEvidence() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "cache.json")
        let store = EventCacheStore(fileURL: fileURL)
        let now = Date()
        let selected = CalendarEventOccurrence.sample(
            eventID: "selected-source", title: "Synthetic selected meeting",
            startDate: now.addingTimeInterval(600), calendarID: "primary"
        )
        let ended = CalendarEventOccurrence.sample(
            eventID: "ended-source", title: "Synthetic ended meeting",
            startDate: now.addingTimeInterval(-4 * 60 * 60),
            endDate: now.addingTimeInterval(-3 * 60 * 60), calendarID: "primary"
        )
        let distant = CalendarEventOccurrence.sample(
            eventID: "distant-source", title: "Synthetic distant meeting",
            startDate: now.addingTimeInterval(10 * 24 * 60 * 60), calendarID: "primary"
        )
        let deselected = CalendarEventOccurrence.sample(
            eventID: "deselected-source", title: "Synthetic deselected meeting",
            startDate: now.addingTimeInterval(600), calendarID: "secondary"
        )
        var disabled = CalendarEventOccurrence.sample(
            eventID: "disabled-source", title: "Synthetic disabled meeting",
            startDate: now.addingTimeInterval(600), calendarID: "primary"
        )
        disabled.accountID = "disabled-account"
        let events = [selected, ended, distant, deselected, disabled]
        let cachedAt = now.addingTimeInterval(-60)
        let envelope = EventCacheEnvelope(cachedAt: cachedAt, events: events)
        let before = try JSONEncoder().encode(envelope)
        try before.write(to: fileURL)
        var settings = AppSettingsSnapshot.defaults
        settings.selectedCalendarIDs = ["primary"]
        settings.disabledGoogleAccountIDs = ["disabled-account"]

        let unfiltered = try #require(try store.loadUnfiltered())
        let protected = try #require(try store.load(now: now, retentionDays: 1, settings: settings))

        #expect(unfiltered.events == events)
        #expect(unfiltered.cachedAt == cachedAt)
        #expect(protected.events == [selected])
        #expect(protected.cachedAt == cachedAt)
        #expect(try Data(contentsOf: fileURL) == before)
    }

    @Test("Missing cache reads remain absent without creating a file")
    func missingCacheRemainsAbsent() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "missing-cache.json")
        let store = EventCacheStore(fileURL: fileURL)

        #expect(try store.loadUnfiltered() == nil)
        #expect(try store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("Corrupt cache reads throw without rewriting the evidence")
    func corruptCachePreservesBytes() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "corrupt-cache.json")
        let store = EventCacheStore(fileURL: fileURL)
        let before = Data("synthetic-invalid-cache-json".utf8)
        try before.write(to: fileURL)

        #expect(throws: DecodingError.self) {
            try store.loadUnfiltered()
        }
        #expect(throws: DecodingError.self) {
            try store.load()
        }
        #expect(try Data(contentsOf: fileURL) == before)
    }
}
