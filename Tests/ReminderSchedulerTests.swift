import Foundation
import Testing
@testable import MeetingShield

@Suite("Reminder scheduler")
struct ReminderSchedulerTests {
    let scheduler = ReminderScheduler()

    @Test("Missing recurring origin cannot establish a true copy")
    func incompleteRecurrenceIdentityStaysSeparate() {
        var first = CalendarEventOccurrence.sample(eventID: "recurrence-incomplete", title: "Synthetic recurring copy", startDate: TestDates.now.addingTimeInterval(30))
        first.recurringEventID = "series"
        first.iCalUID = "series@example.invalid"
        var second = first
        second.eventID = "recurrence-known"
        second.originalStartDate = second.startDate

        let result = compute([first, second])

        #expect(result.due.count == 2)
        #expect(result.due.allSatisfy { $0.members.count == 1 })
    }

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

    @Test("An existing snooze follows an earlier rescheduled danger point", arguments: [49.0, 50.0, 51.0, 55.0, 75.0])
    func movedEarlierOccurrenceReclampsExistingSnooze(elapsed: TimeInterval) throws {
        var original = CalendarEventOccurrence.sample(
            eventID: "audit-moved-occurrence", title: "Synthetic rescheduled event",
            startDate: TestDates.now.addingTimeInterval(600)
        )
        original.originalStartDate = original.startDate
        let store = ReminderStateStore()
        store.snooze(original.occurrenceKey, until: TestDates.now.addingTimeInterval(300), now: TestDates.now)
        var moved = original
        moved.startDate = TestDates.now.addingTimeInterval(60)
        moved.endDate = moved.startDate.addingTimeInterval(1800)
        let now = TestDates.now.addingTimeInterval(elapsed)

        let result = ReminderPipeline().compute(events: [moved], settings: .defaults, stateStore: store, now: now)
        let scheduled = try #require(result.scheduled.first)

        #expect(moved.occurrenceKey == original.occurrenceKey)
        #expect(moved.materialFingerprint(detectedLinks: []) != original.materialFingerprint(detectedLinks: []))
        #expect(scheduled.fireDate == moved.startDate.addingTimeInterval(-10))
        #expect(scheduled.isSnoozed == (elapsed < 50))
        #expect(result.due.map(\.id) == (elapsed >= 50 ? [moved.id] : []))
    }

    @Test("Moving a meeting later does not extend its selected snooze deadline", arguments: [299.0, 300.0, 301.0])
    func movedLaterKeepsSnoozeDeadline(elapsed: TimeInterval) throws {
        var event = CalendarEventOccurrence.sample(
            eventID: "postponed-snooze", title: "Synthetic postponed meeting",
            startDate: TestDates.now.addingTimeInterval(600)
        )
        let store = ReminderStateStore()
        let deadline = TestDates.now.addingTimeInterval(300)
        store.snooze(event.occurrenceKey, until: deadline, now: TestDates.now)
        event.startDate = TestDates.now.addingTimeInterval(1800)
        event.endDate = event.startDate.addingTimeInterval(1800)
        let now = TestDates.now.addingTimeInterval(elapsed)

        let scheduled = scheduler.schedule(candidates: [candidate(event)], stateStore: store, now: now)
        let reminder = try #require(scheduled.first)

        #expect(reminder.fireDate == deadline)
        #expect(reminder.isSnoozed == (elapsed < 300))
        #expect(scheduler.dueReminders(from: scheduled, now: now).map(\.id) == (elapsed >= 300 ? [event.id] : []))
    }

