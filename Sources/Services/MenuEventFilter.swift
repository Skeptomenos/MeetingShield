import Foundation

struct MenuEventFilter: Sendable {
    static func nextMeeting(
        from events: [CalendarEventOccurrence],
        settings: AppSettingsSnapshot,
        now: Date,
        calendar: Calendar = .current
    ) -> CalendarEventOccurrence? {
        let linkExtractor = MeetingLinkExtractor()
        let eligibilityEngine = EventEligibilityEngine()
        return eventsInWindow(from: events, settings: settings, now: now, calendar: calendar).first { event in
            event.startDate > now && eligibilityEngine.evaluate(
                event: event,
                detectedLinks: linkExtractor.extractLinks(from: event),
                settings: settings
            ).isEligible
        }
    }

    static func visibleEvents(
        from events: [CalendarEventOccurrence],
        settings: AppSettingsSnapshot,
        now: Date,
        calendar: Calendar = .current
    ) -> [CalendarEventOccurrence] {
        let visible = eventsInWindow(from: events, settings: settings, now: now, calendar: calendar)
        if settings.visibilityWindow.kind == .nextMeetingOnly {
            return Array(visible.lazy.filter { $0.startDate > now }.prefix(1))
        }
        return visible
    }

    private static func eventsInWindow(
        from events: [CalendarEventOccurrence],
        settings: AppSettingsSnapshot,
        now: Date,
        calendar: Calendar
    ) -> [CalendarEventOccurrence] {
        let end = settings.visibilityWindow.endDate(from: now, calendar: calendar)
        return events
            .filter { event in
                event.endDate > now
                    && event.startDate < end
                    && settings.isAccountEnabled(event.accountID)
                    && settings.isCalendarSelected(event.calendarID)
            }
            .sorted { first, second in
                if first.startDate == second.startDate {
                    return first.title.localizedCaseInsensitiveCompare(second.title) == .orderedAscending
                }
                return first.startDate < second.startDate
            }
    }
}
