import Foundation
import Testing
@testable import MeetingShield

@Suite("Legacy migration controller integration")
@MainActor
struct LegacyMigrationControllerTests {
    @Test("Conflicting disabled legacy cache records retain dismissal provenance across replacement and restart", arguments: [false, true])
    func rejectedCacheStillProtectsLegacyDismissalProvenance(reversed: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let fresh = fixture.event(account: "account-a")
        let cached = fixture.event(account: "account-b")
        var conflictingCached = cached
        conflictingCached.title = "Synthetic conflicting cached meeting"
        try #require(cached.occurrenceKey == conflictingCached.occurrenceKey)
        try #require(fresh.occurrenceKey != cached.occurrenceKey)
        try #require(fresh.occurrenceKey.legacyKey == cached.occurrenceKey.legacyKey)
        try #require(fixture.fingerprint(fresh) == fixture.fingerprint(cached))
        try #require(!fixture.settings.snapshot.isAccountEnabled(cached.accountID))
        try fixture.seedLegacyCache(reversed ? [conflictingCached, cached] : [cached, conflictingCached])
        let legacy = fixture.legacyState(cached, dismissed: true)
        try fixture.writeState([legacy])
        let store = ReminderStateStore(fileURL: fixture.stateFile)
        let controller = fixture.controller(events: [fresh], store: store)

        for reason in ["launch", "timer"] {
            await controller.refresh(reason: reason)

            #expect(controller.events.map(\.id) == [fresh.id])
            #expect(controller.scheduledReminders.map(\.id) == [fresh.id])
            #expect(controller.activeReminders.isEmpty)
            #expect(store.state(for: legacy.occurrenceKey)?.legacyMigrationBlocked == true)
            #expect(store.state(for: fresh.occurrenceKey) == nil)
            #expect(store.unresolvedLegacyCount == 1)
            #expect(!store.isPersistencePending)
            #expect(try fixture.cache.loadUnfiltered()?.events.map(\.id) == [fresh.id])
        }
        let deadline = try #require(store.state(for: legacy.occurrenceKey)?.legacyRecoveryDeadline)
        let restartedStore = ReminderStateStore(fileURL: fixture.stateFile)
        let restarted = fixture.controller(events: [fresh], store: restartedStore)

        for reason in ["launch", "timer"] {
            await restarted.refresh(reason: reason)

            #expect(restarted.events.map(\.id) == [fresh.id])
            #expect(restarted.scheduledReminders.map(\.id) == [fresh.id])
            #expect(restarted.activeReminders.isEmpty)
            #expect(restartedStore.state(for: legacy.occurrenceKey)?.legacyMigrationBlocked == true)
            #expect(restartedStore.state(for: legacy.occurrenceKey)?.legacyRecoveryDeadline == deadline)
            #expect(restartedStore.state(for: fresh.occurrenceKey) == nil)
            #expect(restartedStore.unresolvedLegacyCount == 1)
        }
    }

