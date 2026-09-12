import CryptoKit
import Foundation

enum LogPrivacy {
    static func redactedID(_ value: String) -> String {
        "id:\(hashPrefix(value))"
    }

    static func redactedIDSet(_ values: [String]) -> String {
        guard !values.isEmpty else { return "set:empty" }
        return "set:\(hashPrefix(values.sorted().joined(separator: "|")))"
    }

    static func fingerprintPrefix(_ value: String) -> String {
        "fp:\(hashPrefix(value))"
    }

    static func errorClass(_ error: Error) -> String {
        switch error {
        case let error as CalendarAccountFailure:
            return safeErrorCode(error.errorClass)
        case let error as CalendarProviderError:
            switch error {
            case .notConfigured: return "calendar_not_configured"
            case .disconnected: return "calendar_disconnected"
            case .authExpired: return "calendar_auth_expired"
            case .invalidResponse: return "calendar_invalid_response"
            case .requestFailed: return "calendar_request_failed"
            }
        case let error as GoogleOAuthError:
            switch error {
            case .notConfigured: return "oauth_not_configured"
            case .invalidAuthorizationURL: return "oauth_invalid_authorization_url"
            case .missingAuthorizationCode: return "oauth_missing_code"
            case .authorizationDenied: return "oauth_authorization_denied"
            case .callbackTimedOut: return "oauth_callback_timeout"
            case .loopbackServerFailed: return "oauth_loopback_failed"
            case .tokenExchangeFailed: return "oauth_token_exchange_failed"
            }
        case let error as KeychainError:
            switch error {
            case .readFailed: return "keychain_read_failed"
            case .saveFailed: return "keychain_save_failed"
            case .deleteFailed: return "keychain_delete_failed"
            case .unexpectedData: return "keychain_unexpected_data"
            }
        case let error as MeetingLauncherError:
            switch error {
            case .profileNotFound: return "launch_profile_not_found"
            case .browserNotInstalled: return "launch_browser_not_installed"
            case .launchFailed: return "launch_failed"
            }
        case is DecodingError:
            return "decoding_error"
        case is EncodingError:
            return "encoding_error"
        case is CancellationError:
            return "cancelled"
        default:
            let error = error as NSError
            let domain = error.domain
            guard errorDomains.contains(domain) else { return "unknown" }
            return "\(domain).\(error.code)"
        }
    }

    static func refreshReason(_ value: String) -> String {
        switch value {
        case "launch", "wake", "network-return", "timer", "reconnect", "runtime-check", "settings", "manual":
            value
        default:
            "unknown"
        }
    }

    static func oauthErrorCode(_ value: String) -> String {
        switch value {
        case "access_denied", "invalid_request", "invalid_client", "invalid_grant", "invalid_scope",
             "unauthorized_client", "unsupported_grant_type", "unsupported_response_type",
             "server_error", "temporarily_unavailable", "redirect_uri_mismatch",
             "admin_policy_enforced", "disallowed_useragent", "org_internal":
            value
        default:
            "unknown"
        }
    }

    static func safeErrorCode(_ value: String) -> String {
        if errorCodes.contains(value) { return value }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              errorDomains.contains(String(parts[0])),
              let code = Int(parts[1]),
              String(code) == parts[1] else {
            return "unknown"
        }
        return value
    }

    private static let errorDomains: Set<String> = [
        NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain
    ]

    private static let errorCodes: Set<String> = [
        "unknown", "calendar_not_configured", "calendar_disconnected", "calendar_auth_expired",
        "calendar_invalid_response", "calendar_request_failed", "oauth_not_configured",
        "oauth_invalid_authorization_url", "oauth_missing_code", "oauth_authorization_denied",
        "oauth_callback_timeout", "oauth_loopback_failed", "oauth_token_exchange_failed",
        "keychain_read_failed", "keychain_save_failed", "keychain_delete_failed", "keychain_unexpected_data",
        "launch_profile_not_found", "launch_browser_not_installed", "launch_failed",
        "decoding_error", "encoding_error", "cancelled"
    ]

    static func authState(_ state: CalendarProviderAuthState) -> String {
        switch state {
        case .authenticating:
            "authenticating"
        case .connected:
            "connected"
        case .disconnected:
            "disconnected"
        case .needsConfiguration:
            "needsConfiguration"
        case .expired:
            "expired"
        }
    }

    static func oauthClientSource(_ value: String) -> String {
        switch value {
        case "Developer settings":
            "settings"
        case "This app build":
            "bundle"
        case "Local environment":
            "environment"
        default:
            "missing"
        }
    }

    static func bool(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private static func hashPrefix(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(12).description
    }
}