    @Test("Fixed choices are 30 seconds, one, two and five minutes")
    func fixedChoicesAreIndependentOfGlobalDuration() {
        let event = CalendarEventOccurrence.sample(eventID: "fixed-choices", title: "Synthetic choices", startDate: TestDates.now.addingTimeInterval(600))

        #expect(scheduler.availableSnoozeChoices(event: event, now: TestDates.now)
            == [.seconds(30), .seconds(60), .seconds(120), .seconds(300), .untilDangerPoint])
    }

    @Test("The exact final-ten-second boundary rejects every snooze choice", arguments: [11.0, 10.0, 9.0])
    func exactSnoozeBoundary(secondsBeforeStart: TimeInterval) {
        let event = CalendarEventOccurrence.sample(eventID: "exact-boundary", title: "Synthetic boundary", startDate: TestDates.start)
        let now = event.startDate.addingTimeInterval(-secondsBeforeStart)
        let permitted = secondsBeforeStart > 10

        #expect(scheduler.availableSnoozeChoices(event: event, now: now) == (permitted ? [.untilDangerPoint] : []))
        for choice: SnoozeChoice in [.seconds(30), .seconds(60), .seconds(120), .seconds(300), .untilDangerPoint] {
            #expect(scheduler.snoozeReturnDate(for: event, now: now, choice: choice) == (permitted ? event.startDate.addingTimeInterval(-10) : nil))
        }
    }

    @Test("Expired and muted events remain excluded despite a stored snooze")
    func snoozeDoesNotOverrideEndedOrMutedState() {
        let ended = CalendarEventOccurrence.sample(eventID: "ended-snooze", title: "Synthetic ended meeting", startDate: TestDates.now.addingTimeInterval(-120), endDate: TestDates.now)
        let muted = CalendarEventOccurrence.sample(eventID: "muted-snooze", title: "Synthetic muted meeting", startDate: TestDates.now.addingTimeInterval(60))
        let store = ReminderStateStore()
        for event in [ended, muted] {
            store.snooze(event.occurrenceKey, until: TestDates.now.addingTimeInterval(300), now: TestDates.now)
        }
        store.muteUntilEventEnd(muted.occurrenceKey, now: TestDates.now)

        #expect(scheduler.schedule(candidates: [candidate(ended), candidate(muted)], stateStore: store, now: TestDates.now).isEmpty)
    }

    @Test("Available snooze choices hide impossible fixed durations")
    func availableChoicesHideImpossibleFixedDurations() {
        let event = CalendarEventOccurrence.sample(eventID: "soon", title: "Soon", startDate: TestDates.now.addingTimeInterval(90))
        let choices = scheduler.availableSnoozeChoices(event: event, now: TestDates.now)

        #expect(choices == [.seconds(30), .seconds(60), .untilDangerPoint])
    }

    @Test("Snooze is unavailable in final ten seconds")
    func finalTenSecondsDisablesSnooze() {
        let now = TestDates.start.addingTimeInterval(-9)
        let event = CalendarEventOccurrence.sample(eventID: "final", title: "Final", startDate: TestDates.start)

        #expect(scheduler.availableSnoozeChoices(event: event, now: now).isEmpty)
        #expect(scheduler.snoozeReturnDate(for: event, now: now, choice: .seconds(30)) == nil)
    }

    @Test("Overlapping meetings are grouped and deduped separately")
    func overlapAndDedupe() {
        let first = CalendarEventOccurrence.sample(eventID: "first", title: "First", startDate: TestDates.start, endDate: TestDates.start.addingTimeInterval(1800))
        let second = CalendarEventOccurrence.sample(eventID: "second", title: "Second", startDate: TestDates.start.addingTimeInterval(600))
        var duplicate = CalendarEventOccurrence.sample(eventID: "duplicate", title: "First", startDate: TestDates.start, endDate: TestDates.start.addingTimeInterval(1800))
        duplicate.iCalUID = first.iCalUID
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

    @Test("Distinct recurring occurrences both remain actionable")
    func recurringOccurrencesAreNotDuplicates() {
        var first = CalendarEventOccurrence.sample(
            eventID: "audit-series-occurrence-a", title: "Synthetic recurring meeting",
            startDate: TestDates.now.addingTimeInterval(30)
        )
        first.iCalUID = "audit-recurring-series@example.invalid"
        first.recurringEventID = "audit-recurring-series"
        first.originalStartDate = first.startDate
        var second = first
        second.eventID = "audit-series-occurrence-b"
        second.startDate = TestDates.now.addingTimeInterval(90)
        second.endDate = second.startDate.addingTimeInterval(1800)
        second.originalStartDate = second.startDate

        let result = compute([first, second])

        #expect(result.scheduled.count == 2)
        #expect(Set(result.due.map(\.event.occurrenceKey)) == [first.occurrenceKey, second.occurrenceKey])
    }

    @Test("A reused conference URL cannot hide a distinct meeting")
    func separateMeetingsCanReuseAConferenceURL() {
        let first = CalendarEventOccurrence.sample(
            eventID: "audit-shared-url-a", title: "Synthetic meeting A",
            startDate: TestDates.now.addingTimeInterval(30),
            location: "https://meet.google.com/audit-shared-room"
        )
        let second = CalendarEventOccurrence.sample(
            eventID: "audit-shared-url-b", title: "Synthetic meeting B",
            startDate: TestDates.now.addingTimeInterval(90),
            location: "https://meet.google.com/audit-shared-room"
        )

        let result = compute([first, second])

        #expect(result.scheduled.allSatisfy { !$0.detectedLinks.isEmpty })
        #expect(Set(result.due.map(\.event.occurrenceKey)) == [first.occurrenceKey, second.occurrenceKey])
    }

    @Test("CONTROL: true calendar copies still yield one visible reminder")
    func duplicateCalendarCopiesStillDeduplicate() {
        let first = CalendarEventOccurrence.sample(
            eventID: "audit-original", title: "Synthetic copied meeting",
            startDate: TestDates.now.addingTimeInterval(30)
        )
        var duplicate = first
        duplicate.eventID = "audit-calendar-copy"
        duplicate.calendarID = "secondary"

        let result = compute([first, duplicate])

        #expect(result.scheduled.count == 2)
        #expect(result.due.count == 1)
    }

    @Test("Same-link same-time meetings with distinct UIDs remain separate")
    func sameTimeAndLinkDoNotEstablishIdentity() {
        let first = CalendarEventOccurrence.sample(
            eventID: "same-time-a", title: "Synthetic meeting",
            startDate: TestDates.now.addingTimeInterval(30),
            location: "https://meet.google.com/audit-shared-room"
        )
        var second = first
        second.eventID = "same-time-b"
        second.iCalUID = "unrelated-occurrence@example.invalid"

        let result = compute([first, second])

        #expect(result.due.count == 2)
        #expect(Set(result.due.map(\.event.occurrenceKey)) == [first.occurrenceKey, second.occurrenceKey])
    }

    @Test("Missing or empty UIDs cannot group matching title, time and link", arguments: [String?.none, .some(""), .some("   ")])
    func missingUIDDoesNotCreateCopies(uid: String?) {
        var first = CalendarEventOccurrence.sample(
            eventID: "no-uid-a", title: "Synthetic meeting",
            startDate: TestDates.now.addingTimeInterval(30),
            location: "https://meet.google.com/audit-shared-room"
        )
        first.iCalUID = uid
        var second = first
        second.eventID = "no-uid-b"

        let result = compute([first, second])

        #expect(result.due.count == 2)
        #expect(Set(result.due.map(\.event.occurrenceKey)) == [first.occurrenceKey, second.occurrenceKey])
    }

    @Test("Recurring occurrences moved to the same current time retain distinct original times")
    func shiftedRecurringOccurrencesRemainSeparate() {
        var first = CalendarEventOccurrence.sample(
            eventID: "shifted-a", title: "Synthetic recurring meeting",
            startDate: TestDates.now.addingTimeInterval(30)
        )
        first.iCalUID = "shared-series@example.invalid"
        first.recurringEventID = "shared-series"
        first.originalStartDate = first.startDate.addingTimeInterval(-3600)
        var second = first
        second.eventID = "shifted-b"
        second.originalStartDate = first.startDate.addingTimeInterval(-1800)

        let result = compute([first, second])

        #expect(result.due.count == 2)
    }

    @Test("Copy candidates with disagreeing current start or end remain separate", arguments: [true, false])
    func staleCopyTimesDoNotMerge(changeStart: Bool) {
        var first = CalendarEventOccurrence.sample(
            eventID: "copy-time-a", title: "Synthetic recurring meeting",
            startDate: TestDates.now.addingTimeInterval(30)
        )
        first.originalStartDate = first.startDate
        var second = first
        second.eventID = "copy-time-b"
        if changeStart {
            second.startDate = second.startDate.addingTimeInterval(10)
        } else {
            second.endDate = second.endDate.addingTimeInterval(10)
        }

        let result = compute([first, second])

        #expect(result.due.count == 2)
    }

    @Test("Identical UIDs from different providers do not group")
    func copyIdentityIncludesProvider() {
        let first = CalendarEventOccurrence.sample(
            eventID: "provider-copy", title: "Synthetic copied meeting",
            startDate: TestDates.now.addingTimeInterval(30)
        )
        var second = first
        second.providerID = "another-provider"

        let result = compute([first, second])

        #expect(result.due.count == 2)
    }

    @Test("True-copy members retain each source event and extracted links")
    func trueCopyMembersPreserveOwnFingerprintInputs() throws {
        let first = CalendarEventOccurrence.sample(
            eventID: "member-a", title: "Synthetic copied meeting",
            startDate: TestDates.now.addingTimeInterval(30), calendarID: "calendar-a",
            location: "https://meet.google.com/audit-first-room"
        )
        var second = first
        second.eventID = "member-b"
        second.accountID = "another-account"
        second.calendarID = "calendar-b"
        second.title = "Synthetic local title"
        second.location = "https://meet.google.com/audit-second-room"

        let result = compute([second, first])
        let reminder = try #require(result.due.first)
        let expectedEvents = [first, second].sorted { $0.id < $1.id }

        #expect(result.due.count == 1)
        #expect(reminder.members.map(\.event) == expectedEvents)
        for event in expectedEvents {
            let member = try #require(reminder.members.first { $0.id == event.id })
            let links = MeetingLinkExtractor().extractLinks(from: event)
            #expect(member.detectedLinks == links)
            #expect(member.event.materialFingerprint(detectedLinks: member.detectedLinks) == event.materialFingerprint(detectedLinks: links))
        }
        #expect(Set(reminder.members.map { $0.event.materialFingerprint(detectedLinks: $0.detectedLinks) }).count == 2)
    }

    @Test("A due true copy retains a known member whose later lead time is not due")
    func groupsKnownCopiesBeforeDueFiltering() throws {
        let first = CalendarEventOccurrence.sample(
            eventID: "early-copy", title: "Synthetic copied meeting",
            startDate: TestDates.now.addingTimeInterval(60)
        )
        var second = first
        second.eventID = "later-copy"
        second.calendarID = "secondary"
        let scheduled = scheduler.schedule(
            candidates: [candidate(second, leadTime: 30), candidate(first, leadTime: 120)],
            stateStore: ReminderStateStore(), now: TestDates.now
        )

        let due = scheduler.dueReminders(from: scheduled, now: TestDates.now)
        let reminder = try #require(due.first)

        #expect(scheduled.count == 2)
        #expect(due.count == 1)
        #expect(reminder.event == first)
        #expect(reminder.fireDate == first.startDate.addingTimeInterval(-120))
        #expect(Set(reminder.members.map(\.id)) == [first.id, second.id])
    }

    @Test("Representative, member and reminder ordering are independent of input order")
    func duplicateGroupingHasDeterministicOrdering() throws {
        let first = CalendarEventOccurrence.sample(
            eventID: "copy-z", title: "Synthetic copied meeting",
            startDate: TestDates.now.addingTimeInterval(60)
        )
        var second = first
        second.eventID = "copy-a"
        second.calendarID = "secondary"
        var later = first
        later.eventID = "copy-0"
        let distinct = CalendarEventOccurrence.sample(
            eventID: "distinct", title: "Synthetic unrelated meeting",
            startDate: first.startDate
        )
        let permutations = [
            [candidate(first), candidate(second), candidate(later, leadTime: 90), candidate(distinct)],
            [candidate(distinct), candidate(later, leadTime: 90), candidate(second), candidate(first)],
            [candidate(later, leadTime: 90), candidate(first), candidate(distinct), candidate(second)]
        ]
        let representative = [first, second].min { $0.id < $1.id }
        let expectedRepresentative = try #require(representative)
        let expectedIDs = [expectedRepresentative.id, distinct.id].sorted()
        let expectedMemberIDs = [first.id, second.id, later.id].sorted()

        for candidates in permutations {
            let scheduled = scheduler.schedule(candidates: candidates, stateStore: ReminderStateStore(), now: TestDates.now)
            let due = scheduler.dueReminders(from: scheduled, now: TestDates.now)
            let grouped = try #require(due.first { $0.event.iCalUID == first.iCalUID })

            #expect(due.map(\.id) == expectedIDs)
            #expect(grouped.id == expectedRepresentative.id)
            #expect(grouped.members.map(\.id) == expectedMemberIDs)
        }
    }

    private func candidate(_ event: CalendarEventOccurrence, leadTime: TimeInterval = 120) -> ReminderCandidate {
        ReminderCandidate(
            event: event, detectedLinks: MeetingLinkExtractor().extractLinks(from: event),
            leadTime: leadTime, browserSelection: .systemDefault
        )
    }

    private func compute(_ events: [CalendarEventOccurrence]) -> ReminderPipeline.Result {
        var settings = AppSettingsSnapshot.defaults
        settings.defaultLeadTime = 120
        return ReminderPipeline().compute(
            events: events, settings: settings, stateStore: ReminderStateStore(), now: TestDates.now
        )
    }
}
