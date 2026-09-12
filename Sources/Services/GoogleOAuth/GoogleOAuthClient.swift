import AppKit
import CryptoKit
import Foundation

struct GoogleOAuthClient: Sendable {
    typealias AuthorizationResponse = @MainActor @Sendable (GoogleOAuthPKCE) async throws -> (callbackURL: URL, redirectURI: String)

    struct AuthorizationTicket: Sendable {
        fileprivate let mutationState: GoogleOAuthMutationState
        fileprivate let revisions: GoogleOAuthMutationState.Revisions
    }

    struct LegacyBindingTicket: Sendable {
        fileprivate let mutationState: GoogleOAuthMutationState
        fileprivate let token: GoogleOAuthToken
        fileprivate let revisions: GoogleOAuthMutationState.Revisions
    }

    var configuration: GoogleOAuthConfiguration
    var keychain: any KeychainStoring
    var session: URLSession
    private let diagnostics: DiagnosticsRecorder
    private let authorizationResponse: AuthorizationResponse?

    private let legacyTokenKey = "google.oauth.token"
    private let tokenIndexKey = "google.oauth.tokens.index"
    private let tokenCollectionKey = "google.oauth.tokens"

    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    init(
        configuration: GoogleOAuthConfiguration,
        keychain: any KeychainStoring = KeychainService.shared,
        session: URLSession = GoogleOAuthClient.defaultSession,
        diagnostics: DiagnosticsRecorder = .shared,
        authorizationResponse: AuthorizationResponse? = nil
    ) {
        self.configuration = configuration
        self.keychain = keychain
        self.session = session
        self.diagnostics = diagnostics
        self.authorizationResponse = authorizationResponse
    }

    var persistenceFailures: Set<GoogleOAuthPersistenceFailure> {
        keychain.oauthMutationState.withLock { $0.persistenceFailures }
    }

    func retryPersistence() {
        keychain.oauthMutationState.withLock { revisions in
            let inventory = readTokenInventory(revisions: &revisions)
            guard inventory.isComplete, revisions.legacyInspectionComplete else { return }
            retryLegacyCleanup(revisions: &revisions)
        }
    }

    func storedToken() -> GoogleOAuthToken? {
        storedTokens().first
    }

    func storedTokens() -> [GoogleOAuthToken] {
        tokenInventory().tokens
    }

    func tokenInventory() -> GoogleOAuthTokenInventory {
        keychain.oauthMutationState.withLock { revisions in readTokenInventory(revisions: &revisions) }
    }

    private func readTokenInventory(revisions: inout GoogleOAuthMutationState.Revisions) -> GoogleOAuthTokenInventory {
        do {
            if let collection = try storedValue(GoogleOAuthTokenCollection.self, forKey: tokenCollectionKey) {
                let inventory = validatedInventory(tokens: collection.tokens)
                if let failure = inventory.failure {
                    revisions.persistenceFailures.insert(.read)
                    AppLog.oauth.error("credentialInventoryFailed error=\(failure.errorClass, privacy: .public)")
                } else {
                    revisions.persistenceFailures.remove(.read)
                    revisions.persistenceFailures.remove(.migration)
                    inspectLegacyItems(revisions: &revisions)
                }
                return inventory
            }
            guard revisions.pendingLegacyKeys.isEmpty,
                  !revisions.persistenceFailures.contains(.legacyCleanup) else { throw KeychainError.unexpectedData }

            let accountIDs = try storedAccountIDs()
            var tokens: [GoogleOAuthToken] = []
            var failure: CalendarAccountFailure?
            for accountID in accountIDs {
                do {
                    guard !accountID.isEmpty,
                          let token = try storedValue(GoogleOAuthToken.self, forKey: tokenKey(accountID: accountID)),
                          token.accountID == accountID else {
                        throw KeychainError.unexpectedData
                    }
                    tokens.append(token)
                } catch {
                    if failure == nil { failure = CalendarAccountFailure(error) }
                }
            }
            if accountIDs.isEmpty,
               let legacyToken = try storedValue(GoogleOAuthToken.self, forKey: legacyTokenKey) {
                tokens.append(legacyToken)
            }
            var inventory = validatedInventory(tokens: tokens, knownAccountIDs: Set(accountIDs), failure: failure)
            if inventory.isComplete {
                revisions.persistenceFailures.remove(.read)
                if !inventory.tokens.isEmpty {
                    inventory.failure = migrateTokensToCollection(inventory.tokens, revisions: &revisions)
                } else {
                    revisions.legacyInspectionComplete = true
                }
            } else {
                revisions.persistenceFailures.insert(.read)
            }
            if let failure = inventory.failure {
                AppLog.oauth.error("credentialInventoryFailed error=\(failure.errorClass, privacy: .public)")
            }
            return inventory
        } catch {
            revisions.persistenceFailures.insert(.read)
            let failure = CalendarAccountFailure(error)
            AppLog.oauth.error("credentialInventoryFailed error=\(failure.errorClass, privacy: .public)")
            return GoogleOAuthTokenInventory(tokens: [], knownAccountIDs: [], failure: failure)
        }
    }

