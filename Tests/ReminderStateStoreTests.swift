import Foundation
import Testing
@testable import MeetingShield

@Suite("Reminder state")
struct ReminderStateStoreTests {
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

        // Must not trap; either entry is acceptable, the store just has one.
        #expect(store.state(for: key) != nil)
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
