import Foundation
import Testing
@testable import MeetingShield

@Suite("Refresh cache recovery")
@MainActor
struct RefreshCacheRecoveryTests {
    @Test("Repeated failures do not claim an absent or corrupt cache", arguments: UnavailableCache.allCases)
    func unavailableCacheDoesNotClaimFallback(state: UnavailableCache) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        switch state {
        case .missing:
            #expect(try fixture.cache.loadUnfiltered() == nil)
        case .corrupt:
            try FileManager.default.createDirectory(at: fixture.cacheDirectory, withIntermediateDirectories: true)
            try Data("synthetic-invalid-cache".utf8).write(to: fixture.cache.fileURL)
            #expect(throws: DecodingError.self) { try fixture.cache.loadUnfiltered() }
        }
        let coordinator = fixture.coordinator([.failure(.requestFailed(503)), .failure(.requestFailed(503))])

        let first = try #require(await coordinator.refresh(reason: "timer"))
        let second = try #require(await coordinator.refresh(reason: "timer"))

        #expect(!first.didSucceed)
        #expect(!second.didSucceed)
        #expect(first.events == nil)
        #expect(second.events == nil)
        let message = try #require(second.statusMessage)
        #expect(!message.isEmpty)
        #expect(!message.localizedCaseInsensitiveContains("using local cache"))
    }

    @Test("Corrupt cache reads emit only a safe diagnostic while missing cache is not a read failure", arguments: UnavailableCache.allCases)
    func cacheReadFailureIsObservableAndPrivate(state: UnavailableCache) async throws {
        let pathCanary = "synthetic-private-cache-path-秘密"
        let contentCanary = "synthetic-private-cache-content-秘密"
        let fixture = try Fixture(cacheDirectoryName: pathCanary)
        defer { fixture.cleanup() }
        switch state {
        case .missing:
            #expect(try fixture.cache.loadUnfiltered() == nil)
        case .corrupt:
            try FileManager.default.createDirectory(at: fixture.cacheDirectory, withIntermediateDirectories: true)
            let corrupt = Data("{\"cachedAt\":\"\(contentCanary)\",\"events\":[]}".utf8)
            try corrupt.write(to: fixture.cache.fileURL)
            #expect(throws: DecodingError.self) { try fixture.cache.loadUnfiltered() }
        }
        let capture = DiagnosticTestCapture()
        let diagnosticsDirectory = fixture.directory.appending(path: "diagnostics")
        let recorder = DiagnosticsRecorder(directory: diagnosticsDirectory, nativeSink: { capture.record($0, $1) })
        let coordinator = fixture.coordinator([.failure(.requestFailed(503))], diagnostics: recorder)

        let outcome = try #require(await coordinator.refresh(reason: "timer"))

        #expect(!outcome.didSucceed)
        #expect(outcome.events == nil)
        let saved = try String(contentsOf: diagnosticsDirectory.appending(path: "diagnostics.jsonl"), encoding: .utf8)
        let fileLines = saved.split(separator: "\n").map(String.init)
        #expect(fileLines == capture.payloads)
        let decoded = try capture.decodedStrings()
        for canary in [pathCanary, contentCanary, fixture.cache.fileURL.path] {
            #expect(!saved.contains(canary))
            #expect(!capture.payloads.contains { $0.contains(canary) })
            #expect(!decoded.contains { $0.contains(canary) })
        }
        let records = try fileLines.map { line in
            try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        #expect(records.contains { $0["event"] as? String == "refresh_failed" })
        let readFailures = records.filter { $0["event"] as? String == "cache_load_failed" }
        switch state {
        case .missing:
            #expect(readFailures.isEmpty)
        case .corrupt:
            try #require(!readFailures.isEmpty)
            for record in readFailures {
                #expect(record["level"] as? String == "error")
                #expect(record["metadata"] as? [String: String] == ["error": "decoding_error"])
            }
        }
    }

    @Test("Denied cache file and ancestor reads stay observable without exposing private data", arguments: ReadDenial.allCases)
    func deniedCacheReadsAreNotTreatedAsMissing(denial: ReadDenial) async throws {
        let pathCanary = "synthetic-denied-cache-path-秘密"
        let contentCanary = "synthetic-denied-cache-content-秘密"
        let fixture = try Fixture(cacheDirectoryName: pathCanary)
        defer { fixture.cleanup() }
        var event = fixture.event("read-denial")
        event.title = contentCanary
        try fixture.cache.save(events: [event], detectedLinks: [:], settings: fixture.settings, now: TestDates.now)
        let valid = try #require(try fixture.cache.loadUnfiltered())
        #expect(valid.events.map(\.eventID) == [event.eventID])
        let originalBytes = try Data(contentsOf: fixture.cache.fileURL)
        let restrictedURL = denial == .file ? fixture.cache.fileURL : fixture.cacheDirectory
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: restrictedURL.path)
        let originalPermissions = try #require(originalAttributes[.posixPermissions] as? NSNumber)
        defer {
            do {
                try FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: restrictedURL.path)
                let restored = try FileManager.default.attributesOfItem(atPath: restrictedURL.path)
                #expect(restored[.posixPermissions] as? NSNumber == originalPermissions)
                let restoredBytes = try Data(contentsOf: fixture.cache.fileURL)
                #expect(restoredBytes == originalBytes)
            } catch {
                Issue.record("The owned temporary cache permissions could not be restored.")
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: restrictedURL.path)
        let deniedReadCode: String
        do {
            _ = try Data(contentsOf: fixture.cache.fileURL)
            Issue.record("The active user can still read the permission-restricted fixture.")
            return
        } catch {
            let failure = error as NSError
            let cocoaDenial = failure.domain == NSCocoaErrorDomain && failure.code == CocoaError.Code.fileReadNoPermission.rawValue
            let posixDenial = failure.domain == NSPOSIXErrorDomain && [POSIXErrorCode.EACCES, .EPERM].contains(where: {
                Int($0.rawValue) == failure.code
            })
            try #require(cocoaDenial || posixDenial, "The fixture must fail with read denial, not another I/O error.")
            deniedReadCode = LogPrivacy.errorClass(error)
        }
        var cacheReadThrew = false
        do {
            _ = try fixture.cache.loadUnfiltered()
        } catch {
            cacheReadThrew = true
            #expect(LogPrivacy.errorClass(error) == deniedReadCode)
        }
        #expect(cacheReadThrew, "An inaccessible cache must throw instead of reporting a missing file.")
        let capture = DiagnosticTestCapture()
        let diagnosticsDirectory = fixture.directory.appending(path: "diagnostics")
        let recorder = DiagnosticsRecorder(directory: diagnosticsDirectory, nativeSink: { capture.record($0, $1) })
        let coordinator = fixture.coordinator([.failure(.requestFailed(503))], diagnostics: recorder)

        let outcome = try #require(await coordinator.refresh(reason: "timer"))

        #expect(!outcome.didSucceed)
        #expect(outcome.events == nil)
        let message = try #require(outcome.statusMessage)
        #expect(!message.isEmpty)
        #expect(!message.localizedCaseInsensitiveContains("using local cache"))
        let saved = try String(contentsOf: diagnosticsDirectory.appending(path: "diagnostics.jsonl"), encoding: .utf8)
        let fileLines = saved.split(separator: "\n").map(String.init)
        #expect(fileLines == capture.payloads)
        let decoded = try capture.decodedStrings()
        for canary in [pathCanary, contentCanary, fixture.cache.fileURL.path] {
            #expect(!saved.contains(canary))
            #expect(!capture.payloads.contains { $0.contains(canary) })
            #expect(!decoded.contains { $0.contains(canary) })
            #expect(!message.contains(canary))
        }
        let records = try fileLines.map { line in
            try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        #expect(records.contains { $0["event"] as? String == "refresh_failed" })
        let readFailures = records.filter { $0["event"] as? String == "cache_load_failed" }
        #expect(!readFailures.isEmpty)
        #expect(LogPrivacy.safeErrorCode(deniedReadCode) == deniedReadCode)
        for record in readFailures {
            #expect(record["level"] as? String == "error")
            #expect(record["metadata"] as? [String: String] == ["error": deniedReadCode])
        }
    }

    @Test("A real cache write failure keeps fresh events and reports lost durability")
    func failedSaveWarnsWithoutDiscardingFreshEvents() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let obstruction = Data("synthetic-cache-parent-obstruction".utf8)
        try obstruction.write(to: fixture.cacheDirectory)
        let fresh = fixture.event("fresh")
        try #require(fixture.saveFails([fresh]), "The real cache save must fail before this recovery probe runs.")
        #expect(try Data(contentsOf: fixture.cacheDirectory) == obstruction)
        let coordinator = fixture.coordinator([.success([fresh])])

        let outcome = try #require(await coordinator.refresh(reason: "timer"))

        #expect(outcome.didSucceed)
        #expect(outcome.events == [fresh])
        #expect(outcome.events?.allSatisfy { !$0.isFromCache } == true)
        #expect(outcome.statusMessage?.isEmpty == false)
        #expect(try Data(contentsOf: fixture.cacheDirectory) == obstruction)
        #expect(!FileManager.default.fileExists(atPath: fixture.cache.fileURL.path))
    }

    @Test("Latest memory survives failed writes and fetches but does not survive a new coordinator")
    func latestMemorySurvivesOnlyWithinItsCoordinator() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("synthetic-cache-parent-obstruction".utf8).write(to: fixture.cacheDirectory)
        let earlier = fixture.event("earlier")
        let latest = fixture.event("latest")
        try #require(fixture.saveFails([latest]), "The real cache save must fail before this recovery probe runs.")
        let coordinator = fixture.coordinator([
            .success([earlier]), .success([latest]),
            .failure(.requestFailed(503)), .failure(.requestFailed(503))
        ])

        let firstSuccess = try #require(await coordinator.refresh(reason: "timer"))
        let latestSuccess = try #require(await coordinator.refresh(reason: "timer"))
        let firstFailure = try #require(await coordinator.refresh(reason: "timer"))
        let secondFailure = try #require(await coordinator.refresh(reason: "timer"))

        #expect(firstSuccess.events?.map(\.eventID) == [earlier.eventID])
        #expect(latestSuccess.didSucceed)
        #expect(latestSuccess.events?.map(\.eventID) == [latest.eventID])
        #expect(latestSuccess.statusMessage?.isEmpty == false)
        #expect(!firstFailure.didSucceed)
        #expect(!secondFailure.didSucceed)
        #expect(firstFailure.events?.map(\.eventID) == [latest.eventID])
        #expect(secondFailure.events?.map(\.eventID) == [latest.eventID])
        let recoveryMessage = try #require(secondFailure.statusMessage)
        #expect(!recoveryMessage.isEmpty)
        #expect(!recoveryMessage.localizedCaseInsensitiveContains("using local cache"))
        #expect(!FileManager.default.fileExists(atPath: fixture.cache.fileURL.path))

        let restarted = fixture.coordinator([.failure(.requestFailed(503)), .failure(.requestFailed(503))])
        _ = await restarted.refresh(reason: "startup")
        let afterRestart = try #require(await restarted.refresh(reason: "timer"))

        #expect(!afterRestart.didSucceed)
        #expect(afterRestart.events == nil)
        let message = try #require(afterRestart.statusMessage)
        #expect(!message.localizedCaseInsensitiveContains("using local cache"))
    }

    @Test("Fresh memory takes precedence over readable old disk data after a failed save")
    func latestMemoryBeatsOlderDiskCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let older = fixture.event("older-on-disk")
        let latest = fixture.event("latest-in-memory")
        try fixture.cache.save(events: [older], detectedLinks: [:], settings: fixture.settings, now: TestDates.now.addingTimeInterval(-60))
        let oldBytes = try Data(contentsOf: fixture.cache.fileURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.cacheDirectory.path)
        let originalPermissions = try #require(attributes[.posixPermissions] as? NSNumber)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: fixture.cacheDirectory.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.cacheDirectory.path)
        try #require(fixture.saveFails([latest]), "This environment did not enforce the temporary directory write restriction.")
        let readable = try #require(try fixture.cache.load(now: TestDates.now, settings: fixture.settings))
        #expect(readable.events.map(\.eventID) == [older.eventID])
        #expect(try Data(contentsOf: fixture.cache.fileURL) == oldBytes)
        let coordinator = fixture.coordinator([
            .success([latest]), .failure(.requestFailed(503)), .failure(.requestFailed(503))
        ])

        let success = try #require(await coordinator.refresh(reason: "timer"))
        let firstFailure = try #require(await coordinator.refresh(reason: "timer"))
        let secondFailure = try #require(await coordinator.refresh(reason: "timer"))

        #expect(success.didSucceed)
        #expect(success.events?.map(\.eventID) == [latest.eventID])
        #expect(success.statusMessage?.isEmpty == false)
        #expect(firstFailure.events?.map(\.eventID) == [latest.eventID])
        #expect(secondFailure.events?.map(\.eventID) == [latest.eventID])
        #expect(secondFailure.statusMessage?.isEmpty == false)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == oldBytes)

        let restarted = fixture.coordinator([.failure(.requestFailed(503))])
        let afterRestart = try #require(await restarted.refresh(reason: "startup"))
        #expect(!afterRestart.didSucceed)
        #expect(afterRestart.events?.map(\.eventID) == [older.eventID])
        #expect(afterRestart.events?.allSatisfy(\.isFromCache) == true)
    }

    @Test("A valid empty disk snapshot remains distinct from an unavailable cache")
    func validEmptyCacheRemainsAvailable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let online = fixture.coordinator([.success([])])
        let success = try #require(await online.refresh(reason: "timer"))
        #expect(success.didSucceed)
        #expect(success.events?.isEmpty == true)
        #expect(success.statusMessage == nil)
        let saved = try #require(try fixture.cache.loadUnfiltered())
        #expect(saved.events.isEmpty)
        #expect(saved.cachedAt == TestDates.now)
        let restarted = fixture.coordinator([.failure(.requestFailed(503)), .failure(.requestFailed(503))])

        let first = try #require(await restarted.refresh(reason: "startup"))
        let second = try #require(await restarted.refresh(reason: "timer"))

        #expect(!first.didSucceed)
        #expect(!second.didSucceed)
        #expect(first.events?.isEmpty == true)
        #expect(second.events?.isEmpty == true)
        #expect(second.statusMessage?.isEmpty == false)
    }

    @Test("A successful disk save still protects meetings after restart and repeated fetch failure")
    func persistedCacheRemainsAPassingFallback() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let event = fixture.event("persisted")
        let online = fixture.coordinator([.success([event])])
        let success = try #require(await online.refresh(reason: "timer"))
        #expect(success.didSucceed)
        #expect(success.statusMessage == nil)
        #expect(try fixture.cache.loadUnfiltered()?.events.map(\.eventID) == [event.eventID])
        let restarted = fixture.coordinator([.failure(.requestFailed(503)), .failure(.requestFailed(503))])

        let first = try #require(await restarted.refresh(reason: "startup"))
        let second = try #require(await restarted.refresh(reason: "timer"))

        #expect(!first.didSucceed)
        #expect(!second.didSucceed)
        #expect(first.events?.map(\.eventID) == [event.eventID])
        #expect(second.events?.map(\.eventID) == [event.eventID])
        #expect(second.events?.allSatisfy(\.isFromCache) == true)
        #expect(second.statusMessage?.localizedCaseInsensitiveContains("cache") == true)
    }

    enum UnavailableCache: CaseIterable, Sendable {
        case missing, corrupt
    }

    enum ReadDenial: CaseIterable, Sendable {
        case file, ancestor
    }

    private struct Fixture {
        let directory: URL
        let cacheDirectory: URL
        let cache: EventCacheStore
        let calendar = UserCalendar(
            id: "synthetic-cache-account::calendar", accountID: "synthetic-cache-account",
            displayName: "Synthetic cache calendar", isPrimary: true, isSelected: true
        )
        var settings: AppSettingsSnapshot {
            var snapshot = AppSettingsSnapshot.defaults
            snapshot.selectedCalendarIDs = [calendar.id]
            return snapshot
        }

        init(cacheDirectoryName: String = "cache") throws {
            directory = try TestTempDirectory.make()
            cacheDirectory = directory.appending(path: cacheDirectoryName)
            cache = EventCacheStore(fileURL: cacheDirectory.appending(path: "event-cache.json"))
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }

        func event(_ id: String) -> CalendarEventOccurrence {
            var event = CalendarEventOccurrence.sample(
                eventID: id, title: "Synthetic cache meeting", startDate: TestDates.start,
                calendarID: calendar.id, htmlLink: nil
            )
            event.providerID = "synthetic-cache"
            event.accountID = calendar.accountID
            event.updatedAt = TestDates.now
            return event
        }

        func saveFails(_ events: [CalendarEventOccurrence]) -> Bool {
            do {
                try cache.save(events: events, detectedLinks: [:], settings: settings, now: TestDates.now)
                return false
            } catch {
                return true
            }
        }

        @MainActor
        func coordinator(
            _ responses: [Result<[CalendarEventOccurrence], CalendarProviderError>],
            diagnostics: DiagnosticsRecorder? = nil
        ) -> RefreshCoordinator {
            let snapshot = settings
            return RefreshCoordinator(
                provider: RefreshCacheRecoveryProvider(calendar: calendar, responses: responses),
                cacheStore: cache, settings: { snapshot }, now: { TestDates.now },
                diagnostics: diagnostics ?? DiagnosticsRecorder(directory: directory.appending(path: "diagnostics"), nativeSink: { _, _ in })
            )
        }
    }
}

