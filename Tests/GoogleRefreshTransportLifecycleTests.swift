import Foundation
import Testing
@testable import MeetingShield

@Suite("Google refresh transport lifecycle")
@MainActor
struct GoogleRefreshTransportLifecycleTests {
    @Test("Cancelling held HTTP preserves the newer selection and reports its missing coverage")
    func cancelledHTTPHandsOffNewerSelection() async throws {
        let fixture = try Fixture()
        let controller = fixture.makeController()
        defer { fixture.cleanup(controller) }
        await controller.refresh(reason: "launch")
        #expect(controller.events.map(\.eventID) == [fixture.transport.seedEventID])
        #expect(controller.statusMessage == nil)
        let originalCache = try Data(contentsOf: fixture.cache.fileURL)
        let original = try #require(try fixture.cache.loadUnfiltered())
        let originalAccount = try #require(original.accounts[fixture.transport.accountID])
        #expect(Set(originalAccount.calendars.map(\.id)) == fixture.calendarIDs)
        #expect(originalAccount.coverage?.calendarIDs == [fixture.transport.scopedID("a")])
        let originalCredentials = fixture.keychain.retrieve(forKey: "google.oauth.tokens")
        var ownerFinished = false
        let oldOwner = Task {
            await controller.refresh(reason: "timer")
            ownerFinished = true
        }
        defer { oldOwner.cancel() }
        try #require(await fixture.transport.wait(for: .oldHeld))
        fixture.settings.update { $0.selectedCalendarIDs = fixture.calendarIDs }

        await controller.refresh(reason: "settings")

        #expect(controller.statusMessage?.contains("no fetched coverage") == true)
        #expect(controller.events.map(\.eventID) == [fixture.transport.seedEventID])
        #expect(try Data(contentsOf: fixture.cache.fileURL) == originalCache)
        #expect(fixture.transport.snapshot.startedNewer.isEmpty)
        oldOwner.cancel()

        try #require(await fixture.transport.wait(for: .oldCancelled))
        try #require(await waitUntil { ownerFinished })
        await oldOwner.value
        try #require(await fixture.transport.wait(for: .newerHeld))

        let held = fixture.transport.snapshot
        #expect(held.cancelledOld == 1)
        #expect(!held.overlappedOldOwner)
        #expect(held.completedNewer.isEmpty)
        #expect(held.startedNewer == ["a", "b"])
        #expect(controller.statusMessage?.contains("no fetched coverage") == true)
        #expect(controller.events.map(\.eventID) == [fixture.transport.seedEventID])
        #expect(try Data(contentsOf: fixture.cache.fileURL) == originalCache)
        #expect(fixture.keychain.retrieve(forKey: "google.oauth.tokens") == originalCredentials)
        let cancelledIndex = try #require(held.sequence.firstIndex(of: "old-stop"))
        for calendar in ["a", "b"] {
            let startedIndex = try #require(held.sequence.firstIndex(of: "new-\(calendar)-start"))
            #expect(cancelledIndex < startedIndex)
        }
        #expect(fixture.transport.releaseNewer() == 2)
        let expectedEvents = Set([fixture.transport.currentEventID("a"), fixture.transport.currentEventID("b")])
        try #require(await waitUntil { Set(controller.events.map(\.eventID)) == expectedEvents })

        #expect(controller.statusMessage == nil)
        #expect(controller.events.allSatisfy { !$0.isFromCache })
        #expect(Set(controller.events.map(\.calendarID)) == fixture.calendarIDs)
        #expect(fixture.settings.snapshot.selectedCalendarIDs == fixture.calendarIDs)
        #expect(AppSettingsStore(domainName: fixture.domain).snapshot.selectedCalendarIDs == fixture.calendarIDs)
        let saved = try #require(try fixture.cache.loadUnfiltered())
        #expect(Set(saved.events.map(\.eventID)) == expectedEvents)
        #expect(saved.accounts[fixture.transport.accountID]?.coverage?.calendarIDs == fixture.calendarIDs)
        #expect(saved.accounts[fixture.transport.accountID]?.fetchedAt == fixture.now)
        #expect(fixture.keychain.retrieve(forKey: "google.oauth.tokens") == originalCredentials)
        let finished = fixture.transport.snapshot
        #expect(finished.catalogRequests == 3)
        #expect(finished.aRequests == 3)
        #expect(finished.bRequests == 1)
        #expect(finished.cancelledOld == 1)
        #expect(finished.completedNewer == ["a", "b"])
        #expect(finished.pendingCount == 0)
        #expect(finished.unmatched == 0)
        #expect(!finished.overlappedOldOwner)
        #expect(fixture.transport.releaseNewer() == 0)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        return condition()
    }

