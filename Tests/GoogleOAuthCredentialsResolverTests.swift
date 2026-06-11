import Foundation
import Testing
@testable import MeetingShield

@Suite("Google OAuth credentials resolver")
struct GoogleOAuthCredentialsResolverTests {
    private func resolver(
        bundle: [String: String] = [:],
        environment: [String: String] = [:]
    ) -> GoogleOAuthCredentialsResolver {
        GoogleOAuthCredentialsResolver(
            bundleInfoValue: { key in bundle[key] },
            environment: environment
        )
    }

    @Test("Settings value wins over bundle and environment")
    func settingsWins() {
        let resolver = resolver(
            bundle: [AppIdentity.googleOAuthClientIDInfoKey: "bundle-id"],
            environment: ["MEETING_SHIELD_GOOGLE_CLIENT_ID": "env-id"]
        )

        #expect(resolver.clientID(settingsValue: " settings-id ") == "settings-id")
        #expect(resolver.clientIDSource(settingsValue: "settings-id") == .settings)
    }

    @Test("Bundle value wins over environment when settings empty")
    func bundleBeatsEnvironment() {
        let resolver = resolver(
            bundle: [AppIdentity.googleOAuthClientIDInfoKey: "bundle-id"],
            environment: ["MEETING_SHIELD_GOOGLE_CLIENT_ID": "env-id"]
        )

        #expect(resolver.clientID(settingsValue: "") == "bundle-id")
        #expect(resolver.clientIDSource(settingsValue: "  ") == .bundle)
    }

    @Test("Environment is the last fallback; missing otherwise")
    func environmentFallback() {
        let withEnv = resolver(environment: ["MEETING_SHIELD_GOOGLE_CLIENT_ID": "env-id"])
        #expect(withEnv.clientID(settingsValue: "") == "env-id")
        #expect(withEnv.clientIDSource(settingsValue: "") == .environment)

        let empty = resolver()
        #expect(empty.clientID(settingsValue: "") == "")
        #expect(empty.clientIDSource(settingsValue: "") == .missing)
        #expect(!empty.hasConfiguration(settingsValue: ""))
    }

    @Test("Client secret resolves bundle then environment")
    func clientSecretResolution() {
        let bundled = resolver(bundle: [AppIdentity.googleOAuthClientSecretInfoKey: "bundle-secret"])
        #expect(bundled.clientSecret() == "bundle-secret")

        let env = resolver(environment: ["MEETING_SHIELD_GOOGLE_CLIENT_SECRET": "env-secret"])
        #expect(env.clientSecret() == "env-secret")

        #expect(resolver().clientSecret() == "")
    }

    @Test("Source labels match the settings UI vocabulary")
    func sourceLabels() {
        #expect(GoogleOAuthCredentialsResolver.Source.settings.displayName == "Developer settings")
        #expect(GoogleOAuthCredentialsResolver.Source.bundle.displayName == "This app build")
        #expect(GoogleOAuthCredentialsResolver.Source.environment.displayName == "Local environment")
        #expect(GoogleOAuthCredentialsResolver.Source.missing.displayName == "Missing")
    }
}
