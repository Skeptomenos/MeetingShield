import Foundation
import Testing
@testable import MeetingShield

@Suite("Diagnostic boundaries")
struct DiagnosticBoundaryTests {
    @Test("Static diagnostics are disabled outside assembled app bundles")
    func staticDiagnosticsRespectBundleBoundary() {
        let testBundle = URL(fileURLWithPath: "/tmp/MeetingShieldPackageTests.xctest")
        let appBundle = URL(fileURLWithPath: "/Applications/Meeting Shield.app")

        #expect(DiagnosticsRecorder.recorder(for: testBundle) === DiagnosticsRecorder.disabled)
        #expect(DiagnosticsRecorder.recorder(for: appBundle) === DiagnosticsRecorder.shared)
        #expect(DiagnosticsRecorder.applicationDefault === DiagnosticsRecorder.disabled)
    }

    @Test("OAuth callback errors omit private values from both diagnostic sinks", arguments: 0..<5)
    func callbackErrorIsPrivate(canaryIndex: Int) throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let canary = privateValues()[canaryIndex]
        let capture = DiagnosticTestCapture()
        let recorder = DiagnosticsRecorder(directory: directory, nativeSink: { capture.record($0, $1) })
        let client = GoogleOAuthClient(
            configuration: GoogleOAuthConfiguration(clientID: "test-client"),
            keychain: InMemoryKeychain(),
            diagnostics: recorder
        )
        var components = URLComponents(string: "http://127.0.0.1:49152/callback")!
        components.queryItems = [URLQueryItem(name: "error", value: canary)]
        let callback = try #require(components.url)

