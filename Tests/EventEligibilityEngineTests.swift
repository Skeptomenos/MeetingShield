import Foundation
import Testing
@testable import MeetingShield

@Suite("Event eligibility")
struct EventEligibilityEngineTests {
    let engine = EventEligibilityEngine()

    @Test("Default settings include accepted timed default busy events")
    func defaultsIncludeExpectedEvent() {
        let event = CalendarEventOccurrence.sample(eventID: "ok", title: "OK", startDate: TestDates.start)
        let result = engine.evaluate(event: event, detectedLinks: [], settings: .defaults)

        #expect(result.isEligible)
        #expect(result.reason == .eligible)
    }

    @Test("Default settings exclude declined cancelled all-day free and focus events")
    func defaultsExcludeRiskyNoise() {
        let samples: [(CalendarEventOccurrence, EligibilityReason)] = [
            (.sample(eventID: "cancelled", title: "Cancelled", startDate: TestDates.start, status: .cancelled), .cancelled),
            (.sample(eventID: "declined", title: "Declined", startDate: TestDates.start, rsvpStatus: .declined), .rsvpExcluded),
            (.sample(eventID: "free", title: "Free", startDate: TestDates.start, busyState: .free), .freeExcluded),
            (.sample(eventID: "focus", title: "Focus", startDate: TestDates.start, eventType: .focusTime), .eventTypeExcluded),
            (.sample(eventID: "all-day", title: "All day", startDate: TestDates.start, isAllDay: true), .allDay)
        ]

        for (event, reason) in samples {
            let result = engine.evaluate(event: event, detectedLinks: [], settings: .defaults)
            #expect(result.isEligible == false)
            #expect(result.reason == reason)
        }
    }

    @Test("All-day events become eligible when the calendar opts in")
    func allDayOptInMakesAllDayEligible() {
        let event = CalendarEventOccurrence.sample(
            eventID: "all-day-opt-in",
            title: "Company offsite",
            startDate: TestDates.start,
            endDate: TestDates.start.addingTimeInterval(24 * 60 * 60),
            isAllDay: true
        )
        var settings = AppSettingsSnapshot.defaults
        var calendarSettings = CalendarSettings.defaults(calendarID: "primary")
        calendarSettings.includeAllDayEvents = true
        settings.calendarSettings["primary"] = calendarSettings

        let result = engine.evaluate(event: event, detectedLinks: [], settings: settings)

        #expect(result.isEligible)
    }

    @Test("Zero-duration events are rejected as invalid time")
    func zeroDurationRejected() {
        let event = CalendarEventOccurrence.sample(
            eventID: "zero",
            title: "Zero",
            startDate: TestDates.start,
            endDate: TestDates.start
        )

        let result = engine.evaluate(event: event, detectedLinks: [], settings: .defaults)

        #expect(result.isEligible == false)
        #expect(result.reason == .invalidTime)
    }

    @Test("Calendar override can include free events")
    func calendarOverrideIncludesFree() {
        let event = CalendarEventOccurrence.sample(eventID: "free", title: "Free", startDate: TestDates.start, busyState: .free)
        var settings = AppSettingsSnapshot.defaults
        var calendarSettings = CalendarSettings.defaults(calendarID: "primary")
        calendarSettings.includedBusyStates = [.busy, .free]
        settings.calendarSettings["primary"] = calendarSettings

        let result = engine.evaluate(event: event, detectedLinks: [], settings: settings)

        #expect(result.isEligible)
    }

    @Test("Dismissed occurrence is ineligible until material fingerprint changes")
    func dismissedOccurrenceUsesFingerprint() {
        let event = CalendarEventOccurrence.sample(eventID: "dismiss", title: "Dismiss", startDate: TestDates.start)
        let store = ReminderStateStore()
        let fingerprint = event.materialFingerprint(detectedLinks: [])
        store.dismiss(event.occurrenceKey, fingerprint: fingerprint)

        let dismissed = engine.evaluate(event: event, detectedLinks: [], settings: .defaults, reminderState: store)
        var changed = event
        changed.title = "Dismiss updated"
        let reset = engine.evaluate(event: changed, detectedLinks: [], settings: .defaults, reminderState: store)

        #expect(dismissed.reason == .dismissed)
        #expect(reset.isEligible)
    }
}
