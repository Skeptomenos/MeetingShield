import Foundation
import Testing
@testable import MeetingShield

@Suite("Rule engine")
struct RuleEngineTests {
    @Test("Rules are first match wins")
    func firstMatchWins() {
        let event = CalendarEventOccurrence.sample(eventID: "rule", title: "Planning", startDate: TestDates.start)
        let rules = [
            ReminderRule(name: "Suppress planning", conditions: [.textContains(field: .title, text: "plan")], outcome: .suppress),
            ReminderRule(name: "Alert everything", conditions: [], outcome: .alert)
        ]

        let outcome = RuleEngine().firstMatchingOutcome(for: event, detectedLinks: [], rules: rules)

        #expect(outcome?.shouldAlert == false)
    }

    @Test("Conditions inside one rule are AND only")
    func andOnlyConditions() {
        let event = CalendarEventOccurrence.sample(eventID: "and", title: "Planning", startDate: TestDates.start)
        let rules = [
            ReminderRule(
                name: "Needs link too",
                conditions: [.textContains(field: .title, text: "plan"), .hasMeetingLink(true)],
                outcome: .suppress
            )
        ]

        let noLink = RuleEngine().firstMatchingOutcome(for: event, detectedLinks: [], rules: rules)
        let withLink = RuleEngine().firstMatchingOutcome(
            for: event,
            detectedLinks: [MeetingLink(url: URL(string: "https://meet.google.com/abc")!, kind: .googleMeet, source: .location)],
            rules: rules
        )

        #expect(noLink == nil)
        #expect(withLink?.shouldAlert == false)
    }

    @Test("Time of day handles overnight ranges")
    func overnightTimeRange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 5, day: 22, hour: 23, minute: 30))!
        let event = CalendarEventOccurrence.sample(eventID: "late", title: "Late", startDate: date)
        let engine = RuleEngine(calendar: calendar)

        #expect(engine.matches(.timeOfDay(startMinute: 22 * 60, endMinute: 2 * 60), event: event, detectedLinks: []))
    }
}
