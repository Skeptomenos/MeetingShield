import Foundation
import Testing
@testable import MeetingShield

@Suite("Persistence recovery migration provenance")
@MainActor
struct PersistenceRecoveryMigrationTests {
    @Test("Unreadable reminder recovery retains disabled cache provenance before legacy migration", arguments: [false, true])
    func recoveredLegacyDismissalCannotSuppressAnotherAccount(initiallyCorrupt: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let fresh = fixture.event(account: "account-a")
        let cached = fixture.event(account: "account-b")
        let fingerprint = fixture.fingerprint(cached)
        try #require(fresh.occurrenceKey != cached.occurrenceKey)
        try #require(fresh.occurrenceKey.legacyKey == cached.occurrenceKey.legacyKey)
        try #require(fixture.fingerprint(fresh) == fingerprint)
        try #require(!fixture.settings.snapshot.isAccountEnabled(cached.accountID))
        try fixture.cache.save(events: [cached], detectedLinks: [:], now: fixture.now.addingTimeInterval(-120))
        let originalCache = try Data(contentsOf: fixture.cache.fileURL)
        let legacy = OccurrenceReminderState(
            occurrenceKey: cached.occurrenceKey.legacyKey, snoozedUntil: nil,
            dismissedFingerprint: fingerprint, mutedUntilEventEnd: false,
            updatedAt: fixture.now.addingTimeInterval(-60)
        )
        let recoveredBytes = try JSONEncoder().encode([legacy])
        let corruptBytes = Data("[{\"synthetic-unreadable-reminder\":".utf8)
        if initiallyCorrupt {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode([OccurrenceReminderState].self, from: corruptBytes)
            }
        }
        try (initiallyCorrupt ? corruptBytes : recoveredBytes).write(to: fixture.stateFile)
        let store = fixture.reminderStore()
        #expect(store.unresolvedLegacyCount == (initiallyCorrupt ? 0 : 1))
        #expect(store.isPersistencePending == initiallyCorrupt)
        #expect(store.persistenceFailure == (initiallyCorrupt ? .invalidData : nil))
        let controller = fixture.controller(event: fresh, store: store)
        defer { controller.stop() }

        for reason in ["launch", "timer"] {
            await controller.refresh(reason: reason)

            #expect(controller.events.map(\.id) == [fresh.id])
            #expect(controller.scheduledReminders.map(\.id) == [fresh.id])
            #expect(controller.activeReminders.isEmpty)
            #expect(store.state(for: fresh.occurrenceKey) == nil)
            if initiallyCorrupt {
                #expect(store.isPersistencePending)
                #expect(store.persistenceFailure == .invalidData)
                #expect(try Data(contentsOf: fixture.stateFile) == corruptBytes)
                #expect(try Data(contentsOf: fixture.cache.fileURL) == originalCache)
            } else {
                #expect(!store.isPersistencePending)
                #expect(store.state(for: legacy.occurrenceKey)?.legacyMigrationBlocked == true)
                #expect(try fixture.cache.loadUnfiltered()?.events.map(\.id) == [fresh.id])
            }
        }

        if initiallyCorrupt {
            try recoveredBytes.write(to: fixture.stateFile, options: [.atomic])
        }
        let retried = await store.retryPersistence()
        try #require(retried)
        #expect(store.persistenceFailure == nil)
        #expect(!store.isPersistencePending)
        #expect(store.unresolvedLegacyCount == 1)

        controller.handleSettingsChanged()

        #expect(controller.scheduledReminders.map(\.id) == [fresh.id])
        #expect(store.state(for: legacy.occurrenceKey)?.legacyMigrationBlocked == true)
        #expect(store.state(for: fresh.occurrenceKey) == nil)
        #expect(!store.isDismissed(fresh.occurrenceKey, currentFingerprint: fingerprint))

        await controller.refresh(reason: "timer")

        #expect(controller.scheduledReminders.map(\.id) == [fresh.id])
        #expect(store.unresolvedLegacyCount == 1)
        #expect(store.state(for: legacy.occurrenceKey)?.legacyMigrationBlocked == true)
        #expect(store.state(for: fresh.occurrenceKey) == nil)
        #expect(try fixture.cache.loadUnfiltered()?.events.map(\.id) == [fresh.id])
        let restartedStore = fixture.reminderStore()
        #expect(restartedStore.persistenceFailure == nil)
        #expect(restartedStore.state(for: legacy.occurrenceKey)?.legacyMigrationBlocked == true)
        #expect(restartedStore.state(for: fresh.occurrenceKey) == nil)
        let restarted = fixture.controller(event: fresh, store: restartedStore)
        defer { restarted.stop() }

        await restarted.refresh(reason: "launch")

        #expect(restarted.events.map(\.id) == [fresh.id])
        #expect(restarted.scheduledReminders.map(\.id) == [fresh.id])
        #expect(restarted.activeReminders.isEmpty)
        #expect(restartedStore.unresolvedLegacyCount == 1)
        #expect(restartedStore.state(for: legacy.occurrenceKey)?.legacyMigrationBlocked == true)
        #expect(restartedStore.state(for: fresh.occurrenceKey) == nil)
    }

    @MainActor
    private struct Fixture {
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let directory: URL
        let domain: String
        let settings: AppSettingsStore
        let cache: EventCacheStore
        let stateFile: URL

        init() throws {
            directory = try TestTempDirectory.make()
            domain = "MeetingShieldPersistenceRecoveryMigrationTests.\(UUID().uuidString)"
            settings = AppSettingsStore(domainName: domain)
            settings.update {
                $0.defaultLeadTime = 120
                $0.selectedCalendarIDs = ["shared-calendar"]
                $0.disabledGoogleAccountIDs = ["account-b"]
                $0.presentationModeDefault = true
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

        func reminderStore() -> ReminderStateStore {
            ReminderStateStore(
                fileURL: stateFile,
                diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "diagnostics"), nativeSink: { _, _ in })
            )
        }

        func controller(event: CalendarEventOccurrence, store: ReminderStateStore) -> MeetingShieldController {
            let provider = FakeCalendarProvider()
            provider.eventsValue = [event]
            provider.calendarsValue = [UserCalendar(
                id: event.calendarID, accountID: event.accountID, displayName: "Synthetic calendar",
                isPrimary: true, isSelected: true
            )]
            let now = now
            return MeetingShieldController(
                settingsStore: settings, provider: provider, reminderStateStore: store,
                cacheStore: cache, notificationService: NoopNotificationService(),
                now: { now }, refreshMenuBar: {}
            )
        }
    }
}
