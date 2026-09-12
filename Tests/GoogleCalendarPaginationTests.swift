import Foundation
import Testing
@testable import MeetingShield

@Suite("Google API pagination")
struct GoogleCalendarPaginationTests {
    private let calendarPrefix = "pagination-\(UUID().uuidString)"

    @Test("Event fetch follows nextPageToken across all pages")
    func eventFetchFollowsNextPageToken() async throws {
        let calendarID = "\(calendarPrefix)-events"
        let session = StubURLProtocol.makeSession()
        let client = makeAuthedClient(session: session)
        let provider = GoogleCalendarProvider(oauthClient: client)
        let calendar = UserCalendar(
            id: "acct::\(calendarID)",
            sourceCalendarID: calendarID,
            accountID: "acct@example.com",
            accountDisplayName: "Acct",
            displayName: "Paginated",
            isPrimary: true,
            isSelected: true,
            colorHex: nil
        )

        StubURLProtocol.registerJSON(
            matcher: { request in
                request.url?.path.contains("calendars/\(calendarID)/events") == true
                    && request.queryValues["pageToken"] == nil
            },
            json: eventsPage(ids: ["page1-a", "page1-b"], nextPageToken: "token-page-2")
        )
        StubURLProtocol.registerJSON(
            matcher: { request in
                request.url?.path.contains("calendars/\(calendarID)/events") == true
                    && request.queryValues["pageToken"] == "token-page-2"
            },
            json: eventsPage(ids: ["page2-a"], nextPageToken: nil)
        )

        let window = CalendarFetchWindow(start: TestDates.now, end: TestDates.now.addingTimeInterval(86_400))
        let events = try await provider.refresh(in: window, calendars: [calendar])

        #expect(events.map(\.eventID).sorted() == ["page1-a", "page1-b", "page2-a"])
    }