    @MainActor
    private struct Fixture {
        let now: Date
        let directory: URL
        let domain: String
        let defaults: UserDefaults
        let settings: AppSettingsStore
        let keychain: InMemoryKeychain
        let cache: EventCacheStore
        let state: ReminderStateStore
        let transport: HeldGoogleTransport
        let session: URLSession
        let provider: GoogleCalendarProvider

        var calendarIDs: Set<String> { [transport.scopedID("a"), transport.scopedID("b")] }

        init() throws {
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let directory = try TestTempDirectory.make()
            let domain = "MeetingShieldGoogleTransportLifecycle.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: domain))
            let transport = try HeldGoogleTransport(now: now)
            let settings = AppSettingsStore(domainName: domain)
            settings.update {
                $0.selectedCalendarIDs = [transport.scopedID("a")]
                $0.presentationModeDefault = true
                $0.soundEnabled = false
                $0.urgentRepeatSoundEnabled = false
                $0.wakeGraceEnabled = false
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [HeldGoogleURLProtocol.self]
            configuration.httpAdditionalHeaders = [HeldGoogleURLProtocol.markerHeader: transport.marker]
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 8
            let session = URLSession(configuration: configuration)
            let keychain = InMemoryKeychain()
            let client = GoogleOAuthClient(
                configuration: GoogleOAuthConfiguration(clientID: "synthetic-client-\(transport.marker)"),
                keychain: keychain,
                session: session,
                diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "oauth-diagnostics"), nativeSink: { _, _ in })
            )
            try client.saveToken(GoogleOAuthToken(
                accessToken: transport.accessToken,
                refreshToken: "synthetic-unused-refresh-\(transport.marker)",
                expiresAt: .distantFuture,
                scope: AppIdentity.googleScopes.joined(separator: " "),
                tokenType: "Bearer",
                accountID: transport.accountID,
                accountDisplayName: "Synthetic transport account"
            ))
            HeldGoogleURLProtocol.register(transport)
            self.now = now
            self.directory = directory
            self.domain = domain
            self.defaults = defaults
            self.settings = settings
            self.keychain = keychain
            self.transport = transport
            self.session = session
            self.provider = GoogleCalendarProvider(oauthClient: client)
            self.cache = EventCacheStore(fileURL: directory.appending(path: "cache.json"))
            self.state = ReminderStateStore(fileURL: directory.appending(path: "reminder-state.json"))
        }

        func makeController() -> MeetingShieldController {
            MeetingShieldController(
                settingsStore: settings, provider: provider, reminderStateStore: state, cacheStore: cache,
                notificationService: NoopNotificationService(), soundPlayer: UnexpectedSound(),
                dismissalPresenter: UnexpectedDismissal(), now: { now }, refreshMenuBar: {}
            )
        }