    private func validatedInventory(
        tokens: [GoogleOAuthToken],
        knownAccountIDs: Set<String> = [],
        failure: CalendarAccountFailure? = nil
    ) -> GoogleOAuthTokenInventory {
        let slots = Dictionary(grouping: tokens, by: \.accountID)
        let uniqueTokens = tokens.filter { token in
            token.accountID != "" && slots[token.accountID]?.count == 1
        }
        let knownIDs = knownAccountIDs.union(tokens.compactMap(\.accountID)).filter { !$0.isEmpty }
        return GoogleOAuthTokenInventory(
            tokens: sortedTokens(uniqueTokens),
            knownAccountIDs: Set(knownIDs),
            failure: failure ?? (uniqueTokens.count == tokens.count ? nil : CalendarAccountFailure(KeychainError.unexpectedData))
        )
    }

    private func storedValue<Value: Decodable>(_ type: Value.Type, forKey key: String) throws -> Value? {
        guard let value = try keychain.read(forKey: key) else { return nil }
        return try JSONDecoder().decode(type, from: Data(value.utf8))
    }

    private func completeTokenInventory(
        revisions: inout GoogleOAuthMutationState.Revisions,
        operation: GoogleOAuthPersistenceFailure? = nil
    ) throws -> GoogleOAuthTokenInventory {
        let inventory = readTokenInventory(revisions: &revisions)
        if let failure = inventory.failure {
            if let operation { revisions.persistenceFailures.insert(operation) }
            throw failure
        }
        return inventory
    }

    func saveToken(_ token: GoogleOAuthToken) throws {
        if let accountID = token.accountID {
            try saveToken(token, accountID: accountID, accountDisplayName: token.accountDisplayName ?? "Google Calendar")
            return
        }
        try keychain.oauthMutationState.withLock { revisions in
            let inventory = try completeTokenInventory(revisions: &revisions, operation: .save(accountID: nil))
            var tokens = inventory.tokens.filter { $0.accountID != nil }
            tokens.append(token)
            try saveTokenCollection(tokens, operation: .save(accountID: nil), revisions: &revisions)
            revisions.invalidate(accountID: nil)
            cleanupLegacyTokenItems(accountIDs: Array(inventory.knownAccountIDs), revisions: &revisions)
        }
    }

    func authorizationTicket() throws -> AuthorizationTicket {
        let mutationState = keychain.oauthMutationState
        return try mutationState.withLock { revisions in
            try Task.checkCancellation()
            return AuthorizationTicket(mutationState: mutationState, revisions: revisions)
        }
    }

    func saveToken(
        _ token: GoogleOAuthToken,
        accountID: String,
        accountDisplayName: String,
        authorization: AuthorizationTicket? = nil
    ) throws {
        let mutationState = keychain.oauthMutationState
        try mutationState.withLock { revisions in
            if let authorization {
                try Task.checkCancellation()
                guard mutationState === authorization.mutationState,
                      revisions.revision(for: accountID) == authorization.revisions.revision(for: accountID) else {
                    throw CancellationError()
                }
            }
            let assignedToken = token.assigned(to: accountID, displayName: accountDisplayName)
            let inventory = try completeTokenInventory(revisions: &revisions, operation: .save(accountID: accountID))
            var tokens = inventory.tokens.filter { $0.accountID != accountID }
            tokens.append(assignedToken)
            try saveTokenCollection(tokens, operation: .save(accountID: accountID), revisions: &revisions)
            revisions.persistenceFailures.remove(.remove(accountID: accountID))
            revisions.invalidate(accountID: accountID)
            cleanupLegacyTokenItems(accountIDs: Array(inventory.knownAccountIDs.union([accountID])), revisions: &revisions)
        }
    }

