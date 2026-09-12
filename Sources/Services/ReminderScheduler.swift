import Foundation

enum SnoozeChoice: Equatable, Sendable {
    case seconds(TimeInterval)
    case untilDangerPoint

    var label: String {
        switch self {
        case .seconds(30): "30s"
        case .seconds(60): "1m"
        case .seconds(120): "2m"
        case .seconds(300): "5m"
        case .seconds(let value): "\(Int(value))s"
        case .untilDangerPoint: "Until 10s before"
        }
    }
}

struct ReminderCandidate: Identifiable, Sendable {
    var id: String { event.id }
    var event: CalendarEventOccurrence
    var detectedLinks: [MeetingLink]
    var leadTime: TimeInterval
    var browserSelection: BrowserSelection

    var firstFireDate: Date {
        event.startDate.addingTimeInterval(-leadTime)
    }
}

struct ScheduledReminder: Identifiable, Equatable, Sendable {
    struct Member: Identifiable, Equatable, Sendable {
        var id: String { event.id }
        var event: CalendarEventOccurrence
        var detectedLinks: [MeetingLink]
    }

    var id: String { event.id }
    var event: CalendarEventOccurrence
    var detectedLinks: [MeetingLink]
    var fireDate: Date
    var browserSelection: BrowserSelection
    var isSnoozed: Bool
    var members: [Member]

    init(
        event: CalendarEventOccurrence,
        detectedLinks: [MeetingLink],
        fireDate: Date,
        browserSelection: BrowserSelection,
        isSnoozed: Bool,
        members: [Member] = []
    ) {
        self.event = event
        self.detectedLinks = detectedLinks
        self.fireDate = fireDate
        self.browserSelection = browserSelection
        self.isSnoozed = isSnoozed
        self.members = members.isEmpty ? [Member(event: event, detectedLinks: detectedLinks)] : members
    }
}

enum ReminderScheduleReason: String, Equatable, Sendable {
    case ended
    case muted
    case acknowledged
    case scheduled
    case snoozed
}

struct ReminderScheduleEvaluation: Sendable {
    var candidate: ReminderCandidate
    var reminder: ScheduledReminder?
    var reason: ReminderScheduleReason
}

struct ReminderScheduleResult: Sendable {
    var scheduled: [ScheduledReminder]
    var evaluations: [ReminderScheduleEvaluation]
}

struct ReminderScheduler: Sendable {
    static let dangerPointOffset: TimeInterval = 10

    func schedule(
        candidates: [ReminderCandidate],
        stateStore: ReminderStateStore,
        now: Date,
        ignoringAcknowledgements: Bool = false
    ) -> [ScheduledReminder] {
        scheduleResult(
            candidates: candidates,
            stateStore: stateStore,
            now: now,
            ignoringAcknowledgements: ignoringAcknowledgements
        ).scheduled
    }

    func scheduleResult(
        candidates: [ReminderCandidate],
        stateStore: ReminderStateStore,
        now: Date,
        ignoringAcknowledgements: Bool = false
    ) -> ReminderScheduleResult {
        let evaluations = candidates.map { candidate -> ReminderScheduleEvaluation in
            guard candidate.event.endDate > now else {
                return ReminderScheduleEvaluation(candidate: candidate, reminder: nil, reason: .ended)
            }
            if stateStore.state(for: candidate.event.occurrenceKey)?.mutedUntilEventEnd == true {
                return ReminderScheduleEvaluation(candidate: candidate, reminder: nil, reason: .muted)
            }
            if !ignoringAcknowledgements, stateStore.isAcknowledged(
                candidate.event.occurrenceKey,
                currentFingerprint: candidate.event.materialFingerprint(detectedLinks: candidate.detectedLinks),
                now: now
            ) {
                return ReminderScheduleEvaluation(candidate: candidate, reminder: nil, reason: .acknowledged)
            }
            if let snoozedUntil = stateStore.state(for: candidate.event.occurrenceKey)?.snoozedUntil {
                let returnDate = min(snoozedUntil, dangerPoint(for: candidate.event))
                let reminder = ScheduledReminder(
                    event: candidate.event,
                    detectedLinks: candidate.detectedLinks,
                    fireDate: returnDate,
                    browserSelection: candidate.browserSelection,
                    isSnoozed: returnDate > now
                )
                return ReminderScheduleEvaluation(candidate: candidate, reminder: reminder, reason: .snoozed)
            }
            let reminder = ScheduledReminder(
                event: candidate.event,
                detectedLinks: candidate.detectedLinks,
                fireDate: candidate.firstFireDate,
                browserSelection: candidate.browserSelection,
                isSnoozed: false
            )
            return ReminderScheduleEvaluation(candidate: candidate, reminder: reminder, reason: .scheduled)
        }
        return ReminderScheduleResult(
            scheduled: evaluations.compactMap(\.reminder).sorted(by: precedes),
            evaluations: evaluations
        )
    }

