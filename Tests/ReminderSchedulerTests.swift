import Foundation
import Testing
@testable import MeetingShield

@Suite("Reminder scheduler")
struct ReminderSchedulerTests {
    let scheduler = ReminderScheduler()

    @Test("Initial reminder fires lead time before start")
    func leadTimeBeforeStart() {
        let event = CalendarEventOccurrence.sample(eventID: "lead", title: "Lead", startDate: TestDates.start)
        let candidate = ReminderCandidate(event: event, detectedLinks: [], leadTime: 120, browserSelection: .systemDefault)

        let scheduled = scheduler.schedule(candidates: [candidate], stateStore: ReminderStateStore(), now: TestDates.now)

        #expect(scheduled.first?.fireDate == TestDates.start.addingTimeInterval(-120))
    }

    @Test("Snooze clamps to ten seconds before start")
    func snoozeClampsToDangerPoint() {
        let event = CalendarEventOccurrence.sample(eventID: "snooze", title: "Snooze", startDate: TestDates.now.addingTimeInterval(90))
        let returnDate = scheduler.snoozeReturnDate(for: event, now: TestDates.now, choice: .seconds(300))

        #expect(returnDate == event.startDate.addingTimeInterval(-10))
    }

    @Test("Available snooze choices hide impossible fixed durations")
    func availableChoicesHideImpossibleFixedDurations() {
        let event = CalendarEventOccurrence.sample(eventID: "soon", title: "Soon", startDate: TestDates.now.addingTimeInterval(90))
        let choices = scheduler.availableSnoozeChoices(event: event, now: TestDates.now, globalDuration: 120)

        #expect(choices == [.seconds(30), .seconds(60), .untilDangerPoint])
    }

    @Test("Snooze is unavailable in final ten seconds")
    func finalTenSecondsDisablesSnooze() {
        let now = TestDates.start.addingTimeInterval(-9)
        let event = CalendarEventOccurrence.sample(eventID: "final", title: "Final", startDate: TestDates.start)

        #expect(scheduler.availableSnoozeChoices(event: event, now: now, globalDuration: 120).isEmpty)
        #expect(scheduler.snoozeReturnDate(for: event, now: now, choice: .seconds(30)) == nil)
    }

    @Test("Overlapping meetings are grouped and deduped separately")
    func overlapAndDedupe() {
        let first = CalendarEventOccurrence.sample(eventID: "first", title: "First", startDate: TestDates.start, endDate: TestDates.start.addingTimeInterval(1800))
        let second = CalendarEventOccurrence.sample(eventID: "second", title: "Second", startDate: TestDates.start.addingTimeInterval(600))
        let duplicate = CalendarEventOccurrence.sample(eventID: "duplicate", title: "First", startDate: TestDates.start, endDate: TestDates.start.addingTimeInterval(1800))
        let candidates = [first, second, duplicate].map {
            ReminderCandidate(event: $0, detectedLinks: [], leadTime: 120, browserSelection: .systemDefault)
        }

        let scheduled = scheduler.schedule(candidates: candidates, stateStore: ReminderStateStore(), now: TestDates.now)
        let due = scheduler.dueReminders(from: scheduled, now: TestDates.start.addingTimeInterval(600))
        let groups = scheduler.overlaps(in: due)

        #expect(due.count == 2)
        #expect(groups.count == 1)
        #expect(groups[0].count == 2)
    }
}
