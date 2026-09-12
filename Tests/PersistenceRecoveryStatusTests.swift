import CoreFoundation
import Darwin
import Foundation
import Testing
@testable import MeetingShield

@Suite("Persistence recovery status")
struct PersistenceRecoveryStatusTests {
    @Test("Settings retry preserves invalid data and merges recovered fields with every newer local choice", arguments: SettingsDamage.allCases)
    @MainActor
    func settingsRecoveryKeepsLocalIntent(damage: SettingsDamage) throws {
        let fixture = PreferencesFixture()
        defer { fixture.cleanup() }
        let corrupt = Data("{\"defaultLeadTime\":".utf8)
        let wrongType = "synthetic-invalid-settings-type"
        switch damage {
        case .malformedJSON: try fixture.replace(corrupt as CFData)
        case .wrongStoredType: try fixture.replace(wrongType as CFString)
        }
        let store = AppSettingsStore(domainName: fixture.domain)
        #expect(store.persistenceFailure == .invalidData)
        store.update { $0.defaultLeadTime = 180 }
        store.update { $0.defaultLeadTime = 120 }
        store.update { $0.selectedCalendarIDs = [] }

        let invalidRetry = store.retryPersistence()

        #expect(!invalidRetry)
        #expect(store.persistenceFailure == .invalidData)
        #expect(store.snapshot.defaultLeadTime == 120)
        #expect(store.snapshot.hasExplicitCalendarSelection)
        #expect(store.snapshot.selectedCalendarIDs.isEmpty)
        switch damage {
        case .malformedJSON: #expect(fixture.preferences.read() as? Data == corrupt)
        case .wrongStoredType: #expect(fixture.preferences.read() as? String == wrongType)
        }
        var recovered = AppSettingsSnapshot.defaults
        recovered.defaultLeadTime = 600
        recovered.globalSnoozeDuration = 300
        recovered.soundEnabled = false
        recovered.selectedCalendarIDs = ["synthetic-recovered::primary"]
        recovered.accountNicknames = ["synthetic-recovered": "Recovered account"]
        recovered.calendarAliases = ["synthetic-recovered::primary": "Recovered calendar"]
        try fixture.replace(JSONEncoder().encode(recovered) as CFData)

        let validRetry = store.retryPersistence()

        #expect(validRetry)
        #expect(store.persistenceFailure == nil)
        #expect(store.snapshot.defaultLeadTime == 120)
        #expect(store.snapshot.hasExplicitCalendarSelection)
        #expect(store.snapshot.selectedCalendarIDs.isEmpty)
        #expect(store.snapshot.globalSnoozeDuration == 300)
        #expect(!store.snapshot.soundEnabled)
        #expect(store.snapshot.accountNicknames == recovered.accountNicknames)
        #expect(store.snapshot.calendarAliases == recovered.calendarAliases)
        let savedData = try #require(fixture.preferences.read() as? Data)
        let saved = try JSONDecoder().decode(AppSettingsSnapshot.self, from: savedData)
        #expect(saved == store.snapshot)
        let reloaded = AppSettingsStore(domainName: fixture.domain)
        #expect(reloaded.persistenceFailure == nil)
        #expect(reloaded.snapshot == saved)
    }

