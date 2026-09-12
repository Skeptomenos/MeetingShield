import Foundation
import Testing
@testable import MeetingShield

@Suite("Credential removal recovery")
@MainActor
struct CredentialRemovalRecoveryTests {
    @Test("Committed account removal stops cached protection while obsolete credential cleanup remains visible")
    func committedRemovalSurvivesCleanupFailureAndRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let controller = fixture.makeController()
        defer { controller.stop() }
        try await fixture.prime(controller)
        let retainedCache = try fixture.copyRetainedCache()
        let legacy = try fixture.seedLegacyToken()
        fixture.keychain.setFailures(legacyDeletion: true)
        fixture.keychain.resetAttempts()

        await controller.removeConnectedAccount(fixture.accountID).value

        #expect(try fixture.savedTokens().isEmpty)
        #expect(fixture.keychain.retrieve(forKey: CredentialRemovalKeychain.legacyKey) == legacy)
        expectRemoved(controller, accountID: fixture.accountID)
        #expect(fixture.settings.snapshot.disabledGoogleAccountIDs.contains(fixture.accountID))
        #expect(fixture.settings.snapshot.hasExplicitCalendarSelection)
        #expect(fixture.settings.snapshot.selectedCalendarIDs.isEmpty)
        #expect(controller.credentialPersistenceFailures == [.legacyCleanup])
        #expect(await controller.provider.credentialPersistenceFailures == [.legacyCleanup])
        #expect(!controller.persistenceWarnings.isEmpty)

        await controller.refresh(reason: "timer")

        expectRemoved(controller, accountID: fixture.accountID)
        #expect(controller.credentialPersistenceFailures == [.legacyCleanup])
        #expect(!controller.persistenceWarnings.isEmpty)
        let reloadedSettings = AppSettingsStore(domainName: fixture.domain)
        #expect(reloadedSettings.snapshot.disabledGoogleAccountIDs.contains(fixture.accountID))
        #expect(reloadedSettings.snapshot.hasExplicitCalendarSelection)
        #expect(reloadedSettings.snapshot.selectedCalendarIDs.isEmpty)
        let restarted = fixture.makeController(settings: reloadedSettings, cache: retainedCache)
        defer { restarted.stop() }

        await restarted.refresh(reason: "launch")

        expectRemoved(restarted, accountID: fixture.accountID)
        #expect(restarted.authState == .disconnected)
        #expect(restarted.credentialPersistenceFailures == [.legacyCleanup])
        #expect(!restarted.persistenceWarnings.isEmpty)
        let pendingCredentials = fixture.keychain.snapshot

        await controller.retryPersistence()

        #expect(fixture.keychain.snapshot == pendingCredentials)
        #expect(controller.credentialPersistenceFailures == [.legacyCleanup])
        #expect(!controller.persistenceWarnings.isEmpty)
        fixture.keychain.setFailures()

        await controller.retryPersistence()

