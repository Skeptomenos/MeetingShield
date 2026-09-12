import Foundation
import Testing
@testable import MeetingShield

@Suite("Google reconnect mutation ordering")
@MainActor
struct GoogleReconnectMutationTests {
    @Test("An authorization callback respects the account lifetime changed while it was held", arguments: AccountChange.allCases)
    func heldReconnectRespectsAccountMutation(change: AccountChange) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let connection = Task { try await fixture.provider.reconnect() }
        defer { connection.cancel() }
        try await fixture.callback.waitForArrival()
        #expect(fixture.callback.arrivalCount == 1)
        #expect(fixture.requests.tokenRequestCount == 0)

        switch change {
        case .unchanged:
            break
        case .removeAccount:
            try await fixture.provider.removeAccount(id: fixture.accountA)
        case .clear:
            try fixture.client.clearToken()
        case .replaceAccount:
            try fixture.client.saveToken(fixture.replacementA)
        case .removeUnrelatedAccount:
            try await fixture.provider.removeAccount(id: fixture.accountB)
        }
        let afterMutation = fixture.keychain.snapshot

        try #require(fixture.callback.release())
        let result = await connection.result

        #expect(fixture.callback.returnCount == 1)
        #expect(fixture.requests.unexpectedRequestCount == 0)
        let inventory = fixture.client.tokenInventory()
        #expect(inventory.isComplete)
        if change.invalidatesAccountA {
            if case .success = result {
                Issue.record("The held authorization committed after account A's lifetime changed")
            }
            #expect(fixture.keychain.snapshot == afterMutation)
            #expect(!inventory.tokens.contains { $0.accessToken == fixture.requests.authorizedAccessToken })
        } else {
            try result.get()
            let authorized = try #require(inventory.tokens.first { $0.accountID == fixture.accountA })
            #expect(authorized.accessToken == fixture.requests.authorizedAccessToken)
            #expect(authorized.refreshToken == fixture.requests.authorizedRefreshToken)
            #expect(authorized.isUsable)
            let expectedIDs: Set<String> = change == .removeUnrelatedAccount
                ? [fixture.accountA] : [fixture.accountA, fixture.accountB]
            #expect(Set(inventory.tokens.compactMap(\.accountID)) == expectedIDs)
            if change == .unchanged { #expect(inventory.tokens.contains(fixture.originalB)) }
            #expect(fixture.requests.tokenRequestCount == 1)
            #expect(fixture.requests.validPKCEExchangeCount == 1)
        }
        #expect(fixture.client.persistenceFailures.isEmpty)
    }

