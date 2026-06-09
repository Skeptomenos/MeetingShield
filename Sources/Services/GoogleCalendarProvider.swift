import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

struct GoogleOAuthConfiguration: Equatable, Sendable {
    var clientID: String
    var clientSecret: String = ""
    var redirectURI: String = ""
    var loopbackPath: String = "/oauth2redirect"

    var isConfigured: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct GoogleOAuthToken: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var scope: String
    var tokenType: String
    var accountID: String?
    var accountDisplayName: String?

    var isUsable: Bool {
        expiresAt.timeIntervalSinceNow > 60
    }

    var canRefresh: Bool {
        refreshToken?.isEmpty == false
    }

    func assigned(to accountID: String, displayName: String) -> GoogleOAuthToken {
        var copy = self
        copy.accountID = accountID
        copy.accountDisplayName = displayName
        return copy
    }
}

enum GoogleOAuthError: Error, Equatable, LocalizedError {
    case notConfigured
    case invalidAuthorizationURL
    case missingAuthorizationCode
    case authorizationDenied(String)
    case callbackTimedOut
    case loopbackServerFailed(String)
    case tokenExchangeFailed(status: Int?, googleError: String?)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Google OAuth client ID is required."
        case .invalidAuthorizationURL:
            "Google OAuth authorization URL could not be created."
        case .missingAuthorizationCode:
            "Google did not return an authorization code."
        case let .authorizationDenied(reason):
            "Google Calendar connection was cancelled or denied: \(reason)"
        case .callbackTimedOut:
            "Google Calendar connection timed out before the browser returned to Meeting Shield."
        case let .loopbackServerFailed(reason):
            "Meeting Shield could not start its local Google sign-in listener: \(reason)"
        case let .tokenExchangeFailed(_, googleError):
            if let googleError, !googleError.isEmpty {
                "Google token exchange failed (\(googleError))."
            } else {
                "Google token exchange failed."
            }
        }
    }
}

struct GoogleOAuthPKCE: Equatable, Sendable {
    var codeVerifier: String
    var codeChallenge: String

    init(codeVerifier: String) {
        self.codeVerifier = codeVerifier
        self.codeChallenge = Self.challenge(for: codeVerifier)
    }

    static func generate(byteCount: Int = 32) throws -> GoogleOAuthPKCE {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw GoogleOAuthError.loopbackServerFailed("Secure random generation failed with status \(status).")
        }
        return GoogleOAuthPKCE(codeVerifier: base64URLEncoded(Data(bytes)))
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncoded(Data(digest))
    }

    static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class SingleResumeContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        let continuation = takeContinuation()
        continuation?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        let continuation = takeContinuation()
        continuation?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = continuation
        self.continuation = nil
        return continuation
    }
}

final class GoogleOAuthLoopbackServer: @unchecked Sendable {
    let redirectURI: String

    private let socketFD: Int32
    private let port: UInt16
    private let path: String
    private let lock = NSLock()
    private var closed = false

    init(path: String = "/oauth2redirect") throws {
        self.path = path.hasPrefix("/") ? path : "/\(path)"

        let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            AppLog.oauth.error("loopbackSocketFailed step=socket")
            throw GoogleOAuthError.loopbackServerFailed(String(cString: strerror(errno)))
        }
        self.socketFD = socketFD

