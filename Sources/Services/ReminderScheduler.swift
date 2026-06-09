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

struct ScheduledReminder: Identifiable, Sendable {
    var id: String { event.id }
    var event: CalendarEventOccurrence
    var detectedLinks: [MeetingLink]
    var fireDate: Date
    var browserSelection: BrowserSelection
    var isSnoozed: Bool
}

struct ReminderScheduler: Sendable {
    static let dangerPointOffset: TimeInterval = 10

    func schedule(
        candidates: [ReminderCandidate],
        stateStore: ReminderStateStore,
        now: Date
    ) -> [ScheduledReminder] {
        candidates.compactMap { candidate in
            guard candidate.event.endDate > now else { return nil }
            if stateStore.state(for: candidate.event.occurrenceKey)?.mutedUntilEventEnd == true {
                return nil
            }
            if let snoozedUntil = stateStore.state(for: candidate.event.occurrenceKey)?.snoozedUntil,
               snoozedUntil > now {
                return ScheduledReminder(
                    event: candidate.event,
                    detectedLinks: candidate.detectedLinks,
                    fireDate: snoozedUntil,
                    browserSelection: candidate.browserSelection,
                    isSnoozed: true
                )
            }
            return ScheduledReminder(
                event: candidate.event,
                detectedLinks: candidate.detectedLinks,
                fireDate: candidate.firstFireDate,
                browserSelection: candidate.browserSelection,
                isSnoozed: false
            )
        }
        .sorted { $0.fireDate < $1.fireDate }
    }

    func dueReminders(from scheduled: [ScheduledReminder], now: Date) -> [ScheduledReminder] {
        let due = scheduled.filter { $0.fireDate <= now && $0.event.endDate > now }
        return dedupe(due)
    }

    func nextActionDate(from scheduled: [ScheduledReminder], now: Date) -> Date? {
        scheduled
            .filter { $0.fireDate > now && $0.event.endDate > now }
            .map(\.fireDate)
            .min()
    }

    func availableSnoozeChoices(event: CalendarEventOccurrence, now: Date, globalDuration: TimeInterval) -> [SnoozeChoice] {
        guard now < dangerPoint(for: event) else { return [] }
        let dangerPoint = dangerPoint(for: event)
        let fixed: [SnoozeChoice] = [.seconds(30), .seconds(60), .seconds(globalDuration), .seconds(300)]
        var result: [SnoozeChoice] = []
        for choice in fixed {
            guard case .seconds(let duration) = choice else { continue }
            guard now.addingTimeInterval(duration) <= dangerPoint else { continue }
            if !result.contains(choice) {
                result.append(choice)
            }
        }
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

    private func dedupe(_ reminders: [ScheduledReminder]) -> [ScheduledReminder] {
        var seenKeys: Set<String> = []
        var result: [ScheduledReminder] = []
        for reminder in reminders {
            let linkKey = reminder.detectedLinks.first?.normalizedURLString
            let titleKey = "\(reminder.event.title)|\(reminder.event.startDate.timeIntervalSince1970)|\(reminder.event.endDate.timeIntervalSince1970)"
            let keys = [reminder.event.iCalUID, linkKey, titleKey].compactMap { $0 }
            if keys.contains(where: seenKeys.contains) {
                continue
            }
            keys.forEach { seenKeys.insert($0) }
            result.append(reminder)
        }
        return result
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
