import Foundation

struct EventCacheEnvelope: Codable, Equatable, Sendable {
    var cachedAt: Date
    var events: [CalendarEventOccurrence]
    var accounts: [String: CalendarAccountCache]

    init(cachedAt: Date, events: [CalendarEventOccurrence], accounts: [String: CalendarAccountCache] = [:]) {
        self.cachedAt = cachedAt
        self.events = events
        self.accounts = accounts
    }

    private enum CodingKeys: String, CodingKey {
        case cachedAt, events, accounts
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cachedAt = try values.decode(Date.self, forKey: .cachedAt)
        events = try values.decode([CalendarEventOccurrence].self, forKey: .events)
        accounts = try values.decodeIfPresent([String: CalendarAccountCache].self, forKey: .accounts) ?? [:]
    }
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
        try save(envelope: envelope, settings: settings)
    }

    func save(envelope: EventCacheEnvelope, settings: AppSettingsSnapshot? = nil) throws {
        var stored = filteredEnvelope(envelope, settings: settings)
        let extractor = MeetingLinkExtractor()
        stored.events = stored.events.map {
            $0.privacyPreservingCacheCopy(detectedLinks: extractor.extractLinks(from: $0))
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(stored)
        try data.write(to: fileURL, options: [.atomic])
    }

    func load(
        now: Date = Date(),
        retentionDays: Int = 1,
        settings: AppSettingsSnapshot? = nil
    ) throws -> EventCacheEnvelope? {
        guard let envelope = try loadUnfiltered() else { return nil }
        return retainedSnapshot(envelope, now: now, retentionDays: retentionDays, settings: settings)
    }

    func retainedSnapshot(
        _ envelope: EventCacheEnvelope,
        now: Date,
        retentionDays: Int,
        settings: AppSettingsSnapshot?
    ) -> EventCacheEnvelope {
        var retained = filteredEnvelope(envelope, settings: settings)
        retained.events = retainedEvents(retained.events, now: now, retentionDays: retentionDays)
        return retained
    }

    private func filteredEnvelope(_ envelope: EventCacheEnvelope, settings: AppSettingsSnapshot?) -> EventCacheEnvelope {
        guard let settings else { return envelope }
        var filtered = envelope
        filtered.events = filteredEvents(envelope.events, settings: settings)
        filtered.accounts = envelope.accounts.filter { settings.isAccountEnabled($0.key) }
        for accountID in filtered.accounts.keys {
            guard var entry = filtered.accounts[accountID], var coverage = entry.coverage else { continue }
            coverage.calendarIDs = coverage.calendarIDs.filter { settings.isCalendarSelected($0) }
            entry.coverage = coverage
            filtered.accounts[accountID] = entry
        }
        return filtered
    }

    func loadUnfiltered() throws -> EventCacheEnvelope? {
        guard var envelope = try readEnvelope() else { return nil }
        var resolved: [OccurrenceKey: CalendarEventOccurrence] = [:]
        var events: [CalendarEventOccurrence] = []
        for event in envelope.events {
            if let previous = resolved[event.occurrenceKey] {
                guard previous == event else {
                    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Conflicting cached occurrences."))
                }
            } else {
                resolved[event.occurrenceKey] = event
                events.append(event)
            }
        }
        envelope.events = events
        return envelope
    }

    func loadLegacyIdentityEvidence() throws -> [CalendarEventOccurrence] {
        try readEnvelope()?.events ?? []
    }

    private func readEnvelope() throws -> EventCacheEnvelope? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        return try JSONDecoder().decode(EventCacheEnvelope.self, from: data)
    }

    func retainedEvents(
        _ events: [CalendarEventOccurrence],
        now: Date,
        retentionDays: Int
    ) -> [CalendarEventOccurrence] {
        let retentionStart = now.addingTimeInterval(-2 * 60 * 60)
        let calendarEnd = calendar.date(
            byAdding: .day,
            value: min(max(retentionDays, 1), 7),
            to: now
        ) ?? now.addingTimeInterval(24 * 60 * 60)
        let retentionEnd = max(calendarEnd, now.addingTimeInterval(CalendarFetchWindow.minimumProtectionHorizon))

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
