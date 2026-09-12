import CoreFoundation
import Darwin
import Foundation
import Testing
@testable import MeetingShield

@Suite("Controller persistence warnings")
@MainActor
struct PersistenceWarningTests {
    @Test("Recovery reads leave the UI responsive, retain newer intent, and respect Stop", arguments: ["none", "stop", "cancel"])
    func recoveryReadDoesNotBlockUI(interruption: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("invalid synthetic state".utf8).write(to: fixture.stateFile)
        let event = fixture.event()
        let recovered = OccurrenceReminderState(
            occurrenceKey: event.occurrenceKey, snoozedUntil: fixture.now.addingTimeInterval(60),
            dismissedFingerprint: nil, mutedUntilEventEnd: false, updatedAt: fixture.now
        )
        let gate = RecoveryReadGate()
        defer { gate.release.signal() }
        let state = ReminderStateStore(fileURL: fixture.stateFile, recoveryReader: { _ in
            #expect(!Thread.isMainThread)
            gate.markEntered()
            #expect(gate.release.wait(timeout: .now() + 5) == .success)
            return .success([event.occurrenceKey: recovered])
        })
        let settings = AppSettingsStore(domainName: fixture.domain)
        let controller = fixture.controller(settings: settings, state: state, provider: fixture.provider(event: event))
        defer { controller.stop() }
        await controller.refresh(reason: "launch")
        let retry = Task { await controller.retryPersistence() }
        defer { retry.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !gate.hasEntered && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(gate.hasEntered)
        // These main-actor reads and mutations must finish before the held IO is released.
        #expect(controller.isRetryingPersistence)
        let newerSnooze = fixture.now.addingTimeInterval(180)
        state.snooze(event.occurrenceKey, until: newerSnooze, now: fixture.now.addingTimeInterval(1))
        #expect(state.state(for: event.occurrenceKey)?.snoozedUntil == newerSnooze)
        if interruption == "stop" { controller.stop() }
        if interruption == "cancel" { retry.cancel() }
        gate.release.signal()
        await retry.value
        #expect(!controller.isRetryingPersistence)
        #expect(state.persistenceFailure == nil)
        #expect(fixture.reminderStore().state(for: event.occurrenceKey)?.snoozedUntil == newerSnooze)
        if interruption == "stop" {
            #expect(controller.nextActionTargetDate == nil)
        } else if interruption == "cancel" {
            #expect(controller.reminderPersistenceFailure == .invalidData)
        } else {
            #expect(controller.reminderPersistenceFailure == nil)
            #expect(controller.nextActionTargetDate != nil)
        }
    }

    private final class RecoveryReadGate: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        let release = DispatchSemaphore(value: 0)
        var hasEntered: Bool { lock.withLock { entered } }
        func markEntered() { lock.withLock { entered = true } }
    }

    @Test("Independent storage warnings survive refresh and clear only after their own recovery")
    func corruptStoresRecoverIndependently() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let corruptSettings = Data("{\"synthetic-settings\":".utf8)
        let corruptState = Data("[{\"synthetic-reminder\":".utf8)
        try fixture.replaceSettings(corruptSettings)
        try corruptState.write(to: fixture.stateFile)
        let settings = AppSettingsStore(domainName: fixture.domain)
        let state = fixture.reminderStore()
        let event = fixture.event()
        let provider = fixture.provider(event: event)
        let controller = fixture.controller(settings: settings, state: state, provider: provider)
        defer { controller.stop() }

        #expect(settings.persistenceFailure == .invalidData)
        #expect(state.persistenceFailure == .invalidData)
        #expect(controller.settingsPersistenceFailure == .invalidData)
        #expect(controller.reminderPersistenceFailure == .invalidData)
        let initialWarnings = Set(controller.persistenceWarnings)
        #expect(controller.persistenceWarnings.count == 2)
        #expect(initialWarnings.count == 2)
        #expect(!initialWarnings.contains(""))
        settings.update {
            $0.defaultLeadTime = 180
            $0.selectedCalendarIDs = [event.calendarID]
            $0.soundEnabled = false
            $0.urgentRepeatSoundEnabled = false
            $0.wakeGraceEnabled = false
        }

