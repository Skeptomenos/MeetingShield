import Darwin
import Foundation
import Testing
@testable import MeetingShield

@Suite("Persistence recovery integrity")
struct PersistenceRecoveryIntegrityTests {
    private let settingsKey = "meetingShield.settings.v1"

    @Test("Unreadable saved settings survive ordinary updates and provider-default reconciliation", arguments: SettingsDamage.allCases)
    @MainActor
    func unreadableSettingsAreNotReplaced(damage: SettingsDamage) throws {
        let domain = "PersistenceRecoveryIntegrityTests.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let malformed = Data("{\"defaultLeadTime\":".utf8)
        let wrongType = "synthetic-settings-stored-as-a-string"
        switch damage {
        case .malformedJSON:
            defaults.set(malformed, forKey: settingsKey)
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(AppSettingsSnapshot.self, from: malformed)
            }
        case .wrongStoredType:
            defaults.set(wrongType, forKey: settingsKey)
            #expect(defaults.data(forKey: settingsKey) == nil)
        }
        let store = AppSettingsStore(domainName: domain)
        #expect(store.snapshot == .defaults)

        store.update { $0.defaultLeadTime = 180 }

        #expect(store.snapshot.defaultLeadTime == 180)
        expectOriginalSettings(defaults, damage: damage, data: malformed, string: wrongType)
        let calendarIDs: Set<String> = ["synthetic-account::primary"]

        store.update { $0.recordProviderDefaultCalendarIDs(calendarIDs) }

