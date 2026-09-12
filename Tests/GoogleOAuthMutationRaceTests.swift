import Foundation
import Testing
@testable import MeetingShield

@Suite("Google OAuth mutation and refresh ordering")
struct GoogleOAuthMutationRaceTests {
    @Test("A delayed refresh cannot undo a newer account mutation", arguments: AccountMutation.allCases)
    func delayedRefreshRespectsNewerMutation(mutation: AccountMutation) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = fixture.token("a", usable: false)
        try fixture.first.saveToken(original)
        let refresh = Task { try await fixture.first.validToken(original) }
        defer { refresh.cancel() }
        let arrived = try await fixture.response.waitForArrival()
        try #require(arrived)

        var expected: GoogleOAuthToken?
        switch mutation {
        case .remove:
            try fixture.second.removeToken(accountID: fixture.accountID("a"))
        case .clear:
            try fixture.second.clearToken()
        case .reconnect:
            let replacement = fixture.token("a", usable: true, version: "reconnected")
            try fixture.second.saveToken(replacement)
            expected = replacement
        case .removeThenReaddIdentical:
            try fixture.second.removeToken(accountID: fixture.accountID("a"))
            try fixture.second.saveToken(original)
            expected = original
        }
        let afterMutation = fixture.keychain.snapshot
        #expect(fixture.response.release())
        let result = await refresh.result

