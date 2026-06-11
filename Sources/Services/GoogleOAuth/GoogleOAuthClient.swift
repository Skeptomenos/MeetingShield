import AppKit
import CryptoKit
import Foundation

struct GoogleOAuthClient: Sendable {
    var configuration: GoogleOAuthConfiguration
    var keychain: any KeychainStoring
    var session: URLSession

    private let legacyTokenKey = "google.oauth.token"
    private let tokenIndexKey = "google.oauth.tokens.index"
    private let tokenCollectionKey = "google.oauth.tokens"

    init(
        configuration: GoogleOAuthConfiguration,
        keychain: any KeychainStoring = KeychainService.shared,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.keychain = keychain
        self.session = session
    }

    func storedToken() -> GoogleOAuthToken? {
        storedTokens().first
    }

    func storedTokens() -> [GoogleOAuthToken] {
        if let collection = storedTokenCollection(), !collection.tokens.isEmpty {
            return sortedTokens(collection.tokens)
        }

        var tokens: [GoogleOAuthToken] = []
        for accountID in storedAccountIDs() {
            guard let value = keychain.retrieve(forKey: tokenKey(accountID: accountID)),
                  let data = value.data(using: .utf8),
                  let token = try? JSONDecoder().decode(GoogleOAuthToken.self, from: data) else {
                continue
            }
            tokens.append(token)
        }
        if tokens.isEmpty, let legacyToken = storedLegacyToken() {
            tokens.append(legacyToken)
        }
        if !tokens.isEmpty {
            migrateTokensToCollection(tokens)
        }
        return sortedTokens(tokens)
    }

    private func storedTokenCollection() -> GoogleOAuthTokenCollection? {
        guard let value = keychain.retrieve(forKey: tokenCollectionKey),
              let data = value.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(GoogleOAuthTokenCollection.self, from: data)
    }

    private func storedLegacyToken() -> GoogleOAuthToken? {
        guard let value = keychain.retrieve(forKey: legacyTokenKey),
              let data = value.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(GoogleOAuthToken.self, from: data)
    }

    func saveToken(_ token: GoogleOAuthToken) throws {
        if let accountID = token.accountID {
            try saveToken(token, accountID: accountID, accountDisplayName: token.accountDisplayName ?? "Google Calendar")
            return
        }
        try saveTokenCollection([token])
        cleanupLegacyTokenItems(accountIDs: [])
    }

    func saveToken(_ token: GoogleOAuthToken, accountID: String, accountDisplayName: String) throws {
        let assignedToken = token.assigned(to: accountID, displayName: accountDisplayName)
        var tokens = storedTokens().filter { $0.accountID != accountID }
        tokens.append(assignedToken)
        try saveTokenCollection(tokens)
        cleanupLegacyTokenItems(accountIDs: [accountID])
    }

    func clearToken() throws {
        let accountIDs = storedTokens().compactMap(\.accountID) + storedAccountIDs()
        try keychain.delete(forKey: tokenCollectionKey)
        for accountID in accountIDs {
            try keychain.delete(forKey: tokenKey(accountID: accountID))
        }
        try keychain.delete(forKey: tokenIndexKey)
        try keychain.delete(forKey: legacyTokenKey)
    }

    func removeToken(accountID: String) throws {
        let remainingTokens = storedTokens().filter { $0.accountID != accountID }
        if remainingTokens.isEmpty {
            try keychain.delete(forKey: tokenCollectionKey)
        } else {
            try saveTokenCollection(remainingTokens)
        }
        try keychain.delete(forKey: tokenKey(accountID: accountID))
        let remaining = storedAccountIDs().filter { $0 != accountID }
        if remaining.isEmpty {
            try keychain.delete(forKey: tokenIndexKey)
        } else {
            try saveAccountIDs(remaining)
        }
    }

    func validAccessToken() async throws -> String {
        let token = try await validTokens().firstRequired()
        return token.accessToken
    }

    func validTokens() async throws -> [GoogleOAuthToken] {
        let tokens = storedTokens()
        guard !tokens.isEmpty else {
            AppLog.oauth.debug("validTokens missingStoredTokens")
            throw CalendarProviderError.disconnected
        }
        var valid: [GoogleOAuthToken] = []
        var lastError: Error?
        for token in tokens {
            do {
                valid.append(try await validToken(token))
            } catch {
                lastError = error
                AppLog.oauth.error("validTokenFailed account=\(LogPrivacy.redactedID(token.accountID ?? "legacy"), privacy: .public) error=\(LogPrivacy.errorClass(error), privacy: .public)")
            }
        }
        guard !valid.isEmpty else {
            throw lastError ?? CalendarProviderError.disconnected
        }
        return valid
    }

    func validToken(for accountID: String) async throws -> GoogleOAuthToken {
        guard let token = storedTokens().first(where: { $0.accountID == accountID }) else {
            throw CalendarProviderError.disconnected
        }
        return try await validToken(token)
    }

