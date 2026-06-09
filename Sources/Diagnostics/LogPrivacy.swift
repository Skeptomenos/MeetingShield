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
        String(reflecting: type(of: error))
    }

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
