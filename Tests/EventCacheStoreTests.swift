import Foundation
import Testing
@testable import MeetingShield

@Suite("Event cache")
struct EventCacheStoreTests {
    @Test("Cache drops descriptions and retains only bounded window")
    func cachePrivacyAndRetention() throws {
        let fileURL = try TestTempDirectory.make().appending(path: "cache.json")
        let store = EventCacheStore(fileURL: fileURL)
        let link = MeetingLink(url: URL(string: "https://meet.google.com/cache")!, kind: .googleMeet, source: .description)
        let current = CalendarEventOccurrence.sample(
            eventID: "current",
            title: "Current",
            startDate: TestDates.start,
            meetingRoom: "BER - R99 - Boardroom",
            description: "Sensitive text https://meet.google.com/cache"
        )
        let old = CalendarEventOccurrence.sample(
            eventID: "old",
            title: "Old",
            startDate: TestDates.now.addingTimeInterval(-5 * 60 * 60),
            endDate: TestDates.now.addingTimeInterval(-4 * 60 * 60),
            description: "Old sensitive text"
        )

        try store.save(events: [current, old], detectedLinks: [current.id: [link], old.id: []], now: TestDates.now)
        let loaded = try #require(try store.load(now: TestDates.now, visibleWindowDays: 1))

        #expect(loaded.events.count == 1)
        #expect(loaded.events[0].eventDescription == nil)
        #expect(loaded.events[0].conferenceLinks == [link])
        #expect(loaded.events[0].meetingRoom == "BER - R99 - Boardroom")
    }

    @Test("Cache older than 24 hours is stale")
    func staleCache() {
        let envelope = EventCacheEnvelope(cachedAt: TestDates.now.addingTimeInterval(-25 * 60 * 60), events: [])
        #expect(EventCacheStore(fileURL: URL(fileURLWithPath: "/tmp/unused")).isStale(envelope, now: TestDates.now))
    }

    @Test("Cache persists only protected calendar events")
    func cacheOnlyPersistsProtectedEvents() throws {
        let fileURL = try TestTempDirectory.make().appending(path: "cache.json")
        let store = EventCacheStore(fileURL: fileURL)
        var settings = AppSettingsSnapshot.defaults
        settings.selectedCalendarIDs = ["primary"]
        settings.disabledGoogleAccountIDs = ["disabled-account"]

        let selected = CalendarEventOccurrence.sample(
            eventID: "selected",
            title: "Selected",
            startDate: TestDates.start,
            calendarID: "primary"
        )
        let unchecked = CalendarEventOccurrence.sample(
            eventID: "unchecked",
            title: "Unchecked",
            startDate: TestDates.start,
            calendarID: "secondary"
        )
        var disabled = CalendarEventOccurrence.sample(
            eventID: "disabled",
            title: "Disabled",
            startDate: TestDates.start,
            calendarID: "primary"
        )
        disabled.accountID = "disabled-account"

        try store.save(
            events: [selected, unchecked, disabled],
            detectedLinks: [:],
            settings: settings,
            now: TestDates.now
        )

        let rawEnvelope = try JSONDecoder().decode(EventCacheEnvelope.self, from: Data(contentsOf: fileURL))
        #expect(rawEnvelope.events.map(\.eventID) == ["selected"])

        let loaded = try #require(try store.load(
            now: TestDates.now,
            visibleWindowDays: 1,
            settings: settings
        ))
        #expect(loaded.events.map(\.eventID) == ["selected"])
    }

    @Test("Cache load filters legacy unprotected events")
    func cacheLoadFiltersLegacyUnprotectedEvents() throws {
        let fileURL = try TestTempDirectory.make().appending(path: "cache.json")
        let store = EventCacheStore(fileURL: fileURL)
        var settings = AppSettingsSnapshot.defaults
        settings.selectedCalendarIDs = ["primary"]
        settings.disabledGoogleAccountIDs = ["disabled-account"]

        let selected = CalendarEventOccurrence.sample(
            eventID: "selected",
            title: "Selected",
            startDate: TestDates.start,
            calendarID: "primary"
        )
        let unchecked = CalendarEventOccurrence.sample(
            eventID: "unchecked",
            title: "Unchecked",
            startDate: TestDates.start,
            calendarID: "secondary"
        )
        var disabled = CalendarEventOccurrence.sample(
            eventID: "disabled",
            title: "Disabled",
            startDate: TestDates.start,
            calendarID: "primary"
        )
        disabled.accountID = "disabled-account"
        let envelope = EventCacheEnvelope(
            cachedAt: TestDates.now,
            events: [selected, unchecked, disabled]
        )
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(envelope).write(to: fileURL)

        let loaded = try #require(try store.load(
            now: TestDates.now,
            visibleWindowDays: 1,
            settings: settings
        ))

        #expect(loaded.events.map(\.eventID) == ["selected"])
    }
}