    func validToken(_ token: GoogleOAuthToken) async throws -> GoogleOAuthToken {
        if token.isUsable {
            AppLog.oauth.debug("validAccessToken usable")
            return token
        }
        guard let refreshToken = token.refreshToken else {
            AppLog.oauth.error("validAccessToken missingRefreshToken")
            throw CalendarProviderError.authExpired("No refresh token available")
        }
        AppLog.oauth.info("refreshTokenStart account=\(LogPrivacy.redactedID(token.accountID ?? "legacy"), privacy: .public)")
        let refreshed = try await refresh(refreshToken: refreshToken, existingToken: token)
        let assigned = token.accountID.map {
            refreshed.assigned(to: $0, displayName: token.accountDisplayName ?? "Google Calendar")
        } ?? refreshed
        try saveToken(assigned)
        AppLog.oauth.info("refreshTokenSucceeded account=\(LogPrivacy.redactedID(assigned.accountID ?? "legacy"), privacy: .public)")
        return assigned
    }

    @MainActor
    func authorize() async throws -> GoogleOAuthToken {
        AppLog.oauth.info("authorizationStart configured=\(LogPrivacy.bool(configuration.isConfigured), privacy: .public) expectedClientType=desktop scopeCount=\(AppIdentity.googleScopes.count, privacy: .public)")
        guard configuration.isConfigured else {
            AppLog.oauth.error("authorizationFailed reason=notConfigured")
            throw GoogleOAuthError.notConfigured
        }
        let pkce = try GoogleOAuthPKCE.generate()
        let loopbackServer = try GoogleOAuthLoopbackServer(path: configuration.loopbackPath)
        let redirectURI = loopbackServer.redirectURI
        let authURL = try authorizationURL(redirectURI: redirectURI, pkce: pkce)

        AppLog.oauth.info("authorizationOpenBrowserAttempt loopbackHost=127.0.0.1 path=\(configuration.loopbackPath, privacy: .public)")
        try openAuthorizationURL(authURL)
        AppLog.oauth.info("authorizationOpenBrowserSucceeded")

        let callbackURL = try await loopbackServer.waitForCallback()
        let code = try authorizationCode(from: callbackURL)
        AppLog.oauth.info("authorizationCodeReceived")
        let token = try await exchangeAuthorizationCode(code, redirectURI: redirectURI, codeVerifier: pkce.codeVerifier)
        AppLog.oauth.info("authorizationSucceeded")
        return token
    }

    @MainActor
    func openAuthorizationURL(_ url: URL) throws {
        // NSWorkspace avoids blocking the main actor the way Process +
        // waitUntilExit did.
        guard NSWorkspace.shared.open(url) else {
            AppLog.oauth.error("authorizationOpenBrowserFailed")
            throw GoogleOAuthError.invalidAuthorizationURL
        }
    }

    func authorizationURL(redirectURI: String, pkce: GoogleOAuthPKCE) throws -> URL {
        var components = URLComponents(url: AppIdentity.googleOAuthAuthorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: AppIdentity.googleScopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        guard let url = components.url else { throw GoogleOAuthError.invalidAuthorizationURL }
        return url
    }

    func authorizationCode(from callbackURL: URL) throws -> String {
        let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = queryItems.first(where: { $0.name == "error" })?.value {
            AppLog.oauth.error("authorizationDenied reason=\(error, privacy: .public)")
            throw GoogleOAuthError.authorizationDenied(error)
        }
        guard let code = queryItems.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            AppLog.oauth.error("authorizationMissingCode")
            throw GoogleOAuthError.missingAuthorizationCode
        }
        return code
    }

    func authorizationCodeTokenBody(code: String, redirectURI: String, codeVerifier: String) -> Data {
        formEncoded(oauthClientParameters().merging([
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code"
        ]) { _, new in new })
    }

    func refreshTokenBody(refreshToken: String) -> Data {
        formEncoded(oauthClientParameters().merging([
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]) { _, new in new })
    }

    func decodeTokenResponse(
        _ data: Data,
        fallbackRefreshToken: String?,
        receivedAt: Date = Date()
    ) throws -> GoogleOAuthToken {
        let decoded = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
        return GoogleOAuthToken(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken ?? fallbackRefreshToken,
            expiresAt: receivedAt.addingTimeInterval(TimeInterval(decoded.expiresIn)),
            scope: decoded.scope ?? AppIdentity.googleScopes.joined(separator: " "),
            tokenType: decoded.tokenType
        )
    }

    private func exchangeAuthorizationCode(_ code: String, redirectURI: String, codeVerifier: String) async throws -> GoogleOAuthToken {
        let body = authorizationCodeTokenBody(code: code, redirectURI: redirectURI, codeVerifier: codeVerifier)
        return try await tokenRequest(body: body, fallbackRefreshToken: nil)
    }