    func dueReminders(from scheduled: [ScheduledReminder], now: Date) -> [ScheduledReminder] {
        groupedReminders(from: scheduled.filter { $0.event.endDate > now })
            .filter { $0.fireDate <= now }
    }

    func nextActionDate(from scheduled: [ScheduledReminder], now: Date) -> Date? {
        scheduled
            .filter { $0.event.endDate > now }
            .flatMap { [$0.fireDate, $0.event.endDate] }
            .filter { $0 > now }
            .min()
    }

    func availableSnoozeChoices(event: CalendarEventOccurrence, now: Date) -> [SnoozeChoice] {
        guard now < dangerPoint(for: event) else { return [] }
        let dangerPoint = dangerPoint(for: event)
        var result: [SnoozeChoice] = [30.0, 60, 120, 300]
            .filter { now.addingTimeInterval($0) <= dangerPoint }
            .map(SnoozeChoice.seconds)
        result.append(.untilDangerPoint)
        return result
    }

    func snoozeReturnDate(for event: CalendarEventOccurrence, now: Date, choice: SnoozeChoice) -> Date? {
        guard now < dangerPoint(for: event) else { return nil }
        let candidate: Date
        switch choice {
        case .seconds(let duration):
            candidate = now.addingTimeInterval(duration)
        case .untilDangerPoint:
            candidate = dangerPoint(for: event)
        }
        let clamped = min(candidate, dangerPoint(for: event))
        return clamped > now ? clamped : nil
    }

    func overlaps(in reminders: [ScheduledReminder]) -> [[ScheduledReminder]] {
        let sorted = reminders.sorted { $0.event.startDate < $1.event.startDate }
        var groups: [[ScheduledReminder]] = []
        for reminder in sorted {
            if var last = groups.popLast() {
                let latestEnd = last.map(\.event.endDate).max() ?? reminder.event.endDate
                if reminder.event.startDate < latestEnd {
                    last.append(reminder)
                    groups.append(last)
                } else {
                    groups.append(last)
                    groups.append([reminder])
                }
            } else {
                groups.append([reminder])
            }
        }
        return groups
    }

    private func dangerPoint(for event: CalendarEventOccurrence) -> Date {
        event.startDate.addingTimeInterval(-Self.dangerPointOffset)
    }

    func groupedReminders(from reminders: [ScheduledReminder]) -> [ScheduledReminder] {
        var groupIndices: [CopyIdentity: Int] = [:]
        var result: [ScheduledReminder] = []
        for reminder in reminders.sorted(by: precedes) {
            if let identity = CopyIdentity(event: reminder.event) {
                if let index = groupIndices[identity] {
                    result[index].members.append(contentsOf: reminder.members)
                    continue
                }
                groupIndices[identity] = result.count
            }
            result.append(reminder)
        }
        for index in result.indices {
            result[index].members.sort { $0.id < $1.id }
        }
        return result
    }

    private func precedes(_ first: ScheduledReminder, _ second: ScheduledReminder) -> Bool {
        first.fireDate == second.fireDate ? first.id < second.id : first.fireDate < second.fireDate
    }

    private struct CopyIdentity: Hashable {
        var providerID: String
        var iCalUID: String
        var originalOccurrenceDate: Date
        var startDate: Date
        var endDate: Date

        init?(event: CalendarEventOccurrence) {
            guard let iCalUID = event.iCalUID,
                  !iCalUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard event.recurringEventID == nil || event.originalStartDate != nil else { return nil }
            providerID = event.providerID
            self.iCalUID = iCalUID
            originalOccurrenceDate = event.originalStartDate ?? event.startDate
            startDate = event.startDate
            endDate = event.endDate
        }
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