        switch result {
        case .success(let returned):
            if mutation == .reconnect {
                #expect(returned == expected)
                #expect(returned.isUsable)
            } else {
                Issue.record("The delayed refresh returned credentials after its account lifetime ended")
            }
        case .failure:
            break
        }
        #expect(fixture.keychain.snapshot == afterMutation)
        let inventory = fixture.second.tokenInventory()
        #expect(inventory.isComplete)
        let expectedTokens = expected.map { [$0] } ?? []
        #expect(inventory.tokens == expectedTokens)
        #expect(fixture.first.tokenInventory().tokens == inventory.tokens)
        fixture.response.expectCompleted()
    }

    @Test("An ordinary delayed refresh still updates the stored account")
    func ordinaryRefreshCommitsItsResponse() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = fixture.token("a", usable: false)
        try fixture.first.saveToken(original)
        let refresh = Task { try await fixture.first.validToken(original) }
        defer { refresh.cancel() }
        let arrived = try await fixture.response.waitForArrival()
        try #require(arrived)

        #expect(fixture.response.release())
        let returned = try await refresh.value

        #expect(returned.accountID == original.accountID)
        #expect(returned.accountDisplayName == original.accountDisplayName)
        #expect(returned.accessToken == fixture.response.accessToken)
        #expect(returned.refreshToken == original.refreshToken)
        #expect(returned.isUsable)
        #expect(fixture.second.tokenInventory().isComplete)
        #expect(fixture.second.tokenInventory().tokens == [returned])
        fixture.response.expectCompleted()
    }

    @Test("Normal refresh clears a failed save but only explicit reconnection supersedes failed removal")
    func refreshAndExplicitSaveHaveDifferentSupersessionRights() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let accountID = fixture.accountID("a")
        let original = fixture.token("a", usable: false)
        let unsaved = fixture.token("a", usable: true, version: "failed-explicit-save")
        try fixture.first.saveToken(original)
        let beforeFailures = fixture.keychain.snapshot
        fixture.keychain.setSaveDenied(true, forKey: Fixture.collectionKey)

        #expect(throws: KeychainError.self) { try fixture.second.removeToken(accountID: accountID) }
        #expect(fixture.first.persistenceFailures == [.remove(accountID: accountID)])
        #expect(throws: KeychainError.self) { try fixture.second.saveToken(unsaved) }

        let failures: Set<GoogleOAuthPersistenceFailure> = [.remove(accountID: accountID), .save(accountID: accountID)]
        #expect(fixture.first.persistenceFailures == failures)
        #expect(fixture.second.persistenceFailures == failures)
        #expect(fixture.keychain.snapshot == beforeFailures)
        #expect(fixture.response.requestCount == 0)
        fixture.keychain.setSaveDenied(false, forKey: Fixture.collectionKey)
        #expect(fixture.first.tokenInventory().tokens == [original])
        #expect(fixture.first.persistenceFailures == failures)
        let refresh = Task { try await fixture.first.validToken(original) }
        defer { refresh.cancel() }
        let arrived = try await fixture.response.waitForArrival()
        try #require(arrived)
        #expect(fixture.first.persistenceFailures == failures)

        #expect(fixture.response.release())
        let refreshed = try await refresh.value

        #expect(refreshed.accountID == accountID)
        #expect(refreshed.accessToken == fixture.response.accessToken)
        #expect(refreshed.isUsable)
        #expect(fixture.second.tokenInventory().tokens == [refreshed])
        #expect(fixture.first.persistenceFailures == [.remove(accountID: accountID)])
        #expect(fixture.second.persistenceFailures == [.remove(accountID: accountID)])
        let reconnected = fixture.token("a", usable: true, version: "explicitly-reconnected")

        try fixture.second.saveToken(reconnected)

        #expect(fixture.first.tokenInventory().tokens == [reconnected])
        #expect(fixture.first.persistenceFailures.isEmpty)
        #expect(fixture.second.persistenceFailures.isEmpty)
        fixture.response.expectCompleted()
    }

    @Test("Adding another account during refresh preserves both accounts")
    func unrelatedAdditionSurvivesRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = fixture.token("a", usable: false)
        let added = fixture.token("b", usable: true)
        try fixture.first.saveToken(original)
        let refresh = Task { try await fixture.first.validToken(original) }
        defer { refresh.cancel() }
        let arrived = try await fixture.response.waitForArrival()
        try #require(arrived)

        try fixture.second.saveToken(added)
        #expect(fixture.response.release())
        let returned = try await refresh.value
        let inventory = fixture.second.tokenInventory()

        #expect(returned.accountID == original.accountID)
        #expect(returned.accessToken == fixture.response.accessToken)
        #expect(inventory.isComplete)
        #expect(inventory.tokens.count == 2)
        #expect(inventory.tokens.contains(returned))
        #expect(inventory.tokens.contains(added))
        fixture.response.expectCompleted()
    }

    @Test("Refreshing an unassigned legacy token preserves an account added meanwhile")
    func legacyRefreshDoesNotReplaceAnotherAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var original = fixture.token("a", usable: false)
        original.accountID = nil
        original.accountDisplayName = nil
        try fixture.keychain.save(try Fixture.encode(original), forKey: Fixture.legacyKey)
        let migrated = try #require(fixture.first.tokenInventory().tokens.first)
        #expect(migrated == original)
        let added = fixture.token("b", usable: true)
        let refresh = Task { try await fixture.first.validToken(migrated) }
        defer { refresh.cancel() }
        let arrived = try await fixture.response.waitForArrival()
        try #require(arrived)

        try fixture.second.saveToken(added)
        #expect(fixture.response.release())
        let returned = try await refresh.value
        let inventory = fixture.second.tokenInventory()

        #expect(returned.accountID == nil)
        #expect(returned.accessToken == fixture.response.accessToken)
        #expect(returned.refreshToken == original.refreshToken)
        #expect(inventory.isComplete)
        #expect(inventory.tokens.count == 2)
        #expect(inventory.tokens.contains(returned))
        #expect(inventory.tokens.contains(added))
        fixture.response.expectCompleted()
    }

    @Test("Cancellation does not commit a held token response")
    func cancelledRefreshLeavesCredentialsUnchanged() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = fixture.token("a", usable: false)
        try fixture.first.saveToken(original)
        let before = fixture.keychain.snapshot
        let refresh = Task { try await fixture.first.validToken(original) }
        defer { refresh.cancel() }
        let arrived = try await fixture.response.waitForArrival()
        try #require(arrived)

        refresh.cancel()
        let result = await refresh.result
        let cancelled = try await fixture.response.waitForCancellation()
        try #require(cancelled)

        if case .success = result {
            Issue.record("The cancelled refresh returned credentials")
        }
        #expect(!fixture.response.release())
        #expect(fixture.keychain.snapshot == before)
        #expect(fixture.second.tokenInventory().tokens == [original])
        #expect(fixture.response.requestCount == 1)
        #expect(fixture.response.completionCount == 0)
        #expect(fixture.response.cancellationCount == 1)
        #expect(fixture.response.unmatchedCount == 0)
    }

    @Test("Removing the last account leaves a surviving legacy token disconnected")
    func removalKeepsAnAuthoritativeEmptyCollection() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = fixture.token("a", usable: true)
        try fixture.first.saveToken(original)
        let legacy = try Fixture.encode(original)
        try fixture.keychain.save(legacy, forKey: Fixture.legacyKey)

        try fixture.second.removeToken(accountID: fixture.accountID("a"))

        let collection = fixture.keychain.retrieve(forKey: Fixture.collectionKey)
        #expect(collection != nil)
        if let collection {
            #expect(try Fixture.decodeCollection(collection).isEmpty)
        }
        let inventory = fixture.first.tokenInventory()
        #expect(inventory.isComplete)
        #expect(inventory.tokens.isEmpty)
        #expect(inventory.knownAccountIDs.isEmpty)
        #expect(fixture.second.tokenInventory().tokens.isEmpty)
        #expect(fixture.response.requestCount == 0)
    }

    @Test("A denied legacy deletion reports failure without reviving cleared credentials")
    func clearFailureKeepsAnAuthoritativeEmptyCollection() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = fixture.token("a", usable: true)
        try fixture.first.saveToken(original)
        let legacy = try Fixture.encode(original)
        try fixture.keychain.save(legacy, forKey: Fixture.legacyKey)
        fixture.keychain.denyDeletion(forKey: Fixture.legacyKey)

        do {
            try fixture.second.clearToken()
        } catch {
            Issue.record("Committed clearing was reported as failed instead of retaining cleanup health")
        }
        #expect(fixture.second.persistenceFailures == [.legacyCleanup])

        #expect(fixture.keychain.retrieve(forKey: Fixture.legacyKey) == legacy)
        let collection = fixture.keychain.retrieve(forKey: Fixture.collectionKey)
        #expect(collection != nil)
        if let collection {
            #expect(try Fixture.decodeCollection(collection).isEmpty)
        }
        let beforeRead = fixture.keychain.snapshot
        let inventory = fixture.first.tokenInventory()
        #expect(inventory.isComplete)
        #expect(inventory.tokens.isEmpty)
        #expect(inventory.knownAccountIDs.isEmpty)
        #expect(fixture.second.tokenInventory().tokens.isEmpty)
        #expect(fixture.keychain.snapshot == beforeRead)
        #expect(fixture.response.requestCount == 0)
    }

    enum AccountMutation: CaseIterable, Sendable {
        case remove
        case clear
        case reconnect
        case removeThenReaddIdentical
    }

    @Test("Legacy catalog binding cannot cross a newer credential lifetime", arguments: LegacyMutation.allCases)
    func legacyCatalogBindingRespectsMutation(mutation: LegacyMutation) async throws {
        let fixture = try Fixture(catalogResponse: true)
        defer { fixture.cleanup() }
        var original = fixture.token("a", usable: true)
        original.accountID = nil
        original.accountDisplayName = nil
        try fixture.first.saveToken(original)
        let provider = GoogleCalendarProvider(oauthClient: fixture.first)
        let listing = Task { try await provider.calendarCatalog() }
        defer { listing.cancel() }
        let arrived = try await fixture.response.waitForArrival()
        try #require(arrived)

        let expected: [GoogleOAuthToken]
        switch mutation {
        case .unchanged:
            expected = [original.assigned(to: fixture.accountID("a"), displayName: "Synthetic calendar")]
        case .removeDiscoveredAccount:
            try fixture.second.removeToken(accountID: fixture.accountID("a"))
            expected = [original]
        case .removeUnrelatedAccount:
            try fixture.second.removeToken(accountID: fixture.accountID("b"))
            expected = [original.assigned(to: fixture.accountID("a"), displayName: "Synthetic calendar")]
        case .addUnrelatedAccount:
            let added = fixture.token("b", usable: true)
            try fixture.second.saveToken(added)
            expected = [original.assigned(to: fixture.accountID("a"), displayName: "Synthetic calendar"), added]
        case .clear:
            try fixture.second.clearToken()
            expected = []
        case .replaceLegacy:
            var replacement = fixture.token("a", usable: true, version: "replacement")
            replacement.accountID = nil
            replacement.accountDisplayName = nil
            try fixture.second.saveToken(replacement)
            expected = [replacement]
        case .clearThenReaddIdentical:
            try fixture.second.clearToken()
            try fixture.second.saveToken(original)
            expected = [original]
        }
        let afterMutation = fixture.keychain.snapshot
        #expect(fixture.response.release())
        let result = await listing.result
        let inventory = fixture.second.tokenInventory()

        #expect(inventory.isComplete)
        #expect(inventory.tokens == expected)
        if mutation == .addUnrelatedAccount {
            let catalog = try result.get()
            #expect(!catalog.isComplete)
            #expect(catalog.inventoryFailure != nil)
            let accounts = try #require(catalog.accountResults)
            #expect(accounts.map(\.account.id) == [fixture.accountID("a")])
            #expect(try accounts.first?.result.get().map(\.accountID) == [fixture.accountID("a")])
        } else if mutation != .unchanged && mutation != .removeUnrelatedAccount {
            #expect(fixture.keychain.snapshot == afterMutation)
            if case .success(let catalog) = result {
                #expect(!catalog.isComplete)
                #expect(!(catalog.accountResults ?? []).contains { item in
                    if case .success = item.result { return true }
                    return false
                })
            }
        } else {
            let catalog = try result.get()
            #expect(catalog.isComplete)
            #expect(catalog.inventoryFailure == nil)
            #expect(catalog.calendars.map(\.accountID) == [fixture.accountID("a")])
            let accounts = try #require(catalog.accountResults)
            #expect(accounts.map(\.account.id) == [fixture.accountID("a")])
            #expect(try accounts.first?.result.get() == catalog.calendars)
        }
        fixture.response.expectCompleted()
    }

    enum LegacyMutation: CaseIterable, Sendable {
        case unchanged
        case removeDiscoveredAccount
        case removeUnrelatedAccount
        case addUnrelatedAccount
        case clear
        case replaceLegacy
        case clearThenReaddIdentical
    }

    private final class Fixture: Sendable {
        static let collectionKey = "google.oauth.tokens"
        static let legacyKey = "google.oauth.token"
        let id: String
        let directory: URL
        let keychain: MutationKeychain
        let response: HeldResponse
        let session: URLSession
        let first: GoogleOAuthClient
        let second: GoogleOAuthClient

        init(catalogResponse: Bool = false) throws {
            let id = UUID().uuidString.lowercased()
            let directory = try TestTempDirectory.make()
            let keychain = MutationKeychain()
            let response = HeldResponse(
                accessToken: "synthetic-delayed-\(id)",
                catalogAccountID: catalogResponse ? "race-a-\(id)@example.invalid" : nil,
                catalogAccessToken: catalogResponse ? "synthetic-a-original-\(id)" : nil
            )
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [HeldURLProtocol.self]
            configuration.httpAdditionalHeaders = [HeldURLProtocol.markerHeader: id]
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 8
            let session = URLSession(configuration: configuration)
            let diagnostics = DiagnosticsRecorder(directory: directory.appending(path: "diagnostics"), nativeSink: { _, _ in })
            let oauthConfiguration = GoogleOAuthConfiguration(clientID: "synthetic-race-\(id)")
            self.id = id
            self.directory = directory
            self.keychain = keychain
            self.response = response
            self.session = session
            self.first = GoogleOAuthClient(configuration: oauthConfiguration, keychain: keychain, session: session, diagnostics: diagnostics)
            self.second = GoogleOAuthClient(configuration: oauthConfiguration, keychain: keychain, session: session, diagnostics: diagnostics)
            HeldURLProtocol.register(response, marker: id)
        }

        func accountID(_ name: String) -> String {
            "race-\(name)-\(id)@example.invalid"
        }

        func token(_ name: String, usable: Bool, version: String = "original") -> GoogleOAuthToken {
            GoogleOAuthToken(
                accessToken: "synthetic-\(name)-\(version)-\(id)",
                refreshToken: "synthetic-refresh-\(name)-\(version)-\(id)",
                expiresAt: usable ? .distantFuture : .distantPast,
                scope: AppIdentity.googleScopes.joined(separator: " "),
                tokenType: "Bearer",
                accountID: accountID(name),
                accountDisplayName: "Synthetic account \(name)"
            )
        }

        func cleanup() {
            response.close()
            session.invalidateAndCancel()
            HeldURLProtocol.remove(marker: id)
            try? FileManager.default.removeItem(at: directory)
        }

        static func encode(_ token: GoogleOAuthToken) throws -> String {
            String(decoding: try JSONEncoder().encode(token), as: UTF8.self)
        }

        static func decodeCollection(_ value: String) throws -> [GoogleOAuthToken] {
            struct Collection: Decodable {
                var tokens: [GoogleOAuthToken]
            }
            return try JSONDecoder().decode(Collection.self, from: Data(value.utf8)).tokens
        }
    }

    private final class MutationKeychain: KeychainStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        private var deniedDeletions: Set<String> = []
        private var deniedSaves: Set<String> = []

        var snapshot: [String: String] {
            lock.withLock { values }
        }

        func denyDeletion(forKey key: String) {
            lock.withLock { _ = deniedDeletions.insert(key) }
        }

        func setSaveDenied(_ denied: Bool, forKey key: String) {
            lock.withLock {
                if denied { _ = deniedSaves.insert(key) } else { _ = deniedSaves.remove(key) }
            }
        }

        func save(_ value: String, forKey key: String) throws {
            try lock.withLock {
                if deniedSaves.contains(key) { throw KeychainError.saveFailed(-25308) }
                values[key] = value
            }
        }

        func retrieve(forKey key: String) -> String? {
            lock.withLock { values[key] }
        }

        func delete(forKey key: String) throws {
            try lock.withLock {
                if deniedDeletions.contains(key) { throw KeychainError.deleteFailed(-25308) }
                values.removeValue(forKey: key)
            }
        }
    }

    private final class HeldResponse: @unchecked Sendable {
        let accessToken: String
        private let catalogAccountID: String?
        private let catalogAccessToken: String?
        private let lock = NSLock()
        private var pending: HeldURLProtocol?
        private var arrived = 0
        private var completed = 0
        private var cancelled = 0
        private var unmatched = 0
        private var terminal = false

        init(accessToken: String, catalogAccountID: String? = nil, catalogAccessToken: String? = nil) {
            self.accessToken = accessToken
            self.catalogAccountID = catalogAccountID
            self.catalogAccessToken = catalogAccessToken
        }

        var requestCount: Int { lock.withLock { arrived } }
        var completionCount: Int { lock.withLock { completed } }
        var cancellationCount: Int { lock.withLock { cancelled } }
        var unmatchedCount: Int { lock.withLock { unmatched } }

        func receive(_ request: HeldURLProtocol) {
            let accepted = lock.withLock {
                guard !terminal, pending == nil, arrived == 0, matches(request.request) else {
                    unmatched += 1
                    return false
                }
                arrived += 1
                pending = request
                return true
            }
            if !accepted {
                request.client?.urlProtocol(request, didFailWithError: URLError(.unsupportedURL))
            }
        }

        private func matches(_ request: URLRequest) -> Bool {
            guard catalogAccountID != nil else {
                return request.url == AppIdentity.googleOAuthTokenURL && request.httpMethod == "POST"
            }
            let expectedURL = AppIdentity.googleCalendarBaseURL.appending(path: "users/me/calendarList")
            guard let url = request.url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
            let query = components.queryItems ?? []
            return url.host == expectedURL.host && url.path == expectedURL.path
                && request.httpMethod == "GET"
                && request.value(forHTTPHeaderField: "Authorization") == catalogAccessToken.map { "Bearer \($0)" }
                && query.count == 2
                && query.contains(URLQueryItem(name: "maxResults", value: "250"))
                && query.contains(URLQueryItem(name: "showHidden", value: "true"))
        }

        func cancel(_ request: HeldURLProtocol) {
            lock.withLock {
                guard pending === request else { return }
                pending = nil
                terminal = true
                cancelled += 1
            }
        }

        func release() -> Bool {
            let request = lock.withLock {
                guard !terminal, let request = pending else { return nil as HeldURLProtocol? }
                pending = nil
                terminal = true
                completed += 1
                return request
            }
            guard let request, let url = request.request.url,
                  let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return false }
            let body: Data
            if let catalogAccountID {
                body = Data("{\"items\":[{\"id\":\"\(catalogAccountID)\",\"summary\":\"Synthetic calendar\",\"primary\":true,\"selected\":true}]}".utf8)
            } else {
                body = Data("{\"access_token\":\"\(accessToken)\",\"expires_in\":3600,\"token_type\":\"Bearer\"}".utf8)
            }
            request.client?.urlProtocol(request, didReceive: http, cacheStoragePolicy: .notAllowed)
            request.client?.urlProtocol(request, didLoad: body)
            request.client?.urlProtocolDidFinishLoading(request)
            return true
        }

        func close() {
            let request = lock.withLock {
                let request = pending
                pending = nil
                terminal = true
                if request != nil { cancelled += 1 }
                return request
            }
            if let request {
                request.client?.urlProtocol(request, didFailWithError: URLError(.cancelled))
            }
        }

        func waitForArrival() async throws -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline {
                if requestCount == 1 { return true }
                try await Task.sleep(for: .milliseconds(10))
            }
            return requestCount == 1
        }

        func waitForCancellation() async throws -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline {
                if cancellationCount == 1 { return true }
                try await Task.sleep(for: .milliseconds(10))
            }
            return cancellationCount == 1
        }

        func expectCompleted() {
            #expect(requestCount == 1)
            #expect(completionCount == 1)
            #expect(cancellationCount == 0)
            #expect(unmatchedCount == 0)
            #expect(!release())
        }
    }

    private final class HeldURLProtocol: URLProtocol, @unchecked Sendable {
        static let markerHeader = "X-MeetingShield-OAuth-Race"
        private static let lock = NSLock()
        nonisolated(unsafe) private static var responses: [String: HeldResponse] = [:]

        static func register(_ response: HeldResponse, marker: String) {
            lock.withLock { responses[marker] = response }
        }

        static func remove(marker: String) {
            lock.withLock { _ = responses.removeValue(forKey: marker) }
        }

        private var response: HeldResponse? {
            guard let marker = request.value(forHTTPHeaderField: Self.markerHeader) else { return nil }
            return Self.lock.withLock { Self.responses[marker] }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let response else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            response.receive(self)
        }

        override func stopLoading() {
            response?.cancel(self)
        }
    }
}
