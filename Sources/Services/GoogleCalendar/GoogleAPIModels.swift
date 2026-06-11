import Foundation

struct GoogleCalendarListResponse: Decodable {
    var items: [GoogleCalendarListItem]
    var nextPageToken: String?
}

struct GoogleCalendarListItem: Decodable {
    var id: String
    var summary: String
    var summaryOverride: String?
    var primary: Bool?
    var selected: Bool?
    var hidden: Bool
    var backgroundColor: String?

    enum CodingKeys: String, CodingKey {
        case id
        case summary
        case summaryOverride
        case primary
        case selected
        case hidden
        case backgroundColor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        summary = try container.decode(String.self, forKey: .summary)
        summaryOverride = try container.decodeIfPresent(String.self, forKey: .summaryOverride)
        primary = try container.decodeIfPresent(Bool.self, forKey: .primary)
        selected = try container.decodeIfPresent(Bool.self, forKey: .selected)
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        backgroundColor = try container.decodeIfPresent(String.self, forKey: .backgroundColor)
    }
}

struct GoogleEventsResponse: Decodable {
    var items: [GoogleEvent]
    var nextPageToken: String?
}

struct GoogleEvent: Decodable {
    var id: String
    var status: String?
    var htmlLink: String?
    var summary: String?
    var description: String?
    var location: String?
    var eventType: String?
    var iCalUID: String?
    var recurringEventID: String?
    var start: GoogleEventDateTime?
    var end: GoogleEventDateTime?
    var originalStartTime: GoogleEventDateTime?
    var organizer: GoogleEventPerson?
    var attendees: [GoogleEventPerson]?
    var conferenceData: GoogleConferenceData?
    var transparency: String?
    var updated: String?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case htmlLink
        case summary
        case description
        case location
        case eventType
        case iCalUID
        // Google's API field is `recurringEventId` (lowercase d).
        case recurringEventID = "recurringEventId"
        case start
        case end
        case originalStartTime
        case organizer
        case attendees
        case conferenceData
        case transparency
        case updated
    }
}

struct GoogleEventDateTime: Decodable {
    var date: String?
    var dateTime: String?
    var timeZone: String?
}

struct GoogleEventPerson: Decodable {
    var email: String?
    var displayName: String?
    var responseStatus: String?
    var selfAttendee: Bool?
    var resource: Bool?

    enum CodingKeys: String, CodingKey {
        case email
        case displayName
        case responseStatus
        case selfAttendee = "self"
        case resource
    }
}

struct GoogleConferenceData: Decodable {
    var entryPoints: [GoogleConferenceEntryPoint]?
}

struct GoogleConferenceEntryPoint: Decodable {
    var entryPointType: String?
    var uri: String?
}
