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

    @Test("Error class scrubbing drops embedded URLs and emails")
    func errorClassDropsEmbeddedDetails() {
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/alice@example.com/events")!
        let error = URLError(.timedOut, userInfo: [
            NSURLErrorFailingURLErrorKey: url,
            NSLocalizedDescriptionKey: "The request to https://www.googleapis.com/calendar/v3/calendars/alice@example.com/events timed out."
        ])

        let scrubbed = LogPrivacy.errorClass(error)

        #expect(!scrubbed.contains("alice@example.com"))
        #expect(!scrubbed.contains("googleapis.com"))
        #expect(scrubbed == "NSURLErrorDomain.-1001")
    }

    @Test("Untrusted NSError domains and Swift error names are not public codes")
    func untrustedErrorIdentifiersAreUnknown() {
        let canary = "private-domain-\(UUID().uuidString)@example.invalid"
        let error = NSError(domain: canary, code: 19, userInfo: [NSLocalizedDescriptionKey: canary])
        #expect(LogPrivacy.errorClass(error) == "unknown")
        #expect(LogPrivacy.safeErrorCode("\(canary).19") == "unknown")
        #expect(LogPrivacy.safeErrorCode("NSURLErrorDomain.-1001 private-token") == "unknown")
        #expect(LogPrivacy.safeErrorCode("NSCocoaErrorDomain.004") == "unknown")
        #expect(LogPrivacy.safeErrorCode("NSPOSIXErrorDomain.+13") == "unknown")
    }

    @Test("Known Swift errors use fixed codes without associated values")
    func knownErrorCodesAreStable() {
        let canary = "private-associated-value-\(UUID().uuidString)"
        #expect(LogPrivacy.errorClass(CalendarProviderError.authExpired(canary)) == "calendar_auth_expired")
        #expect(LogPrivacy.errorClass(GoogleOAuthError.authorizationDenied(canary)) == "oauth_authorization_denied")
        #expect(LogPrivacy.errorClass(GoogleOAuthError.tokenExchangeFailed(status: 400, googleError: canary)) == "oauth_token_exchange_failed")
        #expect(LogPrivacy.errorClass(MeetingLauncherError.launchFailed(canary)) == "launch_failed")
        #expect(LogPrivacy.errorClass(KeychainError.unexpectedData) == "keychain_unexpected_data")
        #expect(LogPrivacy.errorClass(CancellationError()) == "cancelled")
        #expect(LogPrivacy.safeErrorCode("calendar_auth_expired") == "calendar_auth_expired")
    }

    @Test("Only fixed refresh reasons and OAuth errors reach diagnostics")
    func externalStringCodesAreBounded() {
        let canary = "https://example.invalid/\(UUID().uuidString)"
        #expect(LogPrivacy.refreshReason(canary) == "unknown")
        #expect(LogPrivacy.refreshReason("network-return") == "network-return")
        #expect(LogPrivacy.refreshReason("runtime-check") == "runtime-check")
        #expect(LogPrivacy.oauthErrorCode(canary) == "unknown")
        #expect(LogPrivacy.oauthErrorCode("invalid_grant") == "invalid_grant")
        #expect(LogPrivacy.oauthErrorCode("access_denied") == "access_denied")
    }

}
