import Foundation

/// Resolves the Google OAuth client credentials from the three supported
/// sources, in precedence order: developer settings > app bundle Info.plist >
/// local environment. Extracted from MeetingShieldController so precedence is
/// unit-testable.
struct GoogleOAuthCredentialsResolver: Sendable {
    enum Source: Equatable, Sendable {
        case settings
        case bundle
        case environment
        case missing

        var displayName: String {
            switch self {
            case .settings: "Developer settings"
            case .bundle: "This app build"
            case .environment: "Local environment"
            case .missing: "Missing"
            }
        }
    }

    var bundleInfoValue: @Sendable (String) -> String?
    var environment: [String: String]

    init(
        bundleInfoValue: @escaping @Sendable (String) -> String? = { key in
            Bundle.main.object(forInfoDictionaryKey: key) as? String
        },
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.bundleInfoValue = bundleInfoValue
        self.environment = environment
    }

    func clientID(settingsValue: String) -> String {
        let settings = trimmed(settingsValue)
        if !settings.isEmpty { return settings }
        let bundled = trimmed(bundleInfoValue(AppIdentity.googleOAuthClientIDInfoKey) ?? "")
        if !bundled.isEmpty { return bundled }
        return trimmed(environment["MEETING_SHIELD_GOOGLE_CLIENT_ID"] ?? "")
    }

    func clientIDSource(settingsValue: String) -> Source {
        if !trimmed(settingsValue).isEmpty { return .settings }
        if !trimmed(bundleInfoValue(AppIdentity.googleOAuthClientIDInfoKey) ?? "").isEmpty { return .bundle }
        if !trimmed(environment["MEETING_SHIELD_GOOGLE_CLIENT_ID"] ?? "").isEmpty { return .environment }
        return .missing
    }

    func hasConfiguration(settingsValue: String) -> Bool {
        !clientID(settingsValue: settingsValue).isEmpty
    }

    func clientSecret() -> String {
        let bundled = trimmed(bundleInfoValue(AppIdentity.googleOAuthClientSecretInfoKey) ?? "")
        if !bundled.isEmpty { return bundled }
        return trimmed(environment["MEETING_SHIELD_GOOGLE_CLIENT_SECRET"] ?? "")
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