    func legacyBindingTicket(for token: GoogleOAuthToken) throws -> LegacyBindingTicket {
        let mutationState = keychain.oauthMutationState
        return try mutationState.withLock { revisions in
            try Task.checkCancellation()
            guard token.accountID == nil,
                  try completeTokenInventory(revisions: &revisions).tokens.filter({ $0.accountID == nil }) == [token] else {
                throw CancellationError()
            }
            return LegacyBindingTicket(
                mutationState: mutationState,
                token: token,
                revisions: revisions
            )
        }
    }

    func bindLegacyToken(
        _ ticket: LegacyBindingTicket,
        accountID: String,
        accountDisplayName: String
    ) throws -> GoogleOAuthToken {
        let mutationState = keychain.oauthMutationState
        guard mutationState === ticket.mutationState else { throw CancellationError() }
        guard !accountID.isEmpty else { throw CalendarProviderError.invalidResponse }
        return try mutationState.withLock { revisions in
            try Task.checkCancellation()
            guard revisions.revision(for: nil) == ticket.revisions.revision(for: nil),
                  revisions.revision(for: accountID) == ticket.revisions.revision(for: accountID) else {
                throw CancellationError()
            }
            let inventory = try completeTokenInventory(revisions: &revisions, operation: .save(accountID: accountID))
            guard inventory.tokens.filter({ $0.accountID == nil }) == [ticket.token],
                  !inventory.tokens.contains(where: { $0.accountID == accountID }) else {
                throw CancellationError()
            }
            let assigned = ticket.token.assigned(to: accountID, displayName: accountDisplayName)
            var tokens = inventory.tokens.filter { $0.accountID != nil }
            tokens.append(assigned)
            try saveTokenCollection(tokens, operation: .save(accountID: accountID), revisions: &revisions)
            revisions.persistenceFailures.remove(.save(accountID: nil))
            revisions.invalidate(accountID: nil)
            revisions.invalidate(accountID: accountID)
            cleanupLegacyTokenItems(accountIDs: Array(inventory.knownAccountIDs.union([accountID])), revisions: &revisions)
            return assigned
        }
    }

    func clearToken() throws {
        try keychain.oauthMutationState.withLock { revisions in
            let inventory = try completeTokenInventory(revisions: &revisions, operation: .clear)
            try saveTokenCollection([], operation: .clear, revisions: &revisions)
            revisions.persistenceFailures = revisions.persistenceFailures.filter { failure in
                switch failure {
                case .save, .remove, .clear: false
                case .read, .migration, .legacyCleanup: true
                }
            }
            revisions.invalidateAll()
            cleanupLegacyTokenItems(accountIDs: Array(inventory.knownAccountIDs), revisions: &revisions)
        }
    }