    @Test("Calendar list follows nextPageToken across all pages")
    func calendarListFollowsNextPageToken() async throws {
        let marker = "\(calendarPrefix)-list"
        let session = StubURLProtocol.makeSession()
        let client = makeAuthedClient(session: session, accountID: "\(marker)@example.com")
        let provider = GoogleCalendarProvider(oauthClient: client)

        StubURLProtocol.registerJSON(
            matcher: { request in
                request.url?.path.contains("users/me/calendarList") == true
                    && request.queryValues["pageToken"] == nil
                    && self.requestBelongsToAccount(request, marker: marker)
            },
            json: calendarListPage(ids: ["\(marker)@example.com", "\(marker)-team"], nextPageToken: "list-page-2")
        )
        StubURLProtocol.registerJSON(
            matcher: { request in
                request.url?.path.contains("users/me/calendarList") == true
                    && request.queryValues["pageToken"] == "list-page-2"
                    && self.requestBelongsToAccount(request, marker: marker)
            },
            json: calendarListPage(ids: ["\(marker)-shared"], nextPageToken: nil)
        )

        let calendars = try await provider.calendars()

        #expect(calendars.count == 3)
        #expect(Set(calendars.compactMap(\.sourceCalendarID)) == [
            "\(marker)@example.com", "\(marker)-team", "\(marker)-shared"
        ])
    }

    @Test("Supplied calendars fetch events even when Google marks them unselected")
    func suppliedCalendarOverridesProviderSelection() async throws {
        let marker = "p02-explicit-\(UUID().uuidString)"
        let calendarID = "\(marker)-calendar"
        let accountID = "\(marker)@example.com"
        let session = StubURLProtocol.makeSession()
        let provider = GoogleCalendarProvider(oauthClient: makeAuthedClient(session: session, accountID: accountID))
        let calendar = UserCalendar(
            id: "\(accountID)::\(calendarID)",
            sourceCalendarID: calendarID,
            accountID: accountID,
            accountDisplayName: "Synthetic account",
            displayName: "Explicit selection",
            isPrimary: false,
            isSelected: false,
            colorHex: nil
        )
        StubURLProtocol.registerJSON(
            matcher: { request in
                request.url?.path.contains("calendars/\(calendarID)/events") == true
                    && self.requestBelongsToAccount(request, marker: marker)
            },
            json: eventsPage(ids: ["\(marker)-event"], nextPageToken: nil)
        )
        let window = CalendarFetchWindow(start: TestDates.now, end: TestDates.now.addingTimeInterval(86_400))

        let events = try await provider.refresh(in: window, calendars: [calendar])

        #expect(events.map(\.eventID) == ["\(marker)-event"])
        #expect(events.map(\.calendarID) == [calendar.id])
        #expect(events.map(\.accountID) == [accountID])
    }

    @Test("Refresh without supplied calendars retains provider defaults", arguments: [false, true])
    func refreshWithoutSuppliedCalendarsUsesProviderDefaults(prefetchCalendars: Bool) async throws {
        let marker = "p02-defaults-\(UUID().uuidString)"
        let session = StubURLProtocol.makeSession()
        let provider = GoogleCalendarProvider(oauthClient: makeAuthedClient(session: session, accountID: "\(marker)@example.com"))
        StubURLProtocol.registerJSON(
            matcher: { request in
                request.url?.path.contains("users/me/calendarList") == true
                    && self.requestBelongsToAccount(request, marker: marker)
            },
            json: selectionCalendarListPage(marker: marker, includeHidden: true)
        )
        for suffix in ["selected", "unselected", "hidden"] {
            let calendarID = "\(marker)-\(suffix)"
            StubURLProtocol.registerJSON(
                matcher: { request in
                    request.url?.path.contains("calendars/\(calendarID)/events") == true
                        && self.requestBelongsToAccount(request, marker: marker)
                },
                json: eventsPage(ids: ["\(calendarID)-event"], nextPageToken: nil)
            )
        }
        if prefetchCalendars {
            _ = try await provider.calendars()
        }
        let window = CalendarFetchWindow(start: TestDates.now, end: TestDates.now.addingTimeInterval(86_400))

        let events = try await provider.refresh(in: window)

        #expect(events.map(\.eventID) == ["\(marker)-selected-event"])
        #expect(events.map(\.calendarID) == ["\(marker)@example.com::\(marker)-selected"])
    }

    @Test("Calendar discovery requests hidden calendars without selecting them by default")
    func calendarDiscoveryIncludesHiddenCalendarsWithoutChangingDefaults() async throws {
        let marker = "p02-discovery-\(UUID().uuidString)"
        let session = StubURLProtocol.makeSession()
        let provider = GoogleCalendarProvider(oauthClient: makeAuthedClient(session: session, accountID: "\(marker)@example.com"))
        StubURLProtocol.registerJSON(
            matcher: { request in
                request.url?.path.contains("users/me/calendarList") == true
                    && request.queryValues["showHidden"] == "true"
                    && self.requestBelongsToAccount(request, marker: marker)
            },
            json: selectionCalendarListPage(marker: marker, includeHidden: true)
        )
        StubURLProtocol.registerJSON(
            matcher: { request in
                request.url?.path.contains("users/me/calendarList") == true
                    && request.queryValues["showHidden"] != "true"
                    && self.requestBelongsToAccount(request, marker: marker)
            },
            json: selectionCalendarListPage(marker: marker, includeHidden: false)
        )

        let calendars = try await provider.calendars()

        #expect(Set(calendars.compactMap(\.sourceCalendarID)) == ["\(marker)-selected", "\(marker)-unselected", "\(marker)-hidden"])
        #expect(calendars.first { $0.sourceCalendarID == "\(marker)-selected" }?.isSelected == true)
        #expect(calendars.first { $0.sourceCalendarID == "\(marker)-unselected" }?.isSelected == false)
        #expect(calendars.first { $0.sourceCalendarID == "\(marker)-hidden" }?.isSelected == false)
    }

    @Test("A discovered hidden calendar can be explicitly refreshed without changing its visibility flag")
    func discoveredHiddenCalendarCanBeExplicitlyRefreshed() async throws {
        let marker = "p02-discovered-fetch-\(UUID().uuidString)"
        let session = StubURLProtocol.makeSession()
        let provider = GoogleCalendarProvider(oauthClient: makeAuthedClient(session: session, accountID: "\(marker)@example.com"))
        StubURLProtocol.registerJSON(
            matcher: { request in
                request.url?.path.contains("users/me/calendarList") == true
                    && request.queryValues["showHidden"] == "true"
                    && self.requestBelongsToAccount(request, marker: marker)
            },
            json: selectionCalendarListPage(marker: marker, includeHidden: true)
        )
        StubURLProtocol.registerJSON(
            matcher: { request in
                request.url?.path.contains("users/me/calendarList") == true
                    && request.queryValues["showHidden"] != "true"
                    && self.requestBelongsToAccount(request, marker: marker)
            },
            json: selectionCalendarListPage(marker: marker, includeHidden: false)
        )
        StubURLProtocol.registerJSON(
            matcher: { request in
                request.url?.path.contains("calendars/\(marker)-hidden/events") == true
                    && self.requestBelongsToAccount(request, marker: marker)
            },
            json: eventsPage(ids: ["\(marker)-hidden-event"], nextPageToken: nil)
        )
        let calendars = try await provider.calendars()
        let hidden = try #require(calendars.first { $0.sourceCalendarID == "\(marker)-hidden" })
        #expect(!hidden.isSelected)
        let window = CalendarFetchWindow(start: TestDates.now, end: TestDates.now.addingTimeInterval(86_400))

        let events = try await provider.refresh(in: window, calendars: [hidden])

        #expect(events.map(\.eventID) == ["\(marker)-hidden-event"])
        #expect(events.map(\.calendarID) == [hidden.id])
        #expect(events.map(\.accountID) == [hidden.accountID])
    }

    @Test("An empty supplied list cannot reuse a nonempty cached calendar selection")
    func emptySuppliedCalendarListDoesNotReuseCachedDefaults() async throws {
        let marker = "p02-empty-fetch-\(UUID().uuidString)"
        let calendarID = "\(marker)-selected"
        let session = StubURLProtocol.makeSession()
        let provider = GoogleCalendarProvider(oauthClient: makeAuthedClient(session: session, accountID: "\(marker)@example.com"))
        StubURLProtocol.registerJSON(
            matcher: { request in
                request.url?.path.contains("users/me/calendarList") == true
                    && self.requestBelongsToAccount(request, marker: marker)
            },
            json: calendarListPage(ids: [calendarID], nextPageToken: nil)
        )
        StubURLProtocol.registerJSON(
            matcher: { request in
                request.url?.path.contains("calendars/\(calendarID)/events") == true
                    && self.requestBelongsToAccount(request, marker: marker)
            },
            json: eventsPage(ids: ["\(marker)-default-event"], nextPageToken: nil)
        )
        let calendars = try await provider.calendars()
        #expect(calendars.compactMap(\.sourceCalendarID) == [calendarID])
        let window = CalendarFetchWindow(start: TestDates.now, end: TestDates.now.addingTimeInterval(86_400))
        let defaultEvents = try await provider.refresh(in: window)
        #expect(defaultEvents.map(\.eventID) == ["\(marker)-default-event"])

        let events = try await provider.refresh(in: window, calendars: [])

        #expect(events.isEmpty)
    }

    @Test("Complete account catalogs advance defaults without erasing unowned legacy choices", arguments: CatalogScenario.allCases)
    @MainActor
    func rememberedDefaultsRequireCompleteAccountCatalog(scenario: CatalogScenario) async throws {
        let marker = "p02-catalog-completeness-\(UUID().uuidString)"
        let domain = "MeetingShieldCatalogCompletenessTests.\(UUID().uuidString)"
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let accountA = "\(marker)-a@example.com"
        let accountB = "\(marker)-b@example.com"
        let oldIDs: Set<String> = ["\(accountA)::\(marker)-a-old", "\(accountB)::\(marker)-b-old"]
        var newIDs: Set<String> = ["\(accountA)::\(marker)-a-new", "\(accountB)::\(marker)-b-new"]
        if scenario.reachesPageCap {
            newIDs.insert("\(accountA)::\(marker)-a-final")
        }
        let settings = AppSettingsStore(domainName: domain)
        settings.update {
            $0.recordProviderDefaultCalendarIDs(oldIDs)
            $0.presentationModeDefault = true
            $0.soundEnabled = false
            $0.urgentRepeatSoundEnabled = false
            $0.wakeGraceEnabled = false
        }
        #expect(!settings.snapshot.hasExplicitCalendarSelection)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Meeting-Shield-Test": marker]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let capture = DiagnosticTestCapture()
        let requests = CatalogRequests()
        let recorder = DiagnosticsRecorder(directory: directory.appending(path: "oauth-diagnostics"), nativeSink: { capture.record($0, $1) })
        let client = GoogleOAuthClient(
            configuration: GoogleOAuthConfiguration(clientID: "\(marker)-client"),
            keychain: InMemoryKeychain(),
            session: session,
            diagnostics: recorder
        )
        for suffix in ["a", "b"] {
            let accountMarker = "\(marker)-\(suffix)"
            let calendarID = "\(accountMarker)-new"
            let token = GoogleOAuthToken(
                accessToken: "access-\(accountMarker)",
                refreshToken: "refresh-\(accountMarker)",
                expiresAt: suffix == "b" && scenario.accountBRefreshFails ? .distantPast : Date().addingTimeInterval(3600),
                scope: AppIdentity.googleScopes.joined(separator: " "),
                tokenType: "Bearer"
            )
            try client.saveToken(token, accountID: "\(accountMarker)@example.com", accountDisplayName: "Synthetic \(suffix)")
            registerCatalogResponses(
                accountMarker: accountMarker,
                scenario: suffix == "a" ? scenario : .complete,
                requests: requests
            )
            StubURLProtocol.registerJSON(
                matcher: { request in
                    request.url?.path.contains("calendars/\(calendarID)/events") == true
                        && self.requestBelongsToAccount(request, marker: accountMarker)
                },
                json: eventsPage(ids: [], nextPageToken: nil)
            )
        }
        if scenario.reachesPageCap {
            StubURLProtocol.registerJSON(
                matcher: { request in
                    request.url?.path.contains("calendars/\(marker)-a-final/events") == true
                        && self.requestBelongsToAccount(request, marker: "\(marker)-a")
                },
                json: eventsPage(ids: [], nextPageToken: nil)
            )
        }
        StubURLProtocol.registerJSON(
            matcher: { request in
                guard request.url == AppIdentity.googleOAuthTokenURL,
                      request.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker else { return false }
                requests.record("token")
                return true
            },
            json: "{\"error\":\"invalid_grant\"}",
            statusCode: 400
        )
        let provider = GoogleCalendarProvider(oauthClient: client)
        let controller = MeetingShieldController(
            settingsStore: settings,
            provider: provider,
            reminderStateStore: ReminderStateStore(fileURL: directory.appending(path: "reminder-state.json")),
            cacheStore: EventCacheStore(fileURL: directory.appending(path: "event-cache.json")),
            notificationService: NoopNotificationService(),
            refreshMenuBar: {}
        )

        await controller.refresh(reason: "launch")

        #expect(controller.calendars.contains { $0.id == "\(accountA)::\(marker)-a-new" })
        #expect(controller.calendars.contains { $0.id == "\(accountB)::\(marker)-b-new" } == !scenario.accountBRefreshFails)
        if scenario.reachesPageCap {
            #expect(controller.calendars.contains { $0.id == "\(accountA)::\(marker)-a-final" })
        }
        #expect(Set(controller.accounts.map(\.id)) == [accountA, accountB])
        #expect(try capture.decodedStrings().contains("invalid_grant") == scenario.accountBRefreshFails)
        #expect(requests.count(for: "\(marker)-a") == scenario.accountARequestCount)
        #expect(requests.count(for: "\(marker)-b") == (scenario.accountBRefreshFails ? 0 : 1))
        #expect(requests.count(for: "token") == (scenario.accountBRefreshFails ? 1 : 0))
        #expect(StubURLProtocol.unmatched.filter { $0.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker }.isEmpty)
        let expectedIDs: Set<String>
        if scenario.isComplete {
            expectedIDs = newIDs
        } else if scenario.accountBRefreshFails {
            expectedIDs = oldIDs.union(["\(accountA)::\(marker)-a-new"])
        } else {
            expectedIDs = oldIDs.union(["\(accountB)::\(marker)-b-new"])
        }
        let reloaded = AppSettingsStore(domainName: domain)
        for snapshot in [settings.snapshot, reloaded.snapshot] {
            #expect(!snapshot.hasExplicitCalendarSelection)
            #expect(snapshot.providerDefaultCalendarIDs == expectedIDs)
            for calendarID in oldIDs.union(newIDs) {
                #expect(snapshot.isCalendarSelected(calendarID) == expectedIDs.contains(calendarID))
            }
        }
    }

    enum CatalogScenario: CaseIterable, Equatable, Sendable {
        case complete
        case accountBTokenFailure
        case completeAtPageCap
        case remainingTokenAtPageCap
        case repeatedPageToken
        case emptyPageToken

        var accountBRefreshFails: Bool { self == .accountBTokenFailure }

        var reachesPageCap: Bool {
            self == .completeAtPageCap || self == .remainingTokenAtPageCap
        }

        var isComplete: Bool {
            self == .complete || self == .completeAtPageCap
        }

        var accountARequestCount: Int {
            switch self {
            case .completeAtPageCap, .remainingTokenAtPageCap: GoogleCalendarProvider.maxPagesPerFetch
            case .repeatedPageToken: 2
            case .complete, .accountBTokenFailure, .emptyPageToken: 1
            }
        }
    }

    private final class CatalogRequests: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        func record(_ account: String) {
            lock.withLock { counts[account, default: 0] += 1 }
        }

        func count(for account: String) -> Int {
            lock.withLock { counts[account, default: 0] }
        }
    }

    private func registerCatalogResponses(accountMarker: String, scenario: CatalogScenario, requests: CatalogRequests) {
        let pages: [(requestToken: String?, calendarIDs: [String], nextToken: String?)]
        switch scenario {
        case .complete, .accountBTokenFailure:
            pages = [(nil, ["\(accountMarker)-new"], nil)]
        case .completeAtPageCap, .remainingTokenAtPageCap:
            pages = (1...GoogleCalendarProvider.maxPagesPerFetch).map { page in
                let requestToken = page == 1 ? nil : "\(accountMarker)-page-\(page)"
                let finalPage = page == GoogleCalendarProvider.maxPagesPerFetch
                let calendarIDs = page == 1 ? ["\(accountMarker)-new"] : (finalPage ? ["\(accountMarker)-final"] : [])
                let nextToken = finalPage && scenario == .completeAtPageCap ? nil : "\(accountMarker)-page-\(page + 1)"
                return (requestToken, calendarIDs, nextToken)
            }
        case .repeatedPageToken:
            let token = "\(accountMarker)-repeat"
            pages = [(nil, ["\(accountMarker)-new"], token), (token, [], token)]
        case .emptyPageToken:
            pages = [(nil, ["\(accountMarker)-new"], ""), ("", [], "")]
        }
        for page in pages {
            StubURLProtocol.registerJSON(
                matcher: { request in
                    guard request.url?.path.contains("users/me/calendarList") == true,
                          self.requestBelongsToAccount(request, marker: accountMarker),
                          request.queryValues["pageToken"] == page.requestToken else { return false }
                    requests.record(accountMarker)
                    return true
                },
                json: calendarListPage(ids: page.calendarIDs, nextPageToken: page.nextToken)
            )
        }
    }

    private func requestBelongsToAccount(_ request: URLRequest, marker: String) -> Bool {
        request.value(forHTTPHeaderField: "Authorization")?.contains("access-\(marker)") == true
    }

    private func makeAuthedClient(session: URLSession, accountID: String = "acct@example.com") -> GoogleOAuthClient {
        let keychain = InMemoryKeychain()
        let client = GoogleOAuthClient(
            configuration: GoogleOAuthConfiguration(clientID: "client-id"),
            keychain: keychain,
            session: session
        )
        let marker = accountID.split(separator: "@").first.map(String.init) ?? accountID
        let token = GoogleOAuthToken(
            accessToken: "access-\(marker)",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600),
            scope: AppIdentity.googleScopes.joined(separator: " "),
            tokenType: "Bearer"
        )
        try? client.saveToken(token, accountID: accountID, accountDisplayName: "Acct")
        return client
    }

    private func eventsPage(ids: [String], nextPageToken: String?) -> String {
        let items = ids.map { id in
            """
            {
              "id": "\(id)",
              "status": "confirmed",
              "summary": "Event \(id)",
              "start": { "dateTime": "2026-06-11T10:00:00Z" },
              "end": { "dateTime": "2026-06-11T10:30:00Z" }
            }
            """
        }.joined(separator: ",")
        let tokenLine = nextPageToken.map { "\"nextPageToken\": \"\($0)\"," } ?? ""
        return "{ \(tokenLine) \"items\": [\(items)] }"
    }

    private func calendarListPage(ids: [String], nextPageToken: String?) -> String {
        let items = ids.map { id in
            """
            {
              "id": "\(id)",
              "summary": "Calendar \(id)",
              "primary": \(id.contains("@") ? "true" : "false")
            }
            """
        }.joined(separator: ",")
        let tokenLine = nextPageToken.map { "\"nextPageToken\": \"\($0)\"," } ?? ""
        return "{ \(tokenLine) \"items\": [\(items)] }"
    }

    private func selectionCalendarListPage(marker: String, includeHidden: Bool) -> String {
        var items = [
            """
            {"id":"\(marker)-selected","summary":"Selected calendar","selected":true,"hidden":false,"accessRole":"reader"}
            """,
            """
            {"id":"\(marker)-unselected","summary":"Unselected calendar","selected":false,"hidden":false,"accessRole":"reader"}
            """
        ]
        if includeHidden {
            items.append("""
            {"id":"\(marker)-hidden","summary":"Hidden calendar","selected":true,"hidden":true,"accessRole":"reader"}
            """)
        }
        return "{\"items\":[\(items.joined(separator: ","))]}"
    }
}
