import Foundation
import Testing
@testable import MeetingShield

@Suite("Google OAuth desktop flow")
struct GoogleOAuthClientTests {
    @Test("PKCE challenge matches the S256 reference vector")
    func pkceChallengeMatchesReferenceVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let pkce = GoogleOAuthPKCE(codeVerifier: verifier)

        #expect(pkce.codeChallenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("Generated PKCE verifier uses the native app-safe character set")
    func generatedPKCEVerifierIsUsable() throws {
        let pkce = try GoogleOAuthPKCE.generate()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

        #expect((43...128).contains(pkce.codeVerifier.count))
        #expect(pkce.codeVerifier.rangeOfCharacter(from: allowed.inverted) == nil)
        #expect(pkce.codeChallenge.rangeOfCharacter(from: allowed.inverted) == nil)
    }

    @Test("Authorization URL includes loopback redirect and PKCE challenge")
    func authorizationURLContainsLoopbackAndPKCE() throws {
        let client = makeClient(clientID: " desktop-client-id ")
        let pkce = GoogleOAuthPKCE(codeVerifier: "test-verifier")
        let url = try client.authorizationURL(redirectURI: "http://127.0.0.1:49152/oauth2redirect", pkce: pkce)
        let query = queryValues(in: url)

        #expect(url.scheme == "https")
        #expect(url.host == "accounts.google.com")
        #expect(query["client_id"] == "desktop-client-id")
        #expect(query["redirect_uri"] == "http://127.0.0.1:49152/oauth2redirect")
        #expect(query["response_type"] == "code")
        #expect(query["code_challenge"] == GoogleOAuthPKCE.challenge(for: "test-verifier"))
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["access_type"] == "offline")
        #expect(query["prompt"] == "consent")
        #expect(query["scope"] == AppIdentity.googleScopes.joined(separator: " "))
    }

    @Test("Authorization callback parsing handles success and user denial")
    func authorizationCodeParsingHandlesCodeAndErrors() throws {
        let client = makeClient()

        let code = try client.authorizationCode(from: URL(string: "http://127.0.0.1:49152/oauth2redirect?code=abc123")!)
        #expect(code == "abc123")

        #expect(throws: GoogleOAuthError.authorizationDenied("access_denied")) {
            _ = try client.authorizationCode(from: URL(string: "http://127.0.0.1:49152/oauth2redirect?error=access_denied")!)
        }
        #expect(throws: GoogleOAuthError.missingAuthorizationCode) {
            _ = try client.authorizationCode(from: URL(string: "http://127.0.0.1:49152/oauth2redirect")!)
        }
    }

    @Test("Token exchange body includes PKCE verifier and form encoding")
    func tokenExchangeBodyIncludesPKCEVerifier() {
        let client = makeClient(clientID: "desktop-client-id", clientSecret: "desktop-client-secret")
        let body = client.authorizationCodeTokenBody(
            code: "code with spaces",
            redirectURI: "http://127.0.0.1:49152/oauth2redirect",
            codeVerifier: "verifier-value"
        )
        let values = formValues(in: body)

        #expect(values["client_id"] == "desktop-client-id")
        #expect(values["client_secret"] == "desktop-client-secret")
        #expect(values["code"] == "code with spaces")
        #expect(values["redirect_uri"] == "http://127.0.0.1:49152/oauth2redirect")
        #expect(values["code_verifier"] == "verifier-value")
        #expect(values["grant_type"] == "authorization_code")
    }

    @Test("Refresh token body and token decoding preserve existing refresh token")
    func refreshTokenPreservation() throws {
        let client = makeClient(clientID: "desktop-client-id", clientSecret: "desktop-client-secret")
        let refreshBody = formValues(in: client.refreshTokenBody(refreshToken: "existing-refresh"))
        #expect(refreshBody["client_id"] == "desktop-client-id")
        #expect(refreshBody["client_secret"] == "desktop-client-secret")
        #expect(refreshBody["refresh_token"] == "existing-refresh")
        #expect(refreshBody["grant_type"] == "refresh_token")

        let response = Data("""
        {
          "access_token": "new-access",
          "expires_in": 3600,
          "scope": "scope-a scope-b",
          "token_type": "Bearer"
        }
        """.utf8)

        let receivedAt = Date(timeIntervalSince1970: 1_000)
        let token = try client.decodeTokenResponse(response, fallbackRefreshToken: "existing-refresh", receivedAt: receivedAt)

        #expect(token.accessToken == "new-access")
        #expect(token.refreshToken == "existing-refresh")
        #expect(token.expiresAt == receivedAt.addingTimeInterval(3600))
        #expect(token.scope == "scope-a scope-b")
        #expect(token.tokenType == "Bearer")
    }

    @Test("Token storage keeps multiple Google accounts")
    func tokenStorageKeepsMultipleAccounts() throws {
        let keychain = InMemoryKeychain()
        let client = makeClient(keychain: keychain)
        let first = token(accessToken: "first-access")
        let second = token(accessToken: "second-access")

        try client.saveToken(first, accountID: "first@example.com", accountDisplayName: "First")
        try client.saveToken(second, accountID: "second@example.com", accountDisplayName: "Second")

        #expect(keychain.valueCount == 1)
        let tokens = client.storedTokens()
        #expect(Set(tokens.compactMap(\.accountID)) == ["first@example.com", "second@example.com"])
        #expect(Set(tokens.map(\.accessToken)) == ["first-access", "second-access"])

        try client.removeToken(accountID: "first@example.com")
        let remaining = client.storedTokens()
        #expect(keychain.valueCount == 1)
        #expect(remaining.map(\.accountID) == ["second@example.com"])

        try client.clearToken()
        #expect(keychain.valueCount == 0)
        #expect(client.storedTokens().isEmpty)
    }

    @Test("Expired access tokens remain connected when a refresh token is stored")
    func expiredAccessTokenWithRefreshTokenIsConnected() async throws {
        let keychain = InMemoryKeychain()
        let client = makeClient(keychain: keychain)
        try client.saveToken(
            token(
                accessToken: "expired-access",
                refreshToken: "stored-refresh",
                expiresAt: Date().addingTimeInterval(-60)
            ),
            accountID: "first@example.com",
            accountDisplayName: "First"
        )
        let provider = GoogleCalendarProvider(oauthClient: client)

        #expect(await provider.authState == .connected(accountEmail: "First"))
    }

    @Test("Expired access tokens without refresh tokens require reconnect")
    func expiredAccessTokenWithoutRefreshTokenIsExpired() async throws {
        let keychain = InMemoryKeychain()
        let client = makeClient(keychain: keychain)
        try client.saveToken(
            token(
                accessToken: "expired-access",
                expiresAt: Date().addingTimeInterval(-60),
                includeRefreshToken: false
            ),
            accountID: "first@example.com",
            accountDisplayName: "First"
        )
        let provider = GoogleCalendarProvider(oauthClient: client)

        #expect(await provider.authState == .expired(reason: "No refresh token available"))
    }

    @Test("Loopback listener captures the browser callback")
    func loopbackListenerCapturesCallback() async throws {
        let server = try GoogleOAuthLoopbackServer(path: "/oauth2redirect-test")
        let waitTask = Task { try await server.waitForCallback(timeout: 5) }
        try await Task.sleep(nanoseconds: 50_000_000)

        let callbackURL = URL(string: "\(server.redirectURI)?code=loopback-code&state=state-1")!
        let (_, response) = try await URLSession.shared.data(from: callbackURL)
        let http = try #require(response as? HTTPURLResponse)
        let receivedURL = try await waitTask.value

        #expect(http.statusCode == 200)
        #expect(try makeClient().authorizationCode(from: receivedURL) == "loopback-code")
    }

    private func makeClient(
        clientID: String = "desktop-client-id",
        clientSecret: String = "",
        keychain: any KeychainStoring = InMemoryKeychain()
    ) -> GoogleOAuthClient {
        GoogleOAuthClient(
            configuration: GoogleOAuthConfiguration(clientID: clientID, clientSecret: clientSecret),
            keychain: keychain
        )
    }

    private func token(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date = Date().addingTimeInterval(3600),
        includeRefreshToken: Bool = true
    ) -> GoogleOAuthToken {
        GoogleOAuthToken(
            accessToken: accessToken,
            refreshToken: includeRefreshToken ? (refreshToken ?? "refresh-\(accessToken)") : nil,
            expiresAt: expiresAt,
            scope: AppIdentity.googleScopes.joined(separator: " "),
            tokenType: "Bearer"
        )
    }

    private func queryValues(in url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .compactMap { item in item.value.map { (item.name, $0) } })
    }

    private func formValues(in data: Data) -> [String: String] {
        let body = String(decoding: data, as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: body.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let key = parts[0].removingPercentEncoding ?? parts[0]
            let value = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
            return (key, value)
        })
    }
}

private final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    var valueCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }

    func save(_ value: String, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    func retrieve(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func delete(forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}
