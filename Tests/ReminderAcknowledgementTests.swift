import Foundation
import Testing
@testable import MeetingShield

@Suite("Reminder acknowledgement")
struct ReminderAcknowledgementTests {
    @Test("A matching persisted scoped acknowledgement suppresses scheduling")
    func matchingAcknowledgementSuppressesScheduler() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = event()
        let file = try write([record(event, acknowledged: true)], in: directory)
        let store = ReminderStateStore(fileURL: file)
        let loaded = try #require(store.state(for: event.occurrenceKey))
        let candidate = ReminderCandidate(
            event: event,
            detectedLinks: MeetingLinkExtractor().extractLinks(from: event),
            leadTime: 120,
            browserSelection: .systemDefault
        )

        #expect(loaded.dismissedFingerprint == nil)
        #expect(loaded.snoozedUntil == nil)
        #expect(!loaded.mutedUntilEventEnd)
        #expect(ReminderScheduler().schedule(
            candidates: [candidate], stateStore: ReminderStateStore(), now: TestDates.now
        ).count == 1)
        #expect(ReminderScheduler().schedule(
            candidates: [candidate], stateStore: store, now: TestDates.now
        ).isEmpty)
    }

    @Test("Acknowledgement survives reload without hiding another due meeting")
    func matchingAcknowledgementLeavesOtherMeetingDueAfterReload() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let acknowledged = event()
        let remaining = event(id: "unacknowledged-overlap")
        let file = try write([record(acknowledged, acknowledged: true)], in: directory)
        let initial = ReminderStateStore(fileURL: file)
        let restarted = ReminderStateStore(fileURL: file)

        for store in [initial, restarted] {
            let result = compute([acknowledged, remaining], store: store)
            #expect(result.scheduled.map(\.id) == [remaining.id])
            #expect(result.due.map(\.id) == [remaining.id])
        }
    }

    @Test("Another account or calendar with the same legacy key still alerts", arguments: ["account", "calendar"])
    func acknowledgementDoesNotCrossSourceScope(changedScope: String) throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = event()
        var other = original
        if changedScope == "account" {
            other.accountID = "other-synthetic-account"
        } else {
            other.calendarID = "other-synthetic-calendar"
        }
        let file = try write([record(original, acknowledged: true)], in: directory)
        let store = ReminderStateStore(fileURL: file)

        #expect(other.occurrenceKey.legacyKey == original.occurrenceKey.legacyKey)
        #expect(other.occurrenceKey != original.occurrenceKey)
        #expect(compute([other], store: store).due.map(\.id) == [other.id])
    }

    @Test("A material edit does not inherit the previous acknowledgement", arguments: MaterialEdit.allCases)
    func materialMismatchDoesNotSuppress(edit: MaterialEdit) throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = event()
        var edited = original
        switch edit {
        case .title:
            edited.title = "Synthetic updated meeting"
        case .start:
            edited.startDate = original.startDate.addingTimeInterval(10)
        case .end:
            edited.endDate = original.endDate.addingTimeInterval(60)
        case .link:
            edited.location = "https://meet.google.com/synthetic-acknowledgement-new"
        }
        let file = try write([record(original, acknowledged: true)], in: directory)
        let store = ReminderStateStore(fileURL: file)

        #expect(edited.occurrenceKey == original.occurrenceKey)
        #expect(fingerprint(edited) != fingerprint(original))
        #expect(compute([edited], store: store).due.map(\.id) == [edited.id])
    }

    @Test("An expired accepted deadline cannot suppress an otherwise eligible occurrence", arguments: [-1.0, 0.0])
    func expiredAcknowledgementDoesNotSuppress(endOffset: TimeInterval) throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = event()
        var seeded = record(event, acknowledged: true)
        seeded.acknowledgement?.eventEnd = TestDates.now.addingTimeInterval(endOffset)
        let file = try write([seeded], in: directory)

        #expect(event.endDate > TestDates.now)
        #expect(compute([event], store: ReminderStateStore(fileURL: file)).due.map(\.id) == [event.id])
    }

    @Test("An acknowledged occurrence remains unscheduled at and after its actual end", arguments: [0.0, 1.0])
    func actualEventEndIsNotResurrected(offset: TimeInterval) throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = event()
        let file = try write([record(event, acknowledged: true)], in: directory)
        let result = compute(
            [event], store: ReminderStateStore(fileURL: file), now: event.endDate.addingTimeInterval(offset)
        )

        #expect(result.scheduled.isEmpty)
        #expect(result.due.isEmpty)
    }

    @Test("A persistence round trip retains acknowledgement and every older state field")
    func persistencePreservesAcknowledgementAndExistingState() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let acknowledged = event()
        let acknowledgementRecord = record(acknowledged, acknowledged: true)
        var snoozed = record(event(id: "old-snooze"))
        snoozed.state.snoozedUntil = TestDates.now.addingTimeInterval(30)
        var dismissed = record(event(id: "old-dismissal"))
        dismissed.state.dismissedFingerprint = fingerprint(event(id: "old-dismissal"))
        var muted = record(event(id: "old-mute"))
        muted.state.mutedUntilEventEnd = true
        muted.state.legacyRecoveryDeadline = TestDates.now.addingTimeInterval(600)
        muted.state.legacyMigrationBlocked = false
        muted.state.legacyObservedSource = acknowledged.occurrenceKey
        let oldRecords = [snoozed, dismissed, muted]
        let file = try write([acknowledgementRecord] + oldRecords, in: directory)
        let store = ReminderStateStore(fileURL: file)

        for old in oldRecords {
            #expect(store.state(for: old.state.occurrenceKey) == old.state)
        }
        store.snooze(event(id: "unrelated-write").occurrenceKey, until: TestDates.now.addingTimeInterval(20), now: TestDates.now)
        #expect(!store.isPersistencePending)
        let restarted = ReminderStateStore(fileURL: file)
        for old in oldRecords {
            #expect(restarted.state(for: old.state.occurrenceKey) == old.state)
        }
        let projections = try JSONDecoder().decode([PersistedProjection].self, from: Data(contentsOf: file))
        let persisted = try #require(projections.first { $0.occurrenceKey == acknowledged.occurrenceKey })
        #expect(persisted.acknowledgement == acknowledgementRecord.acknowledgement)
        #expect(compute([acknowledged], store: restarted).due.isEmpty)
    }

    @Test("An unscoped acknowledgement mixed with dismissal is quarantined instead of migrated")
    func unscopedAcknowledgementCannotMigrateWithDismissal() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = event()
        var legacy = record(event, acknowledged: true)
        legacy.state.occurrenceKey = event.occurrenceKey.legacyKey
        legacy.state.dismissedFingerprint = fingerprint(event)
        let file = try write([legacy], in: directory)
        let store = ReminderStateStore(fileURL: file)

        let result = store.reconcileLegacyStates(events: [event], cachedEvents: [event], now: TestDates.now)

        #expect(result.resolvedCount == 0)
        #expect(result.unresolvedCount == 1)
        #expect(store.state(for: event.occurrenceKey) == nil)
        #expect(compute([event], store: store).due.map(\.id) == [event.id])
        let retained = try #require(store.state(for: legacy.state.occurrenceKey))
        #expect(retained.dismissedFingerprint == legacy.state.dismissedFingerprint)
        #expect(retained.legacyMigrationBlocked == true)
        let restarted = ReminderStateStore(fileURL: file)
        #expect(restarted.state(for: legacy.state.occurrenceKey)?.legacyMigrationBlocked == true)
        #expect(restarted.state(for: event.occurrenceKey) == nil)
        let projections = try JSONDecoder().decode([PersistedProjection].self, from: Data(contentsOf: file))
        let persisted = try #require(projections.first { $0.occurrenceKey == legacy.state.occurrenceKey })
        #expect(persisted.acknowledgement == legacy.acknowledgement)
        let quarantined = try #require(restarted.state(for: legacy.state.occurrenceKey))
        let afterEventEnd = event.endDate.addingTimeInterval(1)
        restarted.reconcileAcknowledgements(events: [event], now: afterEventEnd)
        restarted.clearAcknowledgement(legacy.state.occurrenceKey, now: afterEventEnd)
        #expect(restarted.state(for: legacy.state.occurrenceKey) == quarantined)
        #expect(restarted.reconcileLegacyStates(events: [event], now: afterEventEnd).unresolvedCount == 1)
        #expect(restarted.state(for: legacy.state.occurrenceKey) == quarantined)
        #expect(restarted.state(for: event.occurrenceKey) == nil)
    }

    @Test("Acknowledge and Alert Again preserve prior actions and migration fields")
    func acknowledgeAndClearPreserveExistingFields() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = event()
        var seeded = record(event)
        seeded.state.snoozedUntil = TestDates.now.addingTimeInterval(30)
        seeded.state.dismissedFingerprint = fingerprint(event)
        seeded.state.mutedUntilEventEnd = true
        seeded.state.legacyRecoveryDeadline = TestDates.now.addingTimeInterval(600)
        seeded.state.legacyMigrationBlocked = true
        seeded.state.legacyObservedSource = event.occurrenceKey
        let unrelated = record(self.event(id: "unrelated-actions"))
        let file = try write([seeded, unrelated], in: directory)
        let store = ReminderStateStore(fileURL: file)

        store.acknowledge(event.occurrenceKey, fingerprint: fingerprint(event), eventEnd: event.endDate, now: TestDates.now)

        var acknowledged = seeded.state
        acknowledged.acknowledgement = .init(fingerprint: fingerprint(event), eventEnd: event.endDate)
        acknowledged.updatedAt = TestDates.now
        #expect(store.state(for: event.occurrenceKey) == acknowledged)
        #expect(store.state(for: unrelated.state.occurrenceKey) == unrelated.state)
        let restarted = ReminderStateStore(fileURL: file)
        #expect(restarted.state(for: event.occurrenceKey) == acknowledged)
        let clearTime = TestDates.now.addingTimeInterval(1)

        restarted.clearAcknowledgement(event.occurrenceKey, now: clearTime)

        var cleared = seeded.state
        cleared.updatedAt = clearTime
        #expect(restarted.state(for: event.occurrenceKey) == cleared)
        #expect(restarted.state(for: unrelated.state.occurrenceKey) == unrelated.state)
        #expect(ReminderStateStore(fileURL: file).state(for: event.occurrenceKey) == cleared)
        #expect(restarted.isDismissed(event.occurrenceKey, currentFingerprint: fingerprint(event)))
        #expect(compute([event], store: restarted, now: clearTime).scheduled.isEmpty)
    }

    @Test("Old JSON without an acknowledgement key loads absent acknowledgement")
    func oldJSONLoadsWithoutAcknowledgement() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = event()
        var seeded = record(event)
        seeded.state.snoozedUntil = TestDates.now.addingTimeInterval(20)
        seeded.state.dismissedFingerprint = fingerprint(event)
        seeded.state.mutedUntilEventEnd = true
        let file = try write([seeded], in: directory)
        let objects = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        let raw = try #require(objects.first)

        #expect(raw["acknowledgement"] == nil)
        let store = ReminderStateStore(fileURL: file)
        let loaded = try #require(store.state(for: event.occurrenceKey))
        #expect(loaded.acknowledgement == nil)
        #expect(loaded == seeded.state)
        #expect(!store.isAcknowledged(event.occurrenceKey, currentFingerprint: fingerprint(event), now: TestDates.now))
    }

    @Test("A known material edit clears acknowledgement permanently through revert and restart", arguments: ReconciliationEdit.allCases)
    func materialEditReconciliationSurvivesRevert(edit: ReconciliationEdit) throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = event()
        var edited = original
        switch edit {
        case .title:
            edited.title = "Synthetic reconciled title"
        case .start:
            edited.startDate = original.startDate.addingTimeInterval(10)
        case .end:
            edited.endDate = original.endDate.addingTimeInterval(60)
        case .link:
            edited.location = "https://meet.google.com/synthetic-reconciled-link"
        case .room:
            edited.meetingRoom = "Synthetic second room"
        case .eventType:
            edited.eventType = .focusTime
        case .rsvp:
            edited.rsvpStatus = .declined
        }
        let file = try write([record(original, acknowledged: true)], in: directory)
        let store = ReminderStateStore(fileURL: file)
        let before = try #require(store.state(for: original.occurrenceKey))
        #expect(edited.occurrenceKey == original.occurrenceKey)
        #expect(fingerprint(edited) != fingerprint(original))
        #expect(store.isAcknowledged(original.occurrenceKey, currentFingerprint: fingerprint(original), now: TestDates.now))

        store.reconcileAcknowledgements(events: [edited], now: TestDates.now)

        var cleared = before
        cleared.acknowledgement = nil
        cleared.updatedAt = TestDates.now
        #expect(store.state(for: original.occurrenceKey) == cleared)
        let restarted = ReminderStateStore(fileURL: file)
        restarted.reconcileAcknowledgements(events: [original], now: TestDates.now.addingTimeInterval(1))
        #expect(restarted.state(for: original.occurrenceKey) == cleared)
        #expect(!restarted.isAcknowledged(original.occurrenceKey, currentFingerprint: fingerprint(original), now: TestDates.now))
        #expect(compute([original], store: restarted).due.map(\.id) == [original.id])
    }

    @Test("Description-only and calendar-page edits preserve acknowledgement", arguments: ["description", "htmlLink"])
    func nonmaterialEditsPreserveAcknowledgement(field: String) throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = event()
        var edited = original
        if field == "description" {
            edited.eventDescription = "Synthetic revised notes without a meeting link."
        } else {
            edited.htmlLink = try #require(URL(string: "https://example.com/synthetic-updated-calendar-page"))
        }
        let file = try write([record(original, acknowledged: true)], in: directory)
        let store = ReminderStateStore(fileURL: file)
        let before = try #require(store.state(for: original.occurrenceKey))

        #expect(fingerprint(edited) == fingerprint(original))
        store.reconcileAcknowledgements(events: [edited], now: TestDates.now)

        #expect(store.state(for: original.occurrenceKey) == before)
        let restarted = ReminderStateStore(fileURL: file)
        #expect(restarted.state(for: original.occurrenceKey) == before)
        #expect(restarted.isAcknowledged(edited.occurrenceKey, currentFingerprint: fingerprint(edited), now: TestDates.now))
        #expect(compute([edited], store: restarted).due.isEmpty)
    }

    @Test("A calendar move creates an unsuppressed source without transferring prior acknowledgement")
    func calendarMoveDoesNotInheritAcknowledgement() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = event()
        var moved = original
        moved.calendarID = "synthetic-destination-calendar"
        let file = try write([record(original, acknowledged: true)], in: directory)
        let store = ReminderStateStore(fileURL: file)
        let before = try #require(store.state(for: original.occurrenceKey))

        store.reconcileAcknowledgements(events: [moved], now: TestDates.now)

        #expect(moved.occurrenceKey != original.occurrenceKey)
        #expect(store.state(for: original.occurrenceKey) == before)
        #expect(store.state(for: moved.occurrenceKey) == nil)
        let restarted = ReminderStateStore(fileURL: file)
        #expect(restarted.state(for: original.occurrenceKey) == before)
        #expect(!restarted.isAcknowledged(moved.occurrenceKey, currentFingerprint: fingerprint(moved), now: TestDates.now))
        #expect(compute([moved], store: restarted).due.map(\.id) == [moved.id])
    }

    @Test("Stored expiry clears acknowledgement at and after the deadline even without source data", arguments: [0.0, 1.0])
    func expiryReconciliationClearsWithOrWithoutSource(offset: TimeInterval) throws {
        for includeSource in [false, true] {
            let directory = try TestTempDirectory.make()
            defer { try? FileManager.default.removeItem(at: directory) }
            let event = event()
            let file = try write([record(event, acknowledged: true)], in: directory)
            let store = ReminderStateStore(fileURL: file)
            let before = try #require(store.state(for: event.occurrenceKey))
            let now = event.endDate.addingTimeInterval(offset)
            #expect(store.isAcknowledged(event.occurrenceKey, currentFingerprint: fingerprint(event), now: event.endDate.addingTimeInterval(-1)))

            store.reconcileAcknowledgements(events: includeSource ? [event] : [], now: now)

            var cleared = before
            cleared.acknowledgement = nil
            cleared.updatedAt = now
            #expect(store.state(for: event.occurrenceKey) == cleared)
            #expect(!store.isAcknowledged(event.occurrenceKey, currentFingerprint: fingerprint(event), now: now))
            #expect(ReminderStateStore(fileURL: file).state(for: event.occurrenceKey) == cleared)
            #expect(store.nextAcknowledgementExpiry(after: now) == nil)
        }
    }

    @Test("The next expiry includes only future acknowledgements with complete source scope")
    func nextExpiryExcludesUnscopedAndExpiredRecords() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        var legacy = record(event(id: "legacy-expiry"), acknowledged: true)
        legacy.state.occurrenceKey = legacy.state.occurrenceKey.legacyKey
        legacy.acknowledgement?.eventEnd = TestDates.now.addingTimeInterval(1)
        var partial = record(event(id: "partial-expiry"), acknowledged: true)
        partial.state.occurrenceKey.calendarID = nil
        partial.acknowledgement?.eventEnd = TestDates.now.addingTimeInterval(2)
        var expired = record(event(id: "expired"), acknowledged: true)
        expired.acknowledgement?.eventEnd = TestDates.now.addingTimeInterval(-1)
        var boundary = record(event(id: "boundary"), acknowledged: true)
        boundary.acknowledgement?.eventEnd = TestDates.now
        var sooner = record(event(id: "sooner"), acknowledged: true)
        sooner.acknowledgement?.eventEnd = TestDates.now.addingTimeInterval(30)
        var later = record(event(id: "later"), acknowledged: true)
        later.acknowledgement?.eventEnd = TestDates.now.addingTimeInterval(60)
        let file = try write([legacy, partial, expired, boundary, sooner, later, record(event(id: "no-acknowledgement"))], in: directory)
        let store = ReminderStateStore(fileURL: file)

        #expect(store.nextAcknowledgementExpiry(after: TestDates.now) == TestDates.now.addingTimeInterval(30))
        #expect(store.nextAcknowledgementExpiry(after: TestDates.now.addingTimeInterval(30)) == TestDates.now.addingTimeInterval(60))
        #expect(store.nextAcknowledgementExpiry(after: TestDates.now.addingTimeInterval(60)) == nil)
    }

    @Test("A failed acknowledgement write retries unchanged in-memory state after storage recovers")
    func failedAcknowledgementWriteRetries() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = event()
        let seeded = record(event)
        let file = try write([seeded], in: directory)
        let originalBytes = try Data(contentsOf: file)
        let store = ReminderStateStore(fileURL: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)

        store.acknowledge(event.occurrenceKey, fingerprint: fingerprint(event), eventEnd: event.endDate, now: TestDates.now)

        #expect(store.isPersistencePending)
        let pending = try #require(store.state(for: event.occurrenceKey))
        #expect(store.isAcknowledged(event.occurrenceKey, currentFingerprint: fingerprint(event), now: TestDates.now))
        try FileManager.default.removeItem(at: file)
        try originalBytes.write(to: file)
        #expect(ReminderStateStore(fileURL: file).state(for: event.occurrenceKey) == seeded.state)

        store.reconcileAcknowledgements(events: [event], now: TestDates.now.addingTimeInterval(1))

        #expect(!store.isPersistencePending)
        #expect(store.state(for: event.occurrenceKey) == pending)
        #expect(ReminderStateStore(fileURL: file).state(for: event.occurrenceKey) == pending)
    }

    @Test("A failed clear retries through reconciliation or a repeated clear after storage recovers", arguments: [false, true])
    func failedAcknowledgementClearRetries(repeatClear: Bool) throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = event()
        let file = try write([record(event, acknowledged: true)], in: directory)
        let originalBytes = try Data(contentsOf: file)
        let store = ReminderStateStore(fileURL: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)

        store.clearAcknowledgement(event.occurrenceKey, now: TestDates.now)

        #expect(store.isPersistencePending)
        let pending = try #require(store.state(for: event.occurrenceKey))
        #expect(pending.acknowledgement == nil)
        #expect(pending.updatedAt == TestDates.now)
        try FileManager.default.removeItem(at: file)
        try originalBytes.write(to: file)
        #expect(ReminderStateStore(fileURL: file).isAcknowledged(event.occurrenceKey, currentFingerprint: fingerprint(event), now: TestDates.now))
        if repeatClear {
            store.clearAcknowledgement(event.occurrenceKey, now: TestDates.now.addingTimeInterval(1))
        } else {
            store.reconcileAcknowledgements(events: [event], now: TestDates.now.addingTimeInterval(1))
        }

        #expect(!store.isPersistencePending)
        #expect(store.state(for: event.occurrenceKey) == pending)
        #expect(ReminderStateStore(fileURL: file).state(for: event.occurrenceKey) == pending)
    }

    @Test("Unchanged or absent source data does not rewrite a successfully persisted acknowledgement", arguments: [false, true])
    func noOpReconciliationDoesNotRewrite(includeSource: Bool) throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = event()
        let file = try write([record(event, acknowledged: true)], in: directory)
        try FileManager.default.setAttributes([.modificationDate: TestDates.now.addingTimeInterval(-600)], ofItemAtPath: file.path)
        let store = ReminderStateStore(fileURL: file)
        let before = try #require(store.state(for: event.occurrenceKey))
        let bytes = try Data(contentsOf: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let modifiedAt = try #require(attributes[.modificationDate] as? Date)
        let fileNumber = try #require(attributes[.systemFileNumber] as? NSNumber)

        store.reconcileAcknowledgements(events: includeSource ? [event] : [], now: TestDates.now)
        store.reconcileAcknowledgements(events: includeSource ? [event] : [], now: TestDates.now.addingTimeInterval(1))

        #expect(!store.isPersistencePending)
        #expect(store.state(for: event.occurrenceKey) == before)
        #expect(try Data(contentsOf: file) == bytes)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(after[.modificationDate] as? Date == modifiedAt)
        #expect(after[.systemFileNumber] as? NSNumber == fileNumber)
    }

    @Test("Prune retains an absent long-running acknowledgement until its stored end")
    func pruneRetainsFutureAcknowledgementDespiteOldActionDate() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let retentionInterval: TimeInterval = 8 * 24 * 60 * 60
        var longEvent = event(id: "long-running-acknowledgement")
        longEvent.startDate = TestDates.now.addingTimeInterval(-10 * 24 * 60 * 60)
        longEvent.endDate = TestDates.now.addingTimeInterval(24 * 60 * 60)
        var acknowledged = record(longEvent, acknowledged: true)
        acknowledged.state.updatedAt = TestDates.now.addingTimeInterval(-9 * 24 * 60 * 60)
        var stale = record(event(id: "stale-unacknowledged-record"))
        stale.state.updatedAt = acknowledged.state.updatedAt
        let file = try write([acknowledged, stale], in: directory)
        let store = ReminderStateStore(fileURL: file)
        let before = try #require(store.state(for: longEvent.occurrenceKey))

        store.prune(endedBefore: TestDates.now.addingTimeInterval(-retentionInterval), activeKeys: [], now: TestDates.now)

        #expect(store.state(for: longEvent.occurrenceKey) == before)
        #expect(store.state(for: stale.state.occurrenceKey) == nil)
        let restarted = ReminderStateStore(fileURL: file)
        let persisted = try #require(restarted.state(for: longEvent.occurrenceKey))
        #expect(persisted == before)
        #expect(restarted.isAcknowledged(longEvent.occurrenceKey, currentFingerprint: fingerprint(longEvent), now: TestDates.now))
        let beforeEnd = longEvent.endDate.addingTimeInterval(-1)
        restarted.prune(endedBefore: beforeEnd.addingTimeInterval(-retentionInterval), activeKeys: [], now: beforeEnd)
        #expect(restarted.state(for: longEvent.occurrenceKey) == before)
        let atEnd = ReminderStateStore(fileURL: file)

        atEnd.reconcileAcknowledgements(events: [], now: longEvent.endDate)
        atEnd.prune(endedBefore: longEvent.endDate.addingTimeInterval(-retentionInterval), activeKeys: [], now: longEvent.endDate)

        var cleared = before
        cleared.acknowledgement = nil
        cleared.updatedAt = longEvent.endDate
        #expect(atEnd.state(for: longEvent.occurrenceKey) == cleared)
        let afterExpiry = ReminderStateStore(fileURL: file)
        #expect(afterExpiry.state(for: longEvent.occurrenceKey) == cleared)
        let cleanupTime = longEvent.endDate.addingTimeInterval(retentionInterval + 1)

        afterExpiry.prune(endedBefore: cleanupTime.addingTimeInterval(-retentionInterval), activeKeys: [], now: cleanupTime)

        #expect(afterExpiry.state(for: longEvent.occurrenceKey) == nil)
        #expect(ReminderStateStore(fileURL: file).state(for: longEvent.occurrenceKey) == nil)
    }

    enum MaterialEdit: CaseIterable, Sendable {
        case title, start, end, link
    }

    enum ReconciliationEdit: CaseIterable, Sendable {
        case title, start, end, link, room, eventType, rsvp
    }

    private struct PersistedAcknowledgement: Codable, Equatable {
        var fingerprint: MaterialChangeFingerprint
        var eventEnd: Date
    }

    private struct SeededRecord {
        var state: OccurrenceReminderState
        var acknowledgement: PersistedAcknowledgement?
    }

    private struct PersistedProjection: Decodable {
        var occurrenceKey: OccurrenceKey
        var acknowledgement: PersistedAcknowledgement?
    }

    private func event(id: String = "acknowledged-occurrence") -> CalendarEventOccurrence {
        CalendarEventOccurrence.sample(
            eventID: id,
            title: "Synthetic acknowledgement meeting",
            startDate: TestDates.now.addingTimeInterval(60),
            location: "https://meet.google.com/synthetic-acknowledgement"
        )
    }

    private func fingerprint(_ event: CalendarEventOccurrence) -> MaterialChangeFingerprint {
        event.materialFingerprint(detectedLinks: MeetingLinkExtractor().extractLinks(from: event))
    }

    private func record(_ event: CalendarEventOccurrence, acknowledged: Bool = false) -> SeededRecord {
        SeededRecord(
            state: OccurrenceReminderState(
                occurrenceKey: event.occurrenceKey,
                snoozedUntil: nil,
                dismissedFingerprint: nil,
                mutedUntilEventEnd: false,
                updatedAt: TestDates.now.addingTimeInterval(-30)
            ),
            acknowledgement: acknowledged ? PersistedAcknowledgement(fingerprint: fingerprint(event), eventEnd: event.endDate) : nil
        )
    }

    private func compute(
        _ events: [CalendarEventOccurrence], store: ReminderStateStore, now: Date = TestDates.now
    ) -> ReminderPipeline.Result {
        ReminderPipeline().compute(events: events, settings: .defaults, stateStore: store, now: now)
    }

    private func write(_ records: [SeededRecord], in directory: URL) throws -> URL {
        let encoder = JSONEncoder()
        let objects = try records.map { record in
            var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(record.state)) as? [String: Any])
            if let acknowledgement = record.acknowledgement {
                object["acknowledgement"] = try JSONSerialization.jsonObject(with: encoder.encode(acknowledgement))
            }
            return object
        }
        let file = directory.appending(path: "reminder-state.json")
        try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]).write(to: file)
        return file
    }
}
