import Foundation
import Testing
@testable import MeetingShield

@Suite("App settings")
struct AppSettingsTests {
    @Test("Defaults protect timed default busy events")
    func defaultsProtectTimedDefaultBusyEvents() {
        let settings = AppSettingsSnapshot.defaults
        #expect(settings.defaultLeadTime == 120)
        #expect(settings.globalSnoozeDuration == 120)
        #expect(settings.launchAtLoginEnabled == false)
        #expect(settings.calendarSettings(for: "primary").includedEventTypes == [.defaultEvent])
        #expect(settings.calendarSettings(for: "primary").includedRSVPStatuses.contains(.needsAction))
        #expect(settings.calendarSettings(for: "primary").includedBusyStates == [.busy])
    }

    @Test("Timing settings are clamped to spec bounds and 30 second steps")
    func timingSettingsNormalize() {
        var settings = AppSettingsSnapshot.defaults
        settings.defaultLeadTime = 17
        settings.globalSnoozeDuration = 77
        settings.visibleWindowDays = 99

        let normalized = settings.normalized()

        #expect(normalized.defaultLeadTime == 30)
        #expect(normalized.globalSnoozeDuration == 90)
        #expect(normalized.visibleWindowDays == 7)
    }

    @Test("System default browser cannot retain profile selection")
    func systemDefaultDropsProfileSelection() {
        var settings = AppSettingsSnapshot.defaults
        settings.defaultBrowserSelection = BrowserSelection(browser: .systemDefault, profileID: "Profile 1")

        #expect(settings.normalized().defaultBrowserSelection.profileID == nil)
    }

    @Test("Decoding older settings keeps new account defaults")
    func decodingOlderSettingsKeepsAccountDefaults() throws {
        let data = Data("""
        {
          "defaultLeadTime": 120,
          "globalSnoozeDuration": 120,
          "visibleWindowDays": 1,
          "selectedCalendarIDs": ["primary"]
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(AppSettingsSnapshot.self, from: data)

        #expect(decoded.selectedCalendarIDs == ["primary"])
        #expect(decoded.disabledGoogleAccountIDs.isEmpty)
        #expect(decoded.accountNicknames.isEmpty)
        #expect(decoded.calendarAliases.isEmpty)
        #expect(decoded.defaultBrowserSelection == .systemDefault)
    }

    @Test("Calendar aliases override account nicknames and provider names")
    func displayNamesUseAliasesAndAccountNicknames() {
        var settings = AppSettingsSnapshot.defaults
        let primary = UserCalendar(
            id: "david@example.com::david@example.com",
            accountID: "david@example.com",
            accountDisplayName: "david@example.com",
            displayName: "david@example.com",
            isPrimary: true,
            isSelected: true,
            colorHex: nil
        )
        let secondary = UserCalendar(
            id: "david@example.com::team-calendar",
            accountID: "david@example.com",
            accountDisplayName: "david@example.com",
            displayName: "IT Services Squad",
            isPrimary: false,
            isSelected: true,
            colorHex: nil
        )

        settings.accountNicknames["david@example.com"] = "Work"

        #expect(settings.normalized().displayName(for: primary) == "Work")
        #expect(settings.normalized().displayName(for: secondary) == "IT Services Squad")

        settings.calendarAliases[primary.id] = "Personal"
        settings.calendarAliases[secondary.id] = "Team"

        let normalized = settings.normalized()
        #expect(normalized.displayName(for: primary) == "Personal")
        #expect(normalized.displayName(for: secondary) == "Team")
    }

    @Test("Protected calendars exclude app-unselected calendars and disabled accounts")
    func protectedCalendarsHonorSelectionAndDisabledAccounts() {
        let enabledPrimary = UserCalendar(
            id: "enabled::primary",
            accountID: "enabled",
            accountDisplayName: "Enabled",
            displayName: "Enabled Primary",
            isPrimary: true,
            isSelected: true,
            colorHex: nil
        )
        let enabledSecondary = UserCalendar(
            id: "enabled::secondary",
            accountID: "enabled",
            accountDisplayName: "Enabled",
            displayName: "Enabled Secondary",
            isPrimary: false,
            isSelected: true,
            colorHex: nil
        )
        let hiddenProviderCalendar = UserCalendar(
            id: "enabled::hidden",
            accountID: "enabled",
            accountDisplayName: "Enabled",
            displayName: "Hidden",
            isPrimary: false,
            isSelected: false,
            colorHex: nil
        )
        let disabledAccountCalendar = UserCalendar(
            id: "disabled::primary",
            accountID: "disabled",
            accountDisplayName: "Disabled",
            displayName: "Disabled Primary",
            isPrimary: true,
            isSelected: true,
            colorHex: nil
        )
        var settings = AppSettingsSnapshot.defaults
        settings.selectedCalendarIDs = [enabledPrimary.id]
        settings.disabledGoogleAccountIDs = ["disabled"]

        let protected = settings.protectedCalendars(from: [
            enabledSecondary,
            disabledAccountCalendar,
            hiddenProviderCalendar,
            enabledPrimary
        ])

        #expect(protected.map(\.id) == [enabledPrimary.id])
    }

    @Test("Settings payloads containing removed keys still decode")
    func removedKeysStillDecode() throws {
        // googleOAuthRedirectURI shipped in earlier builds and was removed
        // (the loopback server generates its own redirect URI).
        let legacyPayload = Data("""
        {
          "defaultLeadTime": 180,
          "googleOAuthClientID": "legacy-client",
          "googleOAuthRedirectURI": "http://127.0.0.1:9004/oauth2redirect"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(AppSettingsSnapshot.self, from: legacyPayload)

        #expect(decoded.defaultLeadTime == 180)
        #expect(decoded.googleOAuthClientID == "legacy-client")
    }
}