    @Test("Settings recovery merges changed map entries and removals without dropping untouched accounts")
    @MainActor
    func settingsRecoveryPreservesEntryIntent() throws {
        let fixture = PreferencesFixture()
        defer { fixture.cleanup() }
        let corrupt = Data("{\"synthetic-invalid-settings\":".utf8)
        try fixture.replace(corrupt as CFData)
        let store = AppSettingsStore(domainName: fixture.domain)
        let changed = "synthetic-changed"
        let removed = "synthetic-removed"
        let untouched = "synthetic-untouched"
        let changedCalendar = "\(changed)::primary"
        let removedCalendar = "\(removed)::primary"
        let untouchedCalendar = "\(untouched)::primary"
        var localCalendar = CalendarSettings.defaults(calendarID: changedCalendar)
        localCalendar.isAlertEnabled = false
        localCalendar.leadTimeOverride = 180
        store.update {
            $0.accountNicknames[changed] = "Local account"
            $0.accountNicknames[removed] = "Temporary account"
            $0.calendarAliases[changedCalendar] = "Local calendar"
            $0.calendarAliases[removedCalendar] = "Temporary calendar"
            $0.calendarSettings[changedCalendar] = localCalendar
            $0.calendarSettings[removedCalendar] = .defaults(calendarID: removedCalendar)
            $0.disabledGoogleAccountIDs = [changed, removed]
        }
        store.update {
            $0.accountNicknames.removeValue(forKey: removed)
            $0.calendarAliases.removeValue(forKey: removedCalendar)
            $0.calendarSettings.removeValue(forKey: removedCalendar)
            $0.disabledGoogleAccountIDs.remove(removed)
        }
        #expect(store.persistenceFailure == .invalidData)
        #expect(fixture.preferences.read() as? Data == corrupt)
        var recovered = AppSettingsSnapshot.defaults
        recovered.accountNicknames = [changed: "Recovered changed", removed: "Recovered removed", untouched: "Untouched account"]
        recovered.calendarAliases = [changedCalendar: "Recovered changed", removedCalendar: "Recovered removed", untouchedCalendar: "Untouched calendar"]
        var untouchedConfig = CalendarSettings.defaults(calendarID: untouchedCalendar)
        untouchedConfig.leadTimeOverride = 600
        recovered.calendarSettings = [
            changedCalendar: .defaults(calendarID: changedCalendar),
            removedCalendar: .defaults(calendarID: removedCalendar), untouchedCalendar: untouchedConfig
        ]
        recovered.disabledGoogleAccountIDs = [removed, untouched]
        try fixture.replace(JSONEncoder().encode(recovered) as CFData)

        let retried = store.retryPersistence()

        #expect(retried)
        #expect(store.persistenceFailure == nil)
        #expect(store.snapshot.accountNicknames == [changed: "Local account", untouched: "Untouched account"])
        #expect(store.snapshot.calendarAliases == [changedCalendar: "Local calendar", untouchedCalendar: "Untouched calendar"])
        #expect(store.snapshot.calendarSettings == [changedCalendar: localCalendar, untouchedCalendar: untouchedConfig])
        #expect(store.snapshot.disabledGoogleAccountIDs == [changed, untouched])
        #expect(AppSettingsStore(domainName: fixture.domain).snapshot == store.snapshot)
    }

    @Test("The calendar alert toggle preserves untouched recovered fields inside the same calendar")
    @MainActor
    func alertTogglePreservesRecoveredCalendarFields() throws {
        let fixture = PreferencesFixture()
        defer { fixture.cleanup() }
        let corrupt = Data("{\"synthetic-invalid-calendar-toggle\":".utf8)
        try fixture.replace(corrupt as CFData)
        let store = AppSettingsStore(domainName: fixture.domain)
        let calendarA = "synthetic-nested-a::primary"
        let calendarB = "synthetic-nested-b::primary"
        store.update { settings in
            var calendarSettings = settings.calendarSettings(for: calendarA)
            calendarSettings.isAlertEnabled = false
            settings.calendarSettings[calendarA] = calendarSettings
        }
        #expect(store.persistenceFailure == .invalidData)
        #expect(fixture.preferences.read() as? Data == corrupt)
        var recoveredA = CalendarSettings.defaults(calendarID: calendarA)
        recoveredA.browserSelection = BrowserSelection(browser: .chrome, profileID: "Synthetic recovered profile")
        recoveredA.leadTimeOverride = 600
        recoveredA.includedEventTypes = [.defaultEvent, .focusTime]
        recoveredA.includedRSVPStatuses = [.declined]
        recoveredA.includedBusyStates = [.free]
        recoveredA.includeAllDayEvents = true
        recoveredA.rules = [ReminderRule(name: "Recovered calendar rule", conditions: [.hasMeetingLink(false)], outcome: .suppress)]
        var recoveredB = CalendarSettings.defaults(calendarID: calendarB)
        recoveredB.isAlertEnabled = false
        recoveredB.leadTimeOverride = 300
        var recovered = AppSettingsSnapshot.defaults
        recovered.calendarSettings = [calendarA: recoveredA, calendarB: recoveredB]
        try fixture.replace(JSONEncoder().encode(recovered) as CFData)
        var expectedA = recoveredA
        expectedA.isAlertEnabled = false

        let retried = store.retryPersistence()

        #expect(retried)
        #expect(store.persistenceFailure == nil)
        #expect(store.snapshot.calendarSettings[calendarA] == expectedA)
        #expect(store.snapshot.calendarSettings[calendarB] == recoveredB)
        let reloaded = AppSettingsStore(domainName: fixture.domain)
        #expect(reloaded.persistenceFailure == nil)
        #expect(reloaded.snapshot.calendarSettings[calendarA] == expectedA)
        #expect(reloaded.snapshot.calendarSettings[calendarB] == recoveredB)
    }

