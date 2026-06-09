import Foundation
import Testing
@testable import MeetingShield

@Suite("Log privacy")
struct LogPrivacyTests {
    @Test("Redacted identifiers do not expose private calendar data")
    func redactedIdentifiersHideSourceValues() {
        let privateValues = [
            "Leadership sync with Alice",
            "alice@example.com",
            "https://video.invalid/private-room",
            "https://conference.invalid/j/123456789",
            "Bearer oauth-access-token-private-value",
            "calendar-client-secret-private-value",
            "raw calendar event description"
        ]

        let output = [
            LogPrivacy.redactedID(privateValues[0]),
            LogPrivacy.redactedIDSet(privateValues),
            LogPrivacy.fingerprintPrefix(privateValues.joined(separator: "|"))
        ].joined(separator: "\n")

        for value in privateValues {
            #expect(!output.contains(value))
        }
        #expect(!output.contains("video.invalid"))
        #expect(!output.contains("conference.invalid"))
        #expect(!output.contains("oauth-access-token"))
        #expect(!output.contains("client-secret"))
    }

    @Test("OAuth source labels are coarse and secret-free")
    func oauthSourceLabelsAreSafe() {
        #expect(LogPrivacy.oauthClientSource("Developer settings") == "settings")
        #expect(LogPrivacy.oauthClientSource("This app build") == "bundle")
        #expect(LogPrivacy.oauthClientSource("Local environment") == "environment")
        #expect(LogPrivacy.oauthClientSource("Missing") == "missing")
    }

    @Test("Auth state logging omits account details")
    func authStateLoggingOmitsAccountDetails() {
        #expect(LogPrivacy.authState(.connected(accountEmail: "david.helmus@example.com")) == "connected")
        #expect(LogPrivacy.authState(.expired(reason: "token for david.helmus@example.com expired")) == "expired")
    }
}
