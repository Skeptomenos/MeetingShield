import CoreFoundation
import Darwin
import Foundation
import Testing
@testable import MeetingShield

@Suite("Persistence provider recovery")
@MainActor
struct PersistenceProviderRecoveryTests {
    @Test("Recovered OAuth settings replace the provider without reconnecting and preserve independent warnings")
    func recoveredConfigurationReplacesProvider() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.replaceSettings(Data("{\"synthetic-settings\":".utf8))
        let corruptState = Data("[{\"synthetic-reminder\":".utf8)
        try corruptState.write(to: fixture.stateFile)
        let settings = AppSettingsStore(domainName: fixture.domain)
        let state = fixture.reminderStore()
        let originalEvent = fixture.event("original")
        let recoveredEvent = fixture.event("recovered")
        let original = ProbeProvider(events: [originalEvent])
        let replacement = ProbeProvider(events: [recoveredEvent])
        let factory = ProviderFactory(provider: replacement)
        var menuRefreshCount = 0
        let controller = fixture.controller(settings: settings, state: state, provider: original, factory: factory) {
            menuRefreshCount += 1
        }
        defer { controller.stop() }
        #expect(menuRefreshCount == 0)
        #expect(factory.clientIDs.isEmpty)
        #expect(controller.settingsPersistenceFailure == .invalidData)
        #expect(controller.reminderPersistenceFailure == .invalidData)
        #expect(!controller.isPresentationMode)
        await controller.refresh(reason: "launch")
        try #require(controller.scheduledReminders.map(\.id) == [originalEvent.id])
        let originalReadCount = await original.readCount
        let previousMenuRefreshCount = menuRefreshCount
        var recovered = AppSettingsSnapshot.defaults
        recovered.googleOAuthClientID = "synthetic-recovered-client"
        recovered.selectedCalendarIDs = [recoveredEvent.calendarID]
        recovered.presentationModeDefault = true
        recovered.soundEnabled = false
        recovered.urgentRepeatSoundEnabled = false
        recovered.wakeGraceEnabled = false
        try fixture.replaceSettings(JSONEncoder().encode(recovered))

        await controller.retryPersistence()

        #expect(factory.clientIDs == ["synthetic-recovered-client"])
        #expect((controller.provider as? ProbeProvider) === replacement)
        #expect(await original.readCount == originalReadCount)
        #expect(await replacement.refreshCount == 1)
        #expect(await replacement.requestedCalendarIDs == [[recoveredEvent.calendarID]])
        #expect(controller.events.map(\.id) == [recoveredEvent.id])
        #expect(controller.scheduledReminders.map(\.id) == [recoveredEvent.id])
        #expect(controller.activeReminders.isEmpty)
        #expect(settings.snapshot.presentationModeDefault)
        #expect(!controller.isPresentationMode)
        #expect(controller.settingsPersistenceFailure == nil)
        #expect(controller.reminderPersistenceFailure == .invalidData)
        #expect(controller.persistenceWarnings.count == 1)
        #expect(try Data(contentsOf: fixture.stateFile) == corruptState)
        #expect(menuRefreshCount > previousMenuRefreshCount)

        await controller.retryPersistence()

