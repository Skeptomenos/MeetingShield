import Foundation

struct MenuEventFilter: Sendable {
    static func visibleEvents(
        from events: [CalendarEventOccurrence],
        settings: AppSettingsSnapshot,
        now: Date
    ) -> [CalendarEventOccurrence] {
        events
            .filter { event in
                event.startDate >= now
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