    @Test("Repeated failed provenance writes preserve conflicting legacy bytes until quarantine is durable", arguments: [false, true])
    func rejectedCacheEvidenceSurvivesRepeatedWriteFailureAndRestart(reversed: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let fresh = fixture.event(account: "account-a")
        let cached = fixture.event(account: "account-b")
        var conflictingCached = cached
        conflictingCached.endDate = cached.endDate.addingTimeInterval(60)
        try #require(cached.occurrenceKey == conflictingCached.occurrenceKey)
        try #require(fresh.occurrenceKey.legacyKey == cached.occurrenceKey.legacyKey)
        try #require(fixture.fingerprint(fresh) == fixture.fingerprint(cached))
        try #require(!fixture.settings.snapshot.isAccountEnabled(cached.accountID))
        try fixture.seedLegacyCache(reversed ? [conflictingCached, cached] : [cached, conflictingCached])
        let legacy = fixture.legacyState(cached, dismissed: true)
        try fixture.writeState([legacy])
        let originalState = try Data(contentsOf: fixture.stateFile)
        let originalCache = try Data(contentsOf: fixture.cache.fileURL)

        for _ in 0..<2 {
            let store = ReminderStateStore(fileURL: fixture.stateFile)
            let controller = fixture.controller(events: [fresh], store: store)
            try FileManager.default.removeItem(at: fixture.stateFile)
            try FileManager.default.createDirectory(at: fixture.stateFile, withIntermediateDirectories: false)

            for reason in ["launch", "timer"] {
                await controller.refresh(reason: reason)

                #expect(controller.events.map(\.id) == [fresh.id])
                #expect(controller.scheduledReminders.map(\.id) == [fresh.id])
                #expect(controller.activeReminders.isEmpty)
                #expect(store.state(for: legacy.occurrenceKey)?.legacyMigrationBlocked == true)
                #expect(store.state(for: fresh.occurrenceKey) == nil)
                #expect(store.unresolvedLegacyCount == 1)
                #expect(store.isPersistencePending)
                #expect(try Data(contentsOf: fixture.cache.fileURL) == originalCache)
                #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.stateFile.path).isEmpty)
            }
            try FileManager.default.removeItem(at: fixture.stateFile)
            try originalState.write(to: fixture.stateFile)
        }
        let recoveredStore = ReminderStateStore(fileURL: fixture.stateFile)
        let recovered = fixture.controller(events: [fresh], store: recoveredStore)

        await recovered.refresh(reason: "launch")

        #expect(recovered.scheduledReminders.map(\.id) == [fresh.id])
        #expect(recovered.activeReminders.isEmpty)
        #expect(!recoveredStore.isPersistencePending)
        #expect(recoveredStore.state(for: legacy.occurrenceKey)?.legacyMigrationBlocked == true)
        #expect(recoveredStore.state(for: fresh.occurrenceKey) == nil)
        #expect(try Data(contentsOf: fixture.cache.fileURL) != originalCache)
        #expect(try fixture.cache.loadUnfiltered()?.events.map(\.id) == [fresh.id])
        let restartedStore = ReminderStateStore(fileURL: fixture.stateFile)
        #expect(restartedStore.state(for: legacy.occurrenceKey)?.legacyMigrationBlocked == true)
        #expect(restartedStore.state(for: fresh.occurrenceKey) == nil)
        let restarted = fixture.controller(events: [fresh], store: restartedStore)

        await restarted.refresh(reason: "launch")

        #expect(restarted.scheduledReminders.map(\.id) == [fresh.id])
        #expect(restarted.activeReminders.isEmpty)
        #expect(restartedStore.state(for: legacy.occurrenceKey)?.legacyMigrationBlocked == true)
        #expect(restartedStore.state(for: fresh.occurrenceKey) == nil)
        #expect(restartedStore.unresolvedLegacyCount == 1)
    }

    @Test("Disabled cached source keeps a same-fingerprint dismissal ambiguous after replacement and restart")
    func cachedConflictSurvivesRefreshAndRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let fresh = fixture.event(account: "account-a")
        let cached = fixture.event(account: "account-b")
        #expect(fresh.occurrenceKey.legacyKey == cached.occurrenceKey.legacyKey)
        #expect(fixture.fingerprint(fresh) == fixture.fingerprint(cached))
        try fixture.seedCache([cached])
        let legacy = fixture.legacyState(cached, dismissed: true)
        try fixture.writeState([legacy])
        let store = ReminderStateStore(fileURL: fixture.stateFile)
        let controller = fixture.controller(events: [fresh], store: store)

        await controller.refresh(reason: "launch")

        #expect(controller.events.map(\.id) == [fresh.id])
        #expect(controller.scheduledReminders.map(\.id) == [fresh.id])
        #expect(controller.activeReminders.isEmpty)
        #expect(store.state(for: legacy.occurrenceKey)?.legacyMigrationBlocked == true)
        #expect(store.state(for: fresh.occurrenceKey) == nil)
        #expect(store.unresolvedLegacyCount == 1)
        #expect(try fixture.cache.loadUnfiltered()?.events.map(\.id) == [fresh.id])

        await controller.refresh(reason: "timer")

        #expect(controller.scheduledReminders.map(\.id) == [fresh.id])
        #expect(store.state(for: legacy.occurrenceKey)?.legacyMigrationBlocked == true)
        let restartedStore = ReminderStateStore(fileURL: fixture.stateFile)
        let restarted = fixture.controller(events: [fresh], store: restartedStore)

