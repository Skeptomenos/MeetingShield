import Foundation
import Testing
@testable import MeetingShield

@Suite("Google default selection recovery")
struct GoogleDefaultRefreshRecoveryTests {
    @Test("New complete defaults filter the original cache when event fetching fails")
    @MainActor
    func completeDefaultSwitchRecoversNewlySelectedCachedCalendar() async throws {
        let fixture = try Fixture(scenario: .completeSwitch)
        defer { fixture.cleanup() }
        let coordinator = fixture.makeCoordinator()
        let seeded = try await fixture.seed(coordinator)
        let priorA = try #require(seeded.accounts[fixture.accountID("a")])
        fixture.settings.update {
            $0 = .defaults
            $0.recordProviderDefaultCalendarIDs([fixture.scopedCalendarID("b-main")])
        }
        fixture.requests.move(to: .changed)

        let outcome = try #require(await coordinator.refresh(reason: "timer"))

        #expect(!outcome.didSucceed)
        #expect(outcome.statusMessage?.isEmpty == false)
        #expect(!fixture.settings.snapshot.hasExplicitCalendarSelection)
        #expect(fixture.settings.snapshot.providerDefaultCalendarIDs == [fixture.scopedCalendarID("a-old")])
        fixture.expectEvents(try #require(outcome.events), names: ["a-old"], version: "seed")
        #expect(outcome.events?.allSatisfy { $0.isFromCache } == true)
        let saved = try #require(try fixture.cache.loadUnfiltered())
        fixture.expectEvents(saved.events, names: ["a-old"], version: "seed")
        #expect(saved.accounts[fixture.accountID("a")]?.fetchedAt == priorA.fetchedAt)
        #expect(saved.accounts[fixture.accountID("a")]?.coverage == priorA.coverage)
        #expect(fixture.requests.count(.changed, "a.catalog") == 1)
        #expect(fixture.requests.count(.changed, "b.catalog") == 1)
        #expect(fixture.requests.count(.changed, "a-old.events") == 1)
        #expect(fixture.requests.count(.changed, "b-main.events") == 0)

        try await fixture.expectOfflineRestart(names: ["a-old"], freshName: nil, saved: saved)
    }

    @Test("Successful account defaults advance while a failed account keeps its remembered defaults")
    @MainActor
    func partialDiscoveryPersistsNewDefaultAndRetainsFailedAccount() async throws {
        let fixture = try Fixture(scenario: .partialDiscovery)
        defer { fixture.cleanup() }
        let coordinator = fixture.makeCoordinator()
        let seeded = try await fixture.seed(coordinator)
        fixture.requests.move(to: .changed)

        let outcome = try #require(await coordinator.refresh(reason: "timer"))

        #expect(!outcome.didSucceed)
        #expect(outcome.statusMessage?.isEmpty == false)
        #expect(!fixture.settings.snapshot.hasExplicitCalendarSelection)
        #expect(fixture.settings.snapshot.providerDefaultCalendarIDs == [
            fixture.scopedCalendarID("a-new"), fixture.scopedCalendarID("b-main")
        ])
        fixture.expectMixedEvents(try #require(outcome.events), freshName: "a-new")
        #expect(outcome.events?.first { $0.calendarID == fixture.scopedCalendarID("a-new") }?.isFromCache == false)
        #expect(outcome.events?.first { $0.calendarID == fixture.scopedCalendarID("b-main") }?.isFromCache == true)
        let saved = try #require(try fixture.cache.loadUnfiltered())
        fixture.expectMixedEvents(saved.events, freshName: "a-new")
        #expect(saved.accounts[fixture.accountID("b")] == seeded.accounts[fixture.accountID("b")])
        #expect(saved.accounts[fixture.accountID("a")]?.coverage?.calendarIDs == [fixture.scopedCalendarID("a-new")])
        #expect(saved.accounts[fixture.accountID("a")]?.fetchedAt == fixture.requests.now)
        #expect(fixture.requests.count(.changed, "a.catalog") == 1)
        #expect(fixture.requests.count(.changed, "b.catalog") == 1)
        #expect(fixture.requests.count(.changed, "a-new.events") == 1)
        #expect(fixture.requests.count(.changed, "a-old.events") == 0)
        #expect(fixture.requests.count(.changed, "b-main.events") == 0)

        try await fixture.expectOfflineRestart(names: ["a-new", "b-main"], freshName: "a-new", saved: saved)
    }

