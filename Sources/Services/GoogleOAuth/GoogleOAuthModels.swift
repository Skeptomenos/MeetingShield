import CryptoKit
import Foundation
import Security

struct GoogleOAuthConfiguration: Equatable, Sendable {
    var clientID: String
    var clientSecret: String = ""
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
