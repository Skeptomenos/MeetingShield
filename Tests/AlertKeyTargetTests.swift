import Foundation
import Testing
@testable import MeetingShield

@Suite("Alert key target")
@MainActor
struct AlertKeyTargetTests {
    private func reminder(_ id: String, startOffset: TimeInterval = 600) -> ScheduledReminder {
        let event = CalendarEventOccurrence.sample(
            eventID: id,
            title: "Meeting \(id)",
            startDate: TestDates.now.addingTimeInterval(startOffset)
        )
        return ScheduledReminder(
            event: event,
            detectedLinks: [],
            fireDate: TestDates.now,
            browserSelection: .systemDefault,
            isSnoozed: false
        )
    }

    @Test("Defaults to the first reminder")
    func defaultsToFirstReminder() {
        let reminders = [reminder("first"), reminder("second")]
        let target = AlertKeyTarget(reminders: reminders)

        #expect(target.selectedReminder?.id == reminders[0].id)
    }

    @Test("Enter and S resolve to the user-selected reminder, not the first")
    func keyActionsFollowSelection() {
        let reminders = [reminder("first"), reminder("second")]
        let target = AlertKeyTarget(reminders: reminders)

        target.selectedID = reminders[1].id

        #expect(target.selectedReminder?.id == "mock:second")
    }

    @Test("Selection falls back to first when the selected reminder disappears")
    func selectionFallsBackWhenReminderGone() {
        let reminders = [reminder("first"), reminder("second")]
        let target = AlertKeyTarget(reminders: reminders)
        target.selectedID = reminders[1].id

        target.update(reminders: [reminder("first")])

        #expect(target.selectedReminder?.id == "mock:first")
    }

    @Test("Empty reminder list yields no target")
    func emptyRemindersYieldNoTarget() {
        let target = AlertKeyTarget(reminders: [])

        #expect(target.selectedReminder == nil)
    }
}