        #expect(store.snapshot.defaultLeadTime == 180)
        #expect(store.snapshot.providerDefaultCalendarIDs == calendarIDs)
        expectOriginalSettings(defaults, damage: damage, data: malformed, string: wrongType)
    }

    @Test("Absent and valid explicit-none settings still persist ordinary updates", arguments: SettingsSeed.allCases)
    @MainActor
    func writableSettingsKeepNormalPersistence(seed: SettingsSeed) throws {
        let domain = "PersistenceRecoveryIntegrityTests.settings-control.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        switch seed {
        case .absent:
            #expect(defaults.object(forKey: settingsKey) == nil)
        case .explicitNone:
            var snapshot = AppSettingsSnapshot.defaults
            snapshot.selectedCalendarIDs = []
            try defaults.set(JSONEncoder().encode(snapshot), forKey: settingsKey)
        }
        let store = AppSettingsStore(domainName: domain)
        let calendarIDs: Set<String> = ["synthetic-account::primary"]

        store.update { $0.defaultLeadTime = 180 }
        store.update { $0.recordProviderDefaultCalendarIDs(calendarIDs) }

        let data = try #require(defaults.data(forKey: settingsKey))
        let saved = try JSONDecoder().decode(AppSettingsSnapshot.self, from: data)
        #expect(saved == store.snapshot)
        #expect(saved.defaultLeadTime == 180)
        #expect(saved.providerDefaultCalendarIDs == calendarIDs)
        let restarted = AppSettingsStore(domainName: domain)
        #expect(restarted.snapshot == saved)
        switch seed {
        case .absent:
            #expect(!restarted.snapshot.hasExplicitCalendarSelection)
            #expect(restarted.snapshot.isCalendarSelected("synthetic-account::primary"))
        case .explicitNone:
            #expect(restarted.snapshot.hasExplicitCalendarSelection)
            #expect(restarted.snapshot.selectedCalendarIDs.isEmpty)
            #expect(!restarted.snapshot.isCalendarSelected("synthetic-account::primary"))
        }
    }

    @Test("Corrupt reminder bytes survive dismissal and maintenance while the current dismissal remains effective")
    func corruptReminderStateIsNotReplaced() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "reminder-state.json")
        let original = Data("[{\"synthetic-corrupt-reminder-state\":".utf8)
        try original.write(to: file)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([OccurrenceReminderState].self, from: original)
        }
        let store = reminderStore(file, directory: directory)
        let event = event("current-dismissal")
        let fingerprint = event.materialFingerprint(detectedLinks: [])

        store.dismiss(event.occurrenceKey, fingerprint: fingerprint, now: TestDates.now)

        #expect(store.isDismissed(event.occurrenceKey, currentFingerprint: fingerprint))
        #expect(try Data(contentsOf: file) == original)

        maintain(store, event: event)

        #expect(store.isDismissed(event.occurrenceKey, currentFingerprint: fingerprint))
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("A missing reminder file permits the first dismissal to persist and survive restart")
    func missingReminderStateSupportsFirstSave() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "first-run/reminder-state.json")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let store = reminderStore(file, directory: directory)
        let event = event("first-dismissal")
        let fingerprint = event.materialFingerprint(detectedLinks: [])

        store.dismiss(event.occurrenceKey, fingerprint: fingerprint, now: TestDates.now)
        maintain(store, event: event)

        #expect(store.isDismissed(event.occurrenceKey, currentFingerprint: fingerprint))
        let saved = try JSONDecoder().decode([OccurrenceReminderState].self, from: Data(contentsOf: file))
        #expect(saved.count == 1)
        #expect(saved.first?.occurrenceKey == event.occurrenceKey)
        let restarted = reminderStore(file, directory: directory)
        #expect(restarted.isDismissed(event.occurrenceKey, currentFingerprint: fingerprint))
    }

    @Test("A denied reminder-file read cannot become an atomic replacement during a later action")
    func deniedReminderReadPreservesUnreadBytes() throws {
        try #require(geteuid() != 0, "This probe must run as a non-root user so file read denial is meaningful.")
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "reminder-state.json")
        let previous = event("previous-saved-dismissal")
        reminderStore(file, directory: directory).dismiss(
            previous.occurrenceKey, fingerprint: previous.materialFingerprint(detectedLinks: []), now: TestDates.now
        )
        let original = try Data(contentsOf: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let originalPermissions = try #require(attributes[.posixPermissions] as? NSNumber)
        defer {
            do {
                try FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: file.path)
                let restored = try FileManager.default.attributesOfItem(atPath: file.path)
                #expect(restored[.posixPermissions] as? NSNumber == originalPermissions)
                #expect(try Data(contentsOf: file) == original)
            } catch {
                Issue.record("The owned temporary reminder file could not be verified after restoring permissions.")
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        var readWasDenied = false
        do {
            _ = try Data(contentsOf: file)
        } catch {
            let error = error as NSError
            let cocoaDenial = error.domain == NSCocoaErrorDomain && error.code == CocoaError.Code.fileReadNoPermission.rawValue
            let posixDenial = error.domain == NSPOSIXErrorDomain && [POSIXErrorCode.EACCES, .EPERM].contains {
                Int($0.rawValue) == error.code
            }
            try #require(cocoaDenial || posixDenial, "The fixture must fail with actual read denial, not another I/O error.")
            readWasDenied = true
        }
        try #require(readWasDenied, "The unreadable fixture must be proven before initializing the store.")
        let store = reminderStore(file, directory: directory)
        let current = event("new-in-memory-dismissal")
        let fingerprint = current.materialFingerprint(detectedLinks: [])

        store.dismiss(current.occurrenceKey, fingerprint: fingerprint, now: TestDates.now)
        maintain(store, event: current)

        #expect(store.isDismissed(current.occurrenceKey, currentFingerprint: fingerprint))
    }

    enum SettingsDamage: CaseIterable, Sendable {
        case malformedJSON, wrongStoredType
    }

    enum SettingsSeed: CaseIterable, Sendable {
        case absent, explicitNone
    }

    private func expectOriginalSettings(_ defaults: UserDefaults, damage: SettingsDamage, data: Data, string: String) {
        switch damage {
        case .malformedJSON: #expect(defaults.object(forKey: settingsKey) as? Data == data)
        case .wrongStoredType: #expect(defaults.object(forKey: settingsKey) as? String == string)
        }
    }

    private func event(_ id: String) -> CalendarEventOccurrence {
        CalendarEventOccurrence.sample(
            eventID: "synthetic-persistence-\(id)", title: "Synthetic persistence meeting",
            startDate: TestDates.start, calendarID: "synthetic-account::primary"
        )
    }

    private func reminderStore(_ file: URL, directory: URL) -> ReminderStateStore {
        ReminderStateStore(
            fileURL: file,
            diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "diagnostics"), nativeSink: { _, _ in })
        )
    }

    private func maintain(_ store: ReminderStateStore, event: CalendarEventOccurrence) {
        _ = store.reconcileLegacyStates(events: [event], now: TestDates.now)
        store.reconcileSnoozes(events: [event], now: TestDates.now)
        store.reconcileAcknowledgements(events: [event], now: TestDates.now)
        store.prune(
            endedBefore: TestDates.now.addingTimeInterval(-8 * 24 * 60 * 60),
            activeKeys: [event.occurrenceKey], now: TestDates.now
        )
    }
}
