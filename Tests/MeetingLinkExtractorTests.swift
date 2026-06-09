import Foundation
import Testing
@testable import MeetingShield

@Suite("Meeting link extraction")
struct MeetingLinkExtractorTests {
    let extractor = MeetingLinkExtractor()

    @Test("Extracts Google Meet from location")
    func googleMeetLocation() {
        let event = CalendarEventOccurrence.sample(
            eventID: "meet",
            title: "Meet",
            startDate: TestDates.start,
            location: "meet.google.com/abc-defg-hij"
        )

        let links = extractor.extractLinks(from: event)

        #expect(links.count == 1)
        #expect(links[0].kind == .googleMeet)
        #expect(links[0].url.absoluteString == "https://meet.google.com/abc-defg-hij")
    }

    @Test("Extracts Zoom Teams Webex and generic conferencing links")
    func extractsKnownProviders() {
        let event = CalendarEventOccurrence.sample(
            eventID: "providers",
            title: "Providers",
            startDate: TestDates.start,
            description: """
            https://company.zoom.us/j/123
            https://teams.microsoft.com/l/meetup-join/abc
            https://example.webex.com/meet/room
            https://whereby.com/team-room
            """
        )

        let kinds = extractor.extractLinks(from: event).map(\.kind)

        #expect(kinds.contains(.zoom))
        #expect(kinds.contains(.teams))
        #expect(kinds.contains(.webex))
        #expect(kinds.contains(.generic))
    }

    @Test("Ignores malformed and non-conferencing links")
    func ignoresMalformedLinks() {
        let event = CalendarEventOccurrence.sample(
            eventID: "none",
            title: "None",
            startDate: TestDates.start,
            description: "Read https://example.com/docs and malformed https://"
        )

        #expect(extractor.extractLinks(from: event).isEmpty)
    }

    @Test("Conference metadata wins over description order")
    func metadataSortsFirst() {
        let metadata = MeetingLink(
            url: URL(string: "https://meet.google.com/meta-link")!,
            kind: .googleMeet,
            source: .conferenceMetadata
        )
        let event = CalendarEventOccurrence.sample(
            eventID: "metadata",
            title: "Metadata",
            startDate: TestDates.start,
            description: "https://zoom.us/j/123",
            conferenceLinks: [metadata]
        )

        let links = extractor.extractLinks(from: event)

        #expect(links.first?.source == .conferenceMetadata)
        #expect(links.count == 2)
    }
}
