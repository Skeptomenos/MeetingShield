import Foundation

enum RuleTextField: String, Codable, Sendable {
    case title
    case location
    case description
}

enum RuleCondition: Codable, Equatable, Sendable {
    case calendar(id: String)
    case eventType(EventType)
    case rsvp(RSVPStatus)
    case busy(BusyState)
    case weekday(Int)
    case timeOfDay(startMinute: Int, endMinute: Int)
    case textContains(field: RuleTextField, text: String)
    case hasMeetingLink(Bool)

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case eventType
        case rsvp
        case busy
        case weekday
        case startMinute
        case endMinute
        case field
        case text
        case hasMeetingLink
    }

    private enum Kind: String, Codable {
        case calendar
        case eventType
        case rsvp
        case busy
        case weekday
        case timeOfDay
        case textContains
        case hasMeetingLink
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(Kind.self, forKey: .type)
        switch type {
        case .calendar:
            self = .calendar(id: try container.decode(String.self, forKey: .id))
        case .eventType:
            self = .eventType(try container.decode(EventType.self, forKey: .eventType))
        case .rsvp:
            self = .rsvp(try container.decode(RSVPStatus.self, forKey: .rsvp))
        case .busy:
            self = .busy(try container.decode(BusyState.self, forKey: .busy))
        case .weekday:
            self = .weekday(try container.decode(Int.self, forKey: .weekday))
        case .timeOfDay:
            self = .timeOfDay(
                startMinute: try container.decode(Int.self, forKey: .startMinute),
                endMinute: try container.decode(Int.self, forKey: .endMinute)
            )
        case .textContains:
            self = .textContains(
                field: try container.decode(RuleTextField.self, forKey: .field),
                text: try container.decode(String.self, forKey: .text)
            )
        case .hasMeetingLink:
            self = .hasMeetingLink(try container.decode(Bool.self, forKey: .hasMeetingLink))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .calendar(let id):
            try container.encode(Kind.calendar, forKey: .type)
            try container.encode(id, forKey: .id)
        case .eventType(let eventType):
            try container.encode(Kind.eventType, forKey: .type)
            try container.encode(eventType, forKey: .eventType)
        case .rsvp(let rsvp):
            try container.encode(Kind.rsvp, forKey: .type)
            try container.encode(rsvp, forKey: .rsvp)
        case .busy(let busy):
            try container.encode(Kind.busy, forKey: .type)
            try container.encode(busy, forKey: .busy)
        case .weekday(let weekday):
            try container.encode(Kind.weekday, forKey: .type)
            try container.encode(weekday, forKey: .weekday)
        case .timeOfDay(let startMinute, let endMinute):
            try container.encode(Kind.timeOfDay, forKey: .type)
            try container.encode(startMinute, forKey: .startMinute)
            try container.encode(endMinute, forKey: .endMinute)
        case .textContains(let field, let text):
            try container.encode(Kind.textContains, forKey: .type)
            try container.encode(field, forKey: .field)
            try container.encode(text, forKey: .text)
        case .hasMeetingLink(let hasMeetingLink):
            try container.encode(Kind.hasMeetingLink, forKey: .type)
            try container.encode(hasMeetingLink, forKey: .hasMeetingLink)
        }
    }
}

struct RuleOutcome: Codable, Equatable, Sendable {
    var shouldAlert: Bool
    var leadTimeOverride: TimeInterval?
    var browserOverride: BrowserSelection?

    static let alert = RuleOutcome(shouldAlert: true, leadTimeOverride: nil, browserOverride: nil)
    static let suppress = RuleOutcome(shouldAlert: false, leadTimeOverride: nil, browserOverride: nil)
}

struct ReminderRule: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var conditions: [RuleCondition]
    var outcome: RuleOutcome

    init(id: UUID = UUID(), name: String, isEnabled: Bool = true, conditions: [RuleCondition], outcome: RuleOutcome) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.conditions = conditions
        self.outcome = outcome
    }
}

struct RuleEngine: Sendable {
    private var calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func firstMatchingOutcome(
        for event: CalendarEventOccurrence,
        detectedLinks: [MeetingLink],
        rules: [ReminderRule]
    ) -> RuleOutcome? {
        for rule in rules where rule.isEnabled {
            if rule.conditions.allSatisfy({ matches($0, event: event, detectedLinks: detectedLinks) }) {
                return rule.outcome
            }
        }
        return nil
    }

    func matches(_ condition: RuleCondition, event: CalendarEventOccurrence, detectedLinks: [MeetingLink]) -> Bool {
        switch condition {
        case .calendar(let id):
            return event.calendarID == id
        case .eventType(let eventType):
            return event.eventType == eventType
        case .rsvp(let rsvp):
            return event.rsvpStatus == rsvp
        case .busy(let busy):
            return event.busyState == busy
        case .weekday(let weekday):
            return calendar.component(.weekday, from: event.startDate) == weekday
        case .timeOfDay(let startMinute, let endMinute):
            let components = calendar.dateComponents([.hour, .minute], from: event.startDate)
            let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            if startMinute <= endMinute {
                return minute >= startMinute && minute <= endMinute
            } else {
                return minute >= startMinute || minute <= endMinute
            }
        case .textContains(let field, let text):
            guard !text.isEmpty else { return true }
            let haystack: String?
            switch field {
            case .title: haystack = event.title
            case .location: haystack = event.location
            case .description: haystack = event.eventDescription
            }
            return haystack?.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        case .hasMeetingLink(let expected):
            return !detectedLinks.isEmpty == expected
        }
    }
}