        #expect(try fixture.savedTokens().isEmpty)
        #expect(fixture.keychain.retrieve(forKey: CredentialRemovalKeychain.legacyKey) == nil)
        #expect(controller.credentialPersistenceFailures.isEmpty)
        #expect(controller.persistenceWarnings.isEmpty)
        expectRemoved(controller, accountID: fixture.accountID)
    }

    @Test("Failed removal stays protected and generic Retry cannot repeat it after the Keychain recovers")
    func failedRemovalRequiresAnotherExplicitAction() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let controller = fixture.makeController()
        defer { controller.stop() }
        try await fixture.prime(controller)
        _ = try fixture.seedLegacyToken()
        let originalCredentials = fixture.keychain.snapshot
        let originalSettings = fixture.settings.snapshot
        fixture.keychain.setFailures(collectionSave: true)
        fixture.keychain.resetAttempts()

        await controller.removeConnectedAccount(fixture.accountID).value

        #expect(fixture.keychain.snapshot == originalCredentials)
        #expect(fixture.keychain.deletionAttempts.isEmpty)
        #expect(fixture.settings.snapshot == originalSettings)
        fixture.expectProtected(controller)
        #expect(controller.credentialPersistenceFailures == [.remove(accountID: fixture.accountID)])
        #expect(await controller.provider.credentialPersistenceFailures == [.remove(accountID: fixture.accountID)])
        #expect(!controller.persistenceWarnings.isEmpty)
        fixture.keychain.setFailures()
        let failedSaveAttempts = fixture.keychain.saveAttempts

        await controller.retryPersistence()
        await controller.refresh(reason: "timer")

        #expect(fixture.keychain.saveAttempts == failedSaveAttempts)
        #expect(fixture.keychain.deletionAttempts.isEmpty)
        #expect(fixture.keychain.snapshot == originalCredentials)
        #expect(fixture.settings.snapshot == originalSettings)
        #expect(AppSettingsStore(domainName: fixture.domain).snapshot == originalSettings)
        fixture.expectProtected(controller)
        #expect(controller.credentialPersistenceFailures == [.remove(accountID: fixture.accountID)])
        #expect(!controller.persistenceWarnings.isEmpty)

        await controller.removeConnectedAccount(fixture.accountID).value
        await controller.refresh(reason: "timer")
        #expect(try fixture.savedTokens().isEmpty)
        #expect(fixture.keychain.retrieve(forKey: CredentialRemovalKeychain.legacyKey) == nil)
        #expect(AppSettingsStore(domainName: fixture.domain).snapshot.disabledGoogleAccountIDs.contains(fixture.accountID))
        #expect(controller.credentialPersistenceFailures.isEmpty)
        #expect(controller.persistenceWarnings.isEmpty)
        expectRemoved(controller, accountID: fixture.accountID)
    }

    @Test("Missing OAuth configuration retains credential failures and still permits storage-only recovery")
    func missingConfigurationKeepsStorageRecoveryReachable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let controller = fixture.makeController()
        defer { controller.stop() }
        try await fixture.prime(controller)
        fixture.keychain.setFailures(collectionSave: true)
        var replacement = fixture.token
        replacement.accessToken = "synthetic-unsaved-replacement"
        #expect(throws: KeychainError.self) { try fixture.client.saveToken(replacement) }
        #expect(throws: KeychainError.self) { try fixture.client.removeToken(accountID: fixture.accountID) }
        let unresolved: Set<GoogleOAuthPersistenceFailure> = [
            .save(accountID: fixture.accountID), .remove(accountID: fixture.accountID)
        ]
        try #require(fixture.client.persistenceFailures == unresolved)
        await controller.refresh(reason: "timer")
        try #require(controller.credentialPersistenceFailures == unresolved)
        fixture.settings.update { $0.googleOAuthClientID = "" }
        fixture.keychain.setFailures()
        fixture.keychain.resetAttempts()
        let requestCount = fixture.requests.count

        await controller.retryPersistence()

        #expect(controller.provider is DisconnectedCalendarProvider)
        #expect(controller.authState == .disconnected)
        #expect(controller.credentialPersistenceFailures == unresolved)
        #expect(controller.persistenceWarnings.count == unresolved.count)
        #expect(fixture.keychain.saveAttempts.isEmpty)
        #expect(fixture.requests.count == requestCount)
        #expect(fixture.providerBuilds == 0)
        let legacy = try fixture.seedLegacyToken()
        fixture.keychain.setFailures(legacyDeletion: true)
        var added = fixture.token
        added.accountID = "synthetic-other-\(fixture.domain)@example.invalid"
        added.accessToken = "synthetic-other-access"
        try fixture.client.saveToken(added)
        fixture.keychain.setFailures(legacyDeletion: true, collectionRead: true)
        _ = fixture.client.tokenInventory()
        let pending = unresolved.union([.read, .legacyCleanup])
        try #require(fixture.client.persistenceFailures == pending)
        let savedCollection = fixture.keychain.retrieve(forKey: CredentialRemovalKeychain.collectionKey)
        fixture.keychain.resetAttempts()

        await controller.retryPersistence()

        #expect(controller.credentialPersistenceFailures == pending)
        #expect(controller.persistenceWarnings.count == pending.count)
        let cleanupWarnings = controller.persistenceWarnings.filter { $0.localizedCaseInsensitiveContains("cleanup") }
        #expect(cleanupWarnings.count == 1)
        #expect(!cleanupWarnings.contains { $0.localizedCaseInsensitiveContains("changes are saved") })
        #expect(fixture.keychain.readAttempts.contains(CredentialRemovalKeychain.collectionKey))
        #expect(fixture.keychain.saveAttempts.isEmpty)
        #expect(fixture.keychain.deletionAttempts.isEmpty)
        #expect(fixture.keychain.retrieve(forKey: CredentialRemovalKeychain.legacyKey) == legacy)
        fixture.keychain.setFailures()
        fixture.keychain.resetAttempts()

        await controller.retryPersistence()

        #expect(controller.provider is DisconnectedCalendarProvider)
        #expect(controller.authState == .disconnected)
        #expect(controller.credentialPersistenceFailures == unresolved)
        #expect(controller.persistenceWarnings.count == unresolved.count)
        #expect(fixture.client.persistenceFailures == unresolved)
        #expect(fixture.keychain.readAttempts.contains(CredentialRemovalKeychain.collectionKey))
        #expect(fixture.keychain.deletionAttempts.contains(CredentialRemovalKeychain.legacyKey))
        #expect(fixture.keychain.retrieve(forKey: CredentialRemovalKeychain.legacyKey) == nil)
        #expect(fixture.keychain.retrieve(forKey: CredentialRemovalKeychain.collectionKey) == savedCollection)
        #expect(fixture.keychain.saveAttempts.isEmpty)
        #expect(fixture.requests.count == requestCount)
        #expect(fixture.providerBuilds == 0)
        #expect(controller.activeReminders.isEmpty)
    }

    @Test("Failed removal publishes credential attention before a held calendar refresh can return")
    func failedRemovalWarningDoesNotWaitForNetwork() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let controller = fixture.makeController()
        defer { controller.stop() }
        try await fixture.prime(controller)
        let hold = fixture.holdNextCatalog()
        defer { hold.cancel() }
        fixture.keychain.setFailures(collectionSave: true)
        fixture.keychain.resetAttempts()
        let menuUpdates = fixture.menuUpdates

        let removal = controller.removeConnectedAccount(fixture.accountID)

        let arrived = await hold.arrived.wait()
        try #require(arrived, "The actual post-removal calendar request must be held before checking attention.")
        #expect(!hold.wasReleased)
        #expect(hold.completionCount == 0)
        #expect(fixture.keychain.saveAttempts == [CredentialRemovalKeychain.collectionKey])
        #expect(fixture.keychain.deletionAttempts.isEmpty)
        #expect(fixture.client.persistenceFailures == [.remove(accountID: fixture.accountID)])
        #expect(controller.credentialPersistenceFailures == [.remove(accountID: fixture.accountID)])
        #expect(!controller.persistenceWarnings.isEmpty)
        #expect(fixture.menuUpdates > menuUpdates)
        fixture.expectProtected(controller)

        hold.release()

        await removal.value
        #expect(hold.completionCount == 1)
        #expect(controller.credentialPersistenceFailures == [.remove(accountID: fixture.accountID)])
        fixture.expectProtected(controller)
    }

    private func expectRemoved(_ controller: MeetingShieldController, accountID: String) {
        #expect(controller.accounts.allSatisfy { $0.id != accountID })
        #expect(controller.calendars.allSatisfy { $0.accountID != accountID })
        #expect(controller.events.allSatisfy { $0.accountID != accountID })
        #expect(controller.scheduledReminders.allSatisfy { $0.event.accountID != accountID })
        #expect(controller.activeReminders.isEmpty)
    }

    @MainActor
    private final class Fixture {
        let domain: String
        let directory: URL
        let now: Date
        let accountID: String
        let sourceCalendarID: String
        let calendarID: String
        let eventID: String
        let token: GoogleOAuthToken
        let keychain: CredentialRemovalKeychain
        let session: URLSession
        let settings: AppSettingsStore
        let cache: EventCacheStore
        let client: GoogleOAuthClient
        let requests = CredentialRemovalRequestCount()
        var menuUpdates = 0
        var providerBuilds = 0

        init() throws {
            let marker = "CredentialRemovalRecoveryTests.\(UUID().uuidString)"
            let directory = try TestTempDirectory.make()
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let accountID = "\(marker)@example.invalid"
            let sourceCalendarID = "\(marker)-calendar"
            let calendarID = "\(accountID)::\(sourceCalendarID)"
            let eventID = "\(marker)-meeting"
            let token = GoogleOAuthToken(
                accessToken: "synthetic-access-\(marker)", refreshToken: "synthetic-refresh-\(marker)",
                expiresAt: .distantFuture, scope: AppIdentity.googleScopes.joined(separator: " "), tokenType: "Bearer",
                accountID: accountID, accountDisplayName: "Synthetic removal account"
            )
            let keychain = CredentialRemovalKeychain()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CredentialRemovalHeldCatalogProtocol.self, StubURLProtocol.self]
            configuration.httpAdditionalHeaders = ["X-MeetingShield-Removal-Test": marker]
            let session = URLSession(configuration: configuration)
            self.domain = marker
            self.directory = directory
            self.now = now
            self.accountID = accountID
            self.sourceCalendarID = sourceCalendarID
            self.calendarID = calendarID
            self.eventID = eventID
            self.token = token
            self.keychain = keychain
            self.session = session
            self.settings = AppSettingsStore(domainName: marker)
            self.cache = EventCacheStore(fileURL: directory.appending(path: "event-cache.json"))
            self.client = GoogleOAuthClient(
                configuration: GoogleOAuthConfiguration(clientID: "synthetic-client-\(marker)"),
                keychain: keychain, session: session,
                diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "oauth"), nativeSink: { _, _ in })
            )
            try client.saveToken(token)
            settings.update {
                $0.googleOAuthClientID = "synthetic-client-\(marker)"
                $0.selectedCalendarIDs = [calendarID]
                $0.presentationModeDefault = true
                $0.soundEnabled = false
                $0.urgentRepeatSoundEnabled = false
                $0.wakeGraceEnabled = false
            }
            let start = ISO8601DateFormatter.stableString(from: now.addingTimeInterval(3600))
            let end = ISO8601DateFormatter.stableString(from: now.addingTimeInterval(5400))
            let requests = requests
            StubURLProtocol.registerJSON(matcher: { request in
                guard request.value(forHTTPHeaderField: "X-MeetingShield-Removal-Test") == marker
                    && request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token.accessToken)"
                    && request.url?.path.hasSuffix("/users/me/calendarList") == true
                    && request.queryValues["pageToken"] == nil else { return false }
                requests.record()
                return true
            }, json: "{\"items\":[{\"id\":\"\(sourceCalendarID)\",\"summary\":\"Synthetic removal calendar\",\"primary\":true,\"selected\":true,\"accessRole\":\"reader\"}]}")
            StubURLProtocol.registerJSON(matcher: { request in
                guard request.value(forHTTPHeaderField: "X-MeetingShield-Removal-Test") == marker
                    && request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token.accessToken)"
                    && request.url?.path.hasSuffix("/calendars/\(sourceCalendarID)/events") == true
                    && request.queryValues["pageToken"] == nil else { return false }
                requests.record()
                return true
            }, json: "{\"items\":[{\"id\":\"\(eventID)\",\"status\":\"confirmed\",\"summary\":\"Synthetic future removal meeting\",\"start\":{\"dateTime\":\"\(start)\"},\"end\":{\"dateTime\":\"\(end)\"}}]}")
        }

        func makeController(settings overrideSettings: AppSettingsStore? = nil, cache overrideCache: EventCacheStore? = nil) -> MeetingShieldController {
            let client = client
            let now = now
            return MeetingShieldController(
                settingsStore: overrideSettings ?? settings, provider: GoogleCalendarProvider(oauthClient: client),
                credentialsResolver: GoogleOAuthCredentialsResolver(bundleInfoValue: { _ in nil }, environment: [:]),
                makeGoogleProvider: { [weak self] _ in
                    self?.providerBuilds += 1
                    Issue.record("Credential Retry unexpectedly replaced the unchanged Google provider.")
                    return GoogleCalendarProvider(oauthClient: client)
                },
                reminderStateStore: ReminderStateStore(
                    fileURL: directory.appending(path: "reminder-state.json"),
                    diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "state-diagnostics"), nativeSink: { _, _ in })
                ),
                cacheStore: overrideCache ?? cache, notificationService: NoopNotificationService(),
                soundPlayer: CredentialRemovalUnexpectedSound(), now: { now },
                refreshMenuBar: { [weak self] in
                    self?.menuUpdates += 1
                }
            )
        }

        func prime(_ controller: MeetingShieldController) async throws {
            await controller.refresh(reason: "launch")
            try #require(controller.accounts.map(\.id) == [accountID])
            try #require(controller.calendars.map(\.id) == [calendarID])
            try #require(controller.events.map(\.eventID) == [eventID])
            try #require(controller.scheduledReminders.map { $0.event.eventID } == [eventID])
            try #require(try cache.loadUnfiltered()?.events.map(\.eventID) == [eventID])
            try #require(controller.activeReminders.isEmpty)
            try #require(controller.persistenceWarnings.isEmpty)
        }

        func expectProtected(_ controller: MeetingShieldController) {
            #expect(controller.accounts.map(\.id) == [accountID])
            #expect(controller.calendars.map(\.id) == [calendarID])
            #expect(controller.events.map(\.eventID) == [eventID])
            #expect(controller.scheduledReminders.map { $0.event.eventID } == [eventID])
            #expect(controller.activeReminders.isEmpty)
            #expect(!settings.snapshot.disabledGoogleAccountIDs.contains(accountID))
        }

        func copyRetainedCache() throws -> EventCacheStore {
            let file = directory.appending(path: "retained-event-cache.json")
            try Data(contentsOf: cache.fileURL).write(to: file)
            return EventCacheStore(fileURL: file)
        }

        func seedLegacyToken() throws -> String {
            let value = String(decoding: try JSONEncoder().encode(token), as: UTF8.self)
            try keychain.save(value, forKey: CredentialRemovalKeychain.legacyKey)
            return value
        }

        func savedTokens() throws -> [GoogleOAuthToken] {
            let value = try #require(keychain.retrieve(forKey: CredentialRemovalKeychain.collectionKey))
            return try JSONDecoder().decode(CredentialRemovalCollection.self, from: Data(value.utf8)).tokens
        }

        func holdNextCatalog() -> CredentialRemovalHeldCatalog {
            let body = Data("{\"items\":[{\"id\":\"\(sourceCalendarID)\",\"summary\":\"Synthetic removal calendar\",\"primary\":true,\"selected\":true,\"accessRole\":\"reader\"}]}".utf8)
            let hold = CredentialRemovalHeldCatalog(body: body)
            CredentialRemovalHeldCatalogProtocol.install(hold, marker: domain)
            return hold
        }

        func cleanup() {
            CredentialRemovalHeldCatalogProtocol.remove(marker: domain)
            session.invalidateAndCancel()
            #expect(StubURLProtocol.unmatched.filter {
                $0.value(forHTTPHeaderField: "X-MeetingShield-Removal-Test") == domain
            }.isEmpty)
            UserDefaults.standard.removePersistentDomain(forName: domain)
            #expect(SettingsPreferences(domainName: domain).read() == nil)
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("The owned credential-removal fixture directory could not be removed.") }
        }
    }
}