        var reuse: Int32 = 1
        guard setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse))) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(socketFD)
            AppLog.oauth.error("loopbackSocketFailed step=setsockopt")
            throw GoogleOAuthError.loopbackServerFailed(reason)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(socketFD, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(socketFD)
            AppLog.oauth.error("loopbackSocketFailed step=bind")
            throw GoogleOAuthError.loopbackServerFailed(reason)
        }

        guard Darwin.listen(socketFD, 1) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(socketFD)
            AppLog.oauth.error("loopbackSocketFailed step=listen")
            throw GoogleOAuthError.loopbackServerFailed(reason)
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.getsockname(socketFD, socketAddress, &boundAddressLength)
            }
        }
        guard nameResult == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(socketFD)
            AppLog.oauth.error("loopbackSocketFailed step=getsockname")
            throw GoogleOAuthError.loopbackServerFailed(reason)
        }

        port = UInt16(bigEndian: boundAddress.sin_port)
        redirectURI = "http://127.0.0.1:\(port)\(self.path)"
        AppLog.oauth.info("loopbackListenerStarted host=127.0.0.1 path=\(self.path, privacy: .public)")
    }

    deinit {
        closeListeningSocket()
    }

    func waitForCallback(timeout: TimeInterval = 180) async throws -> URL {
        AppLog.oauth.info("loopbackWaitForCallback timeoutSeconds=\(Int(timeout), privacy: .public)")
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let gate = SingleResumeContinuation(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let url = try self.acceptCallback()
                    self.closeListeningSocket()
                    gate.resume(returning: url)
                } catch {
                    self.closeListeningSocket()
                    gate.resume(throwing: error)
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                self.closeListeningSocket()
                AppLog.oauth.error("loopbackCallbackTimedOut")
                gate.resume(throwing: GoogleOAuthError.callbackTimedOut)
            }
        }
    }

    private func acceptCallback() throws -> URL {
        var clientAddress = sockaddr_in()
        var clientAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.accept(socketFD, socketAddress, &clientAddressLength)
            }
        }
        guard clientFD >= 0 else {
            throw GoogleOAuthError.loopbackServerFailed(String(cString: strerror(errno)))
        }
        defer { Darwin.close(clientFD) }

        let request = try readHTTPRequest(from: clientFD)
        guard let firstLine = request.components(separatedBy: "\r\n").first else {
            try sendResponse(to: clientFD, status: "400 Bad Request", body: "Meeting Shield could not read this Google sign-in callback.")
            AppLog.oauth.error("loopbackCallbackMalformed reason=empty")
            throw GoogleOAuthError.loopbackServerFailed("Callback request was empty.")
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            try sendResponse(to: clientFD, status: "400 Bad Request", body: "Meeting Shield could not read this Google sign-in callback.")
            AppLog.oauth.error("loopbackCallbackMalformed reason=requestLine")
            throw GoogleOAuthError.loopbackServerFailed("Callback request line was malformed.")
        }

        let target = String(parts[1])
        guard let callbackURL = URL(string: "http://127.0.0.1:\(port)\(target)"),
              URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.path == path else {
            try sendResponse(to: clientFD, status: "404 Not Found", body: "This sign-in callback does not belong to Meeting Shield.")
            AppLog.oauth.error("loopbackCallbackUnexpectedPath")
            throw GoogleOAuthError.loopbackServerFailed("Unexpected callback path.")
        }

        AppLog.oauth.info("loopbackCallbackReceived path=\(self.path, privacy: .public)")
        try sendResponse(
            to: clientFD,
            status: "200 OK",
            body: "Google Calendar is connected. You can close this browser tab and return to Meeting Shield."
        )
        return callbackURL
    }

    private func readHTTPRequest(from clientFD: Int32) throws -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while data.count < 16_384 {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.recv(clientFD, rawBuffer.baseAddress, rawBuffer.count, 0)
            }
            if count < 0 {
                throw GoogleOAuthError.loopbackServerFailed(String(cString: strerror(errno)))
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }

        return String(decoding: data, as: UTF8.self)
    }

    private func sendResponse(to clientFD: Int32, status: String, body: String) throws {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>Meeting Shield</title></head><body><p>\(body)</p></body></html>
        """
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """
        let bytes = [UInt8](response.utf8)
        let sent = bytes.withUnsafeBytes { rawBuffer in
            Darwin.send(clientFD, rawBuffer.baseAddress, rawBuffer.count, 0)
        }
        if sent < 0 {
            throw GoogleOAuthError.loopbackServerFailed(String(cString: strerror(errno)))
        }
    }

    private func closeListeningSocket() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.shutdown(socketFD, SHUT_RDWR)
        Darwin.close(socketFD)
    }
}

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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            AppLog.oauth.error("authorizationOpenBrowserFailed status=\(process.terminationStatus, privacy: .public)")
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

