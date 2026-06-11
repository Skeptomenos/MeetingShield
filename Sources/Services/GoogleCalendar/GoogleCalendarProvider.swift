import Foundation

actor GoogleCalendarProvider: CalendarProvider {
    nonisolated let providerID = "google"

    /// Safety valve against a malformed/looping pageToken; 40 pages x 2500 = 100k events per calendar.
    static let maxPagesPerFetch = 40

    private var oauthClient: GoogleOAuthClient
    private var mapper: GoogleCalendarMapper
    private var cachedCalendars: [UserCalendar] = []

    init(oauthClient: GoogleOAuthClient, mapper: GoogleCalendarMapper = GoogleCalendarMapper()) {
        self.oauthClient = oauthClient
        self.mapper = mapper
    }

    var authState: CalendarProviderAuthState {
        get async {
            guard oauthClient.configuration.isConfigured else { return .needsConfiguration }
        let tokens = oauthClient.storedTokens()
        guard !tokens.isEmpty else { return .disconnected }
            if tokens.contains(where: { $0.isUsable || $0.canRefresh }) {
                return .connected(accountEmail: accountStatusLabel(for: tokens))
            }
            return .expired(reason: "No refresh token available")
        }
    }

    func accounts() async -> [ConnectedCalendarAccount] {
        oauthClient.storedTokens()
            .compactMap { token in
                guard let accountID = token.accountID else { return nil }
                return ConnectedCalendarAccount(
                    id: accountID,
                    displayName: token.accountDisplayName ?? accountID
                )
            }
            .sorted { first, second in
                first.displayName.localizedCaseInsensitiveCompare(second.displayName) == .orderedAscending
            }
    }

    func calendars() async throws -> [UserCalendar] {
        AppLog.oauth.debug("googleCalendarListStart")
        let tokens = try await oauthClient.validTokens()
        var mergedCalendars: [UserCalendar] = []
        for token in tokens {
            let mapped = try await calendarList(for: token)
            if token.accountID == nil, let identity = mapper.accountIdentity(from: mapped) {
                try oauthClient.saveToken(token, accountID: identity.id, accountDisplayName: identity.displayName)
                AppLog.oauth.info("legacyTokenMigrated account=\(LogPrivacy.redactedID(identity.id), privacy: .public)")
            }
            mergedCalendars += mapped
        }
        cachedCalendars = mergedCalendars
        AppLog.oauth.info("googleCalendarListSucceeded accounts=\(tokens.count, privacy: .public) count=\(mergedCalendars.count, privacy: .public)")
        return mergedCalendars
    }

    func events(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        try await refresh(in: window)
    }

    func refresh(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        let calendars = cachedCalendars.isEmpty ? try await calendars() : cachedCalendars
        return try await refresh(in: window, calendars: calendars)
    }

    func refresh(in window: CalendarFetchWindow, calendars: [UserCalendar]) async throws -> [CalendarEventOccurrence] {
        AppLog.refresh.debug("googleEventsRefreshStart cachedCalendars=\(self.cachedCalendars.count, privacy: .public)")
        let selectedCalendars = calendars.filter(\.isSelected)
        // Calendars fetch concurrently; pages within a calendar stay sequential
        // (each page needs the previous page's token).
        let allEvents = try await withThrowingTaskGroup(
            of: [CalendarEventOccurrence].self,
            returning: [CalendarEventOccurrence].self
        ) { group in
            for calendar in selectedCalendars {
                group.addTask {
                    try await self.fetchAllEventPages(for: calendar, window: window)
                }
            }
            var merged: [CalendarEventOccurrence] = []
            for try await events in group {
                merged += events
            }
            return merged
        }
        AppLog.refresh.info("googleEventsRefreshSucceeded calendars=\(calendars.count, privacy: .public) selected=\(selectedCalendars.count, privacy: .public) events=\(allEvents.count, privacy: .public)")
        return allEvents
    }

    private func fetchAllEventPages(
        for calendar: UserCalendar,
        window: CalendarFetchWindow
    ) async throws -> [CalendarEventOccurrence] {
        let token = try await oauthClient.validToken(for: calendar.accountID)
        var events: [CalendarEventOccurrence] = []
        var pageToken: String?
        var pageCount = 0
        repeat {
            var components = URLComponents(
                url: AppIdentity.googleCalendarBaseURL
                    .appending(path: "calendars")
                    .appending(path: calendar.apiCalendarID)
                    .appending(path: "events"),
                resolvingAgainstBaseURL: false
            )!
            var queryItems = [
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "timeMin", value: ISO8601DateFormatter.stableString(from: window.start)),
                URLQueryItem(name: "timeMax", value: ISO8601DateFormatter.stableString(from: window.end)),
                URLQueryItem(name: "showDeleted", value: "true"),
                URLQueryItem(name: "conferenceDataVersion", value: "1"),
                URLQueryItem(name: "maxResults", value: "2500")
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = queryItems
            let data = try await get(url: components.url!, accessToken: token.accessToken)
            let page = try mapper.mapEventList(data: data, calendar: calendar)
            events += page.events
            pageToken = page.nextPageToken
            pageCount += 1
            AppLog.refresh.debug("googleEventsCalendarPageFetched calendar=\(LogPrivacy.redactedID(calendar.id), privacy: .public) page=\(pageCount, privacy: .public) events=\(page.events.count, privacy: .public) hasMore=\(LogPrivacy.bool(pageToken != nil), privacy: .public)")
        } while pageToken != nil && pageCount < Self.maxPagesPerFetch
        if pageToken != nil {
            AppLog.refresh.error("googleEventsPaginationTruncated calendar=\(LogPrivacy.redactedID(calendar.id), privacy: .public) pages=\(pageCount, privacy: .public)")
        }
        return events
    }

    func reconnect() async throws {
        AppLog.oauth.info("providerReconnectStart")
        try await migrateLegacyTokensIfNeeded()
        let token = try await oauthClient.authorize()
        let calendars = try await calendarList(for: token)
        guard let identity = mapper.accountIdentity(from: calendars) else {
            AppLog.oauth.error("providerReconnectFailed reason=missingAccountIdentity")
            throw CalendarProviderError.invalidResponse
        }
        try oauthClient.saveToken(token, accountID: identity.id, accountDisplayName: identity.displayName)
        cachedCalendars = try await self.calendars()
        AppLog.oauth.info("providerReconnectSucceeded account=\(LogPrivacy.redactedID(identity.id), privacy: .public) totalCalendars=\(self.cachedCalendars.count, privacy: .public)")
    }

    func removeAccount(id: String) async throws {
        try oauthClient.removeToken(accountID: id)
        cachedCalendars.removeAll { $0.accountID == id }
        AppLog.oauth.info("providerAccountRemoved account=\(LogPrivacy.redactedID(id), privacy: .public)")
    }

    private func calendarList(for token: GoogleOAuthToken) async throws -> [UserCalendar] {
        var calendars: [UserCalendar] = []
        var pageToken: String?
        var pageCount = 0
        repeat {
            var components = URLComponents(
                url: AppIdentity.googleCalendarBaseURL.appending(path: "users/me/calendarList"),
                resolvingAgainstBaseURL: false
            )!
            var queryItems = [URLQueryItem(name: "maxResults", value: "250")]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = queryItems
            let data = try await get(url: components.url!, accessToken: token.accessToken)
            let page = try mapper.mapCalendarList(
                data: data,
                accountID: token.accountID,
                accountDisplayName: token.accountDisplayName
            )
            calendars += page.calendars
            pageToken = page.nextPageToken
            pageCount += 1
        } while pageToken != nil && pageCount < Self.maxPagesPerFetch
        return calendars
    }

    private func migrateLegacyTokensIfNeeded() async throws {
        let legacyTokens = oauthClient.storedTokens().filter { $0.accountID == nil }
        for token in legacyTokens {
            let validToken = try await oauthClient.validToken(token)
            let calendars = try await calendarList(for: validToken)
            guard let identity = mapper.accountIdentity(from: calendars) else { continue }
            try oauthClient.saveToken(validToken, accountID: identity.id, accountDisplayName: identity.displayName)
            AppLog.oauth.info("legacyTokenMigratedBeforeReconnect account=\(LogPrivacy.redactedID(identity.id), privacy: .public)")
        }
    }

    private func accountStatusLabel(for tokens: [GoogleOAuthToken]) -> String {
        let names = Set(tokens.compactMap(\.accountDisplayName).filter { !$0.isEmpty })
        if names.count == 1, let name = names.first {
            return name
        }
        return "\(tokens.count) Google accounts"
    }

    private func get(url: URL, accessToken: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await oauthClient.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CalendarProviderError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            AppLog.refresh.error("googleRequestFailed status=\(http.statusCode, privacy: .public)")
            if http.statusCode == 401 { throw CalendarProviderError.authExpired("Google returned 401") }
            throw CalendarProviderError.requestFailed(http.statusCode)
        }
        return data
    }
}
