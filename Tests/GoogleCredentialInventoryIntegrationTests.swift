import CryptoKit
import Foundation
import Testing
@testable import MeetingShield

@Suite("Google credential inventory cache integration")
struct GoogleCredentialInventoryIntegrationTests {
    @Test("An unreadable indexed account retains its cache while a healthy account advances", arguments: Damage.allCases)
    @MainActor
    func partialInventoryPreservesFailedAccountAcrossRestart(damage: Damage) async throws {
        try await exerciseRecovery(damage: damage, explicitSelection: false)
    }

    @Test("Explicit selection survives incomplete inventory and reaches stale age at 300 seconds")
    @MainActor
    func explicitSelectionRetainsOldestAccountFreshness() async throws {
        try await exerciseRecovery(damage: .denied, explicitSelection: true)
    }

    @MainActor
    private func exerciseRecovery(damage: Damage, explicitSelection: Bool) async throws {
        let fixture = try Fixture(explicitSelection: explicitSelection)
        defer { fixture.cleanup() }
        let seeded = try await fixture.seed()
        let priorA = try #require(seeded.accounts[fixture.accountID("a")])
        let selectedIDs = fixture.settings.snapshot.selectedCalendarIDs
        let keychain = try fixture.damagedKeychain(damage)
        let originalCredentials = keychain.snapshot
        let client = fixture.makeClient(keychain)
        let inventory = client.tokenInventory()
        #expect(!inventory.isComplete)
        #expect(inventory.knownAccountIDs == [fixture.accountID("a"), fixture.accountID("b")])
        #expect(inventory.tokens.compactMap(\.accountID) == [fixture.accountID("b")])
        #expect(inventory.tokens.allSatisfy { $0.isUsable })
        let changedAt: TimeInterval = explicitSelection ? 299 : 60
        fixture.requests.move(to: .changed, at: changedAt)
        let coordinator = fixture.makeCoordinator(client: client)

        let outcome = try #require(await coordinator.refresh(reason: "launch"))

        fixture.expectIncomplete(outcome)
        fixture.expectAccountIdentity(outcome, account: priorA.account)
        #expect(fixture.settings.snapshot.hasExplicitCalendarSelection == explicitSelection)
        #expect(fixture.settings.snapshot.selectedCalendarIDs == selectedIDs)
        #expect(fixture.settings.snapshot.providerDefaultCalendarIDs == [
            fixture.scopedCalendarID("a-main"), fixture.scopedCalendarID("b-new")
        ])
        let freshName = explicitSelection ? "b-old" : "b-new"
        let events = try #require(outcome.events)
        fixture.expectMixedEvents(events, freshName: freshName)
        #expect(events.filter { $0.accountID == fixture.accountID("a") } == seeded.events.filter {
            $0.accountID == fixture.accountID("a")
        })
        #expect(events.first { $0.accountID == fixture.accountID("b") }?.isFromCache == false)
        let calendars = try #require(outcome.calendars)
        #expect(calendars.filter { $0.accountID == fixture.accountID("a") } == priorA.calendars)
        let saved = try #require(try fixture.cache.loadUnfiltered())
        fixture.expectMixedEvents(saved.events, freshName: freshName)
        #expect(saved.accounts[fixture.accountID("a")] == priorA)
        #expect(saved.cachedAt == seeded.cachedAt)
        let currentB = try #require(saved.accounts[fixture.accountID("b")])
        #expect(currentB.account == seeded.accounts[fixture.accountID("b")]?.account)
        #expect(currentB.calendars == calendars.filter { $0.accountID == fixture.accountID("b") })
        #expect(currentB.calendars.filter(\.isSelected).map(\.id) == [fixture.scopedCalendarID("b-new")])
        #expect(currentB.fetchedAt == fixture.requests.now)
        #expect(currentB.coverage == CalendarAccountCache.Coverage(
            calendarIDs: [fixture.scopedCalendarID(freshName)],
            window: .protective(now: fixture.requests.now, visibilityWindow: fixture.settings.snapshot.visibilityWindow)
        ))
        fixture.expectRequests(.changed, freshName: freshName)
        fixture.expectCredentialPreservation(keychain, original: originalCredentials)

        let savedBytes = try Data(contentsOf: fixture.cache.fileURL)
        let savedSettings = fixture.settings.snapshot
        if explicitSelection {
            #expect(coordinator.currentStatusMessage == "Some calendar accounts could not refresh; protection is incomplete.")
        }
        fixture.requests.move(to: .memoryFailure, at: explicitSelection ? 300 : 120)
        if explicitSelection {
            #expect(coordinator.currentStatusMessage?.contains("Calendar data may be stale.") == true)
            #expect(coordinator.currentStatusMessage?.contains("Some calendar accounts could not refresh") == true)
            #expect(try Data(contentsOf: fixture.cache.fileURL) == savedBytes)
            #expect(fixture.requests.count(.memoryFailure, "b.catalog") == 0)
        }

        let fromMemory = try #require(await coordinator.refresh(reason: "timer"))

        fixture.expectRetained(fromMemory, saved: saved, expectedA: priorA.account)
        #expect(try fixture.cache.loadUnfiltered() == saved)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == savedBytes)
        #expect(fixture.settings.snapshot == savedSettings)
        fixture.expectRequests(.memoryFailure, freshName: nil)
        fixture.expectCredentialPreservation(keychain, original: originalCredentials)

        let reloadedSettings = AppSettingsStore(domainName: fixture.marker)
        #expect(reloadedSettings.snapshot == savedSettings)
        fixture.requests.move(to: .restartFailure, at: explicitSelection ? 301 : 180)
        let restarted = fixture.makeCoordinator(client: fixture.makeClient(keychain), settings: reloadedSettings)

        let fromDisk = try #require(await restarted.refresh(reason: "launch"))

        fixture.expectRetained(fromDisk, saved: saved, expectedA: priorA.account)
        #expect(try fixture.cache.loadUnfiltered() == saved)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == savedBytes)
        #expect(reloadedSettings.snapshot == savedSettings)
        #expect(saved.accounts[fixture.accountID("a")]?.fetchedAt == priorA.fetchedAt)
        #expect(saved.accounts[fixture.accountID("a")]?.coverage == priorA.coverage)
        fixture.expectRequests(.restartFailure, freshName: nil)
        fixture.expectCredentialPreservation(keychain, original: originalCredentials)
    }

    enum Damage: CaseIterable, Sendable {
        case denied
        case missing
        case corrupt
    }

    private enum Phase: String, Sendable {
        case seed
        case changed
        case memoryFailure
        case restartFailure
    }

    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var phase: Phase = .seed
        private var elapsed: TimeInterval = 0
        private var counts: [String: Int] = [:]

        var now: Date {
            lock.withLock { TestDates.now.addingTimeInterval(elapsed) }
        }

        func move(to phase: Phase, at elapsed: TimeInterval) {
            lock.withLock {
                self.phase = phase
                self.elapsed = elapsed
            }
        }

        func record(_ phase: Phase, _ key: String) -> Bool {
            lock.withLock {
                guard self.phase == phase else { return false }
                counts["\(phase.rawValue):\(key)", default: 0] += 1
                return true
            }
        }

        func recordUnexpected(_ key: String) {
            lock.withLock { counts["\(phase.rawValue):\(key)", default: 0] += 1 }
        }

        func count(_ phase: Phase, _ key: String) -> Int {
            lock.withLock { counts["\(phase.rawValue):\(key)", default: 0] }
        }
    }

    private final class InventoryKeychain: KeychainStoring, @unchecked Sendable {
        private let lock = NSLock()
        private let deniedKeys: Set<String>
        private var values: [String: String]
        private var saves: [String] = []
        private var deletions: [String] = []

        init(values: [String: String], deniedKeys: Set<String>) {
            self.values = values
            self.deniedKeys = deniedKeys
        }

        var snapshot: [String: String] { lock.withLock { values } }
        var savedKeys: [String] { lock.withLock { saves } }
        var deletedKeys: [String] { lock.withLock { deletions } }

        func read(forKey key: String) throws -> String? {
            try lock.withLock {
                if deniedKeys.contains(key) { throw KeychainError.readFailed(-25308) }
                return values[key]
            }
        }

        func retrieve(forKey key: String) -> String? { try? read(forKey: key) }

        func save(_ value: String, forKey key: String) throws {
            lock.withLock {
                saves.append(key)
                values[key] = value
            }
        }

        func delete(forKey key: String) throws {
            lock.withLock {
                deletions.append(key)
                values.removeValue(forKey: key)
            }
        }
    }

    @MainActor
    private final class Fixture {
        let marker = "p14-inventory-integration-\(UUID().uuidString)"
        let requests = Requests()
        let directory: URL
        let defaults: UserDefaults
        let settings: AppSettingsStore
        let cache: EventCacheStore
        let session: URLSession
        let seedClient: GoogleOAuthClient

        init(explicitSelection: Bool) throws {
            directory = try TestTempDirectory.make()
            defaults = try #require(UserDefaults(suiteName: marker))
            defaults.removePersistentDomain(forName: marker)
            settings = AppSettingsStore(domainName: marker)
            cache = EventCacheStore(fileURL: directory.appending(path: "event-cache.json"))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubURLProtocol.self]
            configuration.httpAdditionalHeaders = ["X-Meeting-Shield-Test": marker]
            session = URLSession(configuration: configuration)
            seedClient = GoogleOAuthClient(
                configuration: GoogleOAuthConfiguration(clientID: "\(marker)-client"),
                keychain: InMemoryKeychain(), session: session,
                diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "seed-oauth"), nativeSink: { _, _ in })
            )
            for account in ["a", "b"] { try seedClient.saveToken(token(account)) }
            if explicitSelection {
                settings.update { $0.selectedCalendarIDs = [scopedCalendarID("a-main"), scopedCalendarID("b-old")] }
            }
            registerResponses()
        }

        func makeClient(_ keychain: InventoryKeychain) -> GoogleOAuthClient {
            GoogleOAuthClient(
                configuration: GoogleOAuthConfiguration(clientID: "\(marker)-client"),
                keychain: keychain, session: session,
                diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "damaged-oauth"), nativeSink: { _, _ in })
            )
        }

        func makeCoordinator(client: GoogleOAuthClient, settings override: AppSettingsStore? = nil) -> RefreshCoordinator {
            let store = override ?? settings
            let requests = requests
            return RefreshCoordinator(
                provider: GoogleCalendarProvider(oauthClient: client), cacheStore: cache,
                settings: { store.snapshot }, now: { requests.now },
                diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "refresh"), nativeSink: { _, _ in }),
                rememberProviderDefaults: { ids in store.update { $0.recordProviderDefaultCalendarIDs(ids) } }
            )
        }

        func seed() async throws -> EventCacheEnvelope {
            #expect(try cache.loadUnfiltered() == nil)
            let outcome = try #require(await makeCoordinator(client: seedClient).refresh(reason: "launch"))
            try #require(outcome.didSucceed)
            #expect(!outcome.skipped)
            #expect(outcome.statusMessage == nil)
            #expect(Set(try #require(outcome.events).map(\.eventID)) == [eventID("a-main", version: "seed"), eventID("b-old", version: "seed")])
            let saved = try #require(try cache.loadUnfiltered())
            #expect(saved.cachedAt == TestDates.now)
            for account in ["a", "b"] {
                let entry = try #require(saved.accounts[accountID(account)])
                #expect(entry.account == .init(id: accountID(account), displayName: displayName(account)))
                #expect(entry.fetchedAt == TestDates.now)
                #expect(entry.coverage?.calendarIDs == [scopedCalendarID(account == "a" ? "a-main" : "b-old")])
                #expect(requests.count(.seed, "\(account).catalog") == 1)
            }
            #expect(requests.count(.seed, "a-main.events") == 1)
            #expect(requests.count(.seed, "b-old.events") == 1)
            #expect(requests.count(.seed, "b-new.events") == 0)
            expectNoUnexpectedRequests(.seed)
            return saved
        }

        func damagedKeychain(_ damage: Damage) throws -> InventoryKeychain {
            let index = try JSONSerialization.data(withJSONObject: ["accountIDs": [accountID("a"), accountID("b")]])
            var values = [
                "google.oauth.tokens.index": String(decoding: index, as: UTF8.self),
                tokenKey("b"): String(decoding: try JSONEncoder().encode(token("b")), as: UTF8.self)
            ]
            switch damage {
            case .denied:
                values[tokenKey("a")] = String(decoding: try JSONEncoder().encode(token("a")), as: UTF8.self)
            case .missing:
                break
            case .corrupt:
                values[tokenKey("a")] = "{\"accessToken\":\"synthetic-corrupt-token\"}"
            }
            return InventoryKeychain(values: values, deniedKeys: damage == .denied ? [tokenKey("a")] : [])
        }

        func expectIncomplete(_ outcome: RefreshCoordinator.Outcome) {
            #expect(!outcome.didSucceed)
            #expect(!outcome.skipped)
            #expect(outcome.statusMessage?.isEmpty == false)
            if case .connected = outcome.authState {} else { Issue.record("Healthy B did not keep the provider connected") }
        }

        func expectAccountIdentity(_ outcome: RefreshCoordinator.Outcome, account: ConnectedCalendarAccount) {
            #expect(outcome.accounts.first { $0.id == account.id } == account)
            #expect(Set(outcome.accounts.map(\.id)) == [accountID("a"), accountID("b")])
        }

        func expectMixedEvents(_ events: [CalendarEventOccurrence], freshName: String) {
            #expect(events.count == 2)
            #expect(Set(events.map(\.eventID)) == [eventID("a-main", version: "seed"), eventID(freshName, version: "changed")])
            #expect(Set(events.map(\.calendarID)) == [scopedCalendarID("a-main"), scopedCalendarID(freshName)])
        }

        func expectRetained(_ outcome: RefreshCoordinator.Outcome, saved: EventCacheEnvelope, expectedA: ConnectedCalendarAccount) {
            expectIncomplete(outcome)
            expectAccountIdentity(outcome, account: expectedA)
            #expect(outcome.events == saved.events)
            #expect(outcome.events?.allSatisfy { $0.isFromCache } == true)
            #expect(Set(outcome.calendars ?? []) == Set(saved.accounts.values.flatMap(\.calendars)))
        }

        func expectRequests(_ phase: Phase, freshName: String?) {
            #expect(requests.count(phase, "a.catalog") == 0)
            #expect(requests.count(phase, "b.catalog") == 1)
            for name in ["a-main", "b-old", "b-new"] {
                #expect(requests.count(phase, "\(name).events") == (name == freshName ? 1 : 0))
            }
            expectNoUnexpectedRequests(phase)
        }

        func expectCredentialPreservation(_ keychain: InventoryKeychain, original: [String: String]) {
            #expect(keychain.snapshot == original)
            #expect(keychain.savedKeys.isEmpty)
            #expect(keychain.deletedKeys.isEmpty)
        }

        func cleanup() {
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: marker)
            try? FileManager.default.removeItem(at: directory)
        }

        func accountID(_ account: String) -> String { "\(marker)-\(account)@example.invalid" }
        func displayName(_ account: String) -> String { "Synthetic saved account \(account.uppercased())" }
        func calendarID(_ name: String) -> String { "\(marker)-\(name)" }
        func scopedCalendarID(_ name: String) -> String { "\(accountID(name.hasPrefix("a-") ? "a" : "b"))::\(calendarID(name))" }
        func eventID(_ name: String, version: String) -> String { "\(marker)-\(name)-\(version)" }

        private func token(_ account: String) -> GoogleOAuthToken {
            GoogleOAuthToken(
                accessToken: "access-\(marker)-\(account)", refreshToken: "refresh-\(marker)-\(account)",
                expiresAt: .distantFuture, scope: AppIdentity.googleScopes.joined(separator: " "), tokenType: "Bearer",
                accountID: accountID(account), accountDisplayName: displayName(account)
            )
        }

        private func tokenKey(_ account: String) -> String {
            let digest = SHA256.hash(data: Data(accountID(account).utf8))
            let prefix = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
            return "google.oauth.token.\(prefix)"
        }

        private func registerResponses() {
            for phase in [Phase.seed, .changed, .memoryFailure, .restartFailure] {
                let fails = phase == .memoryFailure || phase == .restartFailure
                for account in ["a", "b"] {
                    let names = account == "a" ? ["a-main"] : ["b-old", "b-new"]
                    let selected = account == "a" ? "a-main" : (phase == .seed ? "b-old" : "b-new")
                    let items = names.map { name in
                        "{\"id\":\"\(calendarID(name))\",\"summary\":\"Synthetic \(name) calendar\",\"selected\":\(name == selected),\"accessRole\":\"reader\"}"
                    }.joined(separator: ",")
                    register(phase, account: account, path: "/users/me/calendarList", key: "\(account).catalog",
                             json: fails ? "{}" : "{\"items\":[\(items)]}", status: fails ? 503 : 200)
                }
                guard !fails else { continue }
                for name in ["a-main", "b-old", "b-new"] {
                    register(phase, account: name.hasPrefix("a-") ? "a" : "b", path: "/calendars/\(calendarID(name))/events",
                             key: "\(name).events", json: eventPage(name, phase: phase), status: 200)
                }
            }
            let marker = marker
            let requests = requests
            StubURLProtocol.registerJSON(matcher: { request in
                guard request.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker else { return false }
                let host = request.url?.host ?? ""
                requests.recordUnexpected(host.contains("oauth") || host == "accounts.google.com" ? "oauth" : "unexpected")
                return true
            }, json: "{}", statusCode: 503)
        }

        private func register(_ phase: Phase, account: String, path: String, key: String, json: String, status: Int) {
            let marker = marker
            let requests = requests
            StubURLProtocol.registerJSON(matcher: { request in
                guard request.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker,
                      request.url?.host == "www.googleapis.com",
                      request.value(forHTTPHeaderField: "Authorization") == "Bearer access-\(marker)-\(account)",
                      request.url?.path.hasSuffix(path) == true, request.queryValues["pageToken"] == nil else { return false }
                return requests.record(phase, key)
            }, json: json, statusCode: status)
        }

        private func eventPage(_ name: String, phase: Phase) -> String {
            let start = ISO8601DateFormatter.stableString(from: TestDates.start)
            let end = ISO8601DateFormatter.stableString(from: TestDates.start.addingTimeInterval(1800))
            let id = eventID(name, version: phase == .seed ? "seed" : "changed")
            return "{\"items\":[{\"id\":\"\(id)\",\"status\":\"confirmed\",\"summary\":\"Synthetic meeting\",\"start\":{\"dateTime\":\"\(start)\"},\"end\":{\"dateTime\":\"\(end)\"}}]}"
        }

        private func expectNoUnexpectedRequests(_ phase: Phase) {
            #expect(requests.count(phase, "oauth") == 0)
            #expect(requests.count(phase, "unexpected") == 0)
            #expect(!StubURLProtocol.unmatched.contains { $0.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker })
        }
    }
}
