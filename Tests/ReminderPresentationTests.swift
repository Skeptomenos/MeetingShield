import Foundation
import Testing
@testable import MeetingShield

@Suite("Current reminder presentation")
@MainActor
struct ReminderPresentationTests {
    @Test("A visible occurrence refreshes after its time and meeting link change")
    func materialUpdateRefreshesVisibleContent() throws {
        let original = CalendarEventOccurrence.sample(
            eventID: "live-update", title: "Synthetic live update",
            startDate: TestDates.now.addingTimeInterval(30),
            location: "https://meet.google.com/synthetic-old"
        )
        var updated = original
        updated.startDate = TestDates.now.addingTimeInterval(60)
        updated.location = "https://meet.google.com/synthetic-new"
        let before = compute([original])
        let after = compute([updated])
        let oldReminder = try #require(before.due.first)
        let newReminder = try #require(after.due.first)

        #expect(oldReminder.id == newReminder.id)
        #expect(oldReminder.event.startDate != newReminder.event.startDate)
        #expect(oldReminder.detectedLinks != newReminder.detectedLinks)
        #expect(decision(due: after.due, previous: before.due) == .updateFullScreen(playSound: false))
    }

    @Test("Changed visible or actionable fields refresh an existing alert", arguments: ChangedField.allCases)
    func changedFieldsRefresh(field: ChangedField) throws {
        let before = try reminder("field-change")
        var after = before
        switch field {
        case .title:
            after.event.title = "Synthetic revised title"
        case .start:
            after.event.startDate = before.event.startDate.addingTimeInterval(20)
        case .end:
            after.event.endDate = before.event.endDate.addingTimeInterval(60)
        case .calendarURL:
            after.event.htmlLink = URL(string: "https://calendar.google.com/calendar/u/0/r/event?eid=synthetic-new")
        case .calendarLabel:
            after.event.calendarDisplayName = "Synthetic revised calendar"
        case .accountLabel:
            after.event.accountDisplayName = "Synthetic revised account"
        case .cacheStatus:
            after.event.isFromCache = true
        case .meetingURL:
            after.detectedLinks[0].url = try #require(URL(string: "https://meet.google.com/synthetic-new"))
        case .linkSource:
            after.detectedLinks[0].source = .conferenceMetadata
        case .linkKind:
            after.detectedLinks[0].kind = .generic
        case .browserSelection:
            after.browserSelection = BrowserSelection(browser: .safari, profileID: nil)
        }

        #expect(after.id == before.id)
        #expect(decision(due: [after], previous: [before]) == .updateFullScreen(playSound: false))
    }

    @Test("An unchanged visible reminder keeps its current presentation")
    func unchangedContentKeepsCurrentPresentation() throws {
        let current = try reminder("unchanged")

        #expect(decision(due: [current], previous: [current]) == .keepCurrent)
    }

    @Test("A newly due overlap requests sound while keeping existing windows")
    func arrivalRequestsPresentationSound() throws {
        let current = try reminder("current")
        let arriving = try reminder("arriving")

        #expect(decision(due: [current, arriving], previous: [current]) == .updateFullScreen(playSound: true))
        #expect(decision(due: [arriving], previous: [current, arriving]) == .updateFullScreen(playSound: false))
        #expect(decision(due: [arriving, current], previous: [current, arriving]) == .updateFullScreen(playSound: false))
    }

    @Test("An ending visible meeting schedules reevaluation before a later reminder fires")
    func eventEndPrecedesLaterFire() throws {
        let ending = CalendarEventOccurrence.sample(
            eventID: "ending", title: "Synthetic ending meeting",
            startDate: TestDates.now.addingTimeInterval(-300),
            endDate: TestDates.now.addingTimeInterval(15)
        )
        let future = CalendarEventOccurrence.sample(
            eventID: "future", title: "Synthetic future meeting",
            startDate: TestDates.now.addingTimeInterval(900)
        )
        let result = compute([ending, future])
        let futureReminder = try #require(result.scheduled.first { $0.id == future.id })
        let scheduler = ReminderScheduler()

        #expect(result.due.map(\.id) == [ending.id])
        #expect(futureReminder.fireDate > ending.endDate)
        #expect(scheduler.nextActionDate(from: result.scheduled, now: TestDates.now) == ending.endDate)
        #expect(scheduler.dueReminders(from: result.scheduled, now: ending.endDate).isEmpty)
        #expect(scheduler.nextActionDate(from: result.scheduled, now: ending.endDate) == futureReminder.fireDate)
    }

