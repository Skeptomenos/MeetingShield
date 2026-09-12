import Foundation
import Testing
@testable import MeetingShield

@Suite("Google account coverage health")
@MainActor
struct GoogleAccountCoverageHealthTests {
    @Test("A newly selected calendar without a completed fetch remains explicitly uncovered after partial refresh and restart")
    func selectedCalendarDeficitSurvivesPartialRefreshAndRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        try await fixture.seed(coordinator)
        let originalB = try fixture.account("b")
        fixture.selectSecondary()
        expectUnfetchedSelection(coordinator.currentStatusMessage)
        #expect(try fixture.account("b") == originalB)
        fixture.requests.move(to: .failed)
        fixture.requests.advance(by: 60)

        let partial = try #require(await coordinator.refresh(reason: "settings"))

        #expect(!partial.didSucceed)
        expectUnfetchedSelection(partial.statusMessage)
        expectUnfetchedSelection(coordinator.currentStatusMessage)
        #expect(try fixture.account("b") == originalB)
        #expect(try fixture.account("a").fetchedAt == fixture.requests.now)
        fixture.expectMixedEvents(try #require(partial.events))
        #expect(fixture.requests.count(.seed, "b-secondary.events") == 0)
        #expect(fixture.requests.count(.failed, "b-secondary.events") == 1)
        let saved = try Data(contentsOf: fixture.cache.fileURL)
        try fixture.goOffline()

        let restarted = fixture.coordinator()
        let offline = try #require(await restarted.refresh(reason: "launch"))

        #expect(!offline.didSucceed)
        expectUnfetchedSelection(offline.statusMessage)
        expectUnfetchedSelection(restarted.currentStatusMessage)
        #expect(try fixture.account("b") == originalB)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == saved)
        #expect(offline.events?.allSatisfy { $0.isFromCache } == true)
        fixture.expectMixedEvents(try #require(offline.events))
        fixture.expectNoUnmatchedRequests()
    }

    @Test("A failed account's cached meeting stays scheduled and becomes due while another account refreshes")
    func partialRefreshRetainsCachedControllerReminders() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.settings.update {
            $0.defaultLeadTime = 120
            $0.presentationModeDefault = true
            $0.soundEnabled = false
            $0.urgentRepeatSoundEnabled = false
            $0.wakeGraceEnabled = false
        }
        let controller = MeetingShieldController(
            settingsStore: fixture.settings,
            provider: GoogleCalendarProvider(oauthClient: fixture.client),
            reminderStateStore: ReminderStateStore(fileURL: fixture.directory.appending(path: "state.json")),
            cacheStore: fixture.cache,
            notificationService: NoopNotificationService(),
            now: { fixture.requests.now }, refreshMenuBar: {}
        )
        await controller.refresh(reason: "launch")
        let bID = fixture.eventID("b-main", old: true)
        let originalB = try #require(controller.scheduledReminders.first { $0.event.eventID == bID })
        #expect(controller.activeReminders.isEmpty)
        fixture.selectSecondary()
        fixture.requests.move(to: .failed)
        fixture.requests.advance(by: 60)

        await controller.refresh(reason: "settings")

        expectUnfetchedSelection(controller.statusMessage)
        let retainedB = try #require(controller.scheduledReminders.first { $0.event.eventID == bID })
        #expect(retainedB.id == originalB.id)
        #expect(retainedB.fireDate == originalB.fireDate)
        #expect(retainedB.event.isFromCache)
        #expect(controller.events.contains { $0.eventID == fixture.eventID("a-main", old: false) && !$0.isFromCache })
        #expect(controller.activeReminders.isEmpty)
        fixture.requests.advance(by: originalB.fireDate.timeIntervalSince(fixture.requests.now))

        await controller.refresh(reason: "timer")

        expectUnfetchedSelection(controller.statusMessage)
        let dueB = try #require(controller.activeReminders.first { $0.event.eventID == bID })
        #expect(dueB.id == originalB.id)
        #expect(dueB.event.isFromCache)
        #expect(controller.isPresentationMode)
        #expect(controller.fallback == nil)
        fixture.settings.update { $0.selectedCalendarIDs = [] }
        await controller.refresh(reason: "settings")
        #expect(controller.scheduledReminders.isEmpty)
        #expect(controller.activeReminders.isEmpty)
        fixture.expectNoUnmatchedRequests()
    }

