import Foundation
import Testing
@testable import MeetingShield

@Suite("Legacy reminder state migration")
struct LegacyReminderStateTests {
    private let recoveryInterval: TimeInterval = 8 * 24 * 60 * 60

    @Test("A later refresh cannot forget a previously observed source", arguments: [false, true])
    func previouslyObservedSourceRemainsEvidence(restart: Bool) throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        var first = event(account: "account-a")
        let second = event(account: "account-b")
        let old = legacyState(first, dismissed: true)
        first.title = "Materially edited first source"
        let file = try write([old], in: directory)
        let initial = ReminderStateStore(fileURL: file)
        #expect(initial.reconcileLegacyStates(events: [first], now: TestDates.now).unresolvedCount == 1)
        let next = restart ? ReminderStateStore(fileURL: file) : initial

        #expect(next.reconcileLegacyStates(events: [second], now: TestDates.now.addingTimeInterval(60)).unresolvedCount == 1)
        #expect(next.state(for: old.occurrenceKey)?.legacyMigrationBlocked == true)
        #expect(next.state(for: second.occurrenceKey) == nil)
        #expect(ReminderStateStore(fileURL: file).state(for: old.occurrenceKey)?.legacyMigrationBlocked == true)
    }

    @Test("An unchanged migration retries an unsaved quarantine after storage recovers")
    func failedQuarantineWriteRetriesWithoutExtendingDeadline() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = event(account: "account-a")
        let second = event(account: "account-b")
        let old = legacyState(first, dismissed: true)
        let file = try write([old], in: directory)
        let originalBytes = try Data(contentsOf: file)
        let store = ReminderStateStore(fileURL: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)

        #expect(store.reconcileLegacyStates(events: [first, second], now: TestDates.now).unresolvedCount == 1)
        #expect(store.state(for: old.occurrenceKey)?.legacyMigrationBlocked == true)
        try FileManager.default.removeItem(at: file)
        try originalBytes.write(to: file)
        #expect(store.reconcileLegacyStates(events: [first], now: TestDates.now.addingTimeInterval(60)).unresolvedCount == 1)

        let restored = ReminderStateStore(fileURL: file)
        #expect(restored.state(for: old.occurrenceKey)?.legacyMigrationBlocked == true)
        #expect(restored.state(for: old.occurrenceKey)?.legacyRecoveryDeadline == TestDates.now.addingTimeInterval(recoveryInterval))
        #expect(restored.reconcileLegacyStates(events: [first], now: TestDates.now.addingTimeInterval(120)).unresolvedCount == 1)
        #expect(restored.state(for: first.occurrenceKey) == nil)
    }

    @Test("Migration reports only aggregate transitions to actual file and native sinks")
    func diagnosticsContainCountsWithoutSourceContent() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = DiagnosticTestCapture()
        let diagnosticsDirectory = directory.appending(path: "diagnostics")
        let recorder = DiagnosticsRecorder(directory: diagnosticsDirectory, nativeSink: { capture.record($0, $1) })
        var event = event(account: "private-migration-account@example.invalid", calendar: "private-migration-calendar")
        event.title = "Private migration title canary"
        var old = legacyState(event, dismissed: true)
        old.mutedUntilEventEnd = true
        let file = try write([old], in: directory)
        let store = ReminderStateStore(fileURL: file, diagnostics: recorder)
        _ = store.reconcileLegacyStates(events: [event], now: TestDates.now)
        _ = store.reconcileLegacyStates(events: [event], now: TestDates.now.addingTimeInterval(1))
        #expect(capture.payloads.count == 1)
        let record = try #require(JSONSerialization.jsonObject(with: Data(capture.payloads[0].utf8)) as? [String: Any])
        #expect(record["event"] as? String == "legacy_state_migration")
        #expect(record["metadata"] as? [String: String] == ["resolved": "0", "unresolved": "1", "expired": "0"])
        let decoded = try capture.decodedStrings()
        for canary in [event.accountID, event.calendarID, event.eventID, event.title, event.eventDescription ?? "", fingerprint(event).value] {
            #expect(!decoded.contains { $0.contains(canary) })
        }
        let fileLines = try String(contentsOf: diagnosticsDirectory.appending(path: "diagnostics.jsonl"), encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(fileLines == capture.payloads)
        _ = store.reconcileLegacyStates(events: [], now: TestDates.now.addingTimeInterval(recoveryInterval))
        #expect(capture.payloads.count == 2)
    }

    @Test("Old JSON without scope fields retains the newest duplicate record")
    func legacyJSONStillLoads() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = event(account: "account-a")
        let older = legacyState(event)
        var newer = older
        newer.mutedUntilEventEnd = true
        newer.updatedAt = TestDates.now.addingTimeInterval(1)
        let file = try write([older, newer], in: directory)
        let objects = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        let key = try #require(objects.first?["occurrenceKey"] as? [String: Any])
        #expect(key["accountID"] == nil)
        #expect(key["calendarID"] == nil)
        #expect(ReminderStateStore(fileURL: file).state(for: event.occurrenceKey.legacyKey) == newer)
    }

    @Test("A uniquely identified dismissal migrates once and survives restart")
    func dismissalMigratesToItsSource() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = event(account: "account-a")
        let old = legacyState(original, dismissed: true)
        let file = try write([old], in: directory)
        let store = ReminderStateStore(fileURL: file)

        let result = store.reconcileLegacyStates(events: [original], now: TestDates.now)

        #expect(result == .init(resolvedCount: 1, unresolvedCount: 0, expiredCount: 0))
        #expect(store.state(for: old.occurrenceKey) == nil)
        let restored = ReminderStateStore(fileURL: file)
        #expect(restored.isDismissed(original.occurrenceKey, currentFingerprint: fingerprint(original)))
        #expect(restored.state(for: original.occurrenceKey)?.updatedAt == old.updatedAt)
        #expect(restored.reconcileLegacyStates(events: [original], now: TestDates.now).resolvedCount == 0)
    }

    @Test("Prior cache can identify an old dismissal without suppressing materially edited data")
    func priorFingerprintDoesNotSuppressAnEdit() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = event(account: "account-a")
        var edited = original
        edited.title = "Edited synthetic meeting"
        let file = try write([legacyState(original, dismissed: true)], in: directory)
        let store = ReminderStateStore(fileURL: file)

        let result = store.reconcileLegacyStates(events: [edited], cachedEvents: [original], now: TestDates.now)

        #expect(result.resolvedCount == 1)
        #expect(store.isDismissed(original.occurrenceKey, currentFingerprint: fingerprint(original)))
        #expect(!store.isDismissed(edited.occurrenceKey, currentFingerprint: fingerprint(edited)))
        #expect(ReminderPipeline().compute(events: [edited], settings: .defaults, stateStore: store, now: TestDates.now).scheduled.count == 1)
    }

    @Test("Fingerprintless actions and mixed records remain quarantined", arguments: ["snooze", "mute", "mixed"])
    func unknownActionProvenanceIsNeverInferredFromCache(action: String) throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let available = event(account: "account-a")
        let unseenSource = event(account: "account-b")
        #expect(available.occurrenceKey.legacyKey == unseenSource.occurrenceKey.legacyKey)
        var old = legacyState(available, dismissed: action == "mixed")
        old.snoozedUntil = action == "snooze" ? TestDates.start : nil
        old.mutedUntilEventEnd = action != "snooze"
        let file = try write([old], in: directory)
        let store = ReminderStateStore(fileURL: file)

        let result = store.reconcileLegacyStates(events: [available], cachedEvents: [available], now: TestDates.now)

        #expect(result.unresolvedCount == 1)
        #expect(result.resolvedCount == 0)
        #expect(store.state(for: available.occurrenceKey) == nil)
        #expect(store.state(for: unseenSource.occurrenceKey) == nil)
        let retained = try #require(store.state(for: old.occurrenceKey))
        #expect(retained.snoozedUntil == old.snoozedUntil)
        #expect(retained.dismissedFingerprint == old.dismissedFingerprint)
        #expect(retained.mutedUntilEventEnd == old.mutedUntilEventEnd)
        #expect(retained.legacyMigrationBlocked == true)
        #expect(retained.legacyRecoveryDeadline == TestDates.now.addingTimeInterval(recoveryInterval))
        #expect(ReminderPipeline().compute(events: [available], settings: .defaults, stateStore: store, now: TestDates.now).scheduled.count == 1)
        let restored = ReminderStateStore(fileURL: file)
        #expect(restored.reconcileLegacyStates(events: [unseenSource], now: TestDates.now).unresolvedCount == 1)
        #expect(restored.state(for: unseenSource.occurrenceKey) == nil)
    }

    @Test("Observed ambiguity stays blocked after a source disappears and the app restarts")
    func ambiguityIsSticky() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = event(account: "account-a")
        let second = event(account: "account-b")
        #expect(fingerprint(first) == fingerprint(second))
        let old = legacyState(first, dismissed: true)
        let file = try write([old], in: directory)
        let store = ReminderStateStore(fileURL: file)

        #expect(store.reconcileLegacyStates(events: [first], cachedEvents: [second], now: TestDates.now).unresolvedCount == 1)
        #expect(store.state(for: old.occurrenceKey)?.legacyMigrationBlocked == true)
        let restored = ReminderStateStore(fileURL: file)
        #expect(restored.reconcileLegacyStates(events: [first], now: TestDates.now.addingTimeInterval(60)).unresolvedCount == 1)
        #expect(restored.state(for: first.occurrenceKey) == nil)
        #expect(restored.state(for: second.occurrenceKey) == nil)
    }

    @Test("Missing evidence may resolve later when exactly one source becomes known")
    func unresolvedDismissalCanResolveLater() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = event(account: "account-a", calendar: "calendar-a")
        let old = legacyState(first, dismissed: true)
        let file = try write([old], in: directory)
        let store = ReminderStateStore(fileURL: file)

        #expect(store.reconcileLegacyStates(events: [], now: TestDates.now).unresolvedCount == 1)
        #expect(store.state(for: old.occurrenceKey)?.legacyMigrationBlocked != true)
        let restored = ReminderStateStore(fileURL: file)
        #expect(restored.reconcileLegacyStates(events: [first], now: TestDates.now.addingTimeInterval(60)).resolvedCount == 1)
        #expect(restored.isDismissed(first.occurrenceKey, currentFingerprint: fingerprint(first)))
    }

    @Test("A matching fingerprint cannot select one of two colliding sources after an edit")
    func differentCurrentFingerprintsDoNotProveOrigin() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = event(account: "account-a")
        var second = event(account: "account-b")
        let old = legacyState(second, dismissed: true)
        #expect(fingerprint(first) == old.dismissedFingerprint)
        second.title = "Edited second source"
        let file = try write([old], in: directory)
        let store = ReminderStateStore(fileURL: file)

        #expect(store.reconcileLegacyStates(events: [first, second], now: TestDates.now).unresolvedCount == 1)
        #expect(store.state(for: old.occurrenceKey)?.legacyMigrationBlocked == true)
        #expect(store.state(for: first.occurrenceKey) == nil)
        let restored = ReminderStateStore(fileURL: file)
        #expect(restored.reconcileLegacyStates(events: [first], now: TestDates.now).unresolvedCount == 1)
        #expect(restored.state(for: first.occurrenceKey) == nil)
    }

    @Test("An explicit scoped action wins over a legacy dismissal")
    func scopedDestinationWins() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = event(account: "account-a")
        let old = legacyState(event, dismissed: true)
        let file = try write([old], in: directory)
        let store = ReminderStateStore(fileURL: file)
        store.snooze(event.occurrenceKey, until: TestDates.start, now: TestDates.now)
        let explicit = store.state(for: event.occurrenceKey)

        #expect(store.reconcileLegacyStates(events: [event], now: TestDates.now).resolvedCount == 1)
        #expect(store.state(for: event.occurrenceKey) == explicit)
        #expect(store.state(for: old.occurrenceKey) == nil)
        #expect(ReminderStateStore(fileURL: file).state(for: event.occurrenceKey) == explicit)
    }

    @Test("Recovery is bounded from first observation, not old action time or each restart")
    func recoveryDeadlineSurvivesPruneAndRestart() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = event(account: "account-a")
        var old = legacyState(event)
        old.mutedUntilEventEnd = true
        old.updatedAt = TestDates.now.addingTimeInterval(-30 * 24 * 60 * 60)
        let file = try write([old], in: directory)
        let store = ReminderStateStore(fileURL: file)
        #expect(store.reconcileLegacyStates(events: [], now: TestDates.now).unresolvedCount == 1)
        store.prune(endedBefore: TestDates.now.addingTimeInterval(-recoveryInterval), now: TestDates.now)
        let retained = try #require(store.state(for: old.occurrenceKey))
        #expect(retained.updatedAt == old.updatedAt)
        #expect(retained.legacyRecoveryDeadline == TestDates.now.addingTimeInterval(recoveryInterval))
        let before = try Data(contentsOf: file)
        let modifiedBefore = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let restored = ReminderStateStore(fileURL: file)
        #expect(restored.reconcileLegacyStates(events: [], now: TestDates.now.addingTimeInterval(recoveryInterval - 1)).unresolvedCount == 1)
        #expect(restored.state(for: old.occurrenceKey)?.legacyRecoveryDeadline == retained.legacyRecoveryDeadline)
        #expect(try Data(contentsOf: file) == before)
        #expect(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modifiedBefore)
        #expect(restored.reconcileLegacyStates(events: [event], now: TestDates.now.addingTimeInterval(recoveryInterval)) == .init(resolvedCount: 0, unresolvedCount: 0, expiredCount: 1))
        #expect(restored.state(for: old.occurrenceKey) == nil)
        #expect(ReminderStateStore(fileURL: file).state(for: old.occurrenceKey) == nil)
    }

    @Test("Partially scoped records are not guessed into a different source")
    func partialScopeIsQuarantined() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = event(account: "account-a")
        var old = legacyState(event, dismissed: true)
        old.occurrenceKey.calendarID = event.calendarID
        let file = try write([old], in: directory)
        let store = ReminderStateStore(fileURL: file)

        #expect(store.reconcileLegacyStates(events: [event], now: TestDates.now).unresolvedCount == 1)
        #expect(store.state(for: old.occurrenceKey)?.legacyMigrationBlocked == true)
        #expect(store.state(for: event.occurrenceKey) == nil)
    }

    private func event(account: String, calendar: String = "shared-calendar") -> CalendarEventOccurrence {
        var value = CalendarEventOccurrence.sample(eventID: "legacy-shared-id", title: "Synthetic migration", startDate: TestDates.now.addingTimeInterval(60), calendarID: calendar)
        value.accountID = account
        value.eventDescription = "https://meet.google.com/synthetic-migration"
        return value
    }

    private func fingerprint(_ event: CalendarEventOccurrence) -> MaterialChangeFingerprint {
        event.materialFingerprint(detectedLinks: MeetingLinkExtractor().extractLinks(from: event))
    }

    private func legacyState(_ event: CalendarEventOccurrence, dismissed: Bool = false) -> OccurrenceReminderState {
        OccurrenceReminderState(occurrenceKey: event.occurrenceKey.legacyKey, snoozedUntil: nil, dismissedFingerprint: dismissed ? fingerprint(event) : nil, mutedUntilEventEnd: false, updatedAt: TestDates.now.addingTimeInterval(-60))
    }

    private func write(_ states: [OccurrenceReminderState], in directory: URL) throws -> URL {
        let file = directory.appending(path: "state.json")
        try JSONEncoder().encode(states).write(to: file)
        return file
    }
}