    @Test("A future fire remains the next deadline when it occurs before the visible meeting ends")
    func futureFirePrecedesEventEnd() throws {
        let active = CalendarEventOccurrence.sample(
            eventID: "active", title: "Synthetic active meeting",
            startDate: TestDates.now.addingTimeInterval(-300),
            endDate: TestDates.now.addingTimeInterval(900)
        )
        let future = CalendarEventOccurrence.sample(
            eventID: "next", title: "Synthetic next meeting",
            startDate: TestDates.now.addingTimeInterval(180)
        )
        let result = compute([active, future])
        let futureReminder = try #require(result.scheduled.first { $0.id == future.id })

        #expect(futureReminder.fireDate < active.endDate)
        #expect(ReminderScheduler().nextActionDate(from: result.scheduled, now: TestDates.now) == futureReminder.fireDate)
    }

    @Test("Content edits and reordering retain the selected scoped occurrence")
    func selectionSurvivesEditAndReorder() throws {
        let first = try reminder("first")
        let selected = try reminder("selected")
        let target = AlertKeyTarget(reminders: [first, selected])
        target.selectedID = selected.id
        var updated = selected
        updated.event.title = "Synthetic selected revision"
        updated.event.startDate = selected.event.startDate.addingTimeInterval(20)
        updated.detectedLinks[0].url = try #require(URL(string: "https://meet.google.com/selected-new"))

        target.update(reminders: [updated, first])

        #expect(target.selectedID == selected.id)
        #expect(target.selectedReminder?.event.title == updated.event.title)
        #expect(target.selectedReminder?.event.startDate == updated.event.startDate)
        #expect(target.selectedReminder?.detectedLinks == updated.detectedLinks)
    }

    @Test("Removing the selected occurrence retargets the remaining reminder")
    func removalRetargetsRemainingOccurrence() throws {
        let remaining = try reminder("remaining")
        let removed = try reminder("removed")
        let target = AlertKeyTarget(reminders: [remaining, removed])
        target.selectedID = removed.id

        target.update(reminders: [remaining])

        #expect(target.selectedID == remaining.id)
        #expect(target.selectedReminder?.id == remaining.id)
    }

    @Test("Ending the selected occurrence retargets the remaining due meeting")
    func eventEndRetargetsRemainingOccurrence() throws {
        var ending = try reminder("ending-selection")
        ending.event.startDate = TestDates.now.addingTimeInterval(-300)
        ending.event.endDate = TestDates.now.addingTimeInterval(15)
        let remaining = try reminder("remaining-selection")
        let target = AlertKeyTarget(reminders: [remaining, ending])
        target.selectedID = ending.id

        target.update(reminders: ReminderScheduler().dueReminders(
            from: [remaining, ending], now: ending.event.endDate
        ))

        #expect(target.selectedID == remaining.id)
        #expect(target.selectedReminder?.id == remaining.id)
    }

    @Test("A calendar move does not carry selection to another source with the same raw event ID")
    func calendarMoveInvalidatesCapturedSelection() throws {
        let remaining = try reminder("remaining")
        let selected = try reminder("same-provider-id")
        var moved = selected
        moved.event.calendarID = "synthetic-other-calendar"
        let target = AlertKeyTarget(reminders: [remaining, selected])
        target.selectedID = selected.id

        target.update(reminders: [remaining, moved])

        #expect(moved.event.eventID == selected.event.eventID)
        #expect(moved.id != selected.id)
        #expect(target.selectedID == remaining.id)
        #expect(target.selectedReminder?.id != moved.id)
    }

    @Test("Removing all occurrences clears selection and requests alert removal")
    func emptyUpdateClearsTargetAndPresentation() throws {
        let selected = try reminder("last")
        let target = AlertKeyTarget(reminders: [selected])

        target.update(reminders: [])

        #expect(target.selectedID == nil)
        #expect(target.selectedReminder == nil)
        #expect(decision(due: [], previous: [selected]) == .clear)
        #expect(ReminderScheduler().nextActionDate(from: [], now: TestDates.now) == nil)
    }

    enum ChangedField: CaseIterable, Sendable {
        case title, start, end, calendarURL, calendarLabel, accountLabel, cacheStatus
        case meetingURL, linkSource, linkKind, browserSelection
    }

    private func reminder(_ id: String) throws -> ScheduledReminder {
        let event = CalendarEventOccurrence.sample(
            eventID: id, title: "Synthetic meeting", startDate: TestDates.now.addingTimeInterval(30),
            location: "https://meet.google.com/synthetic-old"
        )
        return try #require(compute([event]).due.first)
    }

    private func compute(_ events: [CalendarEventOccurrence]) -> ReminderPipeline.Result {
        ReminderPipeline().compute(
            events: events, settings: .defaults, stateStore: ReminderStateStore(), now: TestDates.now
        )
    }

    private func decision(due: [ScheduledReminder], previous: [ScheduledReminder]) -> ReminderPresentationDecision {
        ReminderPresentationDecision.decide(
            due: due, previous: previous,
            isPresentationMode: false, inWakeGrace: false, alertAlreadyShowing: true
        )
    }
}