    private func refresh(refreshToken: String, existingToken: GoogleOAuthToken) async throws -> GoogleOAuthToken {
        let body = refreshTokenBody(refreshToken: refreshToken)
        return try await tokenRequest(body: body, fallbackRefreshToken: existingToken.refreshToken)
    }

    private func tokenRequest(body: Data, fallbackRefreshToken: String?) async throws -> GoogleOAuthToken {
        var request = URLRequest(url: AppIdentity.googleOAuthTokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        AppLog.oauth.debug("tokenRequestStart")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let tokenError = decodeTokenError(data)
            if let http = response as? HTTPURLResponse {
                AppLog.oauth.error("tokenRequestFailed status=\(http.statusCode, privacy: .public) googleError=\(tokenError ?? "unknown", privacy: .public)")
            } else {
                AppLog.oauth.error("tokenRequestFailed status=invalidResponse")
            }
            if tokenError == "invalid_grant" {
                throw CalendarProviderError.authExpired("Google rejected the refresh token")
            }
            throw GoogleOAuthError.tokenExchangeFailed(status: (response as? HTTPURLResponse)?.statusCode, googleError: tokenError)
        }
        AppLog.oauth.info("tokenRequestSucceeded status=\(http.statusCode, privacy: .public)")
        return try decodeTokenResponse(data, fallbackRefreshToken: fallbackRefreshToken)
    }

    private func oauthClientParameters() -> [String: String] {
        var values = ["client_id": configuration.clientID.trimmingCharacters(in: .whitespacesAndNewlines)]
        let clientSecret = configuration.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clientSecret.isEmpty {
            values["client_secret"] = clientSecret
        }
        return values
    }

    private func decodeTokenError(_ data: Data) -> String? {
        guard let decoded = try? JSONDecoder().decode(GoogleTokenErrorResponse.self, from: data) else { return nil }
        return decoded.error
    }

    private func storedAccountIDs() -> [String] {
        guard let value = keychain.retrieve(forKey: tokenIndexKey),
              let data = value.data(using: .utf8),
              let index = try? JSONDecoder().decode(GoogleOAuthTokenIndex.self, from: data) else {
            return []
        }
        return index.accountIDs
    }

    private func saveAccountIDs(_ accountIDs: [String]) throws {
        let index = GoogleOAuthTokenIndex(accountIDs: Array(Set(accountIDs)).sorted())
        let data = try JSONEncoder().encode(index)
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        try keychain.save(value, forKey: tokenIndexKey)
    }

    private func tokenKey(accountID: String) -> String {
        let digest = SHA256.hash(data: Data(accountID.utf8))
        let prefix = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16)
        return "google.oauth.token.\(prefix)"
    }

    private func saveTokenCollection(_ tokens: [GoogleOAuthToken]) throws {
        let collection = GoogleOAuthTokenCollection(tokens: sortedTokens(tokens))
        let data = try JSONEncoder().encode(collection)
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        try keychain.save(value, forKey: tokenCollectionKey)
    }

    private func migrateTokensToCollection(_ tokens: [GoogleOAuthToken]) {
        do {
            try saveTokenCollection(tokens)
            cleanupLegacyTokenItems(accountIDs: tokens.compactMap(\.accountID))
            AppLog.oauth.info("legacyTokenItemsMigrated count=\(tokens.count, privacy: .public)")
        } catch {
            AppLog.oauth.error("legacyTokenItemsMigrationFailed error=\(LogPrivacy.errorClass(error), privacy: .public)")
        }
    }

    private func cleanupLegacyTokenItems(accountIDs: [String]) {
        for accountID in accountIDs {
            try? keychain.delete(forKey: tokenKey(accountID: accountID))
        }
        try? keychain.delete(forKey: tokenIndexKey)
        try? keychain.delete(forKey: legacyTokenKey)
    }

    private func sortedTokens(_ tokens: [GoogleOAuthToken]) -> [GoogleOAuthToken] {
        tokens.sorted { first, second in
            let firstKey = first.accountID ?? first.accountDisplayName ?? first.accessToken
            let secondKey = second.accountID ?? second.accountDisplayName ?? second.accessToken
            return firstKey.localizedCaseInsensitiveCompare(secondKey) == .orderedAscending
        }
    }

    private func formEncoded(_ values: [String: String]) -> Data {
        values
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private func percentEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private struct GoogleOAuthTokenIndex: Codable {
    var accountIDs: [String]
}

private struct GoogleOAuthTokenCollection: Codable {
    var tokens: [GoogleOAuthToken]
}

private extension Array where Element == GoogleOAuthToken {
    func firstRequired() throws -> GoogleOAuthToken {
        guard let token = first else { throw CalendarProviderError.disconnected }
        return token
    }
}

private struct GoogleTokenResponse: Decodable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Int
    var scope: String?
    var tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }
}

private struct GoogleTokenErrorResponse: Decodable {
    var error: String?
}