    @Test("Explicit selection stays authoritative when another account's discovery fails")
    @MainActor
    func explicitSelectionOverridesChangedGoogleDefaults() async throws {
        let fixture = try Fixture(scenario: .partialDiscovery, explicitSelection: true)
        defer { fixture.cleanup() }
        let coordinator = fixture.makeCoordinator()
        let seeded = try await fixture.seed(coordinator)
        let selected = fixture.settings.snapshot.selectedCalendarIDs
        fixture.requests.move(to: .changed)

        let outcome = try #require(await coordinator.refresh(reason: "timer"))

        #expect(!outcome.didSucceed)
        #expect(outcome.statusMessage?.isEmpty == false)
        #expect(fixture.settings.snapshot.hasExplicitCalendarSelection)
        #expect(fixture.settings.snapshot.selectedCalendarIDs == selected)
        fixture.expectMixedEvents(try #require(outcome.events), freshName: "a-old")
        let saved = try #require(try fixture.cache.loadUnfiltered())
        fixture.expectMixedEvents(saved.events, freshName: "a-old")
        #expect(saved.accounts[fixture.accountID("b")] == seeded.accounts[fixture.accountID("b")])
        #expect(saved.accounts[fixture.accountID("a")]?.coverage?.calendarIDs == [fixture.scopedCalendarID("a-old")])
        #expect(fixture.requests.count(.changed, "a-old.events") == 1)
        #expect(fixture.requests.count(.changed, "a-new.events") == 0)
        #expect(fixture.requests.count(.changed, "b-main.events") == 0)

        try await fixture.expectOfflineRestart(names: ["a-old", "b-main"], freshName: "a-old", saved: saved)
    }

    private enum Scenario: Sendable {
        case completeSwitch
        case partialDiscovery
    }

    private enum Phase: Int, Sendable {
        case seed
        case changed
        case offline
    }

    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var phase: Phase = .seed
        private var counts: [String: Int] = [:]

        var now: Date {
            lock.withLock { TestDates.now.addingTimeInterval(TimeInterval(phase.rawValue * 60)) }
        }

        func move(to phase: Phase) {
            lock.withLock { self.phase = phase }
        }

        func record(_ phase: Phase, _ key: String) -> Bool {
            lock.withLock {
                guard self.phase == phase else { return false }
                counts["\(phase.rawValue):\(key)", default: 0] += 1
                return true
            }
        }

        func count(_ phase: Phase, _ key: String) -> Int {
            lock.withLock { counts["\(phase.rawValue):\(key)", default: 0] }
        }
    }

    @MainActor
    private final class Fixture {
        let marker = "p14-defaults-\(UUID().uuidString)"
        let requests = Requests()
        let scenario: Scenario
        let directory: URL
        let defaults: UserDefaults
        let settings: AppSettingsStore
        let cache: EventCacheStore
        let session: URLSession
        let client: GoogleOAuthClient