actor GoogleCalendarProvider: CalendarProvider {
    nonisolated let providerID = "google"

    private var oauthClient: GoogleOAuthClient
    private var mapper: GoogleCalendarMapper
    private var cachedCalendars: [UserCalendar] = []

    init(oauthClient: GoogleOAuthClient, mapper: GoogleCalendarMapper = GoogleCalendarMapper()) {
        self.oauthClient = oauthClient
        self.mapper = mapper
    }

    var authState: CalendarProviderAuthState {
        get async {
            guard oauthClient.configuration.isConfigured else { return .needsConfiguration }
        let tokens = oauthClient.storedTokens()
        guard !tokens.isEmpty else { return .disconnected }
            if tokens.contains(where: { $0.isUsable || $0.canRefresh }) {
                return .connected(accountEmail: accountStatusLabel(for: tokens))
            }
            return .expired(reason: "No refresh token available")
        }
    }

    func accounts() async -> [ConnectedCalendarAccount] {
        oauthClient.storedTokens()
            .compactMap { token in
                guard let accountID = token.accountID else { return nil }
                return ConnectedCalendarAccount(
                    id: accountID,
                    displayName: token.accountDisplayName ?? accountID
                )
            }
            .sorted { first, second in
                first.displayName.localizedCaseInsensitiveCompare(second.displayName) == .orderedAscending
            }
    }

    func calendars() async throws -> [UserCalendar] {
        AppLog.oauth.debug("googleCalendarListStart")
        let tokens = try await oauthClient.validTokens()
        var mergedCalendars: [UserCalendar] = []
        for token in tokens {
            let mapped = try await calendarList(for: token)
            if token.accountID == nil, let identity = mapper.accountIdentity(from: mapped) {
                try oauthClient.saveToken(token, accountID: identity.id, accountDisplayName: identity.displayName)
                AppLog.oauth.info("legacyTokenMigrated account=\(LogPrivacy.redactedID(identity.id), privacy: .public)")
            }
            mergedCalendars += mapped
        }
        cachedCalendars = mergedCalendars
        AppLog.oauth.info("googleCalendarListSucceeded accounts=\(tokens.count, privacy: .public) count=\(mergedCalendars.count, privacy: .public)")
        return mergedCalendars
    }

    func events(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        try await refresh(in: window)
    }

    func refresh(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        let calendars = cachedCalendars.isEmpty ? try await calendars() : cachedCalendars
        return try await refresh(in: window, calendars: calendars)
    }

    func refresh(in window: CalendarFetchWindow, calendars: [UserCalendar]) async throws -> [CalendarEventOccurrence] {
        AppLog.refresh.debug("googleEventsRefreshStart cachedCalendars=\(self.cachedCalendars.count, privacy: .public)")
        let selectedCalendars = calendars.filter(\.isSelected)
        var allEvents: [CalendarEventOccurrence] = []
        for calendar in selectedCalendars {
            let token = try await oauthClient.validToken(for: calendar.accountID)
            var components = URLComponents(
                url: AppIdentity.googleCalendarBaseURL
                    .appending(path: "calendars")
                    .appending(path: calendar.apiCalendarID)
                    .appending(path: "events"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "timeMin", value: ISO8601DateFormatter.stableString(from: window.start)),
                URLQueryItem(name: "timeMax", value: ISO8601DateFormatter.stableString(from: window.end)),
                URLQueryItem(name: "showDeleted", value: "true"),
                URLQueryItem(name: "conferenceDataVersion", value: "1")
            ]
            let data = try await get(url: components.url!, accessToken: token.accessToken)
            let mapped = try mapper.mapEventList(data: data, calendar: calendar)
            allEvents += mapped
            AppLog.refresh.debug("googleEventsCalendarFetched calendar=\(LogPrivacy.redactedID(calendar.id), privacy: .public) events=\(mapped.count, privacy: .public)")
        }
        AppLog.refresh.info("googleEventsRefreshSucceeded calendars=\(calendars.count, privacy: .public) selected=\(selectedCalendars.count, privacy: .public) events=\(allEvents.count, privacy: .public)")
        return allEvents
    }

    func reconnect() async throws {
        AppLog.oauth.info("providerReconnectStart")
        try await migrateLegacyTokensIfNeeded()
        let token = try await oauthClient.authorize()
        let calendars = try await calendarList(for: token)
        guard let identity = mapper.accountIdentity(from: calendars) else {
            AppLog.oauth.error("providerReconnectFailed reason=missingAccountIdentity")
            throw CalendarProviderError.invalidResponse
        }
        try oauthClient.saveToken(token, accountID: identity.id, accountDisplayName: identity.displayName)
        cachedCalendars = try await self.calendars()
        AppLog.oauth.info("providerReconnectSucceeded account=\(LogPrivacy.redactedID(identity.id), privacy: .public) totalCalendars=\(self.cachedCalendars.count, privacy: .public)")
    }

    func removeAccount(id: String) async throws {
        try oauthClient.removeToken(accountID: id)
        cachedCalendars.removeAll { $0.accountID == id }
        AppLog.oauth.info("providerAccountRemoved account=\(LogPrivacy.redactedID(id), privacy: .public)")
    }

    private func calendarList(for token: GoogleOAuthToken) async throws -> [UserCalendar] {
        let url = AppIdentity.googleCalendarBaseURL.appending(path: "users/me/calendarList")
        let data = try await get(url: url, accessToken: token.accessToken)
        return try mapper.mapCalendarList(
            data: data,
            accountID: token.accountID,
            accountDisplayName: token.accountDisplayName
        )
    }

    private func migrateLegacyTokensIfNeeded() async throws {
        let legacyTokens = oauthClient.storedTokens().filter { $0.accountID == nil }
        for token in legacyTokens {
            let validToken = try await oauthClient.validToken(token)
            let calendars = try await calendarList(for: validToken)
            guard let identity = mapper.accountIdentity(from: calendars) else { continue }
            try oauthClient.saveToken(validToken, accountID: identity.id, accountDisplayName: identity.displayName)
            AppLog.oauth.info("legacyTokenMigratedBeforeReconnect account=\(LogPrivacy.redactedID(identity.id), privacy: .public)")
        }
    }

    private func accountStatusLabel(for tokens: [GoogleOAuthToken]) -> String {
        let names = Set(tokens.compactMap(\.accountDisplayName).filter { !$0.isEmpty })
        if names.count == 1, let name = names.first {
            return name
        }
        return "\(tokens.count) Google accounts"
    }

    private func get(url: URL, accessToken: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CalendarProviderError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            AppLog.refresh.error("googleRequestFailed status=\(http.statusCode, privacy: .public)")
            if http.statusCode == 401 { throw CalendarProviderError.authExpired("Google returned 401") }
            throw CalendarProviderError.requestFailed(http.statusCode)
        }
        return data
    }
}