        await controller.refresh(reason: "launch")

        #expect(provider.refreshCallCount == 1)
        #expect(controller.events.map(\.id) == [event.id])
        #expect(controller.scheduledReminders.map(\.id) == [event.id])
        #expect(controller.activeReminders.isEmpty)
        #expect(controller.settingsPersistenceFailure == .invalidData)
        #expect(controller.reminderPersistenceFailure == .invalidData)
        #expect(Set(controller.persistenceWarnings) == initialWarnings)

        await controller.retryPersistence()

        #expect(controller.settingsPersistenceFailure == .invalidData)
        #expect(controller.reminderPersistenceFailure == .invalidData)
        #expect(Set(controller.persistenceWarnings) == initialWarnings)
        #expect(fixture.preferences.read() as? Data == corruptSettings)
        #expect(try Data(contentsOf: fixture.stateFile) == corruptState)
        #expect(settings.snapshot.defaultLeadTime == 180)
        var recovered = AppSettingsSnapshot.defaults
        recovered.defaultLeadTime = 600
        recovered.globalSnoozeDuration = 300
        recovered.accountNicknames = [event.accountID: "Recovered synthetic account"]
        try fixture.replaceSettings(JSONEncoder().encode(recovered))

        await controller.retryPersistence()

        #expect(controller.settingsPersistenceFailure == nil)
        #expect(controller.reminderPersistenceFailure == .invalidData)
        #expect(controller.persistenceWarnings.count == 1)
        #expect(Set(controller.persistenceWarnings).isSubset(of: initialWarnings))
        #expect(settings.persistenceFailure == nil)
        #expect(settings.snapshot.defaultLeadTime == 180)
        #expect(settings.snapshot.globalSnoozeDuration == 300)
        #expect(settings.snapshot.accountNicknames == recovered.accountNicknames)
        #expect(settings.snapshot.selectedCalendarIDs == [event.calendarID])
        #expect(controller.scheduledReminders.map(\.id) == [event.id])
        #expect(controller.scheduledReminders.first?.fireDate == event.startDate.addingTimeInterval(-180))
        #expect(try Data(contentsOf: fixture.stateFile) == corruptState)
        let dismissal = OccurrenceReminderState(
            occurrenceKey: event.occurrenceKey, snoozedUntil: nil,
            dismissedFingerprint: fixture.fingerprint(event), mutedUntilEventEnd: false,
            updatedAt: fixture.now.addingTimeInterval(-60)
        )
        try JSONEncoder().encode([dismissal]).write(to: fixture.stateFile, options: [.atomic])

        await controller.retryPersistence()