        #expect(throws: GoogleOAuthError.authorizationDenied(canary)) {
            _ = try client.authorizationCode(from: callback)
        }

        let records = try assertPrivateOutput(directory: directory, capture: capture, canaries: [canary])
        let record = try #require(records.first { $0["event"] as? String == "oauth_authorization_failed" })
        #expect((record["metadata"] as? [String: String])?["code"] == "unknown")
    }

    @Test("Token endpoint failures omit response bodies and token data", arguments: 0..<5)
    func tokenErrorIsPrivate(canaryIndex: Int) async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let values = privateValues()
        let canary = values[canaryIndex]
        let capture = DiagnosticTestCapture()
        let recorder = DiagnosticsRecorder(directory: directory, nativeSink: { capture.record($0, $1) })
        let marker = UUID().uuidString
        let session = tokenSession(marker: marker)
        defer { session.invalidateAndCancel() }
        let response = try JSONSerialization.data(withJSONObject: [
            "error": canary,
            "error_description": values.joined(separator: " ")
        ])
        StubURLProtocol.register(
            matcher: { $0.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker },
            response: .init(statusCode: 400, body: response)
        )
        let client = GoogleOAuthClient(
            configuration: GoogleOAuthConfiguration(clientID: values[1], clientSecret: values[3]),
            keychain: InMemoryKeychain(),
            session: session,
            diagnostics: recorder
        )
        let token = expiredToken(privateValues: values)
        try client.saveToken(token)

        await #expect(throws: GoogleOAuthError.tokenExchangeFailed(status: 400, googleError: canary)) {
            _ = try await client.validToken(token)
        }

        let records = try assertPrivateOutput(directory: directory, capture: capture, canaries: values)
        let record = try #require(records.first { $0["event"] as? String == "oauth_token_failed" })
        let metadata = try #require(record["metadata"] as? [String: String])
        #expect(metadata["code"] == "unknown")
        #expect(metadata["status"] == "400")
    }

    @Test("Invalid grant remains an authorization expiry with a safe code")
    func invalidGrantStillRequiresReconnect() async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let values = privateValues()
        let capture = DiagnosticTestCapture()
        let recorder = DiagnosticsRecorder(directory: directory, nativeSink: { capture.record($0, $1) })
        let marker = UUID().uuidString
        let session = tokenSession(marker: marker)
        defer { session.invalidateAndCancel() }
        let response = try JSONSerialization.data(withJSONObject: ["error": "invalid_grant", "error_description": values[4]])
        StubURLProtocol.register(
            matcher: { $0.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker },
            response: .init(statusCode: 400, body: response)
        )
        let client = GoogleOAuthClient(
            configuration: GoogleOAuthConfiguration(clientID: "test-client"),
            keychain: InMemoryKeychain(),
            session: session,
            diagnostics: recorder
        )
        let token = expiredToken(privateValues: values)
        try client.saveToken(token)

        do {
            _ = try await client.validToken(token)
            Issue.record("Invalid grant unexpectedly returned a token")
        } catch CalendarProviderError.authExpired {
        } catch {
            Issue.record("Invalid grant no longer produces authorization expiry")
        }

        let records = try assertPrivateOutput(directory: directory, capture: capture, canaries: values)
        let record = try #require(records.first { $0["event"] as? String == "oauth_token_failed" })
        #expect((record["metadata"] as? [String: String])?["code"] == "invalid_grant")
    }

    @Test("Provider failures omit arbitrary NSError domains and refresh reasons", arguments: 0..<5)
    @MainActor
    func providerErrorIsPrivate(canaryIndex: Int) async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let values = privateValues()
        let canary = values[canaryIndex]
        let capture = DiagnosticTestCapture()
        let recorder = DiagnosticsRecorder(directory: directory, nativeSink: { capture.record($0, $1) })
        let provider = FakeCalendarProvider()
        provider.refreshError = NSError(domain: canary, code: 17, userInfo: [NSLocalizedDescriptionKey: values.joined(separator: " ")])
        let coordinator = RefreshCoordinator(
            provider: provider,
            cacheStore: EventCacheStore(fileURL: directory.appending(path: "event-cache.json")),
            settings: { .defaults },
            now: { TestDates.now },
            diagnostics: recorder
        )

        let outcome = await coordinator.refresh(reason: canary)
        #expect(outcome?.didSucceed == false)
        #expect(outcome?.skipped == false)

        let records = try assertPrivateOutput(directory: directory, capture: capture, canaries: values)
        let record = try #require(records.first { $0["event"] as? String == "refresh_failed" })
        let metadata = try #require(record["metadata"] as? [String: String])
        #expect(metadata["error"] == "unknown")
        #expect(metadata["reason"] == "unknown")
    }

    @Test("A real Google provider failure omits its private response body")
    @MainActor
    func googleProviderResponseIsPrivate() async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let values = privateValues()
        let capture = DiagnosticTestCapture()
        let recorder = DiagnosticsRecorder(directory: directory, nativeSink: { capture.record($0, $1) })
        let marker = UUID().uuidString
        let session = tokenSession(marker: marker)
        defer { session.invalidateAndCancel() }
        let response = try JSONSerialization.data(withJSONObject: ["error": ["message": values.joined(separator: " ")]])
        StubURLProtocol.register(
            matcher: { $0.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker },
            response: .init(statusCode: 503, body: response)
        )
        let client = GoogleOAuthClient(
            configuration: GoogleOAuthConfiguration(clientID: "test-client"),
            keychain: InMemoryKeychain(),
            session: session,
            diagnostics: recorder
        )
        var token = expiredToken(privateValues: values)
        token.expiresAt = Date().addingTimeInterval(3600)
        try client.saveToken(token)
        let coordinator = RefreshCoordinator(
            provider: GoogleCalendarProvider(oauthClient: client),
            cacheStore: EventCacheStore(fileURL: directory.appending(path: "event-cache.json")),
            settings: { .defaults },
            now: { TestDates.now },
            diagnostics: recorder
        )

        let outcome = await coordinator.refresh(reason: "timer")
        #expect(outcome?.didSucceed == false)
        #expect(outcome?.skipped == false)

        let records = try assertPrivateOutput(directory: directory, capture: capture, canaries: values)
        let record = try #require(records.first { $0["event"] as? String == "refresh_failed" })
        #expect((record["metadata"] as? [String: String])?["error"] == "calendar_request_failed")
    }

    @Test("A real cache write failure records only a safe error class")
    @MainActor
    func cacheWriteErrorIsPrivate() async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let values = privateValues()
        let blockedParent = directory.appending(path: values[0])
        let original = Data(values[4].utf8)
        try original.write(to: blockedParent)
        let capture = DiagnosticTestCapture()
        let recorder = DiagnosticsRecorder(directory: directory, nativeSink: { capture.record($0, $1) })
        let coordinator = RefreshCoordinator(
            provider: FakeCalendarProvider(),
            cacheStore: EventCacheStore(fileURL: blockedParent.appending(path: "event-cache.json")),
            settings: { .defaults },
            now: { TestDates.now },
            diagnostics: recorder
        )

        let outcome = await coordinator.refresh(reason: "timer")
        #expect(outcome?.didSucceed == true)
        #expect(try Data(contentsOf: blockedParent) == original)

        let records = try assertPrivateOutput(directory: directory, capture: capture, canaries: values)
        let record = try #require(records.first { $0["event"] as? String == "cache_save_failed" })
        let metadata = try #require(record["metadata"] as? [String: String])
        let code = try #require(metadata["error"])
        #expect(code.hasPrefix("NSCocoaErrorDomain.") || code.hasPrefix("NSPOSIXErrorDomain."))
        #expect(LogPrivacy.safeErrorCode(code) == code)
    }

    private func privateValues() -> [String] {
        let marker = UUID().uuidString
        return [
            "private-title-\(marker)",
            "private-\(marker)@example.invalid",
            "https://example.invalid/private-\(marker)",
            "private-token-\(marker)",
            "private-response-body-\(marker)"
        ]
    }

    private func tokenSession(marker: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Meeting-Shield-Test": marker]
        return URLSession(configuration: configuration)
    }

    private func expiredToken(privateValues: [String]) -> GoogleOAuthToken {
        GoogleOAuthToken(
            accessToken: privateValues[3],
            refreshToken: privateValues[4],
            expiresAt: .distantPast,
            scope: AppIdentity.googleScopes.joined(separator: " "),
            tokenType: "Bearer",
            accountID: privateValues[1],
            accountDisplayName: privateValues[0]
        )
    }

    private func assertPrivateOutput(
        directory: URL,
        capture: DiagnosticTestCapture,
        canaries: [String]
    ) throws -> [[String: Any]] {
        let saved = try String(contentsOf: directory.appending(path: "diagnostics.jsonl"), encoding: .utf8)
        let lines = saved.split(separator: "\n").map(String.init)
        let native = capture.payloads
        #expect(!lines.isEmpty)
        #expect(native == lines)
        let decoded = try capture.decodedStrings()
        for canary in canaries {
            #expect(!saved.contains(canary))
            #expect(!native.contains { $0.contains(canary) })
            #expect(!decoded.contains { $0.contains(canary) })
        }
        return try lines.map { line in
            try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }
}