        func cleanup(_ controller: MeetingShieldController) {
            controller.stop()
            transport.close()
            session.invalidateAndCancel()
            HeldGoogleURLProtocol.remove(marker: transport.marker)
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private struct UnexpectedSound: AlertSoundPlaying {
        func playAlertSound() { Issue.record("The transport fixture must not play sound") }
    }

    @MainActor
    private final class UnexpectedDismissal: DismissalConfirming {
        func present(
            requestID: UUID, reminder: ScheduledReminder, source: DismissalRequestSource,
            completion: @escaping @MainActor (Bool) -> Void
        ) {
            Issue.record("The transport fixture must not present dismissal UI")
            completion(false)
        }

        func cancel(requestID: UUID) {}
    }

    private final class HeldGoogleTransport: @unchecked Sendable {
        enum Checkpoint {
            case oldHeld
            case oldCancelled
            case newerHeld
        }

        struct Snapshot {
            var catalogRequests = 0
            var aRequests = 0
            var bRequests = 0
            var cancelledOld = 0
            var startedNewer: Set<String> = []
            var completedNewer: Set<String> = []
            var pendingCount = 0
            var unmatched = 0
            var overlappedOldOwner = false
            var sequence: [String] = []
        }

        let marker: String
        let accountID: String
        let accessToken: String
        let seedEventID: String
        private let catalog: Data
        private let seedEvents: Data
        private let currentEvents: [String: Data]
        private let lock = NSLock()
        private var values = Snapshot()
        private var oldRequest: HeldGoogleURLProtocol?
        private var newerRequests: [String: HeldGoogleURLProtocol] = [:]
        private var closed = false

        private enum Response {
            case send(Data)
            case held
            case rejected
        }

        var snapshot: Snapshot {
            lock.withLock {
                var result = values
                result.pendingCount = (oldRequest == nil ? 0 : 1) + newerRequests.count
                return result
            }
        }

        init(now: Date) throws {
            let marker = UUID().uuidString.lowercased()
            self.marker = marker
            self.accountID = "transport-\(marker)@example.invalid"
            self.accessToken = "synthetic-transport-access-\(marker)"
            self.seedEventID = "seed-a-\(marker)"
            self.catalog = try JSONSerialization.data(withJSONObject: ["items": [
                ["id": "a-\(marker)", "summary": "Synthetic A", "selected": true, "primary": true, "accessRole": "reader"],
                ["id": "b-\(marker)", "summary": "Synthetic B", "selected": false, "primary": false, "accessRole": "reader"]
            ]])
            self.seedEvents = try Self.events(id: "seed-a-\(marker)", now: now)
            self.currentEvents = try [
                "a": Self.events(id: "current-a-\(marker)", now: now),
                "b": Self.events(id: "current-b-\(marker)", now: now)
            ]
        }

        func scopedID(_ calendar: String) -> String { "\(accountID)::\(calendar)-\(marker)" }
        func currentEventID(_ calendar: String) -> String { "current-\(calendar)-\(marker)" }

        func receive(_ request: HeldGoogleURLProtocol) {
            let action: Response = lock.withLock {
                guard !closed, request.request.httpMethod == "GET",
                      request.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(accessToken)",
                      request.request.url?.host == AppIdentity.googleCalendarBaseURL.host,
                      request.request.queryValues["pageToken"] == nil else {
                    values.unmatched += 1
                    return .rejected
                }
                let path = request.request.url?.path ?? ""
                if path == AppIdentity.googleCalendarBaseURL.appending(path: "users/me/calendarList").path {
                    values.catalogRequests += 1
                    return .send(catalog)
                }
                if path == AppIdentity.googleCalendarBaseURL.appending(path: "calendars/a-\(marker)/events").path {
                    values.aRequests += 1
                    if values.aRequests == 1 { return .send(seedEvents) }
                    if values.aRequests == 2, oldRequest == nil {
                        oldRequest = request
                        values.sequence.append("old-start")
                        return .held
                    }
                    if values.aRequests == 3, newerRequests["a"] == nil {
                        holdNewer(request, calendar: "a")
                        return .held
                    }
                }
                if path == AppIdentity.googleCalendarBaseURL.appending(path: "calendars/b-\(marker)/events").path {
                    values.bRequests += 1
                    if values.bRequests == 1, newerRequests["b"] == nil {
                        holdNewer(request, calendar: "b")
                        return .held
                    }
                }
                values.unmatched += 1
                return .rejected
            }
            switch action {
            case .send(let body):
                complete(request, body: body)
            case .held:
                break
            case .rejected:
                request.client?.urlProtocol(request, didFailWithError: URLError(.unsupportedURL))
            }
        }

        private func holdNewer(_ request: HeldGoogleURLProtocol, calendar: String) {
            values.overlappedOldOwner = values.overlappedOldOwner || oldRequest != nil
            values.startedNewer.insert(calendar)
            values.sequence.append("new-\(calendar)-start")
            newerRequests[calendar] = request
        }

        func cancel(_ request: HeldGoogleURLProtocol) {
            lock.withLock {
                if oldRequest === request {
                    oldRequest = nil
                    values.cancelledOld += 1
                    values.sequence.append("old-stop")
                } else if let calendar = newerRequests.first(where: { $0.value === request })?.key {
                    newerRequests.removeValue(forKey: calendar)
                }
            }
        }

        func releaseNewer() -> Int {
            let requests = lock.withLock {
                let requests = newerRequests
                newerRequests.removeAll()
                values.completedNewer.formUnion(requests.keys)
                return requests
            }
            for (calendar, request) in requests {
                guard let body = currentEvents[calendar] else { continue }
                complete(request, body: body)
            }
            return requests.count
        }

        func wait(for checkpoint: Checkpoint) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline {
                if reached(checkpoint) { return true }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
            }
            return reached(checkpoint)
        }

        private func reached(_ checkpoint: Checkpoint) -> Bool {
            lock.withLock {
                switch checkpoint {
                case .oldHeld: oldRequest != nil
                case .oldCancelled: values.cancelledOld == 1
                case .newerHeld: Set(newerRequests.keys) == ["a", "b"]
                }
            }
        }

        func close() {
            let pending = lock.withLock {
                closed = true
                let requests = Array(newerRequests.values) + (oldRequest.map { [$0] } ?? [])
                newerRequests.removeAll()
                oldRequest = nil
                return requests
            }
            for request in pending {
                request.client?.urlProtocol(request, didFailWithError: URLError(.cancelled))
            }
        }

        private func complete(_ request: HeldGoogleURLProtocol, body: Data) {
            guard let url = request.request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
                request.client?.urlProtocol(request, didFailWithError: URLError(.badServerResponse))
                return
            }
            request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
            request.client?.urlProtocol(request, didLoad: body)
            request.client?.urlProtocolDidFinishLoading(request)
        }

        private static func events(id: String, now: Date) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["items": [[
                "id": id,
                "summary": "Synthetic transport meeting",
                "status": "confirmed",
                "start": ["dateTime": ISO8601DateFormatter.stableString(from: now.addingTimeInterval(3_600))],
                "end": ["dateTime": ISO8601DateFormatter.stableString(from: now.addingTimeInterval(5_400))]
            ]]])
        }
    }

    private final class HeldGoogleURLProtocol: URLProtocol, @unchecked Sendable {
        static let markerHeader = "X-MeetingShield-Transport-Lifecycle"
        private static let lock = NSLock()
        nonisolated(unsafe) private static var transports: [String: HeldGoogleTransport] = [:]

        static func register(_ transport: HeldGoogleTransport) {
            lock.withLock { transports[transport.marker] = transport }
        }

        static func remove(marker: String) {
            lock.withLock { _ = transports.removeValue(forKey: marker) }
        }

        private var transport: HeldGoogleTransport? {
            guard let marker = request.value(forHTTPHeaderField: Self.markerHeader) else { return nil }
            return Self.lock.withLock { Self.transports[marker] }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let transport else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            transport.receive(self)
        }

        override func stopLoading() {
            transport?.cancel(self)
        }
    }
}