        #expect(controller.settingsPersistenceFailure == nil)
        #expect(controller.reminderPersistenceFailure == nil)
        #expect(controller.persistenceWarnings.isEmpty)
        #expect(controller.events.map(\.id) == [event.id])
        #expect(controller.scheduledReminders.isEmpty)
        #expect(controller.activeReminders.isEmpty)
        #expect(state.isDismissed(event.occurrenceKey, currentFingerprint: fixture.fingerprint(event)))
        #expect(!state.isPersistencePending)
        let reloadedSettings = AppSettingsStore(domainName: fixture.domain)
        let reloadedState = fixture.reminderStore()
        #expect(reloadedSettings.persistenceFailure == nil)
        #expect(reloadedSettings.snapshot == settings.snapshot)
        #expect(reloadedState.persistenceFailure == nil)
        #expect(reloadedState.isDismissed(event.occurrenceKey, currentFingerprint: fixture.fingerprint(event)))
    }

    @Test("A failed dismissal save warns immediately and remains visible until durable retry")
    func dismissalWriteFailureReachesControllerImmediately() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let event = fixture.event()
        let settings = AppSettingsStore(domainName: fixture.domain)
        settings.update {
            $0.selectedCalendarIDs = [event.calendarID]
            $0.presentationModeDefault = true
            $0.soundEnabled = false
            $0.urgentRepeatSoundEnabled = false
            $0.wakeGraceEnabled = false
        }
        let state = fixture.reminderStore()
        let provider = fixture.provider(event: event)
        let controller = fixture.controller(settings: settings, state: state, provider: provider)
        defer { controller.stop() }
        await controller.refresh(reason: "launch")
        let reminder = try #require(controller.scheduledReminders.first)
        #expect(controller.activeReminders.isEmpty)
        #expect(controller.persistenceWarnings.isEmpty)
        #expect(state.persistenceFailure == nil)
        if FileManager.default.fileExists(atPath: fixture.stateFile.path) {
            try FileManager.default.removeItem(at: fixture.stateFile)
        }
        try FileManager.default.createDirectory(at: fixture.stateFile, withIntermediateDirectories: false)

        controller.dismiss(reminder, now: fixture.now)

        #expect(state.persistenceFailure == .writeFailed)
        #expect(state.isPersistencePending)
        #expect(state.isDismissed(event.occurrenceKey, currentFingerprint: fixture.fingerprint(event)))
        #expect(controller.scheduledReminders.isEmpty)
        #expect(controller.activeReminders.isEmpty)
        #expect(controller.settingsPersistenceFailure == nil)
        #expect(controller.reminderPersistenceFailure == .writeFailed)
        #expect(controller.persistenceWarnings.count == 1)
        let warnings = controller.persistenceWarnings
        let previousRefreshCount = provider.refreshCallCount

        await controller.refresh(reason: "timer")

        #expect(provider.refreshCallCount == previousRefreshCount + 1)
        #expect(controller.events.map(\.id) == [event.id])
        #expect(controller.scheduledReminders.isEmpty)
        #expect(controller.reminderPersistenceFailure == .writeFailed)
        #expect(controller.persistenceWarnings == warnings)
        try FileManager.default.removeItem(at: fixture.stateFile)

        await controller.retryPersistence()

        #expect(controller.settingsPersistenceFailure == nil)
        #expect(controller.reminderPersistenceFailure == nil)
        #expect(controller.persistenceWarnings.isEmpty)
        #expect(controller.scheduledReminders.isEmpty)
        #expect(!state.isPersistencePending)
        let reloaded = fixture.reminderStore()
        #expect(reloaded.persistenceFailure == nil)
        #expect(reloaded.isDismissed(event.occurrenceKey, currentFingerprint: fixture.fingerprint(event)))
    }

    @Test("A rejected stale action immediately reports an expired acknowledgement save failure")
    func rejectedActionReportsAcknowledgementSaveFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let acknowledgedEvent = fixture.event()
        var unavailableEvent = fixture.event()
        unavailableEvent.eventID = "synthetic-unavailable-target"
        unavailableEvent.iCalUID = "synthetic-unavailable-target@example.com"
        unavailableEvent.startDate = fixture.now.addingTimeInterval(7200)
        unavailableEvent.endDate = unavailableEvent.startDate.addingTimeInterval(1800)
        let settings = AppSettingsStore(domainName: fixture.domain)
        settings.update {
            $0.selectedCalendarIDs = [unavailableEvent.calendarID]
            $0.presentationModeDefault = true
            $0.soundEnabled = false
            $0.urgentRepeatSoundEnabled = false
            $0.wakeGraceEnabled = false
        }
        let state = fixture.reminderStore()
        state.acknowledge(
            acknowledgedEvent.occurrenceKey, fingerprint: fixture.fingerprint(acknowledgedEvent),
            eventEnd: acknowledgedEvent.endDate, now: fixture.now
        )
        try #require(state.persistenceFailure == nil)
        let provider = fixture.provider(event: unavailableEvent)
        var currentNow = fixture.now
        let controller = MeetingShieldController(
            settingsStore: settings, provider: provider, reminderStateStore: state,
            cacheStore: EventCacheStore(fileURL: fixture.directory.appending(path: "cache.json")),
            notificationService: NoopNotificationService(), now: { currentNow }, refreshMenuBar: {}
        )
        defer { controller.stop() }
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.scheduledReminders.first)
        try #require(captured.id == unavailableEvent.id)
        provider.eventsValue = []
        await controller.refresh(reason: "timer")
        try #require(controller.events.isEmpty)
        try #require(controller.scheduledReminders.isEmpty)
        try #require(state.state(for: acknowledgedEvent.occurrenceKey)?.acknowledgement != nil)
        #expect(controller.activeReminders.isEmpty)
        #expect(controller.persistenceWarnings.isEmpty)
        try FileManager.default.removeItem(at: fixture.stateFile)
        try FileManager.default.createDirectory(at: fixture.stateFile, withIntermediateDirectories: false)
        currentNow = acknowledgedEvent.endDate.addingTimeInterval(1)
        try #require(unavailableEvent.startDate > currentNow)
        let previousRefreshCount = provider.refreshCallCount

        controller.dismiss(captured, now: currentNow)

        #expect(state.persistenceFailure == .writeFailed)
        #expect(state.isPersistencePending)
        let expiredState = try #require(state.state(for: acknowledgedEvent.occurrenceKey))
        #expect(expiredState.acknowledgement == nil)
        #expect(state.state(for: unavailableEvent.occurrenceKey) == nil)
        #expect(controller.settingsPersistenceFailure == nil)
        #expect(controller.reminderPersistenceFailure == .writeFailed)
        #expect(controller.persistenceWarnings.count == 1)
        #expect(controller.events.isEmpty)
        #expect(controller.scheduledReminders.isEmpty)
        #expect(controller.activeReminders.isEmpty)
        #expect(provider.refreshCallCount == previousRefreshCount)
        #expect(try fixture.stateFile.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        try FileManager.default.removeItem(at: fixture.stateFile)

        await controller.retryPersistence()

        #expect(state.persistenceFailure == nil)
        #expect(!state.isPersistencePending)
        #expect(controller.settingsPersistenceFailure == nil)
        #expect(controller.reminderPersistenceFailure == nil)
        #expect(controller.persistenceWarnings.isEmpty)
        #expect(controller.events.isEmpty)
        #expect(controller.scheduledReminders.isEmpty)
        #expect(controller.activeReminders.isEmpty)
        let reloaded = fixture.reminderStore()
        #expect(reloaded.persistenceFailure == nil)
        #expect(!reloaded.isPersistencePending)
        let persistedState = try #require(reloaded.state(for: acknowledgedEvent.occurrenceKey))
        #expect(persistedState.acknowledgement == nil)
        #expect(reloaded.state(for: unavailableEvent.occurrenceKey) == nil)
    }

    @Test("A denied settings write reaches the controller before any calendar refresh")
    func settingsWriteFailureReachesControllerImmediately() async throws {
        try #require(geteuid() != 0, "AnyUser write denial requires a non-root process.")
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var baseline = AppSettingsSnapshot.defaults
        baseline.defaultLeadTime = 600
        let original = try JSONEncoder().encode(baseline)
        try fixture.replaceSettings(original)
        let denied = SettingsPreferences(domainName: fixture.domain, userName: kCFPreferencesAnyUser)
        try #require(denied.read() == nil)
        let settings = AppSettingsStore(preferences: denied)
        let state = fixture.reminderStore()
        let provider = fixture.provider(event: fixture.event())
        let controller = fixture.controller(settings: settings, state: state, provider: provider)
        defer { controller.stop() }
        #expect(controller.settingsPersistenceFailure == nil)
        #expect(controller.reminderPersistenceFailure == nil)
        #expect(controller.persistenceWarnings.isEmpty)

        settings.update { $0.defaultLeadTime = 180 }

        try #require(!CFPreferencesSynchronize(fixture.domain as CFString, kCFPreferencesAnyUser, kCFPreferencesAnyHost),
                     "This probe must observe real CF synchronization denial.")
        #expect(settings.persistenceFailure == .writeFailed)
        #expect(settings.snapshot.defaultLeadTime == 180)
        #expect(controller.settingsPersistenceFailure == .writeFailed)
        #expect(controller.reminderPersistenceFailure == nil)
        #expect(controller.persistenceWarnings.count == 1)
        #expect(provider.refreshCallCount == 0)
        #expect(fixture.preferences.read() as? Data == original)
        let warnings = controller.persistenceWarnings

        await controller.refresh(reason: "launch")

        #expect(provider.refreshCallCount == 1)
        #expect(controller.settingsPersistenceFailure == .writeFailed)
        #expect(controller.reminderPersistenceFailure == nil)
        #expect(controller.persistenceWarnings == warnings)

        await controller.retryPersistence()

        #expect(controller.settingsPersistenceFailure == .writeFailed)
        #expect(controller.reminderPersistenceFailure == nil)
        #expect(controller.persistenceWarnings == warnings)
        #expect(settings.snapshot.defaultLeadTime == 180)
        #expect(fixture.preferences.read() as? Data == original)
    }

    @MainActor
    private struct Fixture {
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let domain = "PersistenceWarningTests.\(UUID().uuidString)"
        let directory: URL
        var stateFile: URL { directory.appending(path: "state.json") }
        var preferences: SettingsPreferences { SettingsPreferences(domainName: domain) }

        init() throws {
            directory = try TestTempDirectory.make()
        }

        func replaceSettings(_ data: Data) throws {
            try #require(preferences.write(data))
        }

        func cleanup() {
            for user in [kCFPreferencesCurrentUser, kCFPreferencesAnyUser] {
                CFPreferencesSetValue("meetingShield.settings.v1" as CFString, nil, domain as CFString, user, kCFPreferencesAnyHost)
                _ = CFPreferencesSynchronize(domain as CFString, user, kCFPreferencesAnyHost)
                #expect(CFPreferencesCopyValue("meetingShield.settings.v1" as CFString, domain as CFString, user, kCFPreferencesAnyHost) == nil)
            }
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }

        func event() -> CalendarEventOccurrence {
            var event = CalendarEventOccurrence.sample(
                eventID: "synthetic-persistence-warning", title: "Synthetic future meeting",
                startDate: now.addingTimeInterval(3600), calendarID: "synthetic-warning::primary"
            )
            event.providerID = "fake"
            event.accountID = "fake@example.com"
            return event
        }

        func fingerprint(_ event: CalendarEventOccurrence) -> MaterialChangeFingerprint {
            event.materialFingerprint(detectedLinks: MeetingLinkExtractor().extractLinks(from: event))
        }

        func reminderStore() -> ReminderStateStore {
            ReminderStateStore(fileURL: stateFile, diagnostics: DiagnosticsRecorder(
                directory: directory.appending(path: "diagnostics"), nativeSink: { _, _ in }
            ))
        }

        func provider(event: CalendarEventOccurrence) -> FakeCalendarProvider {
            let provider = FakeCalendarProvider()
            provider.eventsValue = [event]
            provider.calendarsValue = [UserCalendar(
                id: event.calendarID, accountID: event.accountID,
                displayName: "Synthetic calendar", isPrimary: true, isSelected: true
            )]
            return provider
        }

        func controller(
            settings: AppSettingsStore, state: ReminderStateStore, provider: FakeCalendarProvider
        ) -> MeetingShieldController {
            let now = now
            return MeetingShieldController(
                settingsStore: settings, provider: provider, reminderStateStore: state,
                cacheStore: EventCacheStore(fileURL: directory.appending(path: "cache.json")),
                notificationService: NoopNotificationService(), now: { now }, refreshMenuBar: {}
            )
        }
    }
}