    @Test("Locally clearing calendar lead and rules survives recovery without clearing untouched fields")
    @MainActor
    func clearedCalendarFieldsKeepTheirNewerIntent() throws {
        let fixture = PreferencesFixture()
        defer { fixture.cleanup() }
        let corrupt = Data("{\"synthetic-invalid-calendar-clear\":".utf8)
        try fixture.replace(corrupt as CFData)
        let store = AppSettingsStore(domainName: fixture.domain)
        let calendarID = "synthetic-calendar-clear::primary"
        store.update { settings in
            var calendarSettings = settings.calendarSettings(for: calendarID)
            calendarSettings.leadTimeOverride = 180
            calendarSettings.rules = [ReminderRule(name: "Temporary local rule", conditions: [], outcome: .alert)]
            settings.calendarSettings[calendarID] = calendarSettings
        }
        store.update { settings in
            var calendarSettings = settings.calendarSettings(for: calendarID)
            calendarSettings.leadTimeOverride = nil
            calendarSettings.rules = []
            settings.calendarSettings[calendarID] = calendarSettings
        }
        #expect(store.persistenceFailure == .invalidData)
        #expect(fixture.preferences.read() as? Data == corrupt)
        var recoveredCalendar = CalendarSettings.defaults(calendarID: calendarID)
        recoveredCalendar.isAlertEnabled = false
        recoveredCalendar.browserSelection = BrowserSelection(browser: .chrome, profileID: "Synthetic untouched profile")
        recoveredCalendar.leadTimeOverride = 600
        recoveredCalendar.includeAllDayEvents = true
        recoveredCalendar.rules = [ReminderRule(name: "Old recovered rule", conditions: [], outcome: .suppress)]
        var recovered = AppSettingsSnapshot.defaults
        recovered.calendarSettings = [calendarID: recoveredCalendar]
        try fixture.replace(JSONEncoder().encode(recovered) as CFData)
        var expected = recoveredCalendar
        expected.leadTimeOverride = nil
        expected.rules = []

        let retried = store.retryPersistence()

        #expect(retried)
        #expect(store.persistenceFailure == nil)
        #expect(store.snapshot.calendarSettings[calendarID]?.leadTimeOverride == nil)
        #expect(store.snapshot.calendarSettings[calendarID]?.rules.isEmpty == true)
        #expect(store.snapshot.calendarSettings[calendarID] == expected)
        let reloaded = AppSettingsStore(domainName: fixture.domain)
        #expect(reloaded.persistenceFailure == nil)
        #expect(reloaded.snapshot.calendarSettings[calendarID] == expected)
    }