private struct CredentialRemovalCollection: Decodable {
    var tokens: [GoogleOAuthToken]
}

private struct CredentialRemovalUnexpectedSound: AlertSoundPlaying {
    func playAlertSound() { Issue.record("A future credential-removal fixture must not play sound.") }
}

private final class CredentialRemovalKeychain: KeychainStoring, @unchecked Sendable {
    static let collectionKey = "google.oauth.tokens"
    static let legacyKey = "google.oauth.token"
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var saves: [String] = []
    private var deletions: [String] = []
    private var reads: [String] = []
    private var failCollectionSave = false
    private var failLegacyDeletion = false
    private var failCollectionRead = false

    var snapshot: [String: String] { lock.withLock { values } }
    var saveAttempts: [String] { lock.withLock { saves } }
    var deletionAttempts: [String] { lock.withLock { deletions } }
    var readAttempts: [String] { lock.withLock { reads } }

    func setFailures(collectionSave: Bool = false, legacyDeletion: Bool = false, collectionRead: Bool = false) {
        lock.withLock {
            failCollectionSave = collectionSave
            failLegacyDeletion = legacyDeletion
            failCollectionRead = collectionRead
        }
    }

    func resetAttempts() {
        lock.withLock {
            saves.removeAll()
            deletions.removeAll()
            reads.removeAll()
        }
    }

