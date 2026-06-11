import Foundation

enum EligibilityReason: String, Codable, Sendable {
    case eligible
    case cancelled
    case unselectedCalendar
    case calendarDisabled
    case invalidTime
    case allDay
    case eventTypeExcluded
    case rsvpExcluded
    case freeExcluded
    case ruleSuppressed
    case dismissed
}

struct EligibilityResult: Equatable, Sendable {
    var isEligible: Bool
    var reason: EligibilityReason
    var leadTime: TimeInterval
    var browserSelection: BrowserSelection
    var ruleOutcome: RuleOutcome?
}

struct EventEligibilityEngine: Sendable {
    var ruleEngine: RuleEngine

    init(ruleEngine: RuleEngine = RuleEngine()) {
        self.ruleEngine = ruleEngine
    }

    func evaluate(
        event: CalendarEventOccurrence,
        detectedLinks: [MeetingLink],
        settings: AppSettingsSnapshot,
        reminderState: ReminderStateStore? = nil
    ) -> EligibilityResult {
        let calendarSettings = settings.calendarSettings(for: event.calendarID)
        let baseLeadTime = calendarSettings.leadTimeOverride ?? settings.defaultLeadTime
        let baseBrowser = calendarSettings.browserSelection ?? settings.defaultBrowserSelection

        func rejected(_ reason: EligibilityReason) -> EligibilityResult {
            EligibilityResult(
                isEligible: false,
                reason: reason,
                leadTime: baseLeadTime,
                browserSelection: baseBrowser,
                ruleOutcome: nil
            )
        }

        guard !event.isCancelled else { return rejected(.cancelled) }
        guard settings.isAccountEnabled(event.accountID) else { return rejected(.unselectedCalendar) }
        guard settings.isCalendarSelected(event.calendarID) else { return rejected(.unselectedCalendar) }
        guard calendarSettings.isAlertEnabled else { return rejected(.calendarDisabled) }
        guard event.endDate > event.startDate else { return rejected(.invalidTime) }
        guard !event.isAllDay || calendarSettings.includeAllDayEvents else { return rejected(.allDay) }
        guard calendarSettings.includedEventTypes.contains(event.eventType) else { return rejected(.eventTypeExcluded) }
        guard calendarSettings.includedRSVPStatuses.contains(event.rsvpStatus) else { return rejected(.rsvpExcluded) }
        guard calendarSettings.includedBusyStates.contains(event.busyState) else { return rejected(.freeExcluded) }

        let fingerprint = event.materialFingerprint(detectedLinks: detectedLinks)
        if reminderState?.isDismissed(event.occurrenceKey, currentFingerprint: fingerprint) == true {
            return rejected(.dismissed)
        }

        let rules = calendarSettings.rules + settings.rules
        let outcome = ruleEngine.firstMatchingOutcome(for: event, detectedLinks: detectedLinks, rules: rules)
        if outcome?.shouldAlert == false {
            return EligibilityResult(
                isEligible: false,
                reason: .ruleSuppressed,
                leadTime: outcome?.leadTimeOverride ?? baseLeadTime,
                browserSelection: outcome?.browserOverride ?? baseBrowser,
                ruleOutcome: outcome
            )
        }

        return EligibilityResult(
            isEligible: true,
            reason: .eligible,
            leadTime: outcome?.leadTimeOverride ?? baseLeadTime,
            browserSelection: outcome?.browserOverride ?? baseBrowser,
            ruleOutcome: outcome
        )
    }
}