    func removeToken(accountID: String) throws {
        try keychain.oauthMutationState.withLock { revisions in
            let inventory = try completeTokenInventory(revisions: &revisions, operation: .remove(accountID: accountID))
            let remainingTokens = inventory.tokens.filter { $0.accountID != accountID }
            try saveTokenCollection(remainingTokens, operation: .remove(accountID: accountID), revisions: &revisions)
            revisions.persistenceFailures.remove(.save(accountID: accountID))
            revisions.invalidate(accountID: accountID)
            cleanupLegacyTokenItems(accountIDs: Array(inventory.knownAccountIDs.union([accountID])), revisions: &revisions)
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
            try Task.checkCancellation()
            do {
                valid.append(try await validToken(token))
            } catch {
                try Task.checkCancellation()
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
        let mutationState = keychain.oauthMutationState
        let (revision, isUsable) = try mutationState.withLock { revisions in
            try Task.checkCancellation()
            let inventory = readTokenInventory(revisions: &revisions)
            guard inventory.tokens.contains(token) else {
                throw CalendarProviderError.disconnected
            }
            let isUsable = token.isUsable
            if !isUsable, let failure = inventory.failure { throw failure }
            return (revisions.revision(for: token.accountID), isUsable)
        }
        if isUsable {
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
        return try mutationState.withLock { revisions in
            try Task.checkCancellation()
            guard revisions.revision(for: token.accountID) == revision else {
                throw CancellationError()
            }
            let inventory = try completeTokenInventory(revisions: &revisions, operation: .save(accountID: token.accountID))
            guard let current = inventory.tokens.first(where: { $0.accountID == token.accountID }) else {
                throw CalendarProviderError.disconnected
            }
            guard current == token else {
                guard current.isUsable else { throw CancellationError() }
                return current
            }
            var tokens = inventory.tokens.filter { $0.accountID != token.accountID }
            tokens.append(assigned)
            try saveTokenCollection(tokens, operation: .save(accountID: token.accountID), revisions: &revisions)
            cleanupLegacyTokenItems(accountIDs: Array(inventory.knownAccountIDs), revisions: &revisions)
            AppLog.oauth.info("refreshTokenSucceeded account=\(LogPrivacy.redactedID(assigned.accountID ?? "legacy"), privacy: .public)")
            return assigned
        }
    }

    @MainActor
    func authorize() async throws -> GoogleOAuthToken {
        try Task.checkCancellation()
        AppLog.oauth.info("authorizationStart configured=\(LogPrivacy.bool(configuration.isConfigured), privacy: .public) expectedClientType=desktop scopeCount=\(AppIdentity.googleScopes.count, privacy: .public)")
        guard configuration.isConfigured else {
            AppLog.oauth.error("authorizationFailed reason=notConfigured")
            throw GoogleOAuthError.notConfigured
        }
        let pkce = try GoogleOAuthPKCE.generate()
        let response: (callbackURL: URL, redirectURI: String)
        if let authorizationResponse {
            response = try await authorizationResponse(pkce)
        } else {
            response = try await browserAuthorizationResponse(pkce: pkce)
        }
        try Task.checkCancellation()
        let callbackURL = response.callbackURL
        let redirectURI = response.redirectURI
        let code = try authorizationCode(from: callbackURL)
        AppLog.oauth.info("authorizationCodeReceived")
        let token = try await exchangeAuthorizationCode(code, redirectURI: redirectURI, codeVerifier: pkce.codeVerifier)
        try Task.checkCancellation()
        AppLog.oauth.info("authorizationSucceeded")
        return token
    }

    @MainActor
    private func browserAuthorizationResponse(pkce: GoogleOAuthPKCE) async throws -> (callbackURL: URL, redirectURI: String) {
        let loopbackServer = try GoogleOAuthLoopbackServer(path: configuration.loopbackPath)
        let redirectURI = loopbackServer.redirectURI
        let authURL = try authorizationURL(redirectURI: redirectURI, pkce: pkce)

        AppLog.oauth.info("authorizationOpenBrowserAttempt loopbackHost=127.0.0.1")
        try openAuthorizationURL(authURL)
        AppLog.oauth.info("authorizationOpenBrowserSucceeded")

        let callbackURL = try await loopbackServer.waitForCallback()
        return (callbackURL, redirectURI)
    }

    @MainActor
    func openAuthorizationURL(_ url: URL) throws {
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
            diagnostics.recordEvent("oauth_authorization_failed", metadata: ["code": LogPrivacy.oauthErrorCode(error)])
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
            diagnostics.recordEvent("oauth_token_failed", metadata: [
                "code": LogPrivacy.oauthErrorCode(tokenError ?? "unknown"),
                "status": (response as? HTTPURLResponse).map { String($0.statusCode) } ?? "unknown"
            ])
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

    private func storedAccountIDs() throws -> [String] {
        try storedValue(GoogleOAuthTokenIndex.self, forKey: tokenIndexKey)?.accountIDs ?? []
    }

    private func tokenKey(accountID: String) -> String {
        let digest = SHA256.hash(data: Data(accountID.utf8))
        let prefix = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16)
        return "google.oauth.token.\(prefix)"
    }

    private func saveTokenCollection(
        _ tokens: [GoogleOAuthToken],
        operation: GoogleOAuthPersistenceFailure,
        revisions: inout GoogleOAuthMutationState.Revisions
    ) throws {
        do {
            let collection = GoogleOAuthTokenCollection(tokens: sortedTokens(tokens))
            let data = try JSONEncoder().encode(collection)
            guard let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedData
            }
            try keychain.save(value, forKey: tokenCollectionKey)
            revisions.persistenceFailures.remove(operation)
        } catch {
            revisions.persistenceFailures.insert(operation)
            AppLog.oauth.error("credentialPersistenceFailed error=\(LogPrivacy.errorClass(error), privacy: .public)")
            throw error
        }
    }

    private func migrateTokensToCollection(
        _ tokens: [GoogleOAuthToken],
        revisions: inout GoogleOAuthMutationState.Revisions
    ) -> CalendarAccountFailure? {
        do {
            try saveTokenCollection(tokens, operation: .migration, revisions: &revisions)
            cleanupLegacyTokenItems(accountIDs: tokens.compactMap(\.accountID), revisions: &revisions)
            AppLog.oauth.info("legacyTokenItemsMigrated count=\(tokens.count, privacy: .public)")
            return nil
        } catch {
            AppLog.oauth.error("legacyTokenItemsMigrationFailed error=\(LogPrivacy.errorClass(error), privacy: .public)")
            return CalendarAccountFailure(error)
        }
    }

    private func inspectLegacyItems(
        revisions: inout GoogleOAuthMutationState.Revisions,
        force: Bool = false
    ) {
        guard force || !revisions.legacyInspectionComplete else { return }
        do {
            let index = try storedValue(GoogleOAuthTokenIndex.self, forKey: tokenIndexKey)
            let legacy = try keychain.read(forKey: legacyTokenKey)
            if let index {
                revisions.pendingLegacyKeys.formUnion(index.accountIDs.map { tokenKey(accountID: $0) })
                revisions.pendingLegacyKeys.insert(tokenIndexKey)
            }
            if legacy != nil { revisions.pendingLegacyKeys.insert(legacyTokenKey) }
            revisions.legacyInspectionComplete = true
            if !revisions.pendingLegacyKeys.isEmpty {
                revisions.persistenceFailures.insert(.legacyCleanup)
            } else {
                revisions.persistenceFailures.remove(.legacyCleanup)
            }
        } catch {
            revisions.legacyInspectionComplete = false
            revisions.persistenceFailures.insert(.legacyCleanup)
            AppLog.oauth.error("legacyTokenCleanupFailed error=\(LogPrivacy.errorClass(error), privacy: .public)")
        }
    }

    private func cleanupLegacyTokenItems(
        accountIDs: [String],
        revisions: inout GoogleOAuthMutationState.Revisions
    ) {
        inspectLegacyItems(revisions: &revisions, force: true)
        guard revisions.legacyInspectionComplete else { return }
        revisions.pendingLegacyKeys.formUnion(accountIDs.map { tokenKey(accountID: $0) })
        revisions.pendingLegacyKeys.formUnion([tokenIndexKey, legacyTokenKey])
        retryLegacyCleanup(revisions: &revisions)
    }

    private func retryLegacyCleanup(revisions: inout GoogleOAuthMutationState.Revisions) {
        let accountKeys = revisions.pendingLegacyKeys.filter { $0 != tokenIndexKey && $0 != legacyTokenKey }.sorted()
        for key in accountKeys + [tokenIndexKey, legacyTokenKey] where revisions.pendingLegacyKeys.contains(key) {
            do {
                try keychain.delete(forKey: key)
                revisions.pendingLegacyKeys.remove(key)
            } catch {
                revisions.persistenceFailures.insert(.legacyCleanup)
                AppLog.oauth.error("legacyTokenCleanupFailed error=\(LogPrivacy.errorClass(error), privacy: .public)")
                return
            }
        }
        revisions.persistenceFailures.remove(.legacyCleanup)
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