    func save(_ value: String, forKey key: String) throws {
        try lock.withLock {
            saves.append(key)
            if failCollectionSave && key == Self.collectionKey { throw KeychainError.saveFailed(-25308) }
            values[key] = value
        }
    }

    func read(forKey key: String) throws -> String? {
        try lock.withLock {
            reads.append(key)
            if failCollectionRead && key == Self.collectionKey { throw KeychainError.readFailed(-25308) }
            return values[key]
        }
    }
    func retrieve(forKey key: String) -> String? { lock.withLock { values[key] } }

    func delete(forKey key: String) throws {
        try lock.withLock {
            deletions.append(key)
            if failLegacyDeletion && key == Self.legacyKey { throw KeychainError.deleteFailed(-25308) }
            values.removeValue(forKey: key)
        }
    }
}

private final class CredentialRemovalRequestCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}

private actor CredentialRemovalGate {
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]

    func wait() async -> Bool {
        if isOpen { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            if Task.isCancelled { return false }
            return await withCheckedContinuation { continuation in
                waiters[id] = continuation
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    await self?.finish(id, result: false)
                }
            }
        } onCancel: {
            Task { await self.finish(id, result: false) }
        }
    }

    func open() {
        isOpen = true
        for id in Array(waiters.keys) { finish(id, result: true) }
    }

    private func finish(_ id: UUID, result: Bool) {
        timeouts.removeValue(forKey: id)?.cancel()
        waiters.removeValue(forKey: id)?.resume(returning: result)
    }
}

