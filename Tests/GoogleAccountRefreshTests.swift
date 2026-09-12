import Foundation
import Testing
@testable import MeetingShield

@Suite("Google account refresh recovery")
struct GoogleAccountRefreshTests {
    @Test("Repeated account failures leave fresh accounts protected and recovery resets stale health")
    @MainActor
    func repeatedFailuresAreScopedToAccount() async throws {
        let fixture = try Fixture(failure: .eventsPage)
        defer { fixture.cleanup() }
        let coordinator = fixture.makeCoordinator()
        try await fixture.seed(coordinator)
        try fixture.beginChangedRefresh()
        _ = try #require(await coordinator.refresh(reason: "timer"))
        fixture.requests.advance(by: 60)
        let outcome = try #require(await coordinator.refresh(reason: "timer"))

        let metadata = try fixture.readAccountMetadata()
        #expect(metadata[fixture.accountID("a")]?.fetchedAt == fixture.requests.now)
        let snapshot = coordinator.protectionSnapshot(knownAccounts: outcome.accounts)
        #expect(snapshot.accounts.first { $0.accountID == fixture.accountID("a") }?.state == .protected)
        #expect(snapshot.accounts.first { $0.accountID == fixture.accountID("b") }?.state == .stale)
        #expect(coordinator.isProtectionStale)
        #expect(snapshot.refreshIssue)

        fixture.beginRecovery()
        let recovered = try #require(await coordinator.refresh(reason: "timer"))
        let recoveredHealth = coordinator.protectionSnapshot(knownAccounts: recovered.accounts)
        #expect(recovered.didSucceed)
        #expect(recoveredHealth.accounts.allSatisfy { $0.state == .protected })
        #expect(!coordinator.isProtectionStale)
        #expect(!recoveredHealth.refreshIssue)

        let recoveredAt = fixture.requests.now
        try fixture.beginChangedRefresh()
        fixture.requests.advance(by: recoveredAt.timeIntervalSince(fixture.requests.now) + 1)
        let firstFailure = try #require(await coordinator.refresh(reason: "timer"))
        #expect(!firstFailure.didSucceed)
        #expect(!coordinator.isProtectionStale)
        #expect(coordinator.protectionSnapshot(knownAccounts: firstFailure.accounts).accounts.allSatisfy { $0.state == .protected })
        fixture.expectNoUnmatchedRequests()
    }

    @Test("Unselected account failures do not stale fresh selected coverage")
    @MainActor
    func unselectedFailuresDoNotStaleCoverage() async throws {
        let fixture = try Fixture(failure: .calendarList)
        defer { fixture.cleanup() }
        var selection = fixture.settings
        selection.selectedCalendarIDs = selection.selectedCalendarIDs.filter { $0.hasPrefix("\(fixture.accountID("a"))::") }
        let settings = selection
        let requests = fixture.requests
        let coordinator = RefreshCoordinator(
            provider: GoogleCalendarProvider(oauthClient: fixture.client),
            cacheStore: fixture.cache, settings: { settings }, now: { requests.now },
            diagnostics: DiagnosticsRecorder(directory: fixture.directory.appending(path: "health-diagnostics"), nativeSink: { _, _ in })
        )
        let seeded = try #require(await coordinator.refresh(reason: "launch"))
        #expect(seeded.didSucceed)
        try fixture.beginChangedRefresh()
        _ = try #require(await coordinator.refresh(reason: "timer"))
        fixture.requests.advance(by: 60)
        let outcome = try #require(await coordinator.refresh(reason: "timer"))

        let metadata = try fixture.readAccountMetadata()
        #expect(metadata[fixture.accountID("a")]?.fetchedAt == fixture.requests.now)
        let snapshot = coordinator.protectionSnapshot(knownAccounts: outcome.accounts)
        #expect(snapshot.accounts.count == 1)
        #expect(snapshot.accounts.first?.state == .protected)
        #expect(!coordinator.isProtectionStale)
        #expect(snapshot.refreshIssue)
        #expect(!outcome.didSucceed)
        fixture.expectNoUnmatchedRequests()
    }