struct GoogleCalendarMapper: Sendable {
    func mapCalendarList(
        data: Data,
        accountID suppliedAccountID: String? = nil,
        accountDisplayName suppliedAccountDisplayName: String? = nil
    ) throws -> [UserCalendar] {
        let response = try JSONDecoder().decode(GoogleCalendarListResponse.self, from: data)
        let identity = accountIdentity(from: response.items)
        let accountID = suppliedAccountID ?? identity?.id ?? "google"
        let accountDisplayName = suppliedAccountDisplayName ?? identity?.displayName ?? "Google Calendar"
        return response.items.map { item in
            let sourceID = item.id
            return UserCalendar(
                id: scopedCalendarID(accountID: accountID, calendarID: sourceID),
                sourceCalendarID: sourceID,
                accountID: accountID,
                accountDisplayName: accountDisplayName,
                displayName: item.summaryOverride ?? item.summary,
                isPrimary: item.primary ?? false,
                isSelected: !item.hidden,
                colorHex: item.backgroundColor
            )
        }
    }

    func accountIdentity(from calendars: [UserCalendar]) -> (id: String, displayName: String)? {
        guard let primary = calendars.first(where: \.isPrimary) ?? calendars.first else { return nil }
        return (primary.accountID, primary.accountDisplayName ?? primary.displayName)
    }

    private func accountIdentity(from items: [GoogleCalendarListItem]) -> (id: String, displayName: String)? {
        guard let primary = items.first(where: { $0.primary == true }) ?? items.first else { return nil }
        return (primary.id, primary.summary)
    }

    private func scopedCalendarID(accountID: String, calendarID: String) -> String {
        "\(accountID)::\(calendarID)"
    }

    func mapEventList(data: Data, calendar: UserCalendar) throws -> [CalendarEventOccurrence] {
        let response = try JSONDecoder().decode(GoogleEventsResponse.self, from: data)
        return response.items.compactMap { mapEvent($0, calendar: calendar) }
    }

