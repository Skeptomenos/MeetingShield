import Foundation

struct MenuEventFilter: Sendable {
    static func visibleEvents(
        from events: [CalendarEventOccurrence],
        settings: AppSettingsSnapshot,
        now: Date
    ) -> [CalendarEventOccurrence] {
        events
            .filter { event in
                // Keep in-progress meetings visible for rejoining.
                event.endDate > now
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