private actor RefreshCacheRecoveryProvider: CalendarProvider {
    nonisolated let providerID = "synthetic-cache"
    private let calendar: UserCalendar
    private var responses: [Result<[CalendarEventOccurrence], CalendarProviderError>]

    init(calendar: UserCalendar, responses: [Result<[CalendarEventOccurrence], CalendarProviderError>]) {
        self.calendar = calendar
        self.responses = responses
    }

    var authState: CalendarProviderAuthState {
        get async { .connected(accountEmail: "synthetic-cache@example.invalid") }
    }

    func accounts() async -> [ConnectedCalendarAccount] {
        [ConnectedCalendarAccount(id: calendar.accountID, displayName: "Synthetic cache account")]
    }

    func calendars() async throws -> [UserCalendar] { [calendar] }

    func events(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        try await refresh(in: window)
    }

    func refresh(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        try await refresh(in: window, calendars: [calendar])
    }

    func refresh(in window: CalendarFetchWindow, calendars: [UserCalendar]) async throws -> [CalendarEventOccurrence] {
        guard !responses.isEmpty else { throw CalendarProviderError.requestFailed(503) }
        let events = try responses.removeFirst().get()
        let selected = Set(calendars.map(\.id))
        return events.filter { selected.contains($0.calendarID) }
    }

    func reconnect() async throws {}
    func removeAccount(id: String) async throws {}
}
