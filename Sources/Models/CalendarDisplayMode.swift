import Foundation

/// A presentation of existing selection and alert flags, not a new stored preference.
enum CalendarDisplayMode: String, CaseIterable, Identifiable {
    case alertsAndAgenda = "Alerts & agenda"
    case agendaOnly = "Agenda only"
    case off = "Off"
    var id: String { rawValue }
}

extension AppSettingsSnapshot {
    func displayMode(for calendar: UserCalendar) -> CalendarDisplayMode {
        guard isCalendarSelected(calendar) else { return .off }
        return calendarSettings(for: calendar.id).isAlertEnabled ? .alertsAndAgenda : .agendaOnly
    }

    mutating func setDisplayMode(_ mode: CalendarDisplayMode, for calendar: UserCalendar, availableCalendars: [UserCalendar]) {
        guard isAccountEnabled(calendar.accountID) else { return }
        setCalendarSelected(mode != .off, calendarID: calendar.id, availableCalendars: availableCalendars)
        // Switching off retains the last alert choice and all per-calendar overrides.
        if mode != .off {
            var settings = calendarSettings(for: calendar.id)
            settings.isAlertEnabled = mode == .alertsAndAgenda
            calendarSettings[calendar.id] = settings
        }
    }
}
