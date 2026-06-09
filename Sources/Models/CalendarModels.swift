import Foundation

enum EventType: String, Codable, CaseIterable, Identifiable, Sendable {
    case defaultEvent = "default"
    case focusTime
    case outOfOffice
    case workingLocation
    case birthday
    case fromGmail
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .defaultEvent: "Default"
        case .focusTime: "Focus time"
        case .outOfOffice: "Out of office"
        case .workingLocation: "Working location"
        case .birthday: "Birthday"
        case .fromGmail: "From Gmail"
        case .unknown: "Unknown"
        }
    }

    static func googleValue(_ value: String?) -> EventType {
        guard let value else { return .defaultEvent }
        return EventType(rawValue: value) ?? .unknown
    }
}

enum EventStatus: String, Codable, Sendable {
    case confirmed
    case tentative
    case cancelled
    case unknown
}

enum RSVPStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case accepted
    case tentative
    case needsAction
    case declined
    case unknown

    var id: String { rawValue }
}

enum BusyState: String, Codable, CaseIterable, Identifiable, Sendable {
    case busy
    case free
    case unknown

    var id: String { rawValue }
}

enum MeetingLinkKind: String, Codable, CaseIterable, Sendable {
    case googleMeet
    case zoom
    case teams
    case webex
    case generic
}

enum MeetingLinkSource: String, Codable, Sendable {
    case conferenceMetadata
    case location
    case description
}

struct MeetingLink: Codable, Hashable, Identifiable, Sendable {
    var id: String { normalizedURLString }
    var url: URL
    var kind: MeetingLinkKind
    var source: MeetingLinkSource

    var normalizedURLString: String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let scheme = components.scheme?.lowercased()
        let host = components.host?.lowercased()
        components.scheme = scheme
        components.host = host
        return components.url?.absoluteString ?? url.absoluteString
    }
}

struct CalendarAccount: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var email: String
    var displayName: String
}

struct ConnectedCalendarAccount: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var displayName: String
}

struct UserCalendar: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var sourceCalendarID: String?
    var accountID: String
    var accountDisplayName: String?
    var displayName: String
    var isPrimary: Bool
    var isSelected: Bool
    var colorHex: String?

    var apiCalendarID: String {
        sourceCalendarID ?? id
    }
}

struct OccurrenceKey: Codable, Hashable, CustomStringConvertible, Sendable {
    var providerID: String
    var eventID: String
    var originalStartDate: Date?

    var description: String {
        if let originalStartDate {
            "\(providerID):\(eventID):\(ISO8601DateFormatter.stableString(from: originalStartDate))"
        } else {
            "\(providerID):\(eventID)"
        }
    }
}

struct MaterialChangeFingerprint: Codable, Hashable, Sendable {
    var value: String
}

struct CalendarEventOccurrence: Codable, Hashable, Identifiable, Sendable {
    var providerID: String
    var eventID: String
    var calendarID: String
    var calendarDisplayName: String
    var accountID: String
    var accountDisplayName: String
    var iCalUID: String?
    var recurringEventID: String?
    var originalStartDate: Date?
    var title: String
    var startDate: Date
    var endDate: Date
    var timeZoneIdentifier: String?
    var eventType: EventType
    var status: EventStatus
    var rsvpStatus: RSVPStatus
    var busyState: BusyState
    var isAllDay: Bool
    var organizerDomain: String?
    var attendeeDomains: [String]
    var location: String?
    var meetingRoom: String?
    var eventDescription: String?
    var conferenceLinks: [MeetingLink]
    var htmlLink: URL?
    var updatedAt: Date?
    var isFromCache: Bool

    var id: String { occurrenceKey.description }

    var occurrenceKey: OccurrenceKey {
        OccurrenceKey(providerID: providerID, eventID: eventID, originalStartDate: originalStartDate)
    }

    var isCancelled: Bool {
        status == .cancelled
    }

    var isTimed: Bool {
        !isAllDay && endDate > startDate
    }

    func materialFingerprint(detectedLinks: [MeetingLink]) -> MaterialChangeFingerprint {
        let linkPart = detectedLinks.map(\.normalizedURLString).sorted().joined(separator: "|")
        let pieces = [
            ISO8601DateFormatter.stableString(from: startDate),
            ISO8601DateFormatter.stableString(from: endDate),
            linkPart,
            calendarID,
            title,
            meetingRoom ?? "",
            eventType.rawValue,
            rsvpStatus.rawValue
        ]
        let joined = pieces.joined(separator: "\u{1f}")
        let data = Data(joined.utf8)
        return MaterialChangeFingerprint(value: data.base64EncodedString())
    }

    func privacyPreservingCacheCopy(detectedLinks: [MeetingLink]) -> CalendarEventOccurrence {
        var copy = self
        copy.eventDescription = nil
        copy.conferenceLinks = detectedLinks
        copy.location = location.flatMap { MeetingLinkExtractor.textContainsURL($0) ? $0 : nil }
        copy.isFromCache = true
        return copy
    }
}

enum CalendarProviderAuthState: Equatable, Sendable {
    case disconnected
    case needsConfiguration
    case authenticating
    case connected(accountEmail: String)
    case expired(reason: String)
}

struct CalendarFetchWindow: Sendable {
    var start: Date
    var end: Date
}

extension ISO8601DateFormatter {
    static func stableString(from date: Date) -> String {
        stableFormatter().string(from: date)
    }

    static func stableDate(from value: String) -> Date? {
        stableFormatter().date(from: value)
    }

    private static func stableFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}

extension CalendarEventOccurrence {
    static func sample(
        eventID: String,
        title: String,
        startDate: Date,
        endDate: Date? = nil,
        calendarID: String = "primary",
        location: String? = nil,
        meetingRoom: String? = nil,
        description: String? = nil,
        conferenceLinks: [MeetingLink] = [],
        eventType: EventType = .defaultEvent,
        status: EventStatus = .confirmed,
        rsvpStatus: RSVPStatus = .accepted,
        busyState: BusyState = .busy,
        isAllDay: Bool = false,
        htmlLink: URL? = URL(string: "https://calendar.google.com/calendar/u/0/r")
    ) -> CalendarEventOccurrence {
        CalendarEventOccurrence(
            providerID: "mock",
            eventID: eventID,
            calendarID: calendarID,
            calendarDisplayName: "Work",
            accountID: "mock-account",
            accountDisplayName: "Mock Account",
            iCalUID: "\(eventID)@mock",
            recurringEventID: nil,
            originalStartDate: nil,
            title: title,
            startDate: startDate,
            endDate: endDate ?? startDate.addingTimeInterval(30 * 60),
            timeZoneIdentifier: TimeZone.current.identifier,
            eventType: eventType,
            status: status,
            rsvpStatus: rsvpStatus,
            busyState: busyState,
            isAllDay: isAllDay,
            organizerDomain: "example.com",
            attendeeDomains: ["example.com"],
            location: location,
            meetingRoom: meetingRoom,
            eventDescription: description,
            conferenceLinks: conferenceLinks,
            htmlLink: htmlLink,
            updatedAt: Date(),
            isFromCache: false
        )
    }
}
