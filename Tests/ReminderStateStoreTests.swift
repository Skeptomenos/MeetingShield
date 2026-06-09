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
}
