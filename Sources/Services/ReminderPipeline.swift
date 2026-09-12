import Foundation

enum ReminderDecisionReason: String, Equatable, Sendable {
    case cancelled
    case unselectedCalendar = "unselected_calendar"
    case calendarDisabled = "calendar_disabled"
    case invalidTime = "invalid_time"
    case allDay = "all_day"
    case eventTypeExcluded = "event_type_excluded"
    case rsvpExcluded = "rsvp_excluded"
    case freeExcluded = "free_excluded"
    case ruleSuppressed = "rule_suppressed"
    case dismissed
    case ended
    case muted
    case acknowledged
    case scheduled
    case snoozed
    case due
    case groupedDuplicate = "grouped_duplicate"
    case removed
    case unknown

    init(_ reason: EligibilityReason) {
        switch reason {
        case .eligible: self = .unknown
        case .cancelled: self = .cancelled
        case .unselectedCalendar: self = .unselectedCalendar
        case .calendarDisabled: self = .calendarDisabled
        case .invalidTime: self = .invalidTime
        case .allDay: self = .allDay
        case .eventTypeExcluded: self = .eventTypeExcluded
        case .rsvpExcluded: self = .rsvpExcluded
        case .freeExcluded: self = .freeExcluded
        case .ruleSuppressed: self = .ruleSuppressed
        case .dismissed: self = .dismissed
        }
    }

    init(_ reason: ReminderScheduleReason) {
        switch reason {
        case .ended: self = .ended
        case .muted: self = .muted
        case .acknowledged: self = .acknowledged
        case .scheduled: self = .scheduled
        case .snoozed: self = .snoozed
        }
    }
}

struct ReminderPipeline: Sendable {
    struct Decision: Equatable, Sendable {
        var occurrenceID: String
        var accountID: String
        var reason: ReminderDecisionReason
        var targetDate: Date?
    }

    struct Result: Sendable {
        var scheduled: [ScheduledReminder]
        var due: [ScheduledReminder]
        var candidateCount: Int
        var decisions: [Decision]
    }

    var linkExtractor = MeetingLinkExtractor()
    var eligibilityEngine = EventEligibilityEngine()
    var scheduler = ReminderScheduler()

    func compute(
        events: [CalendarEventOccurrence],
        settings: AppSettingsSnapshot,
        stateStore: ReminderStateStore,
        now: Date,
        ignoringAcknowledgements: Bool = false
    ) -> Result {
        var decisions: [Decision] = []
        let candidates = events.compactMap { event -> ReminderCandidate? in
            let links = linkExtractor.extractLinks(from: event)
            let result = eligibilityEngine.evaluate(
                event: event,
                detectedLinks: links,
                settings: settings,
                reminderState: stateStore
            )
            guard result.isEligible else {
                decisions.append(Decision(
                    occurrenceID: event.id,
                    accountID: event.accountID,
                    reason: ReminderDecisionReason(result.reason),
                    targetDate: nil
                ))
                return nil
            }
            return ReminderCandidate(
                event: event,
                detectedLinks: links,
                leadTime: result.leadTime,
                browserSelection: result.browserSelection
            )
        }

        let scheduleResult = scheduler.scheduleResult(
            candidates: candidates, stateStore: stateStore, now: now,
            ignoringAcknowledgements: ignoringAcknowledgements
        )
        let scheduled = scheduleResult.scheduled
        let due = scheduler.dueReminders(from: scheduled, now: now)
        let dueRepresentatives = Set(due.map(\.id))
        let dueMembers = Set(due.flatMap { $0.members.map(\.id) })
        decisions += scheduleResult.evaluations.map { evaluation in
            let occurrenceID = evaluation.candidate.id
            let reason: ReminderDecisionReason
            if dueRepresentatives.contains(occurrenceID) {
                reason = .due
            } else if dueMembers.contains(occurrenceID) {
                reason = .groupedDuplicate
            } else {
                reason = ReminderDecisionReason(evaluation.reason)
            }
            return Decision(
                occurrenceID: occurrenceID,
                accountID: evaluation.candidate.event.accountID,
                reason: reason,
                targetDate: evaluation.reminder?.fireDate
            )
        }
        decisions.sort { $0.occurrenceID < $1.occurrenceID }
        return Result(
            scheduled: scheduled,
            due: due,
            candidateCount: candidates.count,
            decisions: decisions
        )
    }
}

enum ReminderPresentationDecision: Equatable, Sendable {
    case keepCurrent
    case clear
    case presentFullScreen
    case updateFullScreen(playSound: Bool)
    case deliverNotifications

    static func decide(
        due: [ScheduledReminder],
        previous: [ScheduledReminder],
        isPresentationMode: Bool,
        inWakeGrace: Bool,
        alertAlreadyShowing: Bool
    ) -> ReminderPresentationDecision {
        guard !due.isEmpty else {
            return previous.isEmpty && !alertAlreadyShowing ? .keepCurrent : .clear
        }
        if isPresentationMode || inWakeGrace {
            return .deliverNotifications
        }
        if alertAlreadyShowing {
            guard due != previous else { return .keepCurrent }
            let previousIDs = Set(previous.map(\.id))
            return .updateFullScreen(playSound: due.contains { !previousIDs.contains($0.id) })
        }
        return .presentFullScreen
    }
}
