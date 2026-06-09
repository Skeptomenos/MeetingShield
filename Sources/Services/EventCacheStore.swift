import Foundation

struct EventCacheEnvelope: Codable, Sendable {
    var cachedAt: Date
    var events: [CalendarEventOccurrence]
}

struct EventCacheStore: Sendable {
    var fileURL: URL
    var calendar: Calendar

    init(
        fileURL: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MeetingShield/event-cache.json"),
        calendar: Calendar = .current
    ) {
        self.fileURL = fileURL
        self.calendar = calendar
    }

    func save(
        events: [CalendarEventOccurrence],
        detectedLinks: [String: [MeetingLink]],
        settings: AppSettingsSnapshot? = nil,
        now: Date = Date()
    ) throws {
        let cacheableEvents = filteredEvents(events, settings: settings)
        let privacyCopies = cacheableEvents.map { event in
            event.privacyPreservingCacheCopy(detectedLinks: detectedLinks[event.id] ?? event.conferenceLinks)
        }
        let envelope = EventCacheEnvelope(cachedAt: now, events: privacyCopies)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(envelope)
        try data.write(to: fileURL, options: [.atomic])
    }

    func load(
        now: Date = Date(),
        visibleWindowDays: Int = 1,
        settings: AppSettingsSnapshot? = nil
    ) throws -> EventCacheEnvelope? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let envelope = try JSONDecoder().decode(EventCacheEnvelope.self, from: data)
        let retained = retainedEvents(
            filteredEvents(envelope.events, settings: settings),
            now: now,
            visibleWindowDays: visibleWindowDays
        )
        return EventCacheEnvelope(cachedAt: envelope.cachedAt, events: retained)
    }

    func retainedEvents(
        _ events: [CalendarEventOccurrence],
        now: Date,
        visibleWindowDays: Int
    ) -> [CalendarEventOccurrence] {
        let retentionStart = now.addingTimeInterval(-2 * 60 * 60)
        let retentionEnd = calendar.date(
            byAdding: .day,
            value: min(max(visibleWindowDays, 1), 7),
            to: now
        ) ?? now.addingTimeInterval(24 * 60 * 60)

        return events.filter { event in
            event.endDate >= retentionStart && event.startDate <= retentionEnd
        }
    }

    func isStale(_ envelope: EventCacheEnvelope, now: Date = Date()) -> Bool {
        now.timeIntervalSince(envelope.cachedAt) > 24 * 60 * 60
    }

    private func filteredEvents(
        _ events: [CalendarEventOccurrence],
        settings: AppSettingsSnapshot?
    ) -> [CalendarEventOccurrence] {
        guard let settings else { return events }
        return events.filter { settings.protectsEvent($0) }
    }
}
