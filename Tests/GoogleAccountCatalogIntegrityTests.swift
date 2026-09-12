import Foundation
import Testing
@testable import MeetingShield

@Suite("Google account catalog integrity")
struct GoogleAccountCatalogIntegrityTests {
    @Test("The first refresh after legacy account binding reports healthy protection")
    @MainActor
    func firstLegacyRefreshReportsHealthyProtection() async throws {
        let marker = "legacy-first-refresh-\(UUID().uuidString)"
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try #require(UserDefaults(suiteName: marker))
        defer { defaults.removePersistentDomain(forName: marker) }
        let settings = AppSettingsStore(domainName: marker)
        let cache = EventCacheStore(fileURL: directory.appending(path: "event-cache.json"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Meeting-Shield-Test": marker]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let keychain = InMemoryKeychain()
        let token = GoogleOAuthToken(
            accessToken: "access-\(marker)-a", refreshToken: nil,
            expiresAt: .distantFuture, scope: "calendar.readonly", tokenType: "Bearer"
        )
        try keychain.save(String(decoding: JSONEncoder().encode(token), as: UTF8.self), forKey: "google.oauth.token")
        let client = GoogleOAuthClient(
            configuration: GoogleOAuthConfiguration(clientID: "\(marker)-client"),
            keychain: keychain, session: session,
            diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "oauth"), nativeSink: { _, _ in })
        )
        let accountID = "\(marker)-a@example.invalid"
        let calendarID = "\(accountID)::\(accountID)"
        let eventID = "event-\(marker)"
        let requests = Requests()
        try register(
            marker: marker, account: "a", path: "users/me/calendarList", key: "catalog",
            pageToken: nil, items: [calendar(id: accountID)], next: nil, requests: requests
        )
        try register(
            marker: marker, account: "a", path: "calendars/\(accountID)/events", key: "events",
            pageToken: nil, items: [event(id: eventID)], next: nil, requests: requests
        )
        let diagnostics = DiagnosticTestCapture()
        let coordinator = RefreshCoordinator(
            provider: GoogleCalendarProvider(oauthClient: client), cacheStore: cache,
            settings: { settings.snapshot }, now: { TestDates.now },
            diagnostics: DiagnosticsRecorder(
                directory: directory.appending(path: "refresh"), nativeSink: { diagnostics.record($0, $1) }
            ),
            rememberProviderDefaults: { ids in settings.update { $0.recordProviderDefaultCalendarIDs(ids) } }
        )
        #expect(try cache.loadUnfiltered() == nil)

        let outcome = try #require(await coordinator.refresh(reason: "launch"))

        #expect(outcome.didSucceed)
        #expect(!outcome.skipped)
        #expect(outcome.statusMessage == nil)
        #expect(outcome.accounts.map(\.id) == [accountID])
        #expect(outcome.events?.map(\.eventID) == [eventID])
        #expect(outcome.events?.allSatisfy { !$0.isFromCache } == true)
        #expect(settings.snapshot.providerDefaultCalendarIDs == [calendarID])
        let saved = try #require(try cache.loadUnfiltered())
        #expect(saved.accounts[accountID]?.fetchedAt == TestDates.now)
        #expect(saved.accounts[accountID]?.coverage?.calendarIDs == [calendarID])
        #expect(client.tokenInventory().tokens == [token.assigned(to: accountID, displayName: "Synthetic calendar")])
        #expect(client.tokenInventory().isComplete)
        #expect(client.persistenceFailures.isEmpty)
        let protection = coordinator.protectionSnapshot(knownAccounts: outcome.accounts)
        #expect(protection.accounts == [.init(accountID: accountID, state: .protected)])
        #expect(!protection.refreshIssue)
        #expect(!protection.cachePersistenceFailed)
        #expect(!coordinator.isProtectionStale)
        let health = ProtectionHealthSummary.derive(from: .init(
            connection: .connected, accounts: protection.accounts,
            hasCalendarSelection: protection.hasCalendarSelection,
            lastSuccessfulRefresh: protection.lastSuccessfulRefresh, oldestCoverage: protection.oldestCoverage,
            refreshIssue: protection.refreshIssue, schedulerLastEvaluation: TestDates.now,
            nextReminder: nil, notification: .notRequired,
            storageWarningCount: protection.cachePersistenceFailed ? 1 : 0,
            reconnectAccountIDs: protection.reconnectAccountIDs,
            requiresGenericReconnect: protection.requiresGenericReconnect, now: TestDates.now
        ))
        #expect(health.level == .healthy)
        let diagnosticEvents = try diagnostics.payloads.map {
            (try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["event"] as? String
        }
        #expect(diagnosticEvents.filter { $0 == "refresh_succeeded" }.count == 1)
        #expect(!diagnosticEvents.contains("refresh_failed"))
        #expect(requests.count("catalog") == 1)
        #expect(requests.count("events") == 1)
        #expect(StubURLProtocol.unmatched.filter {
            $0.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker
        }.isEmpty)
    }

    @Test("Complete account catalogs contain consistent unique calendar IDs", arguments: Scenario.allCases)
    func completeConsistentCatalog(scenario: Scenario) async throws {
        let marker = "p14-catalog-integrity-\(UUID().uuidString)"
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Meeting-Shield-Test": marker]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = GoogleOAuthClient(
            configuration: GoogleOAuthConfiguration(clientID: "\(marker)-client"),
            keychain: InMemoryKeychain(), session: session,
            diagnostics: DiagnosticsRecorder(directory: directory, nativeSink: { _, _ in })
        )
        let requests = Requests()
        let accountA = "\(marker)-a@example.invalid"
        let accountB = "\(marker)-b@example.invalid"
        let sourceA = "\(marker)-a-main"
        let sourceB = "\(marker)-b-main"
        let sourceBSecond = "\(marker)-b-second"
        for suffix in ["a", "b"] {
            try client.saveToken(GoogleOAuthToken(
                accessToken: "access-\(marker)-\(suffix)", refreshToken: nil,
                expiresAt: .distantFuture, scope: "calendar.readonly", tokenType: "Bearer",
                accountID: "\(marker)-\(suffix)@example.invalid", accountDisplayName: "Synthetic \(suffix)"
            ))
        }
        try register(
            marker: marker, account: "a", path: "users/me/calendarList", key: "a.catalog",
            pageToken: nil, items: [calendar(id: sourceA)], next: nil, requests: requests
        )
        try register(
            marker: marker, account: "b", path: "users/me/calendarList", key: "b.catalog",
            pageToken: nil, items: [calendar(id: sourceB)], next: "second", requests: requests
        )
        let secondID = scenario == .uniqueIDs ? sourceBSecond : sourceB
        let secondTitle = scenario == .conflictingRepeat ? "Changed synthetic calendar" : "Synthetic calendar"
        try register(
            marker: marker, account: "b", path: "users/me/calendarList", key: "b.catalog",
            pageToken: "second", items: [calendar(id: secondID, title: secondTitle)], next: nil, requests: requests
        )
        for (account, source) in [("a", sourceA), ("b", sourceB), ("b", sourceBSecond)] {
            try register(
                marker: marker, account: account, path: "calendars/\(source)/events", key: source,
                pageToken: nil, items: [event(id: "event-\(source)")], next: nil, requests: requests
            )
        }
        let provider = GoogleCalendarProvider(oauthClient: client)

        let catalog = try await provider.calendarCatalog()

        #expect(catalog.isComplete == (scenario != .conflictingRepeat))
        #expect(catalog.inventoryFailure == nil)
        let accounts = try #require(catalog.accountResults)
        #expect(Set(accounts.map { $0.account.id }) == [accountA, accountB])
        let healthyCatalog = try #require(accounts.first { $0.account.id == accountA }).result.get()
        #expect(healthyCatalog.map(\.id) == ["\(accountA)::\(sourceA)"])
        let testedCatalog = try #require(accounts.first { $0.account.id == accountB })
        let expectedBIDs = scenario == .uniqueIDs ? [sourceB, sourceBSecond] : [sourceB]
        if scenario == .conflictingRepeat {
            if case .success = testedCatalog.result {
                Issue.record("Conflicting calendar rows were accepted as a complete account catalog")
            }
        } else {
            let values = try testedCatalog.result.get()
            #expect(values.count == expectedBIDs.count)
            #expect(Set(values.map(\.id)) == Set(expectedBIDs.map { "\(accountB)::\($0)" }))
            #expect(catalog.calendars.filter { $0.accountID == accountB }.count == expectedBIDs.count)
        }
        let readyAccounts = Set(accounts.compactMap { item -> String? in
            guard case .success = item.result else { return nil }
            return item.account.id
        })
        let window = CalendarFetchWindow(start: TestDates.now, end: TestDates.now.addingTimeInterval(86_400))
        let refreshed = try await provider.refreshResult(
            in: window, calendars: catalog.calendars.filter(\.isSelected), accountIDs: readyAccounts
        )

        guard case .accounts(let results) = refreshed else {
            Issue.record("Google did not return account-specific refresh results")
            return
        }
        #expect(results.count == (scenario == .conflictingRepeat ? 1 : 2))
        let healthy = try #require(results.first { $0.accountID == accountA }).result.get()
        #expect(healthy.events.map(\.eventID) == ["event-\(sourceA)"])
        #expect(healthy.fetchedCalendarIDs == ["\(accountA)::\(sourceA)"])
        #expect(healthy.window == window)
        if scenario == .conflictingRepeat {
            #expect(!results.contains { $0.accountID == accountB })
        } else {
            let tested = try #require(results.first { $0.accountID == accountB }).result.get()
            #expect(tested.events.count == expectedBIDs.count)
            #expect(Set(tested.events.map(\.eventID)) == Set(expectedBIDs.map { "event-\($0)" }))
            #expect(tested.fetchedCalendarIDs == Set(expectedBIDs.map { "\(accountB)::\($0)" }))
            #expect(tested.window == window)
        }
        #expect(requests.count("a.catalog") == 1)
        #expect(requests.count("b.catalog") == 2)
        #expect(requests.count(sourceA) == 1)
        #expect(requests.count(sourceB) == (scenario == .conflictingRepeat ? 0 : 1))
        #expect(requests.count(sourceBSecond) == (scenario == .uniqueIDs ? 1 : 0))
        #expect(StubURLProtocol.unmatched.filter {
            $0.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker
        }.isEmpty)
    }

    enum Scenario: CaseIterable, Sendable {
        case uniqueIDs
        case identicalRepeat
        case conflictingRepeat
    }

    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        func record(_ key: String) {
            lock.withLock { counts[key, default: 0] += 1 }
        }

        func count(_ key: String) -> Int {
            lock.withLock { counts[key, default: 0] }
        }
    }

    private func calendar(id: String, title: String = "Synthetic calendar") -> [String: Any] {
        ["id": id, "summary": title, "selected": true, "primary": false, "accessRole": "reader"]
    }

    private func event(id: String) -> [String: Any] {
        [
            "id": id, "summary": "Synthetic meeting", "status": "confirmed",
            "start": ["dateTime": ISO8601DateFormatter.stableString(from: TestDates.start)],
            "end": ["dateTime": ISO8601DateFormatter.stableString(from: TestDates.start.addingTimeInterval(1800))]
        ]
    }

    private func register(
        marker: String, account: String, path: String, key: String,
        pageToken: String?, items: [[String: Any]], next: String?, requests: Requests
    ) throws {
        var page: [String: Any] = ["items": items]
        if let next { page["nextPageToken"] = next }
        let data = try JSONSerialization.data(withJSONObject: page, options: [.sortedKeys])
        let url = AppIdentity.googleCalendarBaseURL.appending(path: path)
        StubURLProtocol.register(
            matcher: { request in
                guard request.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker,
                      request.value(forHTTPHeaderField: "Authorization") == "Bearer access-\(marker)-\(account)",
                      request.url?.host == url.host,
                      request.url?.path == url.path,
                      request.queryValues["pageToken"] == pageToken else { return false }
                requests.record(key)
                return true
            },
            response: .init(statusCode: 200, body: data)
        )
    }
}