    func mapEvent(_ event: GoogleEvent, calendar: UserCalendar) -> CalendarEventOccurrence? {
        guard let start = parseDateTime(event.start),
              let end = parseDateTime(event.end) else {
            return nil
        }

        let conferenceLinks = (event.conferenceData?.entryPoints ?? [])
            .compactMap { entry -> MeetingLink? in
                guard entry.entryPointType == "video",
                      let uri = entry.uri,
                      let url = URL(string: uri),
                      let kind = MeetingLinkExtractor.extractURLs(from: uri, source: .conferenceMetadata).first?.kind else {
                    return nil
                }
                return MeetingLink(url: url, kind: kind, source: .conferenceMetadata)
            }

        let rsvp = event.attendees?.first(where: { $0.selfAttendee == true })?.responseStatus
            .flatMap(RSVPStatus.googleValue) ?? .unknown
        let meetingRoom = event.attendees?
            .compactMap { roomName(from: $0) }
            .first

        return CalendarEventOccurrence(
            providerID: "google",
            eventID: event.id,
            calendarID: calendar.id,
            calendarDisplayName: calendar.displayName,
            accountID: calendar.accountID,
            accountDisplayName: calendar.accountDisplayName ?? calendar.displayName,
            iCalUID: event.iCalUID,
            recurringEventID: event.recurringEventID,
            originalStartDate: parseDateTime(event.originalStartTime)?.date,
            title: event.summary?.isEmpty == false ? event.summary! : "Untitled event",
            startDate: start.date,
            endDate: end.date,
            timeZoneIdentifier: start.timeZone ?? end.timeZone,
            eventType: EventType.googleValue(event.eventType),
            status: EventStatus(rawValue: event.status ?? "confirmed") ?? .unknown,
            rsvpStatus: rsvp,
            busyState: event.transparency == "transparent" ? .free : .busy,
            isAllDay: start.isAllDay || end.isAllDay,
            organizerDomain: domain(from: event.organizer?.email),
            attendeeDomains: (event.attendees ?? []).compactMap { domain(from: $0.email) },
            location: event.location,
            meetingRoom: meetingRoom,
            eventDescription: event.description,
            conferenceLinks: conferenceLinks,
            htmlLink: event.htmlLink.flatMap(URL.init(string:)),
            updatedAt: event.updated.flatMap(parseISODate),
            isFromCache: false
        )
    }

    private func parseDateTime(_ value: GoogleEventDateTime?) -> (date: Date, isAllDay: Bool, timeZone: String?)? {
        guard let value else { return nil }
        if let dateTime = value.dateTime, let date = parseISODate(dateTime) {
            return (date, false, value.timeZone)
        }
        if let dateString = value.date {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: dateString) {
                return (date, true, value.timeZone)
            }
        }
        return nil
    }

    private func parseISODate(_ value: String) -> Date? {
        ISO8601DateFormatter.stableDate(from: value)
            ?? ISO8601DateFormatter().date(from: value)
    }

    private func domain(from email: String?) -> String? {
        email?.split(separator: "@").last.map(String.init)
    }

    private func roomName(from attendee: GoogleEventPerson) -> String? {
        guard attendee.resource == true else { return nil }
        if let displayName = attendee.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return displayName
        }
        if let email = attendee.email?.trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty {
            return email
        }
        return nil
    }
}

private extension RSVPStatus {
    static func googleValue(_ value: String) -> RSVPStatus {
        switch value {
        case "accepted": .accepted
        case "tentative": .tentative
        case "needsAction": .needsAction
        case "declined": .declined
        default: .unknown
        }
    }
}

struct GoogleCalendarListResponse: Decodable {
    var items: [GoogleCalendarListItem]
}

struct GoogleCalendarListItem: Decodable {
    var id: String
    var summary: String
    var summaryOverride: String?
    var primary: Bool?
    var hidden: Bool
    var backgroundColor: String?

    enum CodingKeys: String, CodingKey {
        case id
        case summary
        case summaryOverride
        case primary
        case hidden
        case backgroundColor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        summary = try container.decode(String.self, forKey: .summary)
        summaryOverride = try container.decodeIfPresent(String.self, forKey: .summaryOverride)
        primary = try container.decodeIfPresent(Bool.self, forKey: .primary)
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        backgroundColor = try container.decodeIfPresent(String.self, forKey: .backgroundColor)
    }
}

struct GoogleEventsResponse: Decodable {
    var items: [GoogleEvent]
}

struct GoogleEvent: Decodable {
    var id: String
    var status: String?
    var htmlLink: String?
    var summary: String?
    var description: String?
    var location: String?
    var eventType: String?
    var iCalUID: String?
    var recurringEventID: String?
    var start: GoogleEventDateTime?
    var end: GoogleEventDateTime?
    var originalStartTime: GoogleEventDateTime?
    var organizer: GoogleEventPerson?
    var attendees: [GoogleEventPerson]?
    var conferenceData: GoogleConferenceData?
    var transparency: String?
    var updated: String?
}

struct GoogleEventDateTime: Decodable {
    var date: String?
    var dateTime: String?
    var timeZone: String?
}

struct GoogleEventPerson: Decodable {
    var email: String?
    var displayName: String?
    var responseStatus: String?
    var selfAttendee: Bool?
    var resource: Bool?

    enum CodingKeys: String, CodingKey {
        case email
        case displayName
        case responseStatus
        case selfAttendee = "self"
        case resource
    }
}

struct GoogleConferenceData: Decodable {
    var entryPoints: [GoogleConferenceEntryPoint]?
}

struct GoogleConferenceEntryPoint: Decodable {
    var entryPointType: String?
    var uri: String?
}