    @Test("Controller reconnect work cannot persist after provider replacement or Stop", arguments: ControllerChange.allCases)
    func controllerOwnsReconnectLifetime(change: ControllerChange) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let settings = AppSettingsStore(domainName: fixture.domain)
        settings.update {
            $0.googleOAuthClientID = fixture.clientID
            $0.selectedCalendarIDs = []
            $0.presentationModeDefault = true
            $0.soundEnabled = false
            $0.urgentRepeatSoundEnabled = false
            $0.wakeGraceEnabled = false
        }
        var factoryCallCount = 0
        let controller = MeetingShieldController(
            settingsStore: settings, provider: fixture.provider,
            credentialsResolver: GoogleOAuthCredentialsResolver(bundleInfoValue: { _ in nil }, environment: [:]),
            makeGoogleProvider: { configuration in
                factoryCallCount += 1
                #expect(configuration.clientID == fixture.clientID)
                return fixture.provider
            },
            reminderStateStore: ReminderStateStore(fileURL: fixture.directory.appending(path: "reminders.json")),
            cacheStore: EventCacheStore(fileURL: fixture.directory.appending(path: "cache.json")),
            notificationService: NoopNotificationService(), soundPlayer: NoSound(),
            dismissalPresenter: NoDismissal(), now: { TestDates.now }, refreshMenuBar: {}
        )
        defer { controller.stop() }
        let connection = try #require(controller.reconnectGoogle())
        defer { connection.cancel() }
        try await fixture.callback.waitForArrival()
        #expect(factoryCallCount == 1)
        #expect(fixture.requests.tokenRequestCount == 0)
        let beforeInvalidation = fixture.keychain.snapshot
        let replacement = DisconnectedCalendarProvider()
        switch change {
        case .unchanged:
            break
        case .replaceProvider:
            controller.provider = replacement
        case .stop:
            controller.stop()
        }
        if change != .unchanged { #expect(connection.isCancelled) }

        try #require(fixture.callback.release())
        await connection.value

        #expect(fixture.callback.returnCount == 1)
        #expect(fixture.requests.unexpectedRequestCount == 0)
        #expect(controller.events.isEmpty)
        #expect(controller.scheduledReminders.isEmpty)
        #expect(controller.activeReminders.isEmpty)
        #expect(controller.statusMessage == nil)
        #expect(factoryCallCount == 1)
        if change == .unchanged {
            #expect(!fixture.callback.returnedWhileCancelled)
            #expect(fixture.requests.tokenRequestCount == 1)
            #expect(fixture.requests.validPKCEExchangeCount == 1)
            let authorized = try #require(fixture.client.tokenInventory().tokens.first { $0.accountID == fixture.accountA })
            #expect(authorized.accessToken == fixture.requests.authorizedAccessToken)
            #expect(fixture.client.tokenInventory().tokens.contains(fixture.originalB))
        } else {
            #expect(fixture.callback.returnedWhileCancelled)
            #expect(fixture.keychain.snapshot == beforeInvalidation)
            #expect(!fixture.client.tokenInventory().tokens.contains { $0.accessToken == fixture.requests.authorizedAccessToken })
            if change == .replaceProvider {
                let replacementID = await replacement.providerID
                #expect(controller.provider.providerID == replacementID)
            }
        }
        #expect(fixture.client.persistenceFailures.isEmpty)
    }

    enum AccountChange: CaseIterable, Sendable {
        case unchanged, removeAccount, clear, replaceAccount, removeUnrelatedAccount

        var invalidatesAccountA: Bool {
            self == .removeAccount || self == .clear || self == .replaceAccount
        }
    }

    enum ControllerChange: CaseIterable, Sendable {
        case unchanged, replaceProvider, stop
    }

    private enum ProbeError: Error {
        case callbackNotObserved
        case fixtureClosed
    }

    private struct NoSound: AlertSoundPlaying {
        func playAlertSound() {}
    }

    @MainActor
    private final class NoDismissal: DismissalConfirming {
        func present(
            requestID: UUID, reminder: ScheduledReminder, source: DismissalRequestSource,
            completion: @escaping @MainActor (Bool) -> Void
        ) {
            completion(false)
        }

        func cancel(requestID: UUID) {}
    }

    @MainActor
    private final class CallbackGate {
        typealias Response = (callbackURL: URL, redirectURI: String)
        let requests: Requests
        private var continuation: CheckedContinuation<Response, any Error>?
        private var arrival: CheckedContinuation<Void, any Error>?
        private var arrivalTimeout: Task<Void, Never>?
        private var closed = false
        private(set) var arrivalCount = 0
        private(set) var returnCount = 0
        private(set) var returnedWhileCancelled = false

        init(requests: Requests) {
            self.requests = requests
        }

        func response(for pkce: GoogleOAuthPKCE) async throws -> Response {
            guard !closed else { throw ProbeError.fixtureClosed }
            requests.captureVerifier(pkce.codeVerifier)
            arrivalCount += 1
            arrivalTimeout?.cancel()
            arrivalTimeout = nil
            arrival?.resume()
            arrival = nil
            let result: Response = try await withCheckedThrowingContinuation { continuation = $0 }
            returnCount += 1
            returnedWhileCancelled = Task.isCancelled
            return result
        }

        func waitForArrival() async throws {
            if arrivalCount > 0 { return }
            guard !closed else { throw ProbeError.fixtureClosed }
            try await withCheckedThrowingContinuation { continuation in
                arrival = continuation
                arrivalTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    guard let self else { return }
                    arrival?.resume(throwing: ProbeError.callbackNotObserved)
                    arrival = nil
                }
            }
        }

        func release() -> Bool {
            guard let continuation else { return false }
            self.continuation = nil
            continuation.resume(returning: (requests.callbackURL, Requests.redirectURI))
            return true
        }