    @Test("Changing the menu horizon kind preserves recovered hours and days")
    @MainActor
    func visibilityKindPreservesRecoveredBounds() throws {
        let fixture = PreferencesFixture()
        defer { fixture.cleanup() }
        try fixture.replace(Data("{\"synthetic-invalid-visibility\":".utf8) as CFData)
        let store = AppSettingsStore(domainName: fixture.domain)
        store.update { $0.visibilityWindow.kind = .nextHours }
        #expect(store.persistenceFailure == .invalidData)
        var recovered = AppSettingsSnapshot.defaults
        recovered.visibilityWindow = MenuVisibilityWindow(kind: .today, hours: 9, days: 3)
        try fixture.replace(JSONEncoder().encode(recovered) as CFData)

        let retried = store.retryPersistence()

        #expect(retried)
        #expect(store.persistenceFailure == nil)
        let expected = MenuVisibilityWindow(kind: .nextHours, hours: 9, days: 3)
        #expect(store.snapshot.visibilityWindow == expected)
        #expect(AppSettingsStore(domainName: fixture.domain).snapshot.visibilityWindow == expected)
    }

    @Test("A provider-default update preserves the recovered explicit selection mode and IDs", arguments: [false, true])
    @MainActor
    func providerDefaultsDoNotOverrideRecoveredSelection(selectSome: Bool) throws {
        let fixture = PreferencesFixture()
        defer { fixture.cleanup() }
        let corrupt = Data("{\"synthetic-invalid-selection\":".utf8)
        try fixture.replace(corrupt as CFData)
        let store = AppSettingsStore(domainName: fixture.domain)
        let currentDefaults: Set<String> = ["synthetic-current-defaults::primary"]
        store.update { $0.recordProviderDefaultCalendarIDs(currentDefaults) }
        #expect(!store.snapshot.hasExplicitCalendarSelection)
        #expect(fixture.preferences.read() as? Data == corrupt)
        var recovered = AppSettingsSnapshot.defaults
        recovered.selectedCalendarIDs = selectSome ? ["synthetic-recovered-selection::primary"] : []
        recovered.recordProviderDefaultCalendarIDs(["synthetic-old-defaults::primary"])
        try fixture.replace(JSONEncoder().encode(recovered) as CFData)

        let retried = store.retryPersistence()

        #expect(retried)
        #expect(store.persistenceFailure == nil)
        #expect(store.snapshot.hasExplicitCalendarSelection)
        #expect(store.snapshot.selectedCalendarIDs == recovered.selectedCalendarIDs)
        #expect(store.snapshot.providerDefaultCalendarIDs == currentDefaults)
        let reloaded = AppSettingsStore(domainName: fixture.domain)
        #expect(reloaded.snapshot.hasExplicitCalendarSelection)
        #expect(reloaded.snapshot.selectedCalendarIDs == recovered.selectedCalendarIDs)
        #expect(reloaded.snapshot.providerDefaultCalendarIDs == currentDefaults)
    }

    @Test("Explicit Reset to Defaults replaces invalid settings and clears the warning only after saving")
    @MainActor
    func intentionalResetReplacesInvalidSettings() throws {
        let fixture = PreferencesFixture()
        defer { fixture.cleanup() }
        let corrupt = Data("{\"synthetic-invalid-reset\":".utf8)
        try fixture.replace(corrupt as CFData)
        let store = AppSettingsStore(domainName: fixture.domain)
        store.update {
            $0.defaultLeadTime = 300
            $0.selectedCalendarIDs = []
            $0.accountNicknames = ["synthetic-local": "Local edit"]
        }
        #expect(store.persistenceFailure == .invalidData)
        #expect(fixture.preferences.read() as? Data == corrupt)

        store.restoreDefaults()

        #expect(store.snapshot == .defaults)
        #expect(store.persistenceFailure == nil)
        let savedData = try #require(fixture.preferences.read() as? Data)
        #expect(savedData != corrupt)
        #expect(try JSONDecoder().decode(AppSettingsSnapshot.self, from: savedData) == .defaults)
        let reloaded = AppSettingsStore(domainName: fixture.domain)
        #expect(reloaded.persistenceFailure == nil)
        #expect(reloaded.snapshot == .defaults)
    }

