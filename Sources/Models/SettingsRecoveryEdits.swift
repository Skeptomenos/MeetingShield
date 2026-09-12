struct SettingsRecoveryEdits {
    private typealias Edit = (inout AppSettingsSnapshot) -> Void
    private typealias CalendarEdit = (inout CalendarSettings) -> Void
    private var fields: [String: Edit] = [:]
    private var mapEntries: [String: [String: Edit]] = [:]
    private var disabledAccounts: [String: Bool] = [:]
    private var calendarFields: [String: [String: CalendarEdit]] = [:]
    private var removedCalendars: Set<String> = []
    private var resetCalendars: Set<String> = []

    mutating func record(from previous: AppSettingsSnapshot, to current: AppSettingsSnapshot) {
        record("browser", \.defaultBrowserSelection, previous, current)
        record("leadTime", \.defaultLeadTime, previous, current)
        record("snooze", \.globalSnoozeDuration, previous, current)
        record("visibilityKind", \.visibilityWindow.kind, previous, current)
        record("visibilityHours", \.visibilityWindow.hours, previous, current)
        record("visibilityDays", \.visibilityWindow.days, previous, current)
        record("titles", \.showEventTitlesInMenuBar, previous, current)
        record("sound", \.soundEnabled, previous, current)
        record("repeatSound", \.urgentRepeatSoundEnabled, previous, current)
        record("presentation", \.presentationModeDefault, previous, current)
        record("login", \.launchAtLoginEnabled, previous, current)
        record("wakeGrace", \.wakeGraceEnabled, previous, current)
        record("rules", \.rules, previous, current)
        record("oauthClient", \.googleOAuthClientID, previous, current)
        if previous.selectedCalendarIDs != current.selectedCalendarIDs ||
            previous.hasExplicitCalendarSelection != current.hasExplicitCalendarSelection {
            fields["selection"] = { $0.restoreCalendarSelection(from: current) }
        }
        if previous.providerDefaultCalendarIDs != current.providerDefaultCalendarIDs,
           let defaults = current.providerDefaultCalendarIDs {
            fields["providerDefaults"] = { $0.recordProviderDefaultCalendarIDs(defaults) }
        }
        recordMap("nicknames", \.accountNicknames, previous, current)
        recordMap("aliases", \.calendarAliases, previous, current)
        recordCalendars(previous.calendarSettings, current.calendarSettings)
        for id in previous.disabledGoogleAccountIDs.union(current.disabledGoogleAccountIDs) {
            let isDisabled = current.disabledGoogleAccountIDs.contains(id)
            if previous.disabledGoogleAccountIDs.contains(id) != isDisabled {
                disabledAccounts[id] = isDisabled
            }
        }
    }

    func apply(to snapshot: inout AppSettingsSnapshot) {
        for edit in fields.values { edit(&snapshot) }
        for entries in mapEntries.values {
            for edit in entries.values { edit(&snapshot) }
        }
        for (id, isDisabled) in disabledAccounts {
            if isDisabled {
                snapshot.disabledGoogleAccountIDs.insert(id)
            } else {
                snapshot.disabledGoogleAccountIDs.remove(id)
            }
        }
        for id in removedCalendars {
            snapshot.calendarSettings.removeValue(forKey: id)
        }
        for (id, fields) in calendarFields {
            var calendar = resetCalendars.contains(id)
                ? CalendarSettings.defaults(calendarID: id)
                : snapshot.calendarSettings(for: id)
            for edit in fields.values { edit(&calendar) }
            snapshot.calendarSettings[id] = calendar
        }
    }

    private mutating func record<Value: Equatable>(
        _ name: String,
        _ path: WritableKeyPath<AppSettingsSnapshot, Value>,
        _ previous: AppSettingsSnapshot,
        _ current: AppSettingsSnapshot
    ) {
        guard previous[keyPath: path] != current[keyPath: path] else { return }
        let value = current[keyPath: path]
        fields[name] = { $0[keyPath: path] = value }
    }

    private mutating func recordMap<Value: Equatable>(
        _ name: String,
        _ path: WritableKeyPath<AppSettingsSnapshot, [String: Value]>,
        _ previous: AppSettingsSnapshot,
        _ current: AppSettingsSnapshot
    ) {
        let old = previous[keyPath: path]
        let new = current[keyPath: path]
        for key in Set(old.keys).union(new.keys) where old[key] != new[key] {
            let value = new[key]
            mapEntries[name, default: [:]][key] = { $0[keyPath: path][key] = value }
        }
    }

    private mutating func recordCalendars(_ previous: [String: CalendarSettings], _ current: [String: CalendarSettings]) {
        for id in Set(previous.keys).union(current.keys) {
            guard let calendar = current[id] else {
                removedCalendars.insert(id)
                resetCalendars.insert(id)
                calendarFields.removeValue(forKey: id)
                continue
            }
            let old = previous[id] ?? .defaults(calendarID: id)
            removedCalendars.remove(id)
            if calendarFields[id] == nil { calendarFields[id] = [:] }
            recordCalendar(id, "identity", \.calendarID, old, calendar)
            recordCalendar(id, "alerts", \.isAlertEnabled, old, calendar)
            recordCalendar(id, "browser", \.browserSelection, old, calendar)
            recordCalendar(id, "leadTime", \.leadTimeOverride, old, calendar)
            recordCalendar(id, "eventTypes", \.includedEventTypes, old, calendar)
            recordCalendar(id, "rsvp", \.includedRSVPStatuses, old, calendar)
            recordCalendar(id, "busy", \.includedBusyStates, old, calendar)
            recordCalendar(id, "allDay", \.includeAllDayEvents, old, calendar)
            recordCalendar(id, "rules", \.rules, old, calendar)
        }
    }

    private mutating func recordCalendar<Value: Equatable>(
        _ id: String,
        _ name: String,
        _ path: WritableKeyPath<CalendarSettings, Value>,
        _ previous: CalendarSettings,
        _ current: CalendarSettings
    ) {
        guard previous[keyPath: path] != current[keyPath: path] else { return }
        let value = current[keyPath: path]
        calendarFields[id, default: [:]][name] = { $0[keyPath: path] = value }
    }
}
