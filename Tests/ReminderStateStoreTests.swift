import Foundation
import Testing
@testable import MeetingShield

@Suite("Reminder state")
struct ReminderStateStoreTests {
    @Test("A shortened snooze survives restart and a later reschedule")
    func clampedSnoozePersistsWithoutExtending() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "reminder-state.json")
        let store = ReminderStateStore(fileURL: fileURL)
        var event = CalendarEventOccurrence.sample(eventID: "rescheduled", title: "Synthetic rescheduled meeting", startDate: TestDates.now.addingTimeInterval(600))
        let originalDeadline = TestDates.now.addingTimeInterval(300)
        store.snooze(event.occurrenceKey, until: originalDeadline, now: TestDates.now)
        event.startDate = TestDates.now.addingTimeInterval(60)
        let deadline = event.startDate.addingTimeInterval(-10)

        store.reconcileSnoozes(events: [event], now: TestDates.now)

        #expect(store.state(for: event.occurrenceKey)?.snoozedUntil == deadline)
        let restarted = ReminderStateStore(fileURL: fileURL)
        #expect(restarted.state(for: event.occurrenceKey)?.snoozedUntil == deadline)
        event.startDate = TestDates.now.addingTimeInterval(1200)
        let before = try Data(contentsOf: fileURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)

        restarted.reconcileSnoozes(events: [event], now: TestDates.now.addingTimeInterval(55))

        #expect(restarted.state(for: event.occurrenceKey)?.snoozedUntil == deadline)
        #expect(try Data(contentsOf: fileURL) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date == attributes[.modificationDate] as? Date)
    }

    @Test("Snooze clamp failure keeps safe memory and retries unchanged state")
    func failedClampWriteRetriesWithoutLosingSafety() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "reminder-state.json")
        let store = ReminderStateStore(fileURL: fileURL)
        let event = CalendarEventOccurrence.sample(eventID: "clamp-write-failure", title: "Synthetic failed write", startDate: TestDates.now.addingTimeInterval(60))
        let deadline = event.startDate.addingTimeInterval(-10)
        store.snooze(event.occurrenceKey, until: TestDates.now.addingTimeInterval(300), now: TestDates.now)
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)

        store.reconcileSnoozes(events: [event], now: TestDates.now)

        #expect(store.state(for: event.occurrenceKey)?.snoozedUntil == deadline)
        #expect(store.isPersistencePending)
        try FileManager.default.removeItem(at: fileURL)
        store.reconcileSnoozes(events: [event], now: TestDates.now.addingTimeInterval(1))

        #expect(!store.isPersistencePending)
        #expect(ReminderStateStore(fileURL: fileURL).state(for: event.occurrenceKey)?.snoozedUntil == deadline)
    }

    @Test("Reconciliation changes only a matching scoped snooze and preserves other state")
    func clampPreservesOtherSourcesAndActions() {
        let event = CalendarEventOccurrence.sample(eventID: "shared", title: "Synthetic scoped meeting", startDate: TestDates.now.addingTimeInterval(60))
        var other = event
        other.accountID = "other-account"
        let store = ReminderStateStore()
        let oldDeadline = TestDates.now.addingTimeInterval(300)
        let fingerprint = event.materialFingerprint(detectedLinks: [])
        store.dismiss(event.occurrenceKey, fingerprint: fingerprint, now: TestDates.now)
        store.muteUntilEventEnd(event.occurrenceKey, now: TestDates.now)
        for key in [event.occurrenceKey, other.occurrenceKey, event.occurrenceKey.legacyKey] {
            store.snooze(key, until: oldDeadline, now: TestDates.now)
        }

        store.reconcileSnoozes(events: [event], now: TestDates.now)

        #expect(store.state(for: event.occurrenceKey)?.snoozedUntil == event.startDate.addingTimeInterval(-10))
        #expect(store.isDismissed(event.occurrenceKey, currentFingerprint: fingerprint))
        #expect(store.state(for: event.occurrenceKey)?.mutedUntilEventEnd == true)
        #expect(store.state(for: other.occurrenceKey)?.snoozedUntil == oldDeadline)
        #expect(store.state(for: event.occurrenceKey.legacyKey)?.snoozedUntil == oldDeadline)
    }

    @Test("Dismiss resets on material changes but not description-only changes")
    func dismissalFingerprintBehavior() {
        let event = CalendarEventOccurrence.sample(
            eventID: "state",
            title: "State",
            startDate: TestDates.start,
            description: "Initial"
        )
        let store = ReminderStateStore()
        let fingerprint = event.materialFingerprint(detectedLinks: [])
        store.dismiss(event.occurrenceKey, fingerprint: fingerprint)

        var descriptionOnly = event
        descriptionOnly.eventDescription = "Changed words"

        var titleChanged = event
        titleChanged.title = "New State"

        #expect(store.isDismissed(descriptionOnly.occurrenceKey, currentFingerprint: descriptionOnly.materialFingerprint(detectedLinks: [])))
        #expect(!store.isDismissed(titleChanged.occurrenceKey, currentFingerprint: titleChanged.materialFingerprint(detectedLinks: [])))
    }

    @Test("Description link changes reset dismissal")
    func linkChangeResetsDismissal() {
        let event = CalendarEventOccurrence.sample(eventID: "link", title: "Link", startDate: TestDates.start)
        let oldLink = [MeetingLink(url: URL(string: "https://meet.google.com/old")!, kind: .googleMeet, source: .description)]
        let newLink = [MeetingLink(url: URL(string: "https://meet.google.com/new")!, kind: .googleMeet, source: .description)]
        let store = ReminderStateStore()

        store.dismiss(event.occurrenceKey, fingerprint: event.materialFingerprint(detectedLinks: oldLink))

        #expect(!store.isDismissed(event.occurrenceKey, currentFingerprint: event.materialFingerprint(detectedLinks: newLink)))
    }

    @Test("Persisted state with duplicate occurrence keys loads without crashing")
    func duplicateKeysInPersistedStateDoNotCrash() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "reminder-state.json")
        let key = OccurrenceKey(providerID: "mock", eventID: "dup", originalStartDate: nil)
        let older = OccurrenceReminderState(
            occurrenceKey: key,
            snoozedUntil: nil,
            dismissedFingerprint: nil,
            mutedUntilEventEnd: false,
            updatedAt: TestDates.now
        )
        var newer = older
        newer.mutedUntilEventEnd = true
        newer.updatedAt = TestDates.now.addingTimeInterval(60)
        let data = try JSONEncoder().encode([older, newer])
        try data.write(to: fileURL)

        let store = ReminderStateStore(fileURL: fileURL)

        #expect(store.state(for: key) == newer)
    }

    @Test("Prune drops stale entries but keeps active occurrence keys")
    func pruneKeepsActiveKeys() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "reminder-state.json")
        let store = ReminderStateStore(fileURL: fileURL)
        let staleKey = OccurrenceKey(providerID: "mock", eventID: "stale", originalStartDate: nil)
        let activeKey = OccurrenceKey(providerID: "mock", eventID: "active", originalStartDate: nil)
        let longAgo = TestDates.now.addingTimeInterval(-30 * 24 * 60 * 60)
        store.snooze(staleKey, until: longAgo.addingTimeInterval(60), now: longAgo)
        store.snooze(activeKey, until: longAgo.addingTimeInterval(60), now: longAgo)

        store.prune(endedBefore: TestDates.now.addingTimeInterval(-8 * 24 * 60 * 60), activeKeys: [activeKey])

        #expect(store.state(for: staleKey) == nil)
        #expect(store.state(for: activeKey) != nil)
    }
}
