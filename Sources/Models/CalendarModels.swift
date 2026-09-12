import CryptoKit
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
    var accessRole: String? = nil

    var eventAccessWarning: String? {
        switch accessRole {
        case nil, "reader", "writer", "writerWithoutPrivateAccess", "owner":
            nil
        case "freeBusyReader":
            "Limited access: some meeting details are unavailable."
        case "none":
            "Calendar access is unavailable. Ask its owner for access."
        default:
            "Calendar access could not be verified."
        }
    }

    var apiCalendarID: String {
        sourceCalendarID ?? id
    }
}

struct OccurrenceKey: Codable, Hashable, CustomStringConvertible, Sendable {
    var providerID: String
    var eventID: String
    var originalStartDate: Date?
    var accountID: String? = nil
    var calendarID: String? = nil

    var isScoped: Bool { accountID != nil && calendarID != nil }
    var isLegacy: Bool { accountID == nil && calendarID == nil }

    var legacyKey: OccurrenceKey {
        OccurrenceKey(providerID: providerID, eventID: eventID, originalStartDate: originalStartDate)
    }

    var description: String {
        if isLegacy {
            if let originalStartDate {
                return "\(providerID):\(eventID):\(ISO8601DateFormatter.stableString(from: originalStartDate))"
            }
            return "\(providerID):\(eventID)"
        }
        let date = originalStartDate.map { date in
            let interval = date.timeIntervalSinceReferenceDate
            return interval == 0 ? "0" : String(interval)
        }
        let components: [String?] = [providerID, accountID, calendarID, eventID, date]
        let encoded = components.map { component in
            guard let component else { return "-" }
            let normalized = component.precomposedStringWithCanonicalMapping
            return "\(normalized.utf8.count):\(normalized)"
        }.joined()
        let digest = SHA256.hash(data: Data(encoded.utf8))
        return "occ-v2:" + digest.map { String(format: "%02x", $0) }.joined()
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
        OccurrenceKey(
            providerID: providerID,
            eventID: eventID,
            originalStartDate: originalStartDate,
            accountID: accountID,
            calendarID: calendarID
        )
    }

    var isCancelled: Bool {
        status == .cancelled
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
        let digest = SHA256.hash(data: Data(joined.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return MaterialChangeFingerprint(value: hex)
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

struct CalendarFetchWindow: Codable, Equatable, Sendable {
    var start: Date
    var end: Date

    static let lookback: TimeInterval = 2 * 60 * 60
    static let minimumProtectionHorizon: TimeInterval = 24 * 60 * 60

    static func protective(
        now: Date,
        visibilityWindow: MenuVisibilityWindow,
        calendar: Calendar = .current
    ) -> CalendarFetchWindow {
        let visibilityEnd = visibilityWindow.endDate(from: now, calendar: calendar)
        let protectionEnd = now.addingTimeInterval(minimumProtectionHorizon)
        return CalendarFetchWindow(
            start: now.addingTimeInterval(-lookback),
            end: max(visibilityEnd, protectionEnd)
        )
    }
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
