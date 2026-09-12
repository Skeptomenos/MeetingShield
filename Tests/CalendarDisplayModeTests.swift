import Foundation
import Testing
@testable import MeetingShield

@Suite("Calendar display modes")
struct CalendarDisplayModeTests {
    private let primary = UserCalendar(id: "primary", accountID: "work", displayName: "Work", isPrimary: true, isSelected: true)
    private let other = UserCalendar(id: "other", accountID: "other-account", displayName: "Other", isPrimary: true, isSelected: true)

    @Test("Changing one provider-default calendar preserves other selected calendars")
    func providerDefaults() {
        var settings = AppSettingsSnapshot.defaults
        settings.setDisplayMode(.off, for: primary, availableCalendars: [primary, other])
        #expect(settings.hasExplicitCalendarSelection)
        #expect(settings.displayMode(for: primary) == .off)
        #expect(settings.isCalendarSelected(other))
    }

    @Test("Agenda and off preserve aliases, browser, lead time and filters across encoding")
    func overridesSurvive() throws {
        var settings = AppSettingsSnapshot.defaults
        var overrides = CalendarSettings.defaults(calendarID: primary.id)
        overrides.browserSelection = BrowserSelection(browser: .chrome, profileID: "Work profile")
        overrides.leadTimeOverride = 300
        overrides.includedRSVPStatuses = [.accepted]
        settings.calendarSettings[primary.id] = overrides
        settings.calendarAliases[primary.id] = "My calendar"
        settings.setDisplayMode(.agendaOnly, for: primary, availableCalendars: [primary, other])
        #expect(settings.displayMode(for: primary) == .agendaOnly)
        #expect(settings.isCalendarSelected(primary))
        overrides.isAlertEnabled = false
        settings.setDisplayMode(.off, for: primary, availableCalendars: [primary, other])
        let decoded = try JSONDecoder().decode(AppSettingsSnapshot.self, from: JSONEncoder().encode(settings))
        #expect(decoded.calendarSettings(for: primary.id) == overrides)
        #expect(decoded.calendarAliases[primary.id] == "My calendar")
        #expect(decoded.displayMode(for: primary) == .off)
        settings.setDisplayMode(.alertsAndAgenda, for: primary, availableCalendars: [primary, other])
        overrides.isAlertEnabled = true
        #expect(settings.calendarSettings(for: primary.id) == overrides)
    }

    @Test("A disabled account cannot be reactivated by calendar mode")
    func disabledAccount() {
        var settings = AppSettingsSnapshot.defaults
        settings.disabledGoogleAccountIDs.insert(primary.accountID)
        let before = settings
        for mode in CalendarDisplayMode.allCases {
            settings.setDisplayMode(mode, for: primary, availableCalendars: [primary, other])
            #expect(settings == before)
        }
    }

    @Test("The last selected calendar can stay off after restart")
    func explicitNoneSurvives() throws {
        var settings = AppSettingsSnapshot.defaults
        settings.setDisplayMode(.off, for: primary, availableCalendars: [primary])
        let decoded = try JSONDecoder().decode(AppSettingsSnapshot.self, from: JSONEncoder().encode(settings))
        #expect(decoded.hasExplicitCalendarSelection)
        #expect(decoded.selectedCalendarIDs.isEmpty)
        #expect(decoded.displayMode(for: primary) == .off)
    }
}
