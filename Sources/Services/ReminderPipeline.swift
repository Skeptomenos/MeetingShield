import Foundation

/// Pure events → reminders pipeline: link extraction, eligibility, scheduling,
/// and due-set computation. No UI knowledge.
struct ReminderPipeline: Sendable {
    struct Result: Sendable {
        var scheduled: [ScheduledReminder]
        var due: [ScheduledReminder]
        var candidateCount: Int
    }

    var linkExtractor = MeetingLinkExtractor()
    var eligibilityEngine = EventEligibilityEngine()
    var scheduler = ReminderScheduler()

    func compute(
        events: [CalendarEventOccurrence],
        settings: AppSettingsSnapshot,
        stateStore: ReminderStateStore,
        now: Date
    ) -> Result {
        let candidates = events.compactMap { event -> ReminderCandidate? in
            let links = linkExtractor.extractLinks(from: event)
            let result = eligibilityEngine.evaluate(
                event: event,
                detectedLinks: links,
                settings: settings,
                reminderState: stateStore
            )
            guard result.isEligible else { return nil }
            return ReminderCandidate(
                event: event,
                detectedLinks: links,
                leadTime: result.leadTime,
                browserSelection: result.browserSelection
            )
        }

        let scheduled = scheduler.schedule(candidates: candidates, stateStore: stateStore, now: now)
        let due = scheduler.dueReminders(from: scheduled, now: now)
        return Result(scheduled: scheduled, due: due, candidateCount: candidates.count)
    }
}

/// Pure decision for how a due-reminder set should be surfaced.
/// The controller executes the decision against its window/notification
/// singletons; the logic itself stays testable.
enum ReminderPresentationDecision: Equatable, Sendable {
    case keepCurrent
    case clear
    case presentFullScreen
    case deliverNotifications

    static func decide(
        due: [ScheduledReminder],
        previousIDs: [String],
        isPresentationMode: Bool,
        inWakeGrace: Bool,
        alertAlreadyShowing: Bool
    ) -> ReminderPresentationDecision {
        guard !due.isEmpty else {
            return previousIDs.isEmpty && !alertAlreadyShowing ? .keepCurrent : .clear
        }
        if isPresentationMode || inWakeGrace {
            return .deliverNotifications
        }
        let dueIDs = due.map(\.id)
        if dueIDs == previousIDs && alertAlreadyShowing {
            return .keepCurrent
        }
        return .presentFullScreen
    }
}
