import Foundation

actor GoogleCalendarProvider: CalendarProvider {
    nonisolated let providerID = "google"

    static let maxPagesPerFetch = 40

    private var oauthClient: GoogleOAuthClient
    private var mapper: GoogleCalendarMapper
    private var cachedCalendars: [UserCalendar] = []

    init(oauthClient: GoogleOAuthClient, mapper: GoogleCalendarMapper = GoogleCalendarMapper()) {
        self.oauthClient = oauthClient
        self.mapper = mapper
    }

    var credentialPersistenceFailures: Set<GoogleOAuthPersistenceFailure> {
        oauthClient.persistenceFailures
    }

    func retryCredentialPersistence() async {
        oauthClient.retryPersistence()
    }

    var authState: CalendarProviderAuthState {
        get async {
            guard oauthClient.configuration.isConfigured else { return .needsConfiguration }
            let inventory = oauthClient.tokenInventory()
            let tokens = inventory.tokens
            guard !tokens.isEmpty else {
                return inventory.isComplete ? .disconnected : .expired(reason: "Saved Google credentials could not be read.")
            }
            if tokens.contains(where: { $0.isUsable || $0.canRefresh }) {
                return .connected(accountEmail: accountStatusLabel(for: tokens))
            }
            return .expired(reason: "No refresh token available")
        }
    }

    func accounts() async -> [ConnectedCalendarAccount] {
        let inventory = oauthClient.tokenInventory()
        let tokens = inventory.tokens
        return inventory.knownAccountIDs.map { accountID in
            let token = tokens.first { $0.accountID == accountID }
            return ConnectedCalendarAccount(id: accountID, displayName: token?.accountDisplayName ?? accountID)
        }.sorted { first, second in
            first.displayName.localizedCaseInsensitiveCompare(second.displayName) == .orderedAscending
        }
    }

    func calendars() async throws -> [UserCalendar] {
        try await calendarCatalog().calendars
    }

    func calendarCatalog() async throws -> CalendarCatalog {
        AppLog.oauth.debug("googleCalendarListStart")
        let inventory = oauthClient.tokenInventory()
        let tokens = inventory.tokens
        guard !tokens.isEmpty || !inventory.isComplete else { throw CalendarProviderError.disconnected }
        var expectedAccounts = tokens.map(\.accountID)
        var inventoryComplete = inventory.isComplete
        var unscopedFailure: CalendarAccountFailure?
        var results: [CalendarCatalog.Account] = []
        var mergedCalendars: [UserCalendar] = []
        for (tokenIndex, storedToken) in tokens.enumerated() {
            try Task.checkCancellation()
            var accountID = storedToken.accountID
            var displayName = storedToken.accountDisplayName
            do {
                let token = try await oauthClient.validToken(storedToken)
                let bindingTicket = token.accountID == nil ? try oauthClient.legacyBindingTicket(for: token) : nil
                let catalog = try await calendarList(for: token)
                try Task.checkCancellation()
                if let bindingTicket, catalog.isComplete,
                   let identity = mapper.accountIdentity(from: catalog.calendars) {
                    let assigned = try oauthClient.bindLegacyToken(
                        bindingTicket,
                        accountID: identity.id,
                        accountDisplayName: identity.displayName
                    )
                    accountID = assigned.accountID
                    displayName = assigned.accountDisplayName
                    // Accept this migration, while still detecting unrelated membership changes.
                    expectedAccounts[tokenIndex] = assigned.accountID
                }
                guard let accountID else {
                    inventoryComplete = false
                    mergedCalendars += catalog.calendars
                    continue
                }
                let account = ConnectedCalendarAccount(id: accountID, displayName: displayName ?? accountID)
                if catalog.isComplete {
                    results.append(.init(account: account, result: .success(catalog.calendars)))
                    mergedCalendars += catalog.calendars
                } else {
                    results.append(.init(account: account, result: .failure(CalendarAccountFailure(CalendarProviderError.invalidResponse))))
                    let retained = cachedCalendars.filter { $0.accountID == accountID }
                    mergedCalendars += retained.isEmpty ? catalog.calendars : retained
                }
            } catch {
                try Task.checkCancellation()
                guard let accountID else {
                    inventoryComplete = false
                    if unscopedFailure == nil { unscopedFailure = CalendarAccountFailure(error) }
                    continue
                }
                results.append(.init(
                    account: ConnectedCalendarAccount(id: accountID, displayName: displayName ?? accountID),
                    result: .failure(CalendarAccountFailure(error))
                ))
                mergedCalendars += cachedCalendars.filter { $0.accountID == accountID }
                AppLog.oauth.error("googleAccountCatalogFailed account=\(LogPrivacy.redactedID(accountID), privacy: .public) error=\(LogPrivacy.errorClass(error), privacy: .public)")
            }
        }
        try Task.checkCancellation()
        let currentInventory = oauthClient.tokenInventory()
        let currentAccounts = currentInventory.tokens.map(\.accountID)
        inventoryComplete = inventoryComplete && currentInventory.isComplete && currentAccounts.count == expectedAccounts.count
            && Set(currentAccounts) == Set(expectedAccounts)
        let represented = Set(results.map { $0.account.id })
        for accountID in inventory.knownAccountIDs.subtracting(represented) {
            let account = ConnectedCalendarAccount(
                id: accountID,
                displayName: cachedCalendars.first { $0.accountID == accountID }?.accountDisplayName ?? accountID
            )
            results.append(.init(account: account, result: .failure(inventory.failure ?? CalendarAccountFailure(KeychainError.unexpectedData))))
            mergedCalendars += cachedCalendars.filter { $0.accountID == accountID }
        }
        let complete = inventoryComplete && results.allSatisfy {
            if case .success = $0.result { return true }
            return false
        }
        cachedCalendars = mergedCalendars
        AppLog.oauth.info("googleCalendarListFinished accounts=\(tokens.count, privacy: .public) count=\(mergedCalendars.count, privacy: .public) complete=\(LogPrivacy.bool(complete), privacy: .public)")
        return CalendarCatalog(
            calendars: mergedCalendars,
            isComplete: complete,
            accountResults: results,
            inventoryFailure: inventoryComplete ? nil : (
                inventory.failure ?? currentInventory.failure ?? unscopedFailure
                    ?? CalendarAccountFailure(CalendarProviderError.invalidResponse)
            )
        )
    }

    func events(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        try await refresh(in: window)
    }

    func refresh(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        let calendars = cachedCalendars.isEmpty ? try await calendars() : cachedCalendars
        return try await refresh(in: window, calendars: calendars.filter(\.isSelected))
    }

    func refresh(in window: CalendarFetchWindow, calendars: [UserCalendar]) async throws -> [CalendarEventOccurrence] {
        AppLog.refresh.debug("googleEventsRefreshStart cachedCalendars=\(self.cachedCalendars.count, privacy: .public)")
        let selectedCalendars = calendars
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

    func refreshResult(
        in window: CalendarFetchWindow,
        calendars: [UserCalendar],
        accountIDs: Set<String>
    ) async throws -> CalendarRefreshResult {
        let results = await withTaskGroup(of: CalendarRefreshResult.Account.self) { group in
            for accountID in accountIDs {
                let selected = calendars.filter { $0.accountID == accountID }
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let events = try await self.refresh(in: window, calendars: selected)
                        try Task.checkCancellation()
                        return CalendarRefreshResult.Account(
                            accountID: accountID,
                            result: .success(.init(events: events, fetchedCalendarIDs: Set(selected.map(\.id)), window: window))
                        )
                    } catch {
                        return CalendarRefreshResult.Account(accountID: accountID, result: .failure(CalendarAccountFailure(error)))
                    }
                }
            }
            var values: [CalendarRefreshResult.Account] = []
            for await value in group { values.append(value) }
            return values
        }
        try Task.checkCancellation()
        return .accounts(results)
    }

    private func fetchAllEventPages(
        for calendar: UserCalendar,
        window: CalendarFetchWindow
    ) async throws -> [CalendarEventOccurrence] {
        try Task.checkCancellation()
        let token = try await oauthClient.validToken(for: calendar.accountID)
        var events: [CalendarEventOccurrence] = []
        var pageToken: String?
        var pageCount = 0
        var seenPageTokens: Set<String> = []
        var seenEventItems: [String: Data] = [:]
        repeat {
            try Task.checkCancellation()
            guard var components = URLComponents(
                url: AppIdentity.googleCalendarBaseURL
                    .appending(path: "calendars")
                    .appending(path: calendar.apiCalendarID)
                    .appending(path: "events"),
                resolvingAgainstBaseURL: false
            ) else { throw CalendarProviderError.invalidResponse }
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
            guard let url = components.url else { throw CalendarProviderError.invalidResponse }
            let data = try await get(url: url, accessToken: token.accessToken)
            try Task.checkCancellation()
            let uniqueData = try uniqueListPage(data, seenItems: &seenEventItems)
            let page = try mapper.mapEventList(data: uniqueData, calendar: calendar)
            events += page.events
            pageToken = page.nextPageToken
            pageCount += 1
            AppLog.refresh.debug("googleEventsCalendarPageFetched calendar=\(LogPrivacy.redactedID(calendar.id), privacy: .public) page=\(pageCount, privacy: .public) events=\(page.events.count, privacy: .public) hasMore=\(LogPrivacy.bool(pageToken != nil), privacy: .public)")
            if let pageToken,
               pageToken.isEmpty || !seenPageTokens.insert(pageToken).inserted {
                throw CalendarProviderError.invalidResponse
            }
        } while pageToken != nil && pageCount < Self.maxPagesPerFetch
        try Task.checkCancellation()
        if pageToken != nil {
            AppLog.refresh.error("googleEventsPaginationTruncated calendar=\(LogPrivacy.redactedID(calendar.id), privacy: .public) pages=\(pageCount, privacy: .public)")
            throw CalendarProviderError.invalidResponse
        }
        return events
    }

    private func uniqueListPage(_ data: Data, seenItems: inout [String: Data]) throws -> Data {
        guard var page = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = page["items"] as? [[String: Any]] else {
            throw CalendarProviderError.invalidResponse
        }
        var uniqueItems: [[String: Any]] = []
        for item in items {
            try Task.checkCancellation()
            guard let id = item["id"] as? String, !id.isEmpty else {
                throw CalendarProviderError.invalidResponse
            }
            let canonical = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])
            if let previous = seenItems[id] {
                guard previous == canonical else { throw CalendarProviderError.invalidResponse }
                continue
            }
            seenItems[id] = canonical
            uniqueItems.append(item)
        }
        page["items"] = uniqueItems
        return try JSONSerialization.data(withJSONObject: page)
    }

    func reconnect() async throws {
        AppLog.oauth.info("providerReconnectStart")
        try await migrateLegacyTokensIfNeeded()
        let authorization = try oauthClient.authorizationTicket()
        let token = try await oauthClient.authorize()
        let calendars = try await calendarList(for: token).calendars
        guard let identity = mapper.accountIdentity(from: calendars) else {
            AppLog.oauth.error("providerReconnectFailed reason=missingAccountIdentity")
            throw CalendarProviderError.invalidResponse
        }
        try oauthClient.saveToken(
            token, accountID: identity.id, accountDisplayName: identity.displayName,
            authorization: authorization
        )
        cachedCalendars = try await self.calendars()
        AppLog.oauth.info("providerReconnectSucceeded account=\(LogPrivacy.redactedID(identity.id), privacy: .public) totalCalendars=\(self.cachedCalendars.count, privacy: .public)")
    }

    func removeAccount(id: String) async throws {
        try oauthClient.removeToken(accountID: id)
        cachedCalendars.removeAll { $0.accountID == id }
        AppLog.oauth.info("providerAccountRemoved account=\(LogPrivacy.redactedID(id), privacy: .public)")
    }

    private func calendarList(for token: GoogleOAuthToken) async throws -> CalendarCatalog {
        var calendars: [UserCalendar] = []
        var pageToken: String?
        var pageCount = 0
        var seenPageTokens: Set<String> = []
        var seenCalendarItems: [String: Data] = [:]
        repeat {
            try Task.checkCancellation()
            guard var components = URLComponents(
                url: AppIdentity.googleCalendarBaseURL.appending(path: "users/me/calendarList"),
                resolvingAgainstBaseURL: false
            ) else { throw CalendarProviderError.invalidResponse }
            var queryItems = [
                URLQueryItem(name: "maxResults", value: "250"),
                URLQueryItem(name: "showHidden", value: "true")
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = queryItems
            guard let url = components.url else { throw CalendarProviderError.invalidResponse }
            let data = try await get(url: url, accessToken: token.accessToken)
            try Task.checkCancellation()
            let uniqueData = try uniqueListPage(data, seenItems: &seenCalendarItems)
            let page = try mapper.mapCalendarList(
                data: uniqueData,
                accountID: token.accountID,
                accountDisplayName: token.accountDisplayName
            )
            calendars += page.calendars
            pageToken = page.nextPageToken
            pageCount += 1
            if let pageToken,
               pageToken.isEmpty || !seenPageTokens.insert(pageToken).inserted {
                return CalendarCatalog(calendars: calendars, isComplete: false)
            }
        } while pageToken != nil && pageCount < Self.maxPagesPerFetch
        try Task.checkCancellation()
        return CalendarCatalog(calendars: calendars, isComplete: pageToken == nil)
    }

    private func migrateLegacyTokensIfNeeded() async throws {
        let legacyTokens = oauthClient.storedTokens().filter { $0.accountID == nil }
        for token in legacyTokens {
            let validToken = try await oauthClient.validToken(token)
            let bindingTicket = try oauthClient.legacyBindingTicket(for: validToken)
            let catalog = try await calendarList(for: validToken)
            guard catalog.isComplete else { throw CalendarProviderError.invalidResponse }
            guard let identity = mapper.accountIdentity(from: catalog.calendars) else { continue }
            _ = try oauthClient.bindLegacyToken(bindingTicket, accountID: identity.id, accountDisplayName: identity.displayName)
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