    @Test("A complete account refresh replaces only that account when another account fails", arguments: FailurePoint.allCases)
    @MainActor
    func healthyAccountAdvancesWithoutErasingFailedAccount(failure: FailurePoint) async throws {
        let fixture = try Fixture(failure: failure)
        defer { fixture.cleanup() }
        let coordinator = fixture.makeCoordinator()
        try await fixture.seed(coordinator)
        try fixture.beginChangedRefresh()

        let outcome = try #require(await coordinator.refresh(reason: "timer"))
        let events = try #require(outcome.events)

        #expect(!outcome.skipped)
        #expect(Set(outcome.accounts.map(\.id)) == fixture.accountIDs)
        #expect(outcome.statusMessage?.isEmpty == false)
        #expect(coordinator.currentStatusMessage == outcome.statusMessage)
        fixture.expectEvents(events, ids: fixture.mixedEventIDs)
        #expect(events.filter { $0.accountID == fixture.accountID("a") }.allSatisfy { !$0.isFromCache })
        #expect(events.filter { $0.accountID == fixture.accountID("b") }.allSatisfy { $0.isFromCache })
        let saved = try #require(try fixture.cache.loadUnfiltered())
        fixture.expectEvents(saved.events, ids: fixture.mixedEventIDs)
        fixture.expectChangedRequests()

        let savedBytes = try Data(contentsOf: fixture.cache.fileURL)
        try fixture.beginOfflineRefresh()
        let restarted = fixture.makeCoordinator()
        let recovered = try #require(await restarted.refresh(reason: "launch"))

        #expect(!recovered.didSucceed)
        #expect(recovered.statusMessage?.isEmpty == false)
        fixture.expectEvents(try #require(recovered.events), ids: fixture.mixedEventIDs)
        #expect(recovered.events?.allSatisfy { $0.isFromCache } == true)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == savedBytes)
        #expect(fixture.requests.count(.offline, key: "token") == 2)
        fixture.expectNoUnmatchedRequests()
    }

    @Test("A timed-out account retains its coverage and recovers on the next refresh", arguments: FailurePoint.timeouts)
    @MainActor
    func timedOutAccountRetainsCoverageAndRecovers(failure: FailurePoint) async throws {
        let fixture = try Fixture(failure: failure)
        defer { fixture.cleanup() }
        let coordinator = fixture.makeCoordinator()
        try await fixture.seed(coordinator)
        let seeded = try fixture.readAccountMetadata()
        let previousB = try #require(seeded[fixture.accountID("b")])
        try fixture.beginChangedRefresh()

        let failed = try #require(await coordinator.refresh(reason: "timer"))

        fixture.expectEvents(try #require(failed.events), ids: fixture.mixedEventIDs)
        #expect(failed.statusMessage?.isEmpty == false)
        let partial = try fixture.readAccountMetadata()
        try fixture.expectMetadata(partial, account: "a", fetchedAt: fixture.requests.now)
        #expect(partial[fixture.accountID("b")] == previousB)
        #expect(failed.events?.filter { $0.accountID == fixture.accountID("b") }.allSatisfy { $0.isFromCache } == true)
        fixture.expectChangedRequests()
        fixture.beginRecovery()

        let recovered = try #require(await coordinator.refresh(reason: "timer"))

        #expect(recovered.didSucceed)
        #expect(!recovered.skipped)
        #expect(recovered.statusMessage == nil)
        #expect(coordinator.currentStatusMessage == nil)
        let expected = Set(fixture.calendarNames.map { fixture.eventID($0, version: "new") })
        fixture.expectEvents(try #require(recovered.events), ids: expected)
        #expect(recovered.events?.allSatisfy { !$0.isFromCache } == true)
        let saved = try #require(try fixture.cache.loadUnfiltered())
        fixture.expectEvents(saved.events, ids: expected)
        let metadata = try fixture.readAccountMetadata()
        for account in ["a", "b"] {
            try fixture.expectMetadata(metadata, account: account, fetchedAt: fixture.requests.now)
            #expect(fixture.requests.count(.recovered, key: "\(account).catalog") == 1)
        }
        for calendar in fixture.calendarNames {
            #expect(fixture.requests.count(.recovered, key: "\(calendar).events") == 1)
        }
        #expect(fixture.requests.count(.recovered, key: "token") == (failure == .tokenTimeout ? 1 : 0))
        #expect(Set(fixture.client.storedTokens().compactMap(\.accountID)) == fixture.accountIDs)
        fixture.expectNoUnmatchedRequests()
    }

    @Test("A complete empty account refresh removes its previous meetings from memory and disk")
    @MainActor
    func completeEmptyAccountRemovesOnlyItsPreviousMeetings() async throws {
        let fixture = try Fixture(failure: nil)
        defer { fixture.cleanup() }
        let coordinator = fixture.makeCoordinator()
        try await fixture.seed(coordinator)
        try fixture.beginChangedRefresh()

        let outcome = try #require(await coordinator.refresh(reason: "timer"))

        #expect(outcome.didSucceed)
        #expect(!outcome.skipped)
        #expect(outcome.statusMessage == nil)
        #expect(coordinator.currentStatusMessage == nil)
        #expect(Set(outcome.accounts.map(\.id)) == fixture.accountIDs)
        fixture.expectEvents(try #require(outcome.events), ids: [fixture.eventID("a-main", version: "new")])
        #expect(outcome.events?.allSatisfy { !$0.isFromCache } == true)
        let saved = try #require(try fixture.cache.loadUnfiltered())
        fixture.expectEvents(saved.events, ids: [fixture.eventID("a-main", version: "new")])
        fixture.expectChangedRequests()

        let savedBytes = try Data(contentsOf: fixture.cache.fileURL)
        try fixture.beginOfflineRefresh()
        let restarted = fixture.makeCoordinator()
        let recovered = try #require(await restarted.refresh(reason: "launch"))

        #expect(!recovered.didSucceed)
        #expect(recovered.statusMessage?.isEmpty == false)
        fixture.expectEvents(try #require(recovered.events), ids: [fixture.eventID("a-main", version: "new")])
        #expect(try Data(contentsOf: fixture.cache.fileURL) == savedBytes)
        #expect(fixture.requests.count(.offline, key: "token") == 2)
        fixture.expectNoUnmatchedRequests()
    }

    @Test("Failed token refresh for every account preserves the saved meetings across restart")
    @MainActor
    func allFailedAccountsKeepTheirSavedMeetings() async throws {
        let fixture = try Fixture(failure: nil)
        defer { fixture.cleanup() }
        let coordinator = fixture.makeCoordinator()
        try await fixture.seed(coordinator)
        let savedBytes = try Data(contentsOf: fixture.cache.fileURL)
        try fixture.beginOfflineRefresh()

        let failed = try #require(await coordinator.refresh(reason: "timer"))
        let restarted = fixture.makeCoordinator()
        let recovered = try #require(await restarted.refresh(reason: "launch"))

        for outcome in [failed, recovered] {
            #expect(!outcome.didSucceed)
            #expect(!outcome.skipped)
            #expect(outcome.statusMessage?.isEmpty == false)
            #expect(Set(outcome.accounts.map(\.id)) == fixture.accountIDs)
            fixture.expectEvents(try #require(outcome.events), ids: fixture.seedEventIDs)
            #expect(outcome.events?.allSatisfy { $0.isFromCache } == true)
        }
        let saved = try #require(try fixture.cache.loadUnfiltered())
        fixture.expectEvents(saved.events, ids: fixture.seedEventIDs)
        #expect(saved.cachedAt == TestDates.now)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == savedBytes)
        #expect(fixture.requests.count(.offline, key: "token") == 4)
        #expect(Set(fixture.client.storedTokens().compactMap(\.accountID)) == fixture.accountIDs)
        fixture.expectNoUnmatchedRequests()
    }

    @Test("A fresh account advances its metadata without renewing a failed account's coverage", arguments: FailurePoint.allCases)
    @MainActor
    func partialRefreshPreservesFailedAccountMetadata(failure: FailurePoint) async throws {
        let fixture = try Fixture(failure: failure)
        defer { fixture.cleanup() }
        let coordinator = fixture.makeCoordinator()
        try await fixture.seed(coordinator)
        let seeded = try fixture.readAccountMetadata()
        for account in ["a", "b"] {
            try fixture.expectMetadata(seeded, account: account, fetchedAt: TestDates.now)
        }
        let originalB = try #require(seeded[fixture.accountID("b")])
        try fixture.beginChangedRefresh()

        let outcome = try #require(await coordinator.refresh(reason: "timer"))
        let changed = try fixture.readAccountMetadata()

        #expect(outcome.statusMessage?.isEmpty == false)
        fixture.expectEvents(try #require(outcome.events), ids: fixture.mixedEventIDs)
        try fixture.expectMetadata(changed, account: "a", fetchedAt: fixture.requests.now)
        #expect(changed[fixture.accountID("b")] == originalB)
        fixture.expectChangedRequests()
        let savedBytes = try Data(contentsOf: fixture.cache.fileURL)
        try fixture.beginOfflineRefresh()

        let restarted = fixture.makeCoordinator()
        let recovered = try #require(await restarted.refresh(reason: "launch"))

        #expect(!recovered.didSucceed)
        fixture.expectEvents(try #require(recovered.events), ids: fixture.mixedEventIDs)
        #expect(try fixture.readAccountMetadata() == changed)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == savedBytes)
        fixture.expectNoUnmatchedRequests()
    }

    @Test("Complete empty calendars retain fetched membership and coverage after restart")
    @MainActor
    func completeEmptyAccountRetainsCoverageMetadata() async throws {
        let fixture = try Fixture(failure: nil)
        defer { fixture.cleanup() }
        let coordinator = fixture.makeCoordinator()
        try await fixture.seed(coordinator)
        try fixture.beginChangedRefresh()

        let outcome = try #require(await coordinator.refresh(reason: "timer"))
        let saved = try fixture.readAccountMetadata()

        #expect(outcome.didSucceed)
        #expect(outcome.events?.contains { $0.accountID == fixture.accountID("b") } == false)
        for account in ["a", "b"] {
            try fixture.expectMetadata(saved, account: account, fetchedAt: fixture.requests.now)
        }
        fixture.expectChangedRequests()
        try fixture.beginOfflineRefresh()
        let restarted = fixture.makeCoordinator()

        let recovered = try #require(await restarted.refresh(reason: "launch"))

        #expect(!recovered.didSucceed)
        fixture.expectEvents(try #require(recovered.events), ids: [fixture.eventID("a-main", version: "new")])
        #expect(try fixture.readAccountMetadata() == saved)
        fixture.expectNoUnmatchedRequests()
    }

    @Test("A failed account reaches the stale threshold while another account stays fresh, including after restart")
    @MainActor
    func failedAccountAgeIsNotResetByHealthyAccountRefresh() async throws {
        let fixture = try Fixture(failure: .calendarList)
        defer { fixture.cleanup() }
        let coordinator = fixture.makeCoordinator()
        try await fixture.seed(coordinator)
        try fixture.beginChangedRefresh()
        fixture.requests.advance(by: 239)

        let beforeThreshold = try #require(await coordinator.refresh(reason: "timer"))

        #expect(fixture.requests.now == TestDates.now.addingTimeInterval(299))
        #expect(beforeThreshold.statusMessage?.isEmpty == false)
        #expect(beforeThreshold.statusMessage?.localizedCaseInsensitiveContains("stale") == false)
        fixture.expectEvents(try #require(beforeThreshold.events), ids: fixture.mixedEventIDs)
        fixture.requests.advance(by: 1)
        #expect(coordinator.currentStatusMessage?.localizedCaseInsensitiveContains("stale") == true)

        let atThreshold = try #require(await coordinator.refresh(reason: "timer"))
        let saved = try fixture.readAccountMetadata()

        #expect(atThreshold.statusMessage?.localizedCaseInsensitiveContains("stale") == true)
        try fixture.expectMetadata(saved, account: "a", fetchedAt: TestDates.now.addingTimeInterval(300))
        try fixture.expectMetadata(saved, account: "b", fetchedAt: TestDates.now)
        let restarted = fixture.makeCoordinator()

        let recovered = try #require(await restarted.refresh(reason: "launch"))

        #expect(recovered.statusMessage?.localizedCaseInsensitiveContains("stale") == true)
        fixture.expectEvents(try #require(recovered.events), ids: fixture.mixedEventIDs)
        #expect(try fixture.readAccountMetadata() == saved)
        #expect(fixture.requests.count(.changed, key: "a-main.events") == 3)
        fixture.expectNoUnmatchedRequests()
    }

    @Test("All-account failure cannot create protection from an unavailable cold-start cache", arguments: ColdCache.allCases)
    @MainActor
    func allFailedAccountsDoNotInventColdCacheProtection(state: ColdCache) async throws {
        let fixture = try Fixture(failure: nil)
        defer { fixture.cleanup() }
        var originalBytes: Data?
        var originalPermissions: NSNumber?
        defer {
            do {
                if let originalPermissions {
                    try FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: fixture.cache.fileURL.path)
                    let restored = try FileManager.default.attributesOfItem(atPath: fixture.cache.fileURL.path)
                    #expect(restored[.posixPermissions] as? NSNumber == originalPermissions)
                }
                if let originalBytes {
                    #expect(try Data(contentsOf: fixture.cache.fileURL) == originalBytes)
                } else {
                    #expect(!FileManager.default.fileExists(atPath: fixture.cache.fileURL.path))
                }
            } catch {
                Issue.record("The owned temporary cache could not be checked after restoring its permissions.")
            }
        }
        switch state {
        case .missing:
            try #require(try fixture.cache.loadUnfiltered() == nil)
        case .corrupt:
            let corrupt = Data("synthetic-unreadable-account-cache-json".utf8)
            try corrupt.write(to: fixture.cache.fileURL)
            originalBytes = corrupt
            #expect(throws: DecodingError.self) { try fixture.cache.loadUnfiltered() }
        case .unreadable:
            try await fixture.seed(fixture.makeCoordinator())
            originalBytes = try Data(contentsOf: fixture.cache.fileURL)
            let attributes = try FileManager.default.attributesOfItem(atPath: fixture.cache.fileURL.path)
            originalPermissions = try #require(attributes[.posixPermissions] as? NSNumber)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.cache.fileURL.path)
            var denied = false
            do {
                _ = try Data(contentsOf: fixture.cache.fileURL)
            } catch {
                try fixture.requirePermissionDenial(error, reading: true)
                denied = true
            }
            try #require(denied, "The fixture must prove a real cache read denial before refreshing.")
        }
        try fixture.beginOfflineRefresh()
        let coordinator = fixture.makeCoordinator()

        let first = try #require(await coordinator.refresh(reason: "launch"))

        try fixture.expectNoProtection(first)
        for interval in [TimeInterval(301), TimeInterval(24 * 60 * 60)] {
            fixture.requests.advance(by: interval)
            try fixture.expectNoProtectionMessage(coordinator.currentStatusMessage)
            let retried = try #require(await coordinator.refresh(reason: "timer"))
            try fixture.expectNoProtection(retried)
        }
        let restarted = fixture.makeCoordinator()
        let recovered = try #require(await restarted.refresh(reason: "launch"))

        try fixture.expectNoProtection(recovered)
        #expect(fixture.requests.count(.offline, key: "token") == 8)
        #expect(Set(fixture.client.storedTokens().compactMap(\.accountID)) == fixture.accountIDs)
        fixture.expectNoUnmatchedRequests()
    }

    @Test("Partial account progress survives a failed cache write in memory but cannot appear after restart")
    @MainActor
    func partialRefreshWriteFailureRetainsMemoryWithoutClaimingDurability() async throws {
        let fixture = try Fixture(failure: .calendarList)
        defer { fixture.cleanup() }
        let coordinator = fixture.makeCoordinator()
        try await fixture.seed(coordinator)
        let seeded = try #require(try fixture.cache.loadUnfiltered())
        let savedBytes = try Data(contentsOf: fixture.cache.fileURL)
        let savedMetadata = try fixture.readAccountMetadata()
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)
        let originalPermissions = try #require(attributes[.posixPermissions] as? NSNumber)
        defer {
            do {
                try FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: fixture.directory.path)
                let restored = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)
                #expect(restored[.posixPermissions] as? NSNumber == originalPermissions)
                #expect(try Data(contentsOf: fixture.cache.fileURL) == savedBytes)
            } catch {
                Issue.record("The owned temporary cache directory permissions could not be restored.")
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.directory.path)
        var denied = false
        do {
            try fixture.cache.save(envelope: seeded, settings: fixture.settings)
        } catch {
            try fixture.requirePermissionDenial(error, reading: false)
            denied = true
        }
        try #require(denied, "The real cache save must fail with write denial before refreshing.")
        #expect(try Data(contentsOf: fixture.cache.fileURL) == savedBytes)
        try fixture.beginChangedRefresh()

        let partial = try #require(await coordinator.refresh(reason: "timer"))

        fixture.expectEvents(try #require(partial.events), ids: fixture.mixedEventIDs)
        #expect(partial.statusMessage?.localizedCaseInsensitiveContains("could not be saved") == true)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == savedBytes)
        #expect(try fixture.readAccountMetadata() == savedMetadata)
        fixture.expectChangedRequests()
        try fixture.beginOfflineRefresh()

        let memory = try #require(await coordinator.refresh(reason: "timer"))

        #expect(!memory.didSucceed)
        fixture.expectEvents(try #require(memory.events), ids: fixture.mixedEventIDs)
        #expect(memory.events?.allSatisfy { $0.isFromCache } == true)
        #expect(memory.statusMessage?.localizedCaseInsensitiveContains("could not be saved") == true)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == savedBytes)
        let restarted = fixture.makeCoordinator()

        let recovered = try #require(await restarted.refresh(reason: "launch"))

        #expect(!recovered.didSucceed)
        fixture.expectEvents(try #require(recovered.events), ids: fixture.seedEventIDs)
        #expect(recovered.statusMessage?.localizedCaseInsensitiveContains("could not be saved") == false)
        #expect(try fixture.readAccountMetadata() == savedMetadata)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == savedBytes)
        fixture.expectNoUnmatchedRequests()
    }

    @Test("All-account failure persists explicit account or calendar exclusions to the raw cache", arguments: CacheExclusion.allCases)
    @MainActor
    func failedRefreshPersistsFilteredDiskSnapshot(exclusion: CacheExclusion) async throws {
        let fixture = try Fixture(failure: nil)
        defer { fixture.cleanup() }
        try await fixture.seed(fixture.makeCoordinator())
        let originalBytes = try Data(contentsOf: fixture.cache.fileURL)
        let originalMetadata = try fixture.readAccountMetadata()
        let originalB = try #require(originalMetadata[fixture.accountID("b")])
        var snapshot = fixture.settings
        switch exclusion {
        case .disabledAccount:
            snapshot.disabledGoogleAccountIDs.insert(fixture.accountID("b"))
        case .deselectedCalendars:
            snapshot.selectedCalendarIDs = ["\(fixture.accountID("a"))::\(fixture.calendarID("a-main"))"]
        }
        let selectedSnapshot = snapshot
        let makeCoordinator: @MainActor () -> RefreshCoordinator = {
            RefreshCoordinator(
                provider: GoogleCalendarProvider(oauthClient: fixture.client),
                cacheStore: fixture.cache,
                settings: { selectedSnapshot },
                now: { fixture.requests.now },
                diagnostics: DiagnosticsRecorder(directory: fixture.directory.appending(path: "filtered-diagnostics"), nativeSink: { _, _ in })
            )
        }
        try fixture.beginOfflineRefresh()
        let coordinator = makeCoordinator()

        let outcome = try #require(await coordinator.refresh(reason: "launch"))

        #expect(!outcome.didSucceed)
        fixture.expectEvents(try #require(outcome.events), ids: [fixture.eventID("a-main", version: "old")])
        #expect(outcome.statusMessage?.localizedCaseInsensitiveContains("could not be saved") == false)
        let raw = try #require(try fixture.cache.loadUnfiltered())
        fixture.expectEvents(raw.events, ids: [fixture.eventID("a-main", version: "old")])
        let expectedAccounts: Set<String> = exclusion == .disabledAccount ? [fixture.accountID("a")] : fixture.accountIDs
        let metadata = try fixture.readAccountMetadata(expectedAccountIDs: expectedAccounts)
        #expect(metadata[fixture.accountID("a")] == originalMetadata[fixture.accountID("a")])
        switch exclusion {
        case .disabledAccount:
            #expect(metadata[fixture.accountID("b")] == nil)
        case .deselectedCalendars:
            let retainedB = try #require(metadata[fixture.accountID("b")])
            #expect(retainedB.account == originalB.account)
            #expect(retainedB.calendars == originalB.calendars)
            #expect(retainedB.coverage?.calendarIDs.isEmpty == true)
        }
        let updatedBytes = try Data(contentsOf: fixture.cache.fileURL)
        #expect(updatedBytes != originalBytes)
        let restarted = makeCoordinator()

        let recovered = try #require(await restarted.refresh(reason: "launch"))

        #expect(!recovered.didSucceed)
        fixture.expectEvents(try #require(recovered.events), ids: [fixture.eventID("a-main", version: "old")])
        #expect(try Data(contentsOf: fixture.cache.fileURL) == updatedBytes)
        fixture.expectNoUnmatchedRequests()
    }

    enum ColdCache: CaseIterable, Sendable {
        case missing
        case corrupt
        case unreadable
    }

    enum CacheExclusion: CaseIterable, Equatable, Sendable {
        case disabledAccount
        case deselectedCalendars
    }

    private struct CachedAccounts: Decodable {
        let accounts: [String: CachedAccount]?
    }

    private struct CachedAccount: Decodable, Equatable {
        let account: ConnectedCalendarAccount
        let calendars: [UserCalendar]
        let fetchedAt: Date?
        let coverage: CachedCoverage?
    }

    private struct CachedCoverage: Decodable, Equatable {
        let calendarIDs: Set<String>
        let window: CachedWindow
    }

    private struct CachedWindow: Decodable, Equatable {
        let start: Date
        let end: Date
    }

    enum FailurePoint: CaseIterable, Equatable, Sendable {
        case tokenRefresh
        case calendarList
        case eventsPage
        case selectedCalendar
        case tokenTimeout
        case calendarTimeout
        case eventsPageTimeout

        static let timeouts: [FailurePoint] = [.tokenTimeout, .calendarTimeout, .eventsPageTimeout]
    }

    private enum Phase: Int, Sendable {
        case seed
        case changed
        case offline
        case recovered
    }

    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var phase: Phase = .seed
        private var counts: [String: Int] = [:]
        private var timeOffset: TimeInterval = 0

        var now: Date {
            lock.withLock { TestDates.now.addingTimeInterval(TimeInterval(phase.rawValue * 60) + timeOffset) }
        }

        func advance(by interval: TimeInterval) {
            lock.withLock { timeOffset += interval }
        }

        func move(to phase: Phase) {
            lock.withLock { self.phase = phase }
        }

        func isCurrent(_ phase: Phase) -> Bool {
            lock.withLock { self.phase == phase }
        }

        func record(when phase: Phase, key: String) -> Bool {
            lock.withLock {
                guard self.phase == phase else { return false }
                counts["\(phase.rawValue):\(key)", default: 0] += 1
                return true
            }
        }

        func count(_ phase: Phase, key: String) -> Int {
            lock.withLock { counts["\(phase.rawValue):\(key)", default: 0] }
        }
    }

    private final class TimeoutURLProtocol: URLProtocol, @unchecked Sendable {
        private struct Registration: Sendable {
            let marker: String
            let requests: Requests
            let failure: FailurePoint

            func key(for request: URLRequest) -> String? {
                guard requests.isCurrent(.changed) else { return nil }
                if failure == .tokenTimeout,
                   request.url == AppIdentity.googleOAuthTokenURL,
                   request.httpMethod == "POST" {
                    return "token"
                }
                guard request.httpMethod == "GET",
                      request.url?.host == AppIdentity.googleCalendarBaseURL.host,
                      request.value(forHTTPHeaderField: "Authorization") == "Bearer access-\(marker)-b" else { return nil }
                if failure == .calendarTimeout,
                   request.url?.path.hasSuffix("/users/me/calendarList") == true {
                    return "b.catalog"
                }
                if failure == .eventsPageTimeout,
                   request.url?.path.hasSuffix("/calendars/\(marker)-b-main/events") == true,
                   request.queryValues["pageToken"] == "\(marker)-next" {
                    return "b-main.next-page"
                }
                return nil
            }
        }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var registrations: [String: Registration] = [:]

        static func register(marker: String, requests: Requests, failure: FailurePoint) {
            lock.withLock { registrations[marker] = Registration(marker: marker, requests: requests, failure: failure) }
        }

        static func remove(marker: String) {
            lock.withLock { _ = registrations.removeValue(forKey: marker) }
        }

        private static func registration(for request: URLRequest) -> Registration? {
            guard let marker = request.value(forHTTPHeaderField: "X-Meeting-Shield-Test") else { return nil }
            return lock.withLock { registrations[marker] }
        }

        override class func canInit(with request: URLRequest) -> Bool {
            registration(for: request)?.key(for: request) != nil
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let registration = Self.registration(for: request),
                  let key = registration.key(for: request),
                  registration.requests.record(when: .changed, key: key) else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            _ = registration.requests.record(when: .changed, key: "transport-timeout")
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        }

        override func stopLoading() {}
    }

    private struct Fixture {
        let marker = "p14-account-\(UUID().uuidString)"
        let requests = Requests()
        let failure: FailurePoint?
        let directory: URL
        let cache: EventCacheStore
        let session: URLSession
        let client: GoogleOAuthClient

        var accountIDs: Set<String> { [accountID("a"), accountID("b")] }
        var calendarNames: [String] { ["a-main", "b-main", "b-secondary"] }
        var seedEventIDs: Set<String> { Set(calendarNames.map { eventID($0, version: "old") }) }
        var mixedEventIDs: Set<String> {
            [eventID("a-main", version: "new"), eventID("b-main", version: "old"), eventID("b-secondary", version: "old")]
        }

        var settings: AppSettingsSnapshot {
            var snapshot = AppSettingsSnapshot.defaults
            snapshot.selectedCalendarIDs = Set(calendarNames.map { name in
                "\(accountID(name.hasPrefix("a-") ? "a" : "b"))::\(calendarID(name))"
            })
            return snapshot
        }

        init(failure: FailurePoint?) throws {
            self.failure = failure
            directory = try TestTempDirectory.make()
            cache = EventCacheStore(fileURL: directory.appending(path: "event-cache.json"))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [TimeoutURLProtocol.self, StubURLProtocol.self]
            configuration.httpAdditionalHeaders = ["X-Meeting-Shield-Test": marker]
            session = URLSession(configuration: configuration)
            client = GoogleOAuthClient(
                configuration: GoogleOAuthConfiguration(clientID: "\(marker)-client"),
                keychain: InMemoryKeychain(),
                session: session,
                diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "oauth-diagnostics"), nativeSink: { _, _ in })
            )
            try saveToken(account: "a", expiresAt: .distantFuture)
            try saveToken(account: "b", expiresAt: .distantFuture)
            if let failure, FailurePoint.timeouts.contains(failure) {
                TimeoutURLProtocol.register(marker: marker, requests: requests, failure: failure)
            }
            registerResponses()
        }

        func cleanup() {
            session.invalidateAndCancel()
            TimeoutURLProtocol.remove(marker: marker)
            try? FileManager.default.removeItem(at: directory)
        }

        @MainActor
        func makeCoordinator() -> RefreshCoordinator {
            let snapshot = settings
            let requests = requests
            return RefreshCoordinator(
                provider: GoogleCalendarProvider(oauthClient: client),
                cacheStore: cache,
                settings: { snapshot },
                now: { requests.now },
                diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "refresh-diagnostics"), nativeSink: { _, _ in })
            )
        }

        @MainActor
        func seed(_ coordinator: RefreshCoordinator) async throws {
            #expect(try cache.loadUnfiltered() == nil)
            let outcome = try #require(await coordinator.refresh(reason: "launch"))
            try #require(outcome.didSucceed)
            #expect(outcome.statusMessage == nil)
            expectEvents(try #require(outcome.events), ids: seedEventIDs)
            #expect(outcome.events?.allSatisfy { !$0.isFromCache } == true)
            let saved = try #require(try cache.loadUnfiltered())
            expectEvents(saved.events, ids: seedEventIDs)
            #expect(saved.cachedAt == TestDates.now)
            for account in ["a", "b"] {
                #expect(requests.count(.seed, key: "\(account).catalog") == 1)
            }
            for calendar in calendarNames {
                #expect(requests.count(.seed, key: "\(calendar).events") == 1)
            }
            expectNoUnmatchedRequests()
        }

        func beginChangedRefresh() throws {
            if failure == .tokenRefresh || failure == .tokenTimeout {
                try saveToken(account: "b", expiresAt: .distantPast)
            }
            requests.move(to: .changed)
        }

        func beginOfflineRefresh() throws {
            try saveToken(account: "a", expiresAt: .distantPast)
            try saveToken(account: "b", expiresAt: .distantPast)
            requests.move(to: .offline)
        }

        func beginRecovery() {
            requests.move(to: .recovered)
        }

        func expectEvents(_ events: [CalendarEventOccurrence], ids: Set<String>) {
            #expect(events.count == ids.count)
            #expect(Set(events.map(\.eventID)) == ids)
            #expect(events.allSatisfy { accountIDs.contains($0.accountID) })
            #expect(events.allSatisfy { settings.selectedCalendarIDs.contains($0.calendarID) })
        }

        func readAccountMetadata(expectedAccountIDs: Set<String>? = nil) throws -> [String: CachedAccount] {
            let data = try Data(contentsOf: cache.fileURL)
            let envelope = try JSONDecoder().decode(CachedAccounts.self, from: data)
            let accounts = try #require(envelope.accounts, "The cache must persist per-account fetch metadata.")
            #expect(Set(accounts.keys) == (expectedAccountIDs ?? accountIDs))
            return accounts
        }

        func expectNoProtection(_ outcome: RefreshCoordinator.Outcome) throws {
            #expect(!outcome.didSucceed)
            #expect(!outcome.skipped)
            #expect(outcome.events == nil)
            #expect(Set(outcome.accounts.map(\.id)) == accountIDs)
            try expectNoProtectionMessage(outcome.statusMessage)
        }

        func expectNoProtectionMessage(_ message: String?) throws {
            let message = try #require(message)
            #expect(!message.isEmpty)
            for claim in ["using local cache", "held in memory", "calendar is current", "could not be saved", "stale", "older than 24 hours"] {
                #expect(!message.localizedCaseInsensitiveContains(claim))
            }
        }

        func requirePermissionDenial(_ error: Error, reading: Bool) throws {
            let error = error as NSError
            let expected = reading ? CocoaError.Code.fileReadNoPermission : .fileWriteNoPermission
            let cocoaDenial = error.domain == NSCocoaErrorDomain && error.code == expected.rawValue
            let posixDenial = error.domain == NSPOSIXErrorDomain && [POSIXErrorCode.EACCES, .EPERM].contains {
                Int($0.rawValue) == error.code
            }
            try #require(cocoaDenial || posixDenial, "The temporary permission fixture must fail with access denial.")
        }

        func expectMetadata(_ records: [String: CachedAccount], account: String, fetchedAt: Date) throws {
            let id = accountID(account)
            let record = try #require(records[id])
            let calendarIDs = Set(calendarNames.filter { $0.hasPrefix("\(account)-") }.map {
                "\(id)::\(calendarID($0))"
            })
            #expect(record.account == ConnectedCalendarAccount(id: id, displayName: "Synthetic account \(account)"))
            #expect(record.fetchedAt == fetchedAt)
            #expect(Set(record.calendars.map(\.id)) == calendarIDs)
            #expect(record.calendars.count == calendarIDs.count)
            #expect(record.calendars.allSatisfy { $0.accountID == id && $0.isSelected })
            let coverage = try #require(record.coverage)
            #expect(coverage.calendarIDs == calendarIDs)
            let expectedWindow = CalendarFetchWindow.protective(now: fetchedAt, visibilityWindow: settings.visibilityWindow)
            #expect(coverage.window.start == expectedWindow.start)
            #expect(coverage.window.end == expectedWindow.end)
        }

        func expectChangedRequests() {
            #expect(requests.count(.changed, key: "a.catalog") == 1)
            #expect(requests.count(.changed, key: "a-main.events") == 1)
            switch failure {
            case .tokenRefresh, .tokenTimeout:
                #expect(requests.count(.changed, key: "token") == 1)
            case .calendarList, .calendarTimeout:
                #expect(requests.count(.changed, key: "b.catalog") == 1)
            case .eventsPage, .eventsPageTimeout:
                #expect(requests.count(.changed, key: "b-main.events") == 1)
                #expect(requests.count(.changed, key: "b-main.next-page") == 1)
            case .selectedCalendar:
                #expect(requests.count(.changed, key: "b-secondary.events") == 1)
            case nil:
                #expect(requests.count(.changed, key: "b.catalog") == 1)
                #expect(requests.count(.changed, key: "b-main.events") == 1)
                #expect(requests.count(.changed, key: "b-secondary.events") == 1)
            }
            if let failure, FailurePoint.timeouts.contains(failure) {
                #expect(requests.count(.changed, key: "transport-timeout") == 1)
            }
        }

        func expectNoUnmatchedRequests() {
            #expect(StubURLProtocol.unmatched.filter {
                $0.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker
            }.isEmpty)
        }

        func accountID(_ account: String) -> String { "\(marker)-\(account)@example.invalid" }
        func calendarID(_ calendar: String) -> String { "\(marker)-\(calendar)" }
        func eventID(_ calendar: String, version: String) -> String { "\(marker)-\(calendar)-\(version)" }

        private func saveToken(account: String, expiresAt: Date) throws {
            try client.saveToken(
                GoogleOAuthToken(
                    accessToken: "access-\(marker)-\(account)",
                    refreshToken: "refresh-\(marker)-\(account)",
                    expiresAt: expiresAt,
                    scope: AppIdentity.googleScopes.joined(separator: " "),
                    tokenType: "Bearer"
                ),
                accountID: accountID(account),
                accountDisplayName: "Synthetic account \(account)"
            )
        }

        private func registerResponses() {
            for phase in [Phase.seed, .changed, .recovered] {
                for account in ["a", "b"] {
                    if phase == .changed && account == "b" && (failure == .tokenRefresh || failure == .tokenTimeout) { continue }
                    let fails = phase == .changed && account == "b" && failure == .calendarList
                    let names = calendarNames.filter { $0.hasPrefix("\(account)-") }
                    let items = names.map {
                        "{\"id\":\"\(calendarID($0))\",\"summary\":\"Synthetic calendar\",\"selected\":true,\"accessRole\":\"reader\"}"
                    }.joined(separator: ",")
                    register(
                        phase: phase, account: account, path: "/users/me/calendarList", key: "\(account).catalog",
                        json: fails ? "{}" : "{\"items\":[\(items)]}", status: fails ? 503 : 200
                    )
                }
                for calendar in calendarNames {
                    let isB = calendar.hasPrefix("b-")
                    if phase == .changed && isB && [FailurePoint.tokenRefresh, .tokenTimeout, .calendarList, .calendarTimeout].contains(where: { $0 == failure }) { continue }
                    let fails = phase == .changed && calendar == "b-secondary" && failure == .selectedCalendar
                    let paginates = phase == .changed && calendar == "b-main" && (failure == .eventsPage || failure == .eventsPageTimeout)
                    let isEmpty = phase == .changed && isB && failure == nil
                    let ids = isEmpty ? [] : [eventID(calendar, version: phase == .seed ? "old" : "new")]
                    register(
                        phase: phase, account: isB ? "b" : "a", path: "/calendars/\(calendarID(calendar))/events",
                        key: "\(calendar).events", json: fails ? "{}" : eventsPage(ids: ids, nextPage: paginates ? "\(marker)-next" : nil),
                        status: fails ? 503 : 200
                    )
                    if paginates {
                        register(
                            phase: phase, account: "b", path: "/calendars/\(calendarID(calendar))/events",
                            pageToken: "\(marker)-next", key: "\(calendar).next-page", json: "{}", status: 503
                        )
                    }
                }
            }
            let marker = marker
            let requests = requests
            StubURLProtocol.registerJSON(
                matcher: { request in
                    guard request.url == AppIdentity.googleOAuthTokenURL,
                          request.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker else { return false }
                    return requests.record(when: .changed, key: "token") || requests.record(when: .offline, key: "token")
                },
                json: "{\"error\":\"invalid_grant\"}", statusCode: 400
            )
            StubURLProtocol.registerJSON(
                matcher: { request in
                    guard request.url == AppIdentity.googleOAuthTokenURL,
                          request.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker else { return false }
                    return requests.record(when: .recovered, key: "token")
                },
                json: "{\"access_token\":\"access-\(marker)-b\",\"expires_in\":3600,\"token_type\":\"Bearer\"}"
            )
        }

        private func register(
            phase: Phase, account: String, path: String, pageToken: String? = nil,
            key: String, json: String, status: Int = 200
        ) {
            let marker = marker
            let requests = requests
            StubURLProtocol.registerJSON(
                matcher: { request in
                    guard request.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker,
                          request.value(forHTTPHeaderField: "Authorization") == "Bearer access-\(marker)-\(account)",
                          request.url?.path.hasSuffix(path) == true,
                          request.queryValues["pageToken"] == pageToken else { return false }
                    return requests.record(when: phase, key: key)
                },
                json: json, statusCode: status
            )
        }

        private func eventsPage(ids: [String], nextPage: String?) -> String {
            let start = ISO8601DateFormatter.stableString(from: TestDates.start)
            let end = ISO8601DateFormatter.stableString(from: TestDates.start.addingTimeInterval(1800))
            let items = ids.map {
                "{\"id\":\"\($0)\",\"summary\":\"Synthetic meeting\",\"status\":\"confirmed\",\"start\":{\"dateTime\":\"\(start)\"},\"end\":{\"dateTime\":\"\(end)\"}}"
            }.joined(separator: ",")
            let token = nextPage.map { "\"nextPageToken\":\"\($0)\"," } ?? ""
            return "{\(token)\"items\":[\(items)]}"
        }
    }
}