        #expect(factory.clientIDs.count == 1)
        #expect(await replacement.refreshCount == 1)
        #expect(await original.reconnectCount == 0)
        #expect(await replacement.reconnectCount == 0)
        #expect(await original.removedAccountIDs.isEmpty)
        #expect(await replacement.removedAccountIDs.isEmpty)
        #expect(controller.reminderPersistenceFailure == .invalidData)
    }

    @Test("Equivalent effective settings keep the provider and current session mode", arguments: [false, true])
    func unchangedConfigurationPreservesProviderAndSessionMode(sessionMode: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var baseline = AppSettingsSnapshot.defaults
        baseline.googleOAuthClientID = "synthetic-unchanged-client"
        baseline.presentationModeDefault = sessionMode
        baseline.soundEnabled = false
        baseline.urgentRepeatSoundEnabled = false
        baseline.wakeGraceEnabled = false
        try fixture.replaceSettings(JSONEncoder().encode(baseline))
        let settings = AppSettingsStore(domainName: fixture.domain)
        let original = ProbeProvider(events: [fixture.event("unchanged")])
        let unused = ProbeProvider(events: [fixture.event("unused")])
        let factory = ProviderFactory(provider: unused)
        let controller = fixture.controller(
            settings: settings, state: fixture.reminderStore(), provider: original, factory: factory
        )
        defer { controller.stop() }
        try #require(controller.isPresentationMode == sessionMode)
        settings.update {
            $0.googleOAuthClientID = "  synthetic-unchanged-client  "
            $0.presentationModeDefault = !sessionMode
        }

        await controller.retryPersistence()

        #expect(factory.clientIDs.isEmpty)
        #expect((controller.provider as? ProbeProvider) === original)
        #expect(await original.readCount == 0)
        #expect(await unused.readCount == 0)
        #expect(await original.reconnectCount == 0)
        #expect(await unused.reconnectCount == 0)
        #expect(await original.removedAccountIDs.isEmpty)
        #expect(await unused.removedAccountIDs.isEmpty)
        #expect(settings.snapshot.presentationModeDefault == !sessionMode)
        #expect(controller.isPresentationMode == sessionMode)
        #expect(controller.activeReminders.isEmpty)
        #expect(controller.persistenceWarnings.isEmpty)
    }

    @Test("Recovered calendar selection refreshes the existing provider when effective credentials are unchanged")
    func recoveredSelectionRefreshesWithoutRebuildingProvider() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.replaceSettings(Data("{\"synthetic-selection\":".utf8))
        let settings = AppSettingsStore(domainName: fixture.domain)
        let originalEvent = fixture.event("selected-original")
        let recoveredEvent = fixture.event("selected-recovered")
        let original = ProbeProvider(events: [originalEvent, recoveredEvent])
        let unused = ProbeProvider(events: [fixture.event("unused")])
        let factory = ProviderFactory(provider: unused)
        let controller = fixture.controller(
            settings: settings, state: fixture.reminderStore(), provider: original, factory: factory
        )
        defer { controller.stop() }
        await controller.refresh(reason: "launch")
        try #require(controller.scheduledReminders.map(\.id) == [originalEvent.id])
        var recovered = AppSettingsSnapshot.defaults
        recovered.selectedCalendarIDs = [recoveredEvent.calendarID]
        recovered.soundEnabled = false
        recovered.urgentRepeatSoundEnabled = false
        recovered.wakeGraceEnabled = false
        try fixture.replaceSettings(JSONEncoder().encode(recovered))

        await controller.retryPersistence()

        #expect(factory.clientIDs.isEmpty)
        #expect((controller.provider as? ProbeProvider) === original)
        #expect(await original.refreshCount == 2)
        #expect(await original.requestedCalendarIDs == [[originalEvent.calendarID], [recoveredEvent.calendarID]])
        #expect(await unused.readCount == 0)
        #expect(await original.reconnectCount == 0)
        #expect(await original.removedAccountIDs.isEmpty)
        #expect(controller.events.map(\.id) == [recoveredEvent.id])
        #expect(controller.scheduledReminders.map(\.id) == [recoveredEvent.id])
        #expect(controller.activeReminders.isEmpty)
        #expect(controller.persistenceWarnings.isEmpty)
        #expect(settings.snapshot.hasExplicitCalendarSelection)
        #expect(settings.snapshot.selectedCalendarIDs == [recoveredEvent.calendarID])
        let reloaded = AppSettingsStore(domainName: fixture.domain)
        #expect(reloaded.persistenceFailure == nil)
        #expect(reloaded.snapshot.selectedCalendarIDs == [recoveredEvent.calendarID])
    }

    @Test("Retry applies an unsaved in-memory client change without claiming that settings were saved")
    func deniedSettingsWriteStillAppliesCurrentConfiguration() async throws {
        try #require(geteuid() != 0, "AnyUser write denial requires a non-root process.")
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let originalBytes = try JSONEncoder().encode(AppSettingsSnapshot.defaults)
        try fixture.replaceSettings(originalBytes)
        let denied = SettingsPreferences(domainName: fixture.domain, userName: kCFPreferencesAnyUser)
        try #require(denied.read() == nil)
        let settings = AppSettingsStore(preferences: denied)
        let original = ProbeProvider(events: [fixture.event("before-local-change")])
        let currentEvent = fixture.event("current-local-change")
        let replacement = ProbeProvider(events: [currentEvent])
        let factory = ProviderFactory(provider: replacement)
        var menuRefreshCount = 0
        let controller = fixture.controller(
            settings: settings, state: fixture.reminderStore(), provider: original, factory: factory
        ) {
            menuRefreshCount += 1
        }
        defer { controller.stop() }
        #expect(menuRefreshCount == 0)
        #expect(controller.persistenceWarnings.isEmpty)
        settings.update {
            $0.googleOAuthClientID = "synthetic-unsaved-client"
            $0.selectedCalendarIDs = [currentEvent.calendarID]
            $0.soundEnabled = false
            $0.urgentRepeatSoundEnabled = false
            $0.wakeGraceEnabled = false
        }
        try #require(!CFPreferencesSynchronize(fixture.domain as CFString, kCFPreferencesAnyUser, kCFPreferencesAnyHost),
                     "This probe must observe real CF synchronization denial.")
        try #require(settings.persistenceFailure == .writeFailed)
        #expect(controller.settingsPersistenceFailure == .writeFailed)
        #expect(menuRefreshCount > 0)
        #expect(factory.clientIDs.isEmpty)
        #expect(await original.readCount == 0)

        await controller.retryPersistence()

        #expect(factory.clientIDs == ["synthetic-unsaved-client"])
        #expect((controller.provider as? ProbeProvider) === replacement)
        #expect(await original.readCount == 0)
        #expect(await replacement.refreshCount == 1)
        #expect(await replacement.requestedCalendarIDs == [[currentEvent.calendarID]])
        #expect(controller.events.map(\.id) == [currentEvent.id])
        #expect(controller.scheduledReminders.map(\.id) == [currentEvent.id])
        #expect(controller.activeReminders.isEmpty)
        #expect(controller.settingsPersistenceFailure == .writeFailed)
        #expect(controller.reminderPersistenceFailure == nil)
        #expect(controller.persistenceWarnings.count == 1)
        #expect(settings.snapshot.googleOAuthClientID == "synthetic-unsaved-client")
        #expect(fixture.preferences.read() as? Data == originalBytes)

        await controller.retryPersistence()

        #expect(factory.clientIDs.count == 1)
        #expect(await replacement.refreshCount == 1)
        #expect(await original.reconnectCount == 0)
        #expect(await replacement.reconnectCount == 0)
        #expect(await original.removedAccountIDs.isEmpty)
        #expect(await replacement.removedAccountIDs.isEmpty)
        #expect(controller.settingsPersistenceFailure == .writeFailed)
        #expect(fixture.preferences.read() as? Data == originalBytes)
    }

    @MainActor
    private final class ProviderFactory {
        let provider: ProbeProvider
        private(set) var clientIDs: [String] = []

        init(provider: ProbeProvider) {
            self.provider = provider
        }

        func make(_ configuration: GoogleOAuthConfiguration) -> any CalendarProvider {
            clientIDs.append(configuration.clientID)
            return provider
        }
    }

    private actor ProbeProvider: CalendarProvider {
        nonisolated let providerID = "synthetic-persistence-provider"
        private let eventsValue: [CalendarEventOccurrence]
        private let calendarsValue: [UserCalendar]
        private(set) var readCount = 0
        private(set) var refreshCount = 0
        private(set) var reconnectCount = 0
        private(set) var removedAccountIDs: [String] = []
        private(set) var requestedCalendarIDs: [Set<String>] = []

        init(events: [CalendarEventOccurrence]) {
            eventsValue = events
            calendarsValue = events.enumerated().map { index, event in
                UserCalendar(
                    id: event.calendarID, accountID: event.accountID, displayName: "Synthetic calendar",
                    isPrimary: index == 0, isSelected: index == 0
                )
            }
        }

        var authState: CalendarProviderAuthState {
            readCount += 1
            return .connected(accountEmail: "synthetic-persistence@example.com")
        }

        func accounts() async -> [ConnectedCalendarAccount] {
            readCount += 1
            return [ConnectedCalendarAccount(id: "synthetic-persistence@example.com", displayName: "Synthetic account")]
        }

        func calendars() async throws -> [UserCalendar] {
            readCount += 1
            return calendarsValue
        }

        func events(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
            try await refresh(in: window)
        }

        func refresh(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
            try await refresh(in: window, calendars: calendarsValue)
        }

        func refresh(in window: CalendarFetchWindow, calendars: [UserCalendar]) async throws -> [CalendarEventOccurrence] {
            readCount += 1
            refreshCount += 1
            let requested = Set(calendars.map(\.id))
            requestedCalendarIDs.append(requested)
            return eventsValue.filter { requested.contains($0.calendarID) }
        }

        func reconnect() async throws {
            reconnectCount += 1
        }

        func removeAccount(id: String) async throws {
            removedAccountIDs.append(id)
        }
    }

    @MainActor
    private struct Fixture {
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let domain = "PersistenceProviderRecoveryTests.\(UUID().uuidString)"
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

        func event(_ name: String) -> CalendarEventOccurrence {
            var event = CalendarEventOccurrence.sample(
                eventID: "synthetic-provider-\(name)", title: "Synthetic future meeting",
                startDate: now.addingTimeInterval(3600), calendarID: "synthetic-persistence::\(name)"
            )
            event.providerID = "synthetic-persistence-provider"
            event.accountID = "synthetic-persistence@example.com"
            return event
        }

        func reminderStore() -> ReminderStateStore {
            ReminderStateStore(fileURL: stateFile, diagnostics: DiagnosticsRecorder(
                directory: directory.appending(path: "diagnostics"), nativeSink: { _, _ in }
            ))
        }

        func controller(
            settings: AppSettingsStore, state: ReminderStateStore, provider: ProbeProvider,
            factory: ProviderFactory, refreshMenuBar: @escaping @MainActor () -> Void = {}
        ) -> MeetingShieldController {
            let now = now
            return MeetingShieldController(
                settingsStore: settings, provider: provider,
                credentialsResolver: GoogleOAuthCredentialsResolver(bundleInfoValue: { _ in nil }, environment: [:]),
                makeGoogleProvider: { factory.make($0) }, reminderStateStore: state,
                cacheStore: EventCacheStore(fileURL: directory.appending(path: "cache.json")),
                notificationService: NoopNotificationService(), now: { now }, refreshMenuBar: refreshMenuBar
            )
        }
    }
}