        init(scenario: Scenario, explicitSelection: Bool = false) throws {
            self.scenario = scenario
            directory = try TestTempDirectory.make()
            defaults = try #require(UserDefaults(suiteName: marker))
            defaults.removePersistentDomain(forName: marker)
            settings = AppSettingsStore(domainName: marker)
            cache = EventCacheStore(fileURL: directory.appending(path: "event-cache.json"))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubURLProtocol.self]
            configuration.httpAdditionalHeaders = ["X-Meeting-Shield-Test": marker]
            session = URLSession(configuration: configuration)
            client = GoogleOAuthClient(
                configuration: GoogleOAuthConfiguration(clientID: "\(marker)-client"),
                keychain: InMemoryKeychain(), session: session,
                diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "oauth"), nativeSink: { _, _ in })
            )
            for account in ["a", "b"] {
                try client.saveToken(
                    GoogleOAuthToken(
                        accessToken: "access-\(marker)-\(account)", refreshToken: "refresh-\(marker)-\(account)",
                        expiresAt: .distantFuture, scope: AppIdentity.googleScopes.joined(separator: " "), tokenType: "Bearer"
                    ),
                    accountID: accountID(account), accountDisplayName: "Synthetic \(account)"
                )
            }
            if scenario == .completeSwitch || explicitSelection {
                settings.update { $0.selectedCalendarIDs = [scopedCalendarID("a-old"), scopedCalendarID("b-main")] }
            }
            registerResponses()
        }

        func makeCoordinator(settings override: AppSettingsStore? = nil) -> RefreshCoordinator {
            let store = override ?? settings
            let requests = requests
            return RefreshCoordinator(
                provider: GoogleCalendarProvider(oauthClient: client), cacheStore: cache,
                settings: { store.snapshot }, now: { requests.now },
                diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "refresh"), nativeSink: { _, _ in }),
                rememberProviderDefaults: { ids in store.update { $0.recordProviderDefaultCalendarIDs(ids) } }
            )
        }

        func seed(_ coordinator: RefreshCoordinator) async throws -> EventCacheEnvelope {
            #expect(try cache.loadUnfiltered() == nil)
            let outcome = try #require(await coordinator.refresh(reason: "launch"))
            try #require(outcome.didSucceed)
            #expect(outcome.statusMessage == nil)
            expectEvents(try #require(outcome.events), names: ["a-old", "b-main"], version: "seed")
            let saved = try #require(try cache.loadUnfiltered())
            expectEvents(saved.events, names: ["a-old", "b-main"], version: "seed")
            for account in ["a", "b"] {
                let entry = try #require(saved.accounts[accountID(account)])
                #expect(entry.fetchedAt == TestDates.now)
                #expect(entry.coverage?.calendarIDs == [scopedCalendarID(account == "a" ? "a-old" : "b-main")])
                #expect(requests.count(.seed, "\(account).catalog") == 1)
            }
            #expect(requests.count(.seed, "a-old.events") == 1)
            #expect(requests.count(.seed, "b-main.events") == 1)
            #expect(requests.count(.seed, "a-new.events") == 0)
            expectNoUnmatchedRequests()
            return saved
        }

        func expectOfflineRestart(names: Set<String>, freshName: String?, saved: EventCacheEnvelope) async throws {
            let savedBytes = try Data(contentsOf: cache.fileURL)
            let reloaded = AppSettingsStore(domainName: marker)
            #expect(reloaded.snapshot == settings.snapshot)
            requests.move(to: .offline)
            let restarted = makeCoordinator(settings: reloaded)
            let outcome = try #require(await restarted.refresh(reason: "launch"))
            #expect(!outcome.didSucceed)
            #expect(outcome.statusMessage?.isEmpty == false)
            let events = try #require(outcome.events)
            if let freshName {
                expectMixedEvents(events, freshName: freshName)
            } else {
                expectEvents(events, names: names, version: "seed")
            }
            #expect(events.allSatisfy { $0.isFromCache })
            #expect(try cache.loadUnfiltered() == saved)
            #expect(try Data(contentsOf: cache.fileURL) == savedBytes)
            #expect(reloaded.snapshot == settings.snapshot)
            for account in ["a", "b"] { #expect(requests.count(.offline, "\(account).catalog") == 1) }
            expectNoUnmatchedRequests()
        }

        func expectEvents(_ events: [CalendarEventOccurrence], names: Set<String>, version: String) {
            #expect(events.count == names.count)
            #expect(Set(events.map(\.eventID)) == Set(names.map { eventID($0, version: version) }))
            #expect(Set(events.map(\.calendarID)) == Set(names.map(scopedCalendarID)))
        }

        func expectMixedEvents(_ events: [CalendarEventOccurrence], freshName: String) {
            #expect(events.count == 2)
            #expect(Set(events.map(\.eventID)) == [eventID(freshName, version: "changed"), eventID("b-main", version: "seed")])
            #expect(Set(events.map(\.calendarID)) == [scopedCalendarID(freshName), scopedCalendarID("b-main")])
        }

        func cleanup() {
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: marker)
            try? FileManager.default.removeItem(at: directory)
        }

        func accountID(_ account: String) -> String { "\(marker)-\(account)@example.invalid" }
        func calendarID(_ name: String) -> String { "\(marker)-\(name)" }
        func scopedCalendarID(_ name: String) -> String { "\(accountID(name.hasPrefix("a-") ? "a" : "b"))::\(calendarID(name))" }
        func eventID(_ name: String, version: String) -> String { "\(marker)-\(name)-\(version)" }

        private func registerResponses() {
            for phase in [Phase.seed, .changed, .offline] {
                for account in ["a", "b"] {
                    let fails = phase == .offline || (phase == .changed && scenario == .partialDiscovery && account == "b")
                    let names = account == "a" ? ["a-old", "a-new"] : ["b-main"]
                    let items = names.map { name in
                        let selected: Bool
                        if phase == .seed {
                            selected = name == "b-main" || (name == "a-old" && scenario == .partialDiscovery)
                        } else {
                            selected = scenario == .completeSwitch ? name == "a-old" : name != "a-old"
                        }
                        return "{\"id\":\"\(calendarID(name))\",\"summary\":\"Synthetic calendar\",\"selected\":\(selected),\"accessRole\":\"reader\"}"
                    }.joined(separator: ",")
                    register(phase, account: account, path: "/users/me/calendarList", key: "\(account).catalog",
                             json: fails ? "{}" : "{\"items\":[\(items)]}", status: fails ? 503 : 200)
                }
                guard phase != .offline else { continue }
                for name in ["a-old", "a-new", "b-main"] {
                    let fails = phase == .changed && scenario == .completeSwitch && name == "a-old"
                    register(phase, account: name.hasPrefix("a-") ? "a" : "b", path: "/calendars/\(calendarID(name))/events",
                             key: "\(name).events", json: fails ? "{}" : eventPage(name, phase: phase), status: fails ? 503 : 200)
                }
            }
        }

        private func register(_ phase: Phase, account: String, path: String, key: String, json: String, status: Int) {
            let marker = marker
            let requests = requests
            StubURLProtocol.registerJSON(matcher: { request in
                guard request.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker,
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

        private func expectNoUnmatchedRequests() {
            #expect(StubURLProtocol.unmatched.filter { $0.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker }.isEmpty)
        }
    }
}
