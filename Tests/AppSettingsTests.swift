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
        settings.visibilityWindow.hours = 99
        settings.visibilityWindow.days = 99

        let normalized = settings.normalized()

        #expect(normalized.defaultLeadTime == 30)
        #expect(normalized.globalSnoozeDuration == 90)
        #expect(normalized.visibilityWindow.hours == 12)
        #expect(normalized.visibilityWindow.days == 7)
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

    @Test("Legacy menu days migrate into the canonical visibility window")
    func legacyMenuDaysMigrateIntoVisibilityWindow() throws {
        let data = Data("""
        {
          "visibleWindowDays": 6
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(AppSettingsSnapshot.self, from: data).normalized()

        #expect(decoded.visibilityWindow.days == 6)
    }

    @Test("Canonical visibility wins conflicts and legacy menu days are not encoded")
    func canonicalVisibilityWinsAndLegacyDaysAreNotEncoded() throws {
        let data = Data("""
        {
          "visibilityWindow": {
            "kind": "nextDays",
            "hours": 4,
            "days": 3
          },
          "visibleWindowDays": 7
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(AppSettingsSnapshot.self, from: data).normalized()
        let encoded = try JSONEncoder().encode(decoded)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(decoded.visibilityWindow.days == 3)
        #expect(object["visibleWindowDays"] == nil)
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

    @Test("Persisted explicit none protects no calendars or events after a round trip")
    func explicitNoneSurvivesSettingsRoundTrip() throws {
        let calendars = [
            calendar("primary"),
            calendar("secondary", accountID: "synthetic-account-b"),
            calendar("hidden", isSelected: false)
        ]
        let decoded = try decodeSettings("""
        {"hasExplicitCalendarSelection":true,"selectedCalendarIDs":[]}
        """)
        let reloaded = try roundTrip(decoded)

        for settings in [decoded, reloaded] {
            #expect(settings.protectedCalendars(from: calendars).isEmpty)
            #expect(!settings.isCalendarSelected("synthetic-undiscovered-calendar"))
            for calendar in calendars {
                #expect(!settings.isCalendarSelected(calendar.id))
                #expect(!settings.protectsEvent(event(in: calendar)))
            }
        }
    }

    @Test("Removing the last selected calendar keeps an explicit empty selection")
    func removingFinalSelectedCalendarKeepsNone() throws {
        let primary = calendar("primary")
        let secondary = calendar("secondary", accountID: "synthetic-account-b")
        let calendars = [primary, secondary]
        var settings = AppSettingsSnapshot.defaults
        settings.selectedCalendarIDs = [primary.id, secondary.id]

        settings.selectedCalendarIDs.remove(primary.id)

        #expect(settings.protectedCalendars(from: calendars).map(\.id) == [secondary.id])

        settings.selectedCalendarIDs.remove(secondary.id)

        for current in [settings, try roundTrip(settings)] {
            #expect(current.protectedCalendars(from: calendars).isEmpty)
            for calendar in calendars {
                #expect(!current.isCalendarSelected(calendar.id))
                #expect(!current.protectsEvent(event(in: calendar)))
            }
        }
    }

    @Test("Explicit app selection overrides Google visibility but not account disabling", arguments: [false, true])
    func explicitSelectionOverridesProviderVisibility(decodedLegacy: Bool) throws {
        let hidden = calendar("hidden", isSelected: false)
        let providerSelected = calendar("primary")
        var settings: AppSettingsSnapshot
        if decodedLegacy {
            settings = try decodeSettings("""
            {"selectedCalendarIDs":["\(hidden.id)"]}
            """)
        } else {
            settings = .defaults
            settings.selectedCalendarIDs = [hidden.id]
        }

        for current in [settings, try roundTrip(settings)] {
            #expect(current.protectedCalendars(from: [hidden, providerSelected]).map(\.id) == [hidden.id])
            #expect(current.isCalendarSelected(hidden.id))
            #expect(current.protectsEvent(event(in: hidden)))
            #expect(!current.protectsEvent(event(in: providerSelected)))
        }

        settings.disabledGoogleAccountIDs = [hidden.accountID]

        #expect(settings.protectedCalendars(from: [hidden, providerSelected]).isEmpty)
        #expect(!settings.protectsEvent(event(in: hidden)))
        #expect(settings.selectedCalendarIDs == [hidden.id])
    }

    @Test("Legacy missing or empty selection follows provider defaults and new discoveries", arguments: ["{}", "{\"selectedCalendarIDs\":[]}"])
    func legacyEmptySelectionUsesProviderDefaults(payload: String) throws {
        let primary = calendar("primary")
        let secondary = calendar("secondary", accountID: "synthetic-account-b")
        let hidden = calendar("hidden", isSelected: false)
        let discovered = calendar("discovered", accountID: "synthetic-account-b")
        let settings = try decodeSettings(payload)

        for current in [settings, try roundTrip(settings)] {
            #expect(current.protectedCalendars(from: [primary, hidden, secondary]).map(\.id) == [primary.id, secondary.id])
            #expect(current.protectedCalendars(from: [primary, hidden, secondary, discovered]).map(\.id) == [primary.id, secondary.id, discovered.id])
        }
    }

    @Test("Explicit subset stays fixed through new discovery and account disable then reenable")
    func explicitSubsetSurvivesDiscoveryAndAccountToggle() throws {
        let primary = calendar("primary")
        let secondary = calendar("secondary", accountID: "synthetic-account-b")
        let discovered = calendar("discovered", accountID: "synthetic-account-b")
        let calendars = [primary, secondary, discovered]
        var settings = AppSettingsSnapshot.defaults
        settings.selectedCalendarIDs = [primary.id, secondary.id]

        #expect(settings.protectedCalendars(from: calendars).map(\.id) == [primary.id, secondary.id])
        #expect(!settings.isCalendarSelected(discovered.id))
        #expect(!settings.protectsEvent(event(in: discovered)))

        settings.disabledGoogleAccountIDs = [secondary.accountID]
        settings = try roundTrip(settings)

        #expect(settings.selectedCalendarIDs == [primary.id, secondary.id])
        #expect(settings.protectedCalendars(from: calendars).map(\.id) == [primary.id])
        #expect(!settings.protectsEvent(event(in: secondary)))

        settings.disabledGoogleAccountIDs.remove(secondary.accountID)
        settings = try roundTrip(settings)

        #expect(settings.protectedCalendars(from: calendars).map(\.id) == [primary.id, secondary.id])
        #expect(settings.protectsEvent(event(in: primary)))
        #expect(settings.protectsEvent(event(in: secondary)))
        #expect(!settings.protectsEvent(event(in: discovered)))
    }

    @Test("Explicit none persists across reconstruction of the real settings store")
    @MainActor
    func explicitNoneSurvivesSettingsStoreReconstruction() throws {
        let domain = "meeting-shield-p02-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let primary = calendar("primary")
        let secondary = calendar("secondary", accountID: "synthetic-account-b")
        let calendars = [primary, secondary]
        let store = AppSettingsStore(domainName: domain)
        store.update { $0.selectedCalendarIDs = [primary.id, secondary.id] }
        store.update { $0.selectedCalendarIDs.remove(primary.id) }
        store.update { $0.selectedCalendarIDs.remove(secondary.id) }
        _ = try #require(UserDefaults(suiteName: domain))
        let reloadedStore = AppSettingsStore(domainName: domain)

        for settings in [store.snapshot, reloadedStore.snapshot] {
            #expect(settings.protectedCalendars(from: calendars).isEmpty)
            for calendar in calendars {
                #expect(!settings.isCalendarSelected(calendar.id))
                #expect(!settings.protectsEvent(event(in: calendar)))
            }
        }
    }

    @Test("Remembered provider defaults filter offline events without becoming explicit", arguments: [false, true])
    func rememberedDefaultsSurviveReload(noDefaults: Bool) throws {
        let primary = calendar("primary")
        let hidden = calendar("hidden", isSelected: false)
        let defaultIDs = noDefaults ? "[]" : "[\"\(primary.id)\"]"
        let decoded = try decodeSettings("""
        {"hasExplicitCalendarSelection":false,"selectedCalendarIDs":[],"providerDefaultCalendarIDs":\(defaultIDs)}
        """)

        for settings in [decoded, try roundTrip(decoded)] {
            #expect(settings.protectsEvent(event(in: primary)) == !noDefaults)
            #expect(!settings.protectsEvent(event(in: hidden)))
            #expect(!settings.isCalendarSelected("synthetic-undiscovered-calendar"))
        }

        let legacyUnknown = try decodeSettings("{}")
        #expect(legacyUnknown.protectsEvent(event(in: primary)))
    }

    @Test("The first checkbox edit preserves provider defaults across disabled accounts")
    func firstCheckboxEditPreservesOtherDefaults() throws {
        let primary = calendar("primary")
        let disabled = calendar("secondary", accountID: "synthetic-account-b")
        let hidden = calendar("hidden", isSelected: false)
        let calendars = [primary, disabled, hidden]
        var settings = AppSettingsSnapshot.defaults
        settings.disabledGoogleAccountIDs = [disabled.accountID]
        #expect(!settings.isCalendarSelected(hidden))

        settings.setCalendarSelected(false, calendarID: primary.id, availableCalendars: calendars)
        settings = try roundTrip(settings)

        #expect(settings.hasExplicitCalendarSelection)
        #expect(settings.selectedCalendarIDs == [disabled.id])
        #expect(settings.protectedCalendars(from: calendars).isEmpty)
        settings.disabledGoogleAccountIDs.remove(disabled.accountID)
        #expect(settings.protectedCalendars(from: calendars).map(\.id) == [disabled.id])
        settings.setCalendarSelected(false, calendarID: disabled.id, availableCalendars: calendars)
        settings.setCalendarSelected(true, calendarID: hidden.id, availableCalendars: calendars)
        #expect(settings.protectedCalendars(from: calendars).map(\.id) == [hidden.id])
    }

    private func decodeSettings(_ payload: String) throws -> AppSettingsSnapshot {
        try JSONDecoder().decode(AppSettingsSnapshot.self, from: Data(payload.utf8))
    }

    private func roundTrip(_ settings: AppSettingsSnapshot) throws -> AppSettingsSnapshot {
        try JSONDecoder().decode(AppSettingsSnapshot.self, from: JSONEncoder().encode(settings))
    }

    private func calendar(
        _ id: String,
        accountID: String = "synthetic-account-a",
        isSelected: Bool = true
    ) -> UserCalendar {
        UserCalendar(
            id: "\(accountID)::\(id)",
            accountID: accountID,
            accountDisplayName: accountID,
            displayName: "Synthetic \(id)",
            isPrimary: id == "primary",
            isSelected: isSelected,
            colorHex: nil
        )
    }

    private func event(in calendar: UserCalendar) -> CalendarEventOccurrence {
        var event = CalendarEventOccurrence.sample(
            eventID: "synthetic-selection-event",
            title: "Synthetic selection event",
            startDate: TestDates.now,
            calendarID: calendar.id
        )
        event.accountID = calendar.accountID
        return event
    }
}