private final class CredentialRemovalHeldCatalog: @unchecked Sendable {
    let arrived = CredentialRemovalGate()
    private let body: Data
    private let lock = NSLock()
    private var pending: CredentialRemovalHeldCatalogProtocol?
    private var released = false
    private var completions = 0

    init(body: Data) { self.body = body }

    var wasReleased: Bool { lock.withLock { released } }
    var completionCount: Int { lock.withLock { completions } }

    func accept(_ loader: CredentialRemovalHeldCatalogProtocol) -> Bool {
        let accepted = lock.withLock {
            guard !released, pending == nil else { return false }
            pending = loader
            return true
        }
        if accepted { Task { await arrived.open() } }
        return accepted
    }

    func release() {
        let loader = lock.withLock { () -> CredentialRemovalHeldCatalogProtocol? in
            guard let loader = pending else { return nil }
            pending = nil
            released = true
            completions += 1
            return loader
        }
        loader?.complete(body: body)
    }

    func cancel(_ expected: CredentialRemovalHeldCatalogProtocol? = nil) {
        let loader = lock.withLock { () -> CredentialRemovalHeldCatalogProtocol? in
            guard let loader = pending, expected == nil || expected === loader else { return nil }
            pending = nil
            released = true
            return loader
        }
        loader?.fail()
    }
}

private final class CredentialRemovalHeldCatalogProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var holds: [String: CredentialRemovalHeldCatalog] = [:]

    static func install(_ hold: CredentialRemovalHeldCatalog, marker: String) {
        lock.withLock { holds[marker] = hold }
    }

    static func remove(marker: String) {
        let hold = lock.withLock { holds.removeValue(forKey: marker) }
        hold?.cancel()
    }

    private static func hold(for request: URLRequest) -> CredentialRemovalHeldCatalog? {
        guard let marker = request.value(forHTTPHeaderField: "X-MeetingShield-Removal-Test"),
              request.url?.path.hasSuffix("/users/me/calendarList") == true else { return nil }
        return lock.withLock { holds[marker] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let hold = hold(for: request) else { return false }
        return !hold.wasReleased
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let hold = Self.hold(for: request), hold.accept(self) else {
            fail()
            return
        }
    }

    override func stopLoading() { Self.hold(for: request)?.cancel(self) }

    func complete(body: Data) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            fail()
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    func fail() { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
}
