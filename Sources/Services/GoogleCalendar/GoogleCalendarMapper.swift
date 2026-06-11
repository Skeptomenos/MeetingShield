import Foundation

struct GoogleCalendarMapper: Sendable {
    func mapCalendarList(
        data: Data,
        accountID suppliedAccountID: String? = nil,
        accountDisplayName suppliedAccountDisplayName: String? = nil
    ) throws -> (calendars: [UserCalendar], nextPageToken: String?) {
        let response = try JSONDecoder().decode(GoogleCalendarListResponse.self, from: data)
        let identity = accountIdentity(from: response.items)
        let accountID = suppliedAccountID ?? identity?.id ?? "google"
        let accountDisplayName = suppliedAccountDisplayName ?? identity?.displayName ?? "Google Calendar"
        let calendars = response.items.map { item in
            let sourceID = item.id
            return UserCalendar(
                id: scopedCalendarID(accountID: accountID, calendarID: sourceID),
                sourceCalendarID: sourceID,
                accountID: accountID,
                accountDisplayName: accountDisplayName,
                displayName: item.summaryOverride ?? item.summary,
                isPrimary: item.primary ?? false,
                // Google's `selected` mirrors the calendar checkbox in the
                // Google Calendar UI. Absent flag fails safe toward protection.
                isSelected: (item.selected ?? true) && !item.hidden,
                colorHex: item.backgroundColor
            )
        }
        return (calendars, response.nextPageToken)
    }

    func accountIdentity(from calendars: [UserCalendar]) -> (id: String, displayName: String)? {
        guard let primary = calendars.first(where: \.isPrimary) ?? calendars.first else { return nil }
        return (primary.accountID, primary.accountDisplayName ?? primary.displayName)
    }

    private func accountIdentity(from items: [GoogleCalendarListItem]) -> (id: String, displayName: String)? {
        guard let primary = items.first(where: { $0.primary == true }) ?? items.first else { return nil }
        return (primary.id, primary.summary)
    }

    private func scopedCalendarID(accountID: String, calendarID: String) -> String {
        "\(accountID)::\(calendarID)"
    }

    func mapEventList(data: Data, calendar: UserCalendar) throws -> (events: [CalendarEventOccurrence], nextPageToken: String?) {
        let response = try JSONDecoder().decode(GoogleEventsResponse.self, from: data)
        return (response.items.compactMap { mapEvent($0, calendar: calendar) }, response.nextPageToken)
    }

    func mapEvent(_ event: GoogleEvent, calendar: UserCalendar) -> CalendarEventOccurrence? {
        guard let start = parseDateTime(event.start),
              let end = parseDateTime(event.end) else {
            return nil
        }

        let conferenceLinks = (event.conferenceData?.entryPoints ?? [])
            .compactMap { entry -> MeetingLink? in
                guard entry.entryPointType == "video",
                      let uri = entry.uri,
                      let url = URL(string: uri),
                      let kind = MeetingLinkExtractor.extractURLs(from: uri, source: .conferenceMetadata).first?.kind else {
                    return nil
                }
                return MeetingLink(url: url, kind: kind, source: .conferenceMetadata)
            }

        let rsvp = event.attendees?.first(where: { $0.selfAttendee == true })?.responseStatus
            .flatMap(RSVPStatus.googleValue) ?? .unknown
        let meetingRoom = event.attendees?
            .compactMap { roomName(from: $0) }
            .first

        return CalendarEventOccurrence(
            providerID: "google",
            eventID: event.id,
            calendarID: calendar.id,
            calendarDisplayName: calendar.displayName,
            accountID: calendar.accountID,
            accountDisplayName: calendar.accountDisplayName ?? calendar.displayName,
            iCalUID: event.iCalUID,
            recurringEventID: event.recurringEventID,
            originalStartDate: parseDateTime(event.originalStartTime)?.date,
            title: event.summary?.isEmpty == false ? event.summary! : "Untitled event",
            startDate: start.date,
            endDate: end.date,
            timeZoneIdentifier: start.timeZone ?? end.timeZone,
            eventType: EventType.googleValue(event.eventType),
            status: EventStatus(rawValue: event.status ?? "confirmed") ?? .unknown,
            rsvpStatus: rsvp,
            busyState: event.transparency == "transparent" ? .free : .busy,
            isAllDay: start.isAllDay || end.isAllDay,
            organizerDomain: domain(from: event.organizer?.email),
            attendeeDomains: (event.attendees ?? []).compactMap { domain(from: $0.email) },
            location: event.location,
            meetingRoom: meetingRoom,
            eventDescription: event.description,
            conferenceLinks: conferenceLinks,
            htmlLink: event.htmlLink.flatMap(URL.init(string:)),
            updatedAt: event.updated.flatMap(parseISODate),
            isFromCache: false
        )
    }

    private func parseDateTime(_ value: GoogleEventDateTime?) -> (date: Date, isAllDay: Bool, timeZone: String?)? {
        guard let value else { return nil }
        if let dateTime = value.dateTime, let date = parseISODate(dateTime) {
            return (date, false, value.timeZone)
        }
        if let dateString = value.date {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: dateString) {
                return (date, true, value.timeZone)
            }
        }
        return nil
    }

    private func parseISODate(_ value: String) -> Date? {
        ISO8601DateFormatter.stableDate(from: value)
            ?? ISO8601DateFormatter().date(from: value)
    }

    private func domain(from email: String?) -> String? {
        email?.split(separator: "@").last.map(String.init)
    }

    private func roomName(from attendee: GoogleEventPerson) -> String? {
        guard attendee.resource == true else { return nil }
        if let displayName = attendee.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return displayName
        }
        if let email = attendee.email?.trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty {
            return email
        }
        return nil
    }
}

private extension RSVPStatus {
    static func googleValue(_ value: String) -> RSVPStatus {
        switch value {
        case "accepted": .accepted
        case "tentative": .tentative
        case "needsAction": .needsAction
        case "declined": .declined
        default: .unknown
        }
    }
}