        func close() {
            closed = true
            arrivalTimeout?.cancel()
            arrivalTimeout = nil
            arrival?.resume(throwing: ProbeError.fixtureClosed)
            arrival = nil
            continuation?.resume(throwing: ProbeError.fixtureClosed)
            continuation = nil
        }
    }

    @MainActor
    private final class Fixture {
        let marker: String
        let directory: URL
        let domain: String
        let clientID: String
        let accountA: String
        let accountB: String
        let originalA: GoogleOAuthToken
        let originalB: GoogleOAuthToken
        let replacementA: GoogleOAuthToken
        let keychain: SyntheticKeychain
        let requests: Requests
        let callback: CallbackGate
        let session: URLSession
        let client: GoogleOAuthClient
        let provider: GoogleCalendarProvider

        init() throws {
            let marker = UUID().uuidString.lowercased()
            let directory = try TestTempDirectory.make()
            let clientID = "synthetic-reconnect-client-\(marker)"
            let accountA = "reconnect-a-\(marker)@example.invalid"
            let accountB = "reconnect-b-\(marker)@example.invalid"
            let originalA = Self.token(accountA, version: "original-a")
            let originalB = Self.token(accountB, version: "original-b")
            let replacementA = Self.token(accountA, version: "replacement-a")
            let keychain = SyntheticKeychain()
            let requests = try Requests(
                marker: marker, clientID: clientID, accountA: accountA,
                tokens: [originalA, originalB, replacementA]
            )
            let callback = CallbackGate(requests: requests)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SyntheticURLProtocol.self]
            configuration.httpAdditionalHeaders = [SyntheticURLProtocol.markerHeader: marker]
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 8
            let session = URLSession(configuration: configuration)
            let diagnostics = DiagnosticsRecorder(directory: directory.appending(path: "diagnostics"), nativeSink: { _, _ in })
            let client = GoogleOAuthClient(
                configuration: GoogleOAuthConfiguration(clientID: clientID), keychain: keychain,
                session: session, diagnostics: diagnostics,
                authorizationResponse: { pkce in try await callback.response(for: pkce) }
            )
            self.marker = marker
            self.directory = directory
            self.domain = "GoogleReconnectMutationTests.\(marker)"
            self.clientID = clientID
            self.accountA = accountA
            self.accountB = accountB
            self.originalA = originalA
            self.originalB = originalB
            self.replacementA = replacementA
            self.keychain = keychain
            self.requests = requests
            self.callback = callback
            self.session = session
            self.client = client
            self.provider = GoogleCalendarProvider(oauthClient: client)
            SyntheticURLProtocol.register(requests, marker: marker)
            try client.saveToken(originalA)
            try client.saveToken(originalB)
        }

        func cleanup() {
            callback.close()
            session.invalidateAndCancel()
            SyntheticURLProtocol.remove(marker: marker)
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }

        private static func token(_ accountID: String, version: String) -> GoogleOAuthToken {
            GoogleOAuthToken(
                accessToken: "synthetic-access-\(version)", refreshToken: "synthetic-refresh-\(version)",
                expiresAt: .distantFuture, scope: AppIdentity.googleScopes.joined(separator: " "),
                tokenType: "Bearer", accountID: accountID, accountDisplayName: "Synthetic account"
            )
        }
    }

    private final class SyntheticKeychain: KeychainStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]

        var snapshot: [String: String] { lock.withLock { values } }

        func save(_ value: String, forKey key: String) throws {
            lock.withLock { values[key] = value }
        }

        func retrieve(forKey key: String) -> String? {
            lock.withLock { values[key] }
        }

        func delete(forKey key: String) throws {
            lock.withLock { _ = values.removeValue(forKey: key) }
        }
    }

    private final class Requests: @unchecked Sendable {
        static let redirectURI = "http://127.0.0.1:49152/synthetic-reconnect-callback"
        static let authorizationCode = "synthetic-reconnect-code"
        let callbackURL: URL
        let authorizedAccessToken: String
        let authorizedRefreshToken: String
        private let clientID: String
        private let accountsByAccessToken: [String: String]
        private let lock = NSLock()
        private var expectedVerifier: String?
        private var tokenRequests = 0
        private var validPKCEExchanges = 0
        private var unexpectedRequests = 0

        init(marker: String, clientID: String, accountA: String, tokens: [GoogleOAuthToken]) throws {
            callbackURL = try #require(URL(string: Self.redirectURI + "?code=" + Self.authorizationCode))
            let authorizedAccessToken = "synthetic-authorized-\(marker)"
            self.authorizedAccessToken = authorizedAccessToken
            authorizedRefreshToken = "synthetic-authorized-refresh-\(marker)"
            self.clientID = clientID
            var accounts: [String: String] = [:]
            for token in tokens { accounts[token.accessToken] = token.accountID }
            accounts[authorizedAccessToken] = accountA
            accountsByAccessToken = accounts
        }

        var tokenRequestCount: Int { lock.withLock { tokenRequests } }
        var validPKCEExchangeCount: Int { lock.withLock { validPKCEExchanges } }
        var unexpectedRequestCount: Int { lock.withLock { unexpectedRequests } }

        func captureVerifier(_ verifier: String) {
            lock.withLock { expectedVerifier = verifier }
        }

        func response(for request: URLRequest) -> Data? {
            lock.withLock {
                guard let url = request.url else { return reject() }
                if url == AppIdentity.googleOAuthTokenURL, request.httpMethod == "POST" {
                    tokenRequests += 1
                    guard let data = Self.body(of: request),
                          let components = URLComponents(string: "?" + String(decoding: data, as: UTF8.self)),
                          let items = components.queryItems, items.count == 5 else { return reject() }
                    let fields = Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } },
                                            uniquingKeysWith: { _, new in new })
                    guard let expectedVerifier, !expectedVerifier.isEmpty,
                          fields == [
                            "client_id": clientID, "code": Self.authorizationCode,
                            "redirect_uri": Self.redirectURI, "code_verifier": expectedVerifier,
                            "grant_type": "authorization_code"
                          ] else { return reject() }
                    validPKCEExchanges += 1
                    return Data("{\"access_token\":\"\(authorizedAccessToken)\",\"refresh_token\":\"\(authorizedRefreshToken)\",\"expires_in\":3600,\"token_type\":\"Bearer\"}".utf8)
                }
                guard request.httpMethod == "GET",
                      let authorization = request.value(forHTTPHeaderField: "Authorization"),
                      authorization.hasPrefix("Bearer "),
                      let account = accountsByAccessToken[String(authorization.dropFirst(7))] else { return reject() }
                let catalogURL = AppIdentity.googleCalendarBaseURL.appending(path: "users/me/calendarList")
                if url.host == catalogURL.host, url.path == catalogURL.path,
                   request.queryValues == ["maxResults": "250", "showHidden": "true"] {
                    return Data("{\"items\":[{\"id\":\"\(account)\",\"summary\":\"Synthetic account\",\"primary\":true,\"selected\":true}]}".utf8)
                }
                let eventsURL = AppIdentity.googleCalendarBaseURL
                    .appending(path: "calendars").appending(path: account).appending(path: "events")
                if url.host == eventsURL.host, url.path == eventsURL.path,
                   request.queryValues["singleEvents"] == "true", request.queryValues["maxResults"] == "2500" {
                    return Data("{\"items\":[]}".utf8)
                }
                return reject()
            }
        }

        private func reject() -> Data? {
            unexpectedRequests += 1
            return nil
        }

        private static func body(of request: URLRequest) -> Data? {
            if let data = request.httpBody { return data }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { return nil }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= 65_536 else { return nil }
            }
            return stream.streamError == nil ? data : nil
        }
    }

    private final class SyntheticURLProtocol: URLProtocol, @unchecked Sendable {
        static let markerHeader = "X-MeetingShield-Reconnect-Probe"
        private static let lock = NSLock()
        nonisolated(unsafe) private static var requests: [String: Requests] = [:]

        static func register(_ requests: Requests, marker: String) {
            lock.withLock { Self.requests[marker] = requests }
        }

        static func remove(marker: String) {
            lock.withLock { _ = requests.removeValue(forKey: marker) }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let marker = request.value(forHTTPHeaderField: Self.markerHeader),
                  let requests = Self.lock.withLock({ Self.requests[marker] }),
                  let body = requests.response(for: request), let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
}