    @Test("Complete empty selected calendars establish coverage and clear the deficit, including offline restart")
    func completeEmptyFetchEstablishesCoverage() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        try await fixture.seed(coordinator)
        fixture.selectSecondary()
        fixture.requests.move(to: .failed)
        let partial = try #require(await coordinator.refresh(reason: "settings"))
        expectUnfetchedSelection(partial.statusMessage)
        fixture.requests.move(to: .recovered)
        fixture.requests.advance(by: 60)

        let recovered = try #require(await coordinator.refresh(reason: "timer"))

        #expect(recovered.didSucceed)
        #expect(recovered.statusMessage == nil)
        #expect(coordinator.currentStatusMessage == nil)
        #expect(recovered.events?.contains { $0.accountID == fixture.accountID("b") } == false)
        let b = try fixture.account("b")
        #expect(b.fetchedAt == fixture.requests.now)
        #expect(b.coverage?.calendarIDs == [fixture.calendarID("b-main"), fixture.calendarID("b-secondary")])
        #expect(b.coverage?.window == CalendarFetchWindow.protective(
            now: fixture.requests.now, visibilityWindow: fixture.settings.snapshot.visibilityWindow
        ))
        #expect(fixture.requests.count(.recovered, "b-main.events") == 1)
        #expect(fixture.requests.count(.recovered, "b-secondary.events") == 1)
        let saved = try Data(contentsOf: fixture.cache.fileURL)
        try fixture.goOffline()

        let offline = try #require(await fixture.coordinator().refresh(reason: "launch"))

        #expect(!offline.didSucceed)
        #expect(!hasUnfetchedSelection(offline.statusMessage))
        #expect(!hasUnknownCoverage(offline.statusMessage))
        #expect(try fixture.account("b") == b)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == saved)
        fixture.expectNoUnmatchedRequests()
    }

    @Test("Removing an uncovered selection removes its deficit without waiting for another fetch", arguments: SelectionRemoval.allCases)
    func selectionRemovalClearsDeficit(removal: SelectionRemoval) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        try await fixture.seed(coordinator)
        fixture.selectSecondary()
        fixture.requests.move(to: .failed)
        let partial = try #require(await coordinator.refresh(reason: "settings"))
        expectUnfetchedSelection(partial.statusMessage)

        fixture.settings.update {
            switch removal {
            case .deselectCalendar: $0.selectedCalendarIDs.remove(fixture.calendarID("b-secondary"))
            case .disableAccount: $0.disabledGoogleAccountIDs.insert(fixture.accountID("b"))
            }
        }
        #expect(coordinator.settingsDidChange())
        #expect(!hasUnfetchedSelection(coordinator.currentStatusMessage))
        #expect(!hasUnknownCoverage(coordinator.currentStatusMessage))
        try fixture.goOffline()

        let offline = try #require(await coordinator.refresh(reason: "settings"))
        let restarted = try #require(await fixture.coordinator().refresh(reason: "launch"))

        for outcome in [offline, restarted] {
            #expect(!hasUnfetchedSelection(outcome.statusMessage))
            #expect(!hasUnknownCoverage(outcome.statusMessage))
        }
        fixture.expectNoUnmatchedRequests()
    }

    @Test("Legacy caches cannot establish account coverage, and only a complete fetch resolves the unknown", arguments: [false, true])
    func legacyCoverageStaysUnknownUntilCompleteFetch(hasOldEvent: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.selectSecondary()
        let oldDate = TestDates.now.addingTimeInterval(-600)
        let events = hasOldEvent ? [fixture.legacyEvent()] : []
        let legacy = LegacyEnvelope(cachedAt: oldDate, events: events)
        try JSONEncoder().encode(legacy).write(to: fixture.cache.fileURL)
        #expect(try fixture.cache.loadUnfiltered()?.accounts.isEmpty == true)
        fixture.requests.move(to: .failed)
        let coordinator = fixture.coordinator()

        let partial = try #require(await coordinator.refresh(reason: "launch"))

        #expect(!partial.didSucceed)
        expectUnknownCoverage(partial.statusMessage)
        expectUnknownCoverage(coordinator.currentStatusMessage)
        let b = try fixture.account("b")
        #expect(b.coverage == nil)
        #expect(b.fetchedAt == (hasOldEvent ? oldDate : nil))
        let retainedB = try #require(partial.events).filter { $0.accountID == fixture.accountID("b") }
        #expect(retainedB.map(\.eventID) == events.map(\.eventID))
        #expect(retainedB.allSatisfy { $0.isFromCache })
        if hasOldEvent {
            #expect(try fixture.cache.loadUnfiltered()?.cachedAt == oldDate)
        }
        #expect(try fixture.account("a").fetchedAt == fixture.requests.now)
        let saved = try Data(contentsOf: fixture.cache.fileURL)
        try fixture.goOffline()
        let restarted = fixture.coordinator()

        let offline = try #require(await restarted.refresh(reason: "launch"))

        expectUnknownCoverage(offline.statusMessage)
        #expect(try fixture.account("b") == b)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == saved)
        try fixture.restoreTokens()
        fixture.requests.move(to: .recovered)
        fixture.requests.advance(by: 60)

        let recovered = try #require(await restarted.refresh(reason: "timer"))

        #expect(recovered.didSucceed)
        #expect(recovered.statusMessage == nil)
        #expect(restarted.currentStatusMessage == nil)
        #expect(try fixture.account("b").fetchedAt == fixture.requests.now)
        #expect(try fixture.account("b").coverage?.calendarIDs == [fixture.calendarID("b-main"), fixture.calendarID("b-secondary")])
        #expect(recovered.events?.contains { $0.accountID == fixture.accountID("b") } == false)
        fixture.expectNoUnmatchedRequests()
    }

    @Test("Exhausted fetched coverage stays explicit when another account refreshes and after restart")
    func exhaustedWindowIsNotHiddenByFreshAccount() async throws {
        let fixture = try Fixture(failCatalog: true)
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        try await fixture.seed(coordinator)
        let originalB = try fixture.account("b")
        let coverage = try #require(originalB.coverage)
        #expect(coverage.window.end == TestDates.now.addingTimeInterval(24 * 60 * 60))
        fixture.requests.advance(by: 24 * 60 * 60 + 1)
        fixture.requests.move(to: .failed)

        let partial = try #require(await coordinator.refresh(reason: "timer"))

        #expect(!partial.didSucceed)
        expectExhaustedCoverage(partial.statusMessage)
        expectExhaustedCoverage(coordinator.currentStatusMessage)
        #expect(try fixture.account("a").fetchedAt == fixture.requests.now)
        #expect(try fixture.account("b") == originalB)
        let saved = try Data(contentsOf: fixture.cache.fileURL)
        try fixture.goOffline()

        let offline = try #require(await fixture.coordinator().refresh(reason: "launch"))

        expectExhaustedCoverage(offline.statusMessage)
        #expect(try fixture.account("b") == originalB)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == saved)
        fixture.expectNoUnmatchedRequests()
    }

    @Test("Cold fallback retains both the failure reason and persisted account coverage deficits", arguments: ColdFallback.allCases, CoverageDeficit.allCases)
    func coldFallbackShowsPersistedCoverage(fallback: ColdFallback, deficit: CoverageDeficit) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.seed(fixture.coordinator())
        switch deficit {
        case .unfetched:
            fixture.selectSecondary()
        case .unknown:
            var envelope = try #require(try fixture.cache.loadUnfiltered())
            envelope.accounts[fixture.accountID("b")]?.coverage = nil
            try fixture.cache.save(envelope: envelope, settings: fixture.settings.snapshot)
        case .exhausted:
            fixture.requests.advance(by: 24 * 60 * 60 + 1)
        }
        let saved = try Data(contentsOf: fixture.cache.fileURL)
        let metadata = try #require(try fixture.cache.loadUnfiltered()).accounts
        let provider = fixture.fallbackProvider(fallback)
        let coordinator = fixture.coordinator(provider: provider)

        let outcome = try #require(await coordinator.refresh(reason: "launch"))

        #expect(!outcome.didSucceed)
        #expect(outcome.skipped == (fallback != .catalogFailure))
        expectFallbackReason(outcome.statusMessage, fallback: fallback)
        expectCoverage(outcome.statusMessage, deficit: deficit)
        #expect(coordinator.currentStatusMessage == outcome.statusMessage)
        #expect(outcome.events?.count == (deficit == .exhausted ? 0 : 2))
        #expect(outcome.events?.allSatisfy { $0.isFromCache } == true)
        #expect(Set(outcome.accounts.map(\.id)) == Set(metadata.keys))
        #expect(await provider.catalogCalls == (fallback == .catalogFailure ? 1 : 0))
        #expect(await provider.eventCalls == 0)
        #expect(try fixture.cache.loadUnfiltered()?.accounts == metadata)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == saved)
        fixture.expectNoUnmatchedRequests()
    }

    @Test("Cold fallback cannot infer coverage from an old legacy timestamp or cached events", arguments: ColdFallback.allCases, [false, true])
    func coldLegacyFallbackRemainsUnknown(fallback: ColdFallback, hasOldEvent: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.selectSecondary()
        let oldDate = TestDates.now.addingTimeInterval(-600)
        let events = hasOldEvent ? [fixture.legacyEvent()] : []
        try JSONEncoder().encode(LegacyEnvelope(cachedAt: oldDate, events: events)).write(to: fixture.cache.fileURL)
        let saved = try Data(contentsOf: fixture.cache.fileURL)
        let provider = fixture.fallbackProvider(fallback)
        let coordinator = fixture.coordinator(provider: provider)

        let outcome = try #require(await coordinator.refresh(reason: "launch"))

        #expect(!outcome.didSucceed)
        #expect(outcome.skipped == (fallback != .catalogFailure))
        expectFallbackReason(outcome.statusMessage, fallback: fallback)
        expectUnknownCoverage(outcome.statusMessage)
        #expect(coordinator.currentStatusMessage == outcome.statusMessage)
        #expect(outcome.events?.map(\.eventID) == events.map(\.eventID))
        #expect(Set(outcome.accounts.map(\.id)) == [fixture.accountID("a"), fixture.accountID("b")])
        let retained = try #require(try fixture.cache.loadUnfiltered())
        #expect(retained.cachedAt == oldDate)
        #expect(retained.accounts.isEmpty)
        #expect(retained.accounts[fixture.accountID("b")]?.fetchedAt == nil)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == saved)
        #expect(await provider.catalogCalls == (fallback == .catalogFailure ? 1 : 0))
        #expect(await provider.eventCalls == 0)
        fixture.expectNoUnmatchedRequests()
    }

    @Test("A complete generic refresh resolves legacy uncertainty even when its result is empty", arguments: [false, true])
    func completeGenericRefreshClearsLegacyUncertainty(hasFreshEvent: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.settings.update { $0.selectedCalendarIDs = [fixture.calendarID("b-main")] }
        let oldDate = TestDates.now.addingTimeInterval(-600)
        try JSONEncoder().encode(LegacyEnvelope(cachedAt: oldDate, events: [fixture.legacyEvent()])).write(to: fixture.cache.fileURL)
        let coordinator = fixture.coordinator(provider: fixture.fallbackProvider(.catalogFailure))
        let failed = try #require(await coordinator.refresh(reason: "launch"))
        expectUnknownCoverage(failed.statusMessage)
        var event = fixture.legacyEvent()
        event.eventID = fixture.eventID("b-main", old: false)
        event.isFromCache = false
        let events = hasFreshEvent ? [event] : []
        let calendar = UserCalendar(
            id: fixture.calendarID("b-main"), accountID: fixture.accountID("b"),
            displayName: "Synthetic calendar", isPrimary: true, isSelected: true
        )
        let provider = FallbackProvider(
            auth: .connected(accountEmail: fixture.accountID("b")), knownAccounts: [
                ConnectedCalendarAccount(id: fixture.accountID("b"), displayName: "Synthetic account b")
            ], failsCatalog: false, calendarValues: [calendar], eventValues: events
        )
        coordinator.provider = provider

        let recovered = try #require(await coordinator.refresh(reason: "reconnect"))

        #expect(recovered.didSucceed)
        #expect(recovered.statusMessage == nil)
        #expect(coordinator.currentStatusMessage == nil)
        #expect(recovered.events?.map(\.eventID) == events.map(\.eventID))
        #expect(recovered.events?.allSatisfy { !$0.isFromCache } == true)
        let stored = try #require(try fixture.cache.loadUnfiltered())
        #expect(stored.cachedAt == fixture.requests.now)
        let account = try #require(stored.accounts[fixture.accountID("b")])
        #expect(account.calendars == [calendar])
        #expect(account.fetchedAt == fixture.requests.now)
        #expect(account.coverage == CalendarAccountCache.Coverage(
            calendarIDs: [calendar.id],
            window: .protective(now: fixture.requests.now, visibilityWindow: fixture.settings.snapshot.visibilityWindow)
        ))
        let storedBytes = try Data(contentsOf: fixture.cache.fileURL)
        let restarted = fixture.coordinator(provider: fixture.fallbackProvider(.disconnected))
        let offline = try #require(await restarted.refresh(reason: "launch"))
        #expect(offline.skipped)
        #expect(!offline.didSucceed)
        expectFallbackReason(offline.statusMessage, fallback: .disconnected)
        #expect(!hasUnknownCoverage(offline.statusMessage))
        #expect(!hasUnfetchedSelection(offline.statusMessage))
        #expect(offline.events?.map(\.eventID) == events.map(\.eventID))
        #expect(offline.events?.allSatisfy { $0.isFromCache } == true)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == storedBytes)
        #expect(await provider.catalogCalls == 1)
        #expect(await provider.eventCalls == 1)
        fixture.expectNoUnmatchedRequests()
    }

    enum ColdFallback: CaseIterable, Sendable {
        case disconnected, needsConfiguration, catalogFailure
    }

    enum CoverageDeficit: CaseIterable, Sendable {
        case unfetched, unknown, exhausted
    }

    enum SelectionRemoval: CaseIterable, Sendable {
        case deselectCalendar, disableAccount
    }

    private func hasUnfetchedSelection(_ status: String?) -> Bool {
        guard let status = status?.lowercased(), status.contains("selected"), status.contains("calendar") else { return false }
        return ["unfetched", "not fetched", "not been fetched", "not yet fetched", "without fetched coverage", "no fetched coverage", "uncovered", "not covered"].contains { status.contains($0) }
    }

    private func expectUnfetchedSelection(_ status: String?) {
        #expect(hasUnfetchedSelection(status), "Status must state that selected calendars have no fetched coverage; generic stale or incomplete text is insufficient. Actual: \(status ?? "nil")")
    }

    private func hasUnknownCoverage(_ status: String?) -> Bool {
        guard let status = status?.lowercased(), status.contains("coverage") else { return false }
        return ["unknown", "not known", "unverified", "cannot be verified", "not verified"].contains { status.contains($0) }
    }

    private func expectUnknownCoverage(_ status: String?) {
        #expect(hasUnknownCoverage(status), "Status must identify unknown coverage, not merely an old or incomplete refresh. Actual: \(status ?? "nil")")
    }

    private func expectExhaustedCoverage(_ status: String?) {
        let message = status?.lowercased() ?? ""
        let namesCoverage = ["coverage", "protection", "fetched window"].contains { message.contains($0) }
        let explainsEnd = ["exhaust", "expired", "ended", "no longer", "does not cover", "outside", "beyond"].contains { message.contains($0) }
        #expect(namesCoverage && explainsEnd, "Status must state that the fetched protection window ended; age alone does not explain coverage. Actual: \(status ?? "nil")")
    }

    private func expectFallbackReason(_ status: String?, fallback: ColdFallback) {
        let message = status?.lowercased() ?? ""
        switch fallback {
        case .disconnected, .needsConfiguration:
            #expect(message.contains("connect") || message.contains("configur"), "The saved coverage warning must retain the connection or configuration reason. Actual: \(status ?? "nil")")
        case .catalogFailure:
            #expect(message.contains("calendar") && (message.contains("failed") || message.contains("failing")), "The saved coverage warning must retain the calendar refresh failure reason. Actual: \(status ?? "nil")")
        }
    }

    private func expectCoverage(_ status: String?, deficit: CoverageDeficit) {
        switch deficit {
        case .unfetched: expectUnfetchedSelection(status)
        case .unknown: expectUnknownCoverage(status)
        case .exhausted: expectExhaustedCoverage(status)
        }
    }

    private actor FallbackProvider: CalendarProvider {
        nonisolated let providerID = "google"
        let auth: CalendarProviderAuthState
        let knownAccounts: [ConnectedCalendarAccount]
        let failsCatalog: Bool
        let calendarValues: [UserCalendar]
        let eventValues: [CalendarEventOccurrence]
        private(set) var catalogCalls = 0
        private(set) var eventCalls = 0

        init(
            auth: CalendarProviderAuthState, knownAccounts: [ConnectedCalendarAccount], failsCatalog: Bool,
            calendarValues: [UserCalendar] = [], eventValues: [CalendarEventOccurrence] = []
        ) {
            self.auth = auth
            self.knownAccounts = knownAccounts
            self.failsCatalog = failsCatalog
            self.calendarValues = calendarValues
            self.eventValues = eventValues
        }

        var authState: CalendarProviderAuthState { get async { auth } }
        func accounts() async -> [ConnectedCalendarAccount] { knownAccounts }

        func calendars() async throws -> [UserCalendar] {
            catalogCalls += 1
            if failsCatalog { throw CalendarProviderError.requestFailed(503) }
            return calendarValues
        }

        func events(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
            try await refresh(in: window)
        }

        func refresh(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
            try await refresh(in: window, calendars: calendarValues)
        }

        func refresh(in window: CalendarFetchWindow, calendars: [UserCalendar]) async throws -> [CalendarEventOccurrence] {
            eventCalls += 1
            let selected = Set(calendars.map(\.id))
            return eventValues.filter { selected.contains($0.calendarID) }
        }

        func reconnect() async throws {}
        func removeAccount(id: String) async throws {}
    }

    private struct LegacyEnvelope: Encodable {
        let cachedAt: Date
        let events: [CalendarEventOccurrence]
    }

    private enum Phase: String, Sendable {
        case seed, failed, recovered, offline
    }

    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var phase = Phase.seed
        private var counts: [String: Int] = [:]
        private var date = TestDates.now

        var now: Date { lock.withLock { date } }
        func advance(by interval: TimeInterval) { lock.withLock { date += interval } }
        func move(to phase: Phase) { lock.withLock { self.phase = phase } }
        func count(_ phase: Phase, _ key: String) -> Int { lock.withLock { counts["\(phase.rawValue):\(key)", default: 0] } }

        func record(_ phase: Phase, _ key: String) -> Bool {
            lock.withLock {
                guard self.phase == phase else { return false }
                counts["\(phase.rawValue):\(key)", default: 0] += 1
                return true
            }
        }
    }

    @MainActor
    private final class Fixture {
        let marker = "p14-coverage-\(UUID().uuidString)"
        let requests = Requests()
        let directory: URL
        let domain: String
        let settings: AppSettingsStore
        let cache: EventCacheStore
        let session: URLSession
        let client: GoogleOAuthClient

        init(failCatalog: Bool = false) throws {
            directory = try TestTempDirectory.make()
            domain = "GoogleAccountCoverageHealthTests.\(UUID().uuidString)"
            settings = AppSettingsStore(domainName: domain)
            cache = EventCacheStore(fileURL: directory.appending(path: "cache.json"))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubURLProtocol.self]
            configuration.httpAdditionalHeaders = ["X-Meeting-Shield-Test": marker]
            session = URLSession(configuration: configuration)
            client = GoogleOAuthClient(
                configuration: GoogleOAuthConfiguration(clientID: "\(marker)-client"),
                keychain: InMemoryKeychain(), session: session,
                diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "oauth"), nativeSink: { _, _ in })
            )
            settings.update {
                $0.selectedCalendarIDs = [calendarID("a-main"), calendarID("b-main")]
                $0.visibilityWindow = MenuVisibilityWindow(kind: .nextHours, hours: 1, days: 1)
            }
            try restoreTokens()
            registerResponses(failCatalog: failCatalog)
        }

        func coordinator(provider: (any CalendarProvider)? = nil) -> RefreshCoordinator {
            RefreshCoordinator(
                provider: provider ?? GoogleCalendarProvider(oauthClient: client), cacheStore: cache,
                settings: { self.settings.snapshot }, now: { self.requests.now },
                diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "refresh"), nativeSink: { _, _ in })
            )
        }

        func fallbackProvider(_ fallback: ColdFallback) -> FallbackProvider {
            let auth: CalendarProviderAuthState = switch fallback {
            case .disconnected: .disconnected
            case .needsConfiguration: .needsConfiguration
            case .catalogFailure: .connected(accountEmail: accountID("a"))
            }
            return FallbackProvider(
                auth: auth,
                knownAccounts: ["a", "b"].map { ConnectedCalendarAccount(id: accountID($0), displayName: "Synthetic account \($0)") },
                failsCatalog: fallback == .catalogFailure
            )
        }

        func seed(_ coordinator: RefreshCoordinator) async throws {
            let outcome = try #require(await coordinator.refresh(reason: "launch"))
            try #require(outcome.didSucceed)
            #expect(outcome.statusMessage == nil)
            #expect(Set(try #require(outcome.events).map(\.eventID)) == [eventID("a-main", old: true), eventID("b-main", old: true)])
            #expect(try account("b").coverage?.calendarIDs == [calendarID("b-main")])
            #expect(try account("b").calendars.map(\.id).contains(calendarID("b-secondary")))
        }

        func selectSecondary() { settings.update { $0.selectedCalendarIDs.insert(calendarID("b-secondary")) } }
        func accountID(_ account: String) -> String { "\(marker)-\(account)@example.invalid" }
        func sourceID(_ calendar: String) -> String { "\(marker)-\(calendar)" }
        func calendarID(_ calendar: String) -> String { "\(accountID(calendar.hasPrefix("a-") ? "a" : "b"))::\(sourceID(calendar))" }
        func eventID(_ calendar: String, old: Bool) -> String { "\(marker)-\(calendar)-\(old ? "old" : "new")" }

        func account(_ account: String) throws -> CalendarAccountCache {
            try #require(try cache.loadUnfiltered()?.accounts[accountID(account)])
        }

        func expectMixedEvents(_ events: [CalendarEventOccurrence]) {
            #expect(Set(events.map(\.eventID)) == [eventID("a-main", old: false), eventID("b-main", old: true)])
            #expect(events.filter { $0.accountID == accountID("b") }.allSatisfy { $0.isFromCache })
        }

        func legacyEvent() -> CalendarEventOccurrence {
            var event = CalendarEventOccurrence.sample(
                eventID: eventID("b-main", old: true), title: "Synthetic legacy meeting",
                startDate: TestDates.start, calendarID: calendarID("b-main")
            )
            event.providerID = "google"
            event.accountID = accountID("b")
            return event.privacyPreservingCacheCopy(detectedLinks: [])
        }

        func goOffline() throws {
            try saveTokens(expiresAt: .distantPast)
            requests.move(to: .offline)
        }

        func restoreTokens() throws { try saveTokens(expiresAt: .distantFuture) }

        private func saveTokens(expiresAt: Date) throws {
            for account in ["a", "b"] {
                try client.saveToken(GoogleOAuthToken(
                    accessToken: "access-\(marker)-\(account)", refreshToken: "refresh-\(marker)-\(account)",
                    expiresAt: expiresAt, scope: AppIdentity.googleScopes.joined(separator: " "), tokenType: "Bearer"
                ), accountID: accountID(account), accountDisplayName: "Synthetic account \(account)")
            }
        }

        private func registerResponses(failCatalog: Bool) {
            for phase in [Phase.seed, .failed, .recovered] {
                for account in ["a", "b"] {
                    let names = account == "a" ? ["a-main"] : ["b-main", "b-secondary"]
                    let items = names.map {
                        "{\"id\":\"\(sourceID($0))\",\"summary\":\"Synthetic calendar\",\"selected\":true,\"accessRole\":\"reader\"}"
                    }.joined(separator: ",")
                    let fails = failCatalog && phase == .failed && account == "b"
                    register(phase, account: account, path: "/users/me/calendarList", key: "\(account).catalog",
                             json: fails ? "{}" : "{\"items\":[\(items)]}", status: fails ? 503 : 200)
                    for name in names {
                        let fails = phase == .failed && name == "b-secondary"
                        let empty = phase == .recovered && account == "b"
                        let ids = empty ? [] : [eventID(name, old: phase == .seed)]
                        register(phase, account: account, path: "/calendars/\(sourceID(name))/events", key: "\(name).events",
                                 json: fails ? "{}" : eventsPage(ids), status: fails ? 503 : 200)
                    }
                }
            }
            let marker = marker
            let requests = requests
            StubURLProtocol.registerJSON(matcher: { request in
                request.url == AppIdentity.googleOAuthTokenURL
                    && request.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker
                    && requests.record(.offline, "token")
            }, json: "{\"error\":\"temporarily_unavailable\"}", statusCode: 503)
        }

        private func register(_ phase: Phase, account: String, path: String, key: String, json: String, status: Int) {
            let marker = marker
            let requests = requests
            StubURLProtocol.registerJSON(matcher: { request in
                request.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker
                    && request.value(forHTTPHeaderField: "Authorization") == "Bearer access-\(marker)-\(account)"
                    && request.url?.path.hasSuffix(path) == true
                    && requests.record(phase, key)
            }, json: json, statusCode: status)
        }

        private func eventsPage(_ ids: [String]) -> String {
            let start = ISO8601DateFormatter.stableString(from: TestDates.start)
            let end = ISO8601DateFormatter.stableString(from: TestDates.start.addingTimeInterval(1800))
            let items = ids.map {
                "{\"id\":\"\($0)\",\"summary\":\"Synthetic meeting\",\"status\":\"confirmed\",\"start\":{\"dateTime\":\"\(start)\"},\"end\":{\"dateTime\":\"\(end)\"}}"
            }.joined(separator: ",")
            return "{\"items\":[\(items)]}"
        }

        func expectNoUnmatchedRequests() {
            #expect(StubURLProtocol.unmatched.filter { $0.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker }.isEmpty)
        }

        func cleanup() {
            session.invalidateAndCancel()
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
