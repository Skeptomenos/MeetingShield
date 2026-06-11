import Foundation
import Testing
@testable import MeetingShield

@Suite("Google Calendar mapping")
struct GoogleCalendarMappingTests {
    @Test("Maps event types RSVP all-day free conference metadata recurrence and cancelled events")
    func mapsGoogleEvents() throws {
        let calendar = UserCalendar(id: "primary", accountID: "acct", accountDisplayName: "Account", displayName: "Work", isPrimary: true, isSelected: true, colorHex: nil)
        let url = try #require(Bundle.module.url(forResource: "google-events", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)

        let (events, eventsPageToken) = try GoogleCalendarMapper().mapEventList(data: data, calendar: calendar)

        #expect(eventsPageToken == nil)
        #expect(events.count == 3)
        #expect(events[0].eventType == .defaultEvent)
        #expect(events[0].rsvpStatus == .accepted)
        #expect(events[0].conferenceLinks.first?.kind == .googleMeet)
        #expect(events[0].recurringEventID == "series-1")
        #expect(events[0].meetingRoom == "BER - R99 - Boardroom")
        #expect(events[1].isAllDay)
        #expect(events[1].busyState == .free)
        #expect(events[1].eventType == .focusTime)
        #expect(events[2].status == .cancelled)
    }

    @Test("Calendar list mapping scopes IDs by Google account")
    func calendarListMappingScopesIDsByAccount() throws {
        let data = Data("""
        {
          "items": [
            {
              "id": "first@example.com",
              "summary": "First Account",
              "primary": true,
              "selected": true,
              "backgroundColor": "#0A84FF"
            },
            {
              "id": "team-calendar@example.com",
              "summary": "Team Calendar",
              "hidden": false
            }
          ]
        }
        """.utf8)

        let (calendars, listPageToken) = try GoogleCalendarMapper().mapCalendarList(data: data)

        #expect(listPageToken == nil)
        #expect(calendars.map(\.id) == [
            "first@example.com::first@example.com",
            "first@example.com::team-calendar@example.com"
        ])
        #expect(Set(calendars.map(\.accountID)) == ["first@example.com"])
        #expect(calendars[0].accountDisplayName == "First Account")
        #expect(calendars[1].sourceCalendarID == "team-calendar@example.com")
    }

    @Test("Calendar selection honors Google's selected flag, fails safe when absent")
    func calendarSelectionHonorsSelectedFlag() throws {
        let data = Data("""
        {
          "items": [
            {
              "id": "shown@example.com",
              "summary": "Shown",
              "primary": true,
              "selected": true
            },
            {
              "id": "unchecked@example.com",
              "summary": "Unchecked in Google UI",
              "selected": false
            },
            {
              "id": "unspecified@example.com",
              "summary": "No selected field"
            },
            {
              "id": "hidden@example.com",
              "summary": "Hidden",
              "selected": true,
              "hidden": true
            }
          ]
        }
        """.utf8)

        let (calendars, _) = try GoogleCalendarMapper().mapCalendarList(data: data)
        let selection = Dictionary(
            calendars.compactMap { calendar in calendar.sourceCalendarID.map { ($0, calendar.isSelected) } },
            uniquingKeysWith: { _, new in new }
        )

        #expect(selection["shown@example.com"] == true)
        #expect(selection["unchecked@example.com"] == false)
        // Absent flag fails safe toward protection (extra alerts beat missed meetings).
        #expect(selection["unspecified@example.com"] == true)
        #expect(selection["hidden@example.com"] == false)
    }
}