    @Test("Missing and valid settings report no persistence failure", arguments: [false, true])
    @MainActor
    func settingsWithoutFailure(hasSavedSettings: Bool) throws {
        let fixture = PreferencesFixture()
        defer { fixture.cleanup() }
        var expected = AppSettingsSnapshot.defaults
        if hasSavedSettings {
            expected.defaultLeadTime = 300
            expected.selectedCalendarIDs = []
            try fixture.replace(JSONEncoder().encode(expected) as CFData)
        } else {
            #expect(fixture.preferences.read() == nil)
        }
        let store = AppSettingsStore(domainName: fixture.domain)

        #expect(store.persistenceFailure == nil)
        #expect(store.snapshot == expected)
        #expect(store.retryPersistence())
        #expect(store.persistenceFailure == nil)
        #expect(AppSettingsStore(domainName: fixture.domain).snapshot == expected)
    }

    @Test("A denied CF settings write reports failure despite its process-local staged value")
    @MainActor
    func settingsSynchronizationFailureIsNotSuccess() throws {
        try #require(geteuid() != 0, "AnyUser write denial requires a non-root process.")
        let fixture = PreferencesFixture()
        defer { fixture.cleanup() }
        var baseline = AppSettingsSnapshot.defaults
        baseline.defaultLeadTime = 600
        let original = try JSONEncoder().encode(baseline)
        try fixture.replace(original as CFData)
        CFPreferencesSetValue("synthetic.p15.canary" as CFString, "preserve-current-user" as CFString,
                              fixture.domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        try #require(CFPreferencesSynchronize(fixture.domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
        let denied = SettingsPreferences(domainName: fixture.domain, userName: kCFPreferencesAnyUser)
        #expect(denied.read() == nil)
        let store = AppSettingsStore(preferences: denied)
        #expect(store.persistenceFailure == nil)

        store.update { $0.defaultLeadTime = 180 }

        try #require(!CFPreferencesSynchronize(fixture.domain as CFString, kCFPreferencesAnyUser, kCFPreferencesAnyHost),
                     "This probe must observe real CF synchronization denial.")
        let stagedData = try #require(denied.read() as? Data)
        let staged = try JSONDecoder().decode(AppSettingsSnapshot.self, from: stagedData)
        #expect(staged.defaultLeadTime == 180)
        #expect(store.snapshot.defaultLeadTime == 180)
        #expect(store.persistenceFailure == .writeFailed)

        let retried = store.retryPersistence()

        #expect(!retried)
        #expect(store.persistenceFailure == .writeFailed)
        #expect(store.snapshot.defaultLeadTime == 180)
        #expect(fixture.preferences.read() as? Data == original)
        #expect(CFPreferencesCopyValue("synthetic.p15.canary" as CFString, fixture.domain as CFString,
                                      kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String == "preserve-current-user")
    }

    @Test("Unreadable reminder recovery preserves recovered occurrences, newer local intent, and local removal", arguments: ReminderDamage.allCases)
    func reminderRecoveryMergesWithoutRevivingPrunedState(damage: ReminderDamage) async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "state.json")
        let seedFile = directory.appending(path: "recovered-state.json")
        let untouched = event("untouched")
        let changed = event("changed")
        let pruned = event("pruned")
        let seed = self.store(seedFile, directory: directory)
        seed.dismiss(untouched.occurrenceKey, fingerprint: fingerprint(untouched), now: TestDates.now)
        seed.snooze(changed.occurrenceKey, until: TestDates.now.addingTimeInterval(300), now: TestDates.now)
        seed.dismiss(pruned.occurrenceKey, fingerprint: fingerprint(pruned), now: TestDates.now)
        let recoveredBytes = try Data(contentsOf: seedFile)
        let invalidBytes = Data("[{\"synthetic-invalid-reminder\":".utf8)
        let original = damage == .invalidData ? invalidBytes : recoveredBytes
        try original.write(to: file)
        var permissions: NSNumber?
        defer {
            if let permissions {
                do {
                    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
                } catch { Issue.record("The owned reminder fixture permissions could not be restored.") }
            }
        }
        if damage == .readDenied {
            try #require(geteuid() != 0, "Read-denial recovery must run as a non-root user.")
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
            try requireReadDenial(file)
        }
        let store = self.store(file, directory: directory)
        let expectedFailure: PersistenceFailure = damage == .invalidData ? .invalidData : .readFailed
        #expect(store.persistenceFailure == expectedFailure)
        #expect(store.isPersistencePending)
        store.dismiss(changed.occurrenceKey, fingerprint: fingerprint(changed), now: TestDates.now)
        store.dismiss(pruned.occurrenceKey, fingerprint: fingerprint(pruned), now: TestDates.now.addingTimeInterval(-10 * 24 * 60 * 60))
        store.prune(endedBefore: TestDates.now.addingTimeInterval(-8 * 24 * 60 * 60), activeKeys: [changed.occurrenceKey], now: TestDates.now)
        #expect(store.isDismissed(changed.occurrenceKey, currentFingerprint: fingerprint(changed)))
        #expect(store.state(for: pruned.occurrenceKey) == nil)

        let invalidRetry = await store.retryPersistence()

        #expect(!invalidRetry)
        #expect(store.persistenceFailure == expectedFailure)
        #expect(store.isPersistencePending)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber == permissions)
        }
        #expect(try Data(contentsOf: file) == original)
        try recoveredBytes.write(to: file, options: [.atomic])

        let validRetry = await store.retryPersistence()

        #expect(validRetry)
        #expect(store.persistenceFailure == nil)
        #expect(!store.isPersistencePending)
        #expect(store.state(for: untouched.occurrenceKey) == seed.state(for: untouched.occurrenceKey))
        #expect(store.isDismissed(changed.occurrenceKey, currentFingerprint: fingerprint(changed)))
        #expect(store.state(for: changed.occurrenceKey)?.snoozedUntil == nil)
        #expect(store.state(for: pruned.occurrenceKey) == nil)
        let reloaded = self.store(file, directory: directory)
        #expect(reloaded.persistenceFailure == nil)
        #expect(reloaded.state(for: untouched.occurrenceKey) == seed.state(for: untouched.occurrenceKey))
        #expect(reloaded.isDismissed(changed.occurrenceKey, currentFingerprint: fingerprint(changed)))
        #expect(reloaded.state(for: changed.occurrenceKey)?.snoozedUntil == nil)
        #expect(reloaded.state(for: pruned.occurrenceKey) == nil)
    }

    @Test("A blocked reminder write stays pending until a real retry can save the current dismissal")
    func reminderWriteFailureRecoversAfterObstructionIsRemoved() async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "state.json")
        let store = self.store(file, directory: directory)
        #expect(store.persistenceFailure == nil)
        #expect(!store.isPersistencePending)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let event = event("write-failure")

        store.dismiss(event.occurrenceKey, fingerprint: fingerprint(event), now: TestDates.now)

        #expect(store.persistenceFailure == .writeFailed)
        #expect(store.isPersistencePending)
        #expect(store.isDismissed(event.occurrenceKey, currentFingerprint: fingerprint(event)))
        #expect(await store.retryPersistence() == false)
        #expect(store.persistenceFailure == .writeFailed)
        try FileManager.default.removeItem(at: file)

        let retried = await store.retryPersistence()

        #expect(retried)
        #expect(store.persistenceFailure == nil)
        #expect(!store.isPersistencePending)
        let reloaded = self.store(file, directory: directory)
        #expect(reloaded.persistenceFailure == nil)
        #expect(reloaded.isDismissed(event.occurrenceKey, currentFingerprint: fingerprint(event)))
    }

    @Test("A recovered reminder read followed by a denied save keeps merged memory and removals pending")
    func reminderRecoveredMergeSurvivesWriteDenial() async throws {
        try #require(geteuid() != 0, "Recovery write denial requires a non-root process.")
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appending(path: "storage")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)
        let file = storage.appending(path: "state.json")
        let seedFile = directory.appending(path: "recovered-state.json")
        let untouched = event("write-denied-untouched")
        let changed = event("write-denied-changed")
        let pruned = event("write-denied-pruned")
        let seed = self.store(seedFile, directory: directory)
        seed.dismiss(untouched.occurrenceKey, fingerprint: fingerprint(untouched), now: TestDates.now)
        seed.snooze(changed.occurrenceKey, until: TestDates.now.addingTimeInterval(300), now: TestDates.now)
        seed.dismiss(pruned.occurrenceKey, fingerprint: fingerprint(pruned), now: TestDates.now)
        let recoveredBytes = try Data(contentsOf: seedFile)
        try Data("[{\"synthetic-invalid-before-recovery\":".utf8).write(to: file)
        let store = self.store(file, directory: directory)
        #expect(store.persistenceFailure == .invalidData)
        store.dismiss(changed.occurrenceKey, fingerprint: fingerprint(changed), now: TestDates.now)
        store.dismiss(pruned.occurrenceKey, fingerprint: fingerprint(pruned), now: TestDates.now.addingTimeInterval(-10 * 24 * 60 * 60))
        store.prune(endedBefore: TestDates.now.addingTimeInterval(-8 * 24 * 60 * 60), activeKeys: [changed.occurrenceKey], now: TestDates.now)
        try recoveredBytes.write(to: file, options: [.atomic])
        let attributes = try FileManager.default.attributesOfItem(atPath: storage.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        defer {
            do {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: storage.path)
                #expect(try FileManager.default.attributesOfItem(atPath: storage.path)[.posixPermissions] as? NSNumber == permissions)
            } catch { Issue.record("The owned recovery directory permissions could not be restored.") }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: storage.path)
        let readableRecovery = try Data(contentsOf: file)
        try #require(readableRecovery == recoveredBytes, "Recovery data must remain readable during the denied save.")
        try requireWriteDenial(storage.appending(path: "owned-write-probe"))

        let deniedRetry = await store.retryPersistence()

        #expect(!deniedRetry)
        #expect(store.persistenceFailure == .writeFailed)
        #expect(store.isPersistencePending)
        #expect(try Data(contentsOf: file) == recoveredBytes)
        #expect(store.state(for: untouched.occurrenceKey) == seed.state(for: untouched.occurrenceKey))
        #expect(store.isDismissed(changed.occurrenceKey, currentFingerprint: fingerprint(changed)))
        #expect(store.state(for: changed.occurrenceKey)?.snoozedUntil == nil)
        #expect(store.state(for: pruned.occurrenceKey) == nil)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: storage.path)

        let savedRetry = await store.retryPersistence()

        #expect(savedRetry)
        #expect(store.persistenceFailure == nil)
        #expect(!store.isPersistencePending)
        let reloaded = self.store(file, directory: directory)
        #expect(reloaded.persistenceFailure == nil)
        #expect(reloaded.state(for: untouched.occurrenceKey) == seed.state(for: untouched.occurrenceKey))
        #expect(reloaded.isDismissed(changed.occurrenceKey, currentFingerprint: fingerprint(changed)))
        #expect(reloaded.state(for: changed.occurrenceKey)?.snoozedUntil == nil)
        #expect(reloaded.state(for: pruned.occurrenceKey) == nil)
    }

    @Test("Missing and valid reminder files report no persistence failure", arguments: [false, true])
    func reminderStateWithoutFailure(hasSavedState: Bool) async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "state.json")
        let event = event("healthy")
        if hasSavedState {
            self.store(file, directory: directory).dismiss(event.occurrenceKey, fingerprint: fingerprint(event), now: TestDates.now)
        }
        let store = self.store(file, directory: directory)

        #expect(store.persistenceFailure == nil)
        #expect(!store.isPersistencePending)
        #expect(await store.retryPersistence())
        #expect(store.persistenceFailure == nil)
        #expect(!store.isPersistencePending)
        #expect(store.isDismissed(event.occurrenceKey, currentFingerprint: fingerprint(event)) == hasSavedState)
        #expect(self.store(file, directory: directory).persistenceFailure == nil)
    }

    enum SettingsDamage: CaseIterable, Sendable {
        case malformedJSON, wrongStoredType
    }

    enum ReminderDamage: CaseIterable, Sendable {
        case invalidData, readDenied
    }

    @MainActor
    private struct PreferencesFixture {
        let domain = "PersistenceRecoveryStatusTests.\(UUID().uuidString)"
        var preferences: SettingsPreferences { SettingsPreferences(domainName: domain) }

        func replace(_ value: CFPropertyList) throws {
            CFPreferencesSetValue("meetingShield.settings.v1" as CFString, value, domain as CFString,
                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            try #require(CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
        }

        func cleanup() {
            let users: [CFString] = [kCFPreferencesCurrentUser, kCFPreferencesAnyUser]
            for user in users {
                CFPreferencesSetValue("meetingShield.settings.v1" as CFString, nil, domain as CFString, user, kCFPreferencesAnyHost)
                _ = CFPreferencesSynchronize(domain as CFString, user, kCFPreferencesAnyHost)
                #expect(CFPreferencesCopyValue("meetingShield.settings.v1" as CFString, domain as CFString, user, kCFPreferencesAnyHost) == nil)
            }
            CFPreferencesSetValue("synthetic.p15.canary" as CFString, nil, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            _ = CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            #expect(CFPreferencesCopyValue("synthetic.p15.canary" as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) == nil)
        }
    }

    private func store(_ file: URL, directory: URL) -> ReminderStateStore {
        ReminderStateStore(fileURL: file, diagnostics: DiagnosticsRecorder(
            directory: directory.appending(path: "diagnostics"), nativeSink: { _, _ in }
        ))
    }

    private func event(_ id: String) -> CalendarEventOccurrence {
        CalendarEventOccurrence.sample(
            eventID: "synthetic-persistence-status-\(id)", title: "Synthetic persistence meeting",
            startDate: TestDates.start, calendarID: "synthetic-account::primary"
        )
    }

    private func fingerprint(_ event: CalendarEventOccurrence) -> MaterialChangeFingerprint {
        event.materialFingerprint(detectedLinks: [])
    }

    private func requireReadDenial(_ file: URL) throws {
        var denied = false
        do {
            _ = try Data(contentsOf: file)
        } catch {
            let error = error as NSError
            let cocoa = error.domain == NSCocoaErrorDomain && error.code == CocoaError.Code.fileReadNoPermission.rawValue
            let posix = error.domain == NSPOSIXErrorDomain && [POSIXErrorCode.EACCES, .EPERM].contains { Int($0.rawValue) == error.code }
            try #require(cocoa || posix, "The fixture must fail with an actual file read denial.")
            denied = true
        }
        try #require(denied, "The denied read must be proven before initializing the store under test.")
    }

    private func requireWriteDenial(_ file: URL) throws {
        var denied = false
        do {
            try Data("synthetic-write-denial-probe".utf8).write(to: file, options: [.atomic])
        } catch {
            let error = error as NSError
            let cocoa = error.domain == NSCocoaErrorDomain && error.code == CocoaError.Code.fileWriteNoPermission.rawValue
            let posix = error.domain == NSPOSIXErrorDomain && [POSIXErrorCode.EACCES, .EPERM].contains { Int($0.rawValue) == error.code }
            try #require(cocoa || posix, "The fixture must fail with an actual file write denial.")
            denied = true
        }
        try #require(denied, "Write denial must be proven before retrying the recovered state.")
    }
}