        await restarted.refresh(reason: "launch")

        #expect(restarted.events.map(\.id) == [fresh.id])
        #expect(restarted.scheduledReminders.map(\.id) == [fresh.id])
        #expect(restarted.activeReminders.isEmpty)
        #expect(restartedStore.state(for: legacy.occurrenceKey)?.legacyMigrationBlocked == true)
        #expect(restartedStore.state(for: fresh.occurrenceKey) == nil)
        #expect(restartedStore.unresolvedLegacyCount == 1)
    }

    @Test("Unique dismissal migrates before the first eligibility computation")
    func uniqueDismissalMigratesBeforeEligibility() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let event = fixture.event(account: "account-a")
        try fixture.seedCache([event])
        let legacy = fixture.legacyState(event, dismissed: true)
        try fixture.writeState([legacy])
        let store = ReminderStateStore(fileURL: fixture.stateFile)
        let controller = fixture.controller(events: [event], store: store)

        await controller.refresh(reason: "launch")

        #expect(controller.events.map(\.id) == [event.id])
        #expect(controller.scheduledReminders.isEmpty)
        #expect(controller.activeReminders.isEmpty)
        #expect(store.unresolvedLegacyCount == 0)
        #expect(store.state(for: legacy.occurrenceKey) == nil)
        #expect(store.isDismissed(event.occurrenceKey, currentFingerprint: fixture.fingerprint(event)))
        #expect(ReminderStateStore(fileURL: fixture.stateFile).isDismissed(event.occurrenceKey, currentFingerprint: fixture.fingerprint(event)))
    }

    @Test("Failed migration persistence preserves prior cache evidence through restart")
    func failedStateWriteCannotReplaceConflictEvidence() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let fresh = fixture.event(account: "account-a")
        let cached = fixture.event(account: "account-b")
        try fixture.seedCache([cached])
        let legacy = fixture.legacyState(cached, dismissed: true)
        try fixture.writeState([legacy])
        let originalState = try Data(contentsOf: fixture.stateFile)
        let originalCache = try Data(contentsOf: fixture.cache.fileURL)
        let store = ReminderStateStore(fileURL: fixture.stateFile)
        let controller = fixture.controller(events: [fresh], store: store)
        try FileManager.default.removeItem(at: fixture.stateFile)
        try FileManager.default.createDirectory(at: fixture.stateFile, withIntermediateDirectories: false)

        await controller.refresh(reason: "launch")

        #expect(controller.events.map(\.id) == [fresh.id])
        #expect(controller.scheduledReminders.map(\.id) == [fresh.id])
        #expect(controller.activeReminders.isEmpty)
        #expect(store.state(for: legacy.occurrenceKey)?.legacyMigrationBlocked == true)
        #expect(store.state(for: fresh.occurrenceKey) == nil)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == originalCache)
        try FileManager.default.removeItem(at: fixture.stateFile)
        try originalState.write(to: fixture.stateFile)
        let restartedStore = ReminderStateStore(fileURL: fixture.stateFile)
        let restarted = fixture.controller(events: [fresh], store: restartedStore)

        await restarted.refresh(reason: "launch")

        #expect(restarted.events.map(\.id) == [fresh.id])
        #expect(restarted.scheduledReminders.map(\.id) == [fresh.id])
        #expect(restarted.activeReminders.isEmpty)
        #expect(restartedStore.state(for: legacy.occurrenceKey)?.legacyMigrationBlocked == true)
        #expect(restartedStore.state(for: fresh.occurrenceKey) == nil)
        #expect(restartedStore.unresolvedLegacyCount == 1)
    }

    @Test("First-seen recovery deadline is established before apply prunes old records")
    func migrationPrecedesPruneAndRetainsDeadline() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let event = fixture.event(account: "account-a")
        var legacy = fixture.legacyState(event)
        legacy.mutedUntilEventEnd = true
        legacy.updatedAt = fixture.now.addingTimeInterval(-30 * 24 * 60 * 60)
        try fixture.writeState([legacy])
        let store = ReminderStateStore(fileURL: fixture.stateFile)
        let controller = fixture.controller(events: [event], store: store)
        let beforeRefresh = Date()

        await controller.refresh(reason: "launch")

        let retained = try #require(store.state(for: legacy.occurrenceKey))
        let deadline = try #require(retained.legacyRecoveryDeadline)
        #expect(retained.updatedAt == legacy.updatedAt)
        #expect(retained.legacyMigrationBlocked == true)
        #expect(deadline >= beforeRefresh.addingTimeInterval(8 * 24 * 60 * 60))
        #expect(deadline <= Date().addingTimeInterval(8 * 24 * 60 * 60))
        #expect(controller.scheduledReminders.map(\.id) == [event.id])

        await controller.refresh(reason: "timer")

        #expect(store.state(for: legacy.occurrenceKey)?.legacyRecoveryDeadline == deadline)
        let restartedStore = ReminderStateStore(fileURL: fixture.stateFile)
        let restarted = fixture.controller(events: [event], store: restartedStore)

        await restarted.refresh(reason: "launch")

        #expect(restartedStore.state(for: legacy.occurrenceKey)?.legacyRecoveryDeadline == deadline)
        #expect(restartedStore.state(for: legacy.occurrenceKey)?.updatedAt == legacy.updatedAt)
        #expect(restarted.scheduledReminders.map(\.id) == [event.id])
        #expect(restarted.activeReminders.isEmpty)
    }

    @Test("No-legacy controller refresh preserves ordinary scheduling and cache replacement")
    func ordinaryRefreshHasNoMigrationState() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let event = fixture.event(account: "account-a")
        try fixture.seedCache([fixture.event(account: "account-b")])
        let store = ReminderStateStore(fileURL: fixture.stateFile)
        let controller = fixture.controller(events: [event], store: store)

        await controller.refresh(reason: "launch")

        #expect(controller.events.map(\.id) == [event.id])
        #expect(controller.scheduledReminders.map(\.id) == [event.id])
        #expect(controller.activeReminders.isEmpty)
        #expect(store.unresolvedLegacyCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.stateFile.path))
        #expect(try fixture.cache.loadUnfiltered()?.events.map(\.id) == [event.id])
    }

    @Test("Coordinator captures the original cache once across coalesced and later refreshes")
    func originalEvidenceIsRetainedOnceThenReleased() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let event = fixture.event(account: "account-a")
        let cached = fixture.event(account: "account-b")
        try fixture.seedCache([cached])
        try fixture.writeState([fixture.legacyState(cached, dismissed: true)])
        let store = ReminderStateStore(fileURL: fixture.stateFile)
        let provider = fixture.provider(events: [event])
        provider.refreshDelayNanoseconds = 100_000_000
        let coordinator = RefreshCoordinator(
            provider: provider, cacheStore: fixture.cache,
            settings: { fixture.settings.snapshot }, legacyStateStore: store
        )

        async let first = coordinator.refresh(reason: "launch")
        async let second = coordinator.refresh(reason: "timer")
        async let third = coordinator.refresh(reason: "timer")
        let outcomes = await [first, second, third]

        #expect(outcomes.compactMap { $0 }.contains { $0.didSucceed })
        #expect(provider.maxConcurrentRefreshes == 1)
        #expect(provider.refreshCallCount <= 2)
        #expect(coordinator.legacyIdentityEvidence.map(\.id) == [cached.id])
        #expect(try fixture.cache.loadUnfiltered()?.events.map(\.id) == [event.id])

        _ = await coordinator.refresh(reason: "timer")

        #expect(coordinator.legacyIdentityEvidence.map(\.id) == [cached.id])
        coordinator.clearLegacyIdentityEvidence()
        #expect(coordinator.legacyIdentityEvidence.map(\.id) == [cached.id])
        _ = store.reconcileLegacyStates(events: [], now: Date().addingTimeInterval(9 * 24 * 60 * 60))
        coordinator.clearLegacyIdentityEvidence()
        #expect(coordinator.legacyIdentityEvidence.isEmpty)

        _ = await coordinator.refresh(reason: "timer")

        #expect(coordinator.legacyIdentityEvidence.isEmpty)
        #expect(try fixture.cache.loadUnfiltered()?.events.map(\.id) == [event.id])
    }

    @Test("Coordinator without legacy state does not retain old source evidence")
    func ordinaryCoordinatorDoesNotRetainEvidence() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let event = fixture.event(account: "account-a")
        try fixture.seedCache([fixture.event(account: "account-b")])
        let coordinator = RefreshCoordinator(
            provider: fixture.provider(events: [event]), cacheStore: fixture.cache,
            settings: { fixture.settings.snapshot }
        )

        _ = await coordinator.refresh(reason: "launch")

        #expect(coordinator.legacyIdentityEvidence.isEmpty)
        #expect(try fixture.cache.loadUnfiltered()?.events.map(\.id) == [event.id])
    }

    @MainActor
    private struct Fixture {
        let now = Date()
        let directory: URL
        let domain: String
        let settings: AppSettingsStore
        let cache: EventCacheStore
        let stateFile: URL

        init() throws {
            directory = try TestTempDirectory.make()
            domain = "MeetingShieldLegacyMigrationTests.\(UUID().uuidString)"
            _ = try #require(UserDefaults(suiteName: domain))
            settings = AppSettingsStore(domainName: domain)
            settings.update {
                $0.defaultLeadTime = 120
                $0.selectedCalendarIDs = ["shared-calendar"]
                $0.disabledGoogleAccountIDs = ["account-b"]
                $0.soundEnabled = false
                $0.urgentRepeatSoundEnabled = false
                $0.wakeGraceEnabled = false
            }
            cache = EventCacheStore(fileURL: directory.appending(path: "cache.json"))
            stateFile = directory.appending(path: "state.json")
        }

        func cleanup() {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }

        func event(account: String) -> CalendarEventOccurrence {
            var event = CalendarEventOccurrence.sample(
                eventID: "shared-legacy-id", title: "Synthetic future meeting",
                startDate: now.addingTimeInterval(3600), calendarID: "shared-calendar"
            )
            event.accountID = account
            return event
        }

        func fingerprint(_ event: CalendarEventOccurrence) -> MaterialChangeFingerprint {
            event.materialFingerprint(detectedLinks: MeetingLinkExtractor().extractLinks(from: event))
        }

        func legacyState(_ event: CalendarEventOccurrence, dismissed: Bool = false) -> OccurrenceReminderState {
            OccurrenceReminderState(
                occurrenceKey: event.occurrenceKey.legacyKey, snoozedUntil: nil,
                dismissedFingerprint: dismissed ? fingerprint(event) : nil,
                mutedUntilEventEnd: false, updatedAt: now.addingTimeInterval(-60)
            )
        }

        func seedCache(_ events: [CalendarEventOccurrence]) throws {
            try cache.save(events: events, detectedLinks: [:], now: now.addingTimeInterval(-120))
        }

        func seedLegacyCache(_ events: [CalendarEventOccurrence]) throws {
            let envelope = EventCacheEnvelope(cachedAt: now.addingTimeInterval(-120), events: events)
            let encoded = try JSONEncoder().encode(envelope)
            var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object.removeValue(forKey: "accounts")
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: cache.fileURL)
            let diskObject = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: cache.fileURL)) as? [String: Any])
            try #require(diskObject["accounts"] == nil)
        }

        func writeState(_ states: [OccurrenceReminderState]) throws {
            try JSONEncoder().encode(states).write(to: stateFile)
        }

        func provider(events: [CalendarEventOccurrence]) -> FakeCalendarProvider {
            let provider = FakeCalendarProvider()
            provider.eventsValue = events
            provider.calendarsValue = events.map {
                UserCalendar(
                    id: $0.calendarID, accountID: $0.accountID, displayName: "Synthetic calendar",
                    isPrimary: true, isSelected: true
                )
            }
            return provider
        }

        func controller(events: [CalendarEventOccurrence], store: ReminderStateStore) -> MeetingShieldController {
            MeetingShieldController(
                settingsStore: settings, provider: provider(events: events),
                reminderStateStore: store, cacheStore: cache,
                notificationService: NoopNotificationService(), refreshMenuBar: {}
            )
        }
    }
}
