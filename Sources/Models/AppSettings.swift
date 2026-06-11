import Combine
import Foundation

enum BrowserKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case systemDefault
    case safari
    case chrome
    case arc
    case chromium

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemDefault: "System Default"
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .arc: "Arc"
        case .chromium: "Chromium"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .systemDefault: nil
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .arc: "company.thebrowser.Browser"
        case .chromium: "org.chromium.Chromium"
        }
    }

    var supportsProfileSelection: Bool {
        switch self {
        case .systemDefault, .safari:
            false
        case .chrome, .arc, .chromium:
            true
        }
    }
}

struct BrowserProfile: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var browser: BrowserKind
    var localPath: String?

    static let none = BrowserProfile(id: "default", displayName: "Default profile", browser: .systemDefault)
}

struct BrowserSelection: Codable, Hashable, Sendable {
    var browser: BrowserKind
    var profileID: String?

    static let systemDefault = BrowserSelection(browser: .systemDefault, profileID: nil)
}

enum MenuVisibilityKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case nextMeetingOnly
    case nextHours
    case today
    case nextDays

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nextMeetingOnly: "Next meeting"
        case .nextHours: "Next hours"
        case .today: "Today"
        case .nextDays: "Next days"
        }
    }
}

struct MenuVisibilityWindow: Codable, Equatable, Sendable {
    var kind: MenuVisibilityKind
    var hours: Int
    var days: Int

    static let today = MenuVisibilityWindow(kind: .today, hours: 4, days: 1)

    func endDate(from start: Date, calendar: Calendar = .current) -> Date {
        switch kind {
        case .nextMeetingOnly:
            return calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 24 * 60 * 60)
        case .nextHours:
            return start.addingTimeInterval(TimeInterval(max(1, hours)) * 60 * 60)
        case .today:
            return calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: start) ?? start)
        case .nextDays:
            return calendar.date(byAdding: .day, value: min(max(days, 1), 7), to: start) ?? start.addingTimeInterval(24 * 60 * 60)
        }
    }
}

struct CalendarSettings: Codable, Equatable, Sendable {
    var calendarID: String
    var isAlertEnabled: Bool
    var browserSelection: BrowserSelection?
    var leadTimeOverride: TimeInterval?
    var includedEventTypes: Set<EventType>
    var includedRSVPStatuses: Set<RSVPStatus>
    var includedBusyStates: Set<BusyState>
    var includeAllDayEvents: Bool
    var rules: [ReminderRule]

    static func defaults(calendarID: String) -> CalendarSettings {
        CalendarSettings(
            calendarID: calendarID,
            isAlertEnabled: true,
            browserSelection: nil,
            leadTimeOverride: nil,
            includedEventTypes: [.defaultEvent],
            includedRSVPStatuses: [.accepted, .tentative, .needsAction, .unknown],
            includedBusyStates: [.busy],
            includeAllDayEvents: false,
            rules: []
        )
    }
}

struct AppSettingsSnapshot: Codable, Equatable, Sendable {
    var defaultBrowserSelection: BrowserSelection
    var defaultLeadTime: TimeInterval
    var globalSnoozeDuration: TimeInterval
    var visibilityWindow: MenuVisibilityWindow
    var showEventTitlesInMenuBar: Bool
    var soundEnabled: Bool
    var urgentRepeatSoundEnabled: Bool
    var presentationModeDefault: Bool
    var launchAtLoginEnabled: Bool
    var wakeGraceEnabled: Bool
    var visibleWindowDays: Int
    var selectedCalendarIDs: Set<String>
    var disabledGoogleAccountIDs: Set<String>
    var accountNicknames: [String: String]
    var calendarAliases: [String: String]
    var calendarSettings: [String: CalendarSettings]
    var rules: [ReminderRule]
    var googleOAuthClientID: String

    enum CodingKeys: String, CodingKey {
        case defaultBrowserSelection
        case defaultLeadTime
        case globalSnoozeDuration
        case visibilityWindow
        case showEventTitlesInMenuBar
        case soundEnabled
        case urgentRepeatSoundEnabled
        case presentationModeDefault
        case launchAtLoginEnabled
        case wakeGraceEnabled
        case visibleWindowDays
        case selectedCalendarIDs
        case disabledGoogleAccountIDs
        case accountNicknames
        case calendarAliases
        case calendarSettings
        case rules
        case googleOAuthClientID
    }

    static let defaultLeadTimeRange: ClosedRange<TimeInterval> = 30...900
    static let defaultLeadTimeStep: TimeInterval = 30

    static let defaults = AppSettingsSnapshot(
        defaultBrowserSelection: .systemDefault,
        defaultLeadTime: 120,
        globalSnoozeDuration: 120,
        visibilityWindow: .today,
        showEventTitlesInMenuBar: true,
        soundEnabled: false,
        urgentRepeatSoundEnabled: false,
        presentationModeDefault: false,
        launchAtLoginEnabled: false,
        wakeGraceEnabled: true,
        visibleWindowDays: 1,
        selectedCalendarIDs: [],
        disabledGoogleAccountIDs: [],
        accountNicknames: [:],
        calendarAliases: [:],
        calendarSettings: [:],
        rules: [],
        googleOAuthClientID: ""
    )

    init(
        defaultBrowserSelection: BrowserSelection,
        defaultLeadTime: TimeInterval,
        globalSnoozeDuration: TimeInterval,
        visibilityWindow: MenuVisibilityWindow,
        showEventTitlesInMenuBar: Bool,
        soundEnabled: Bool,
        urgentRepeatSoundEnabled: Bool,
        presentationModeDefault: Bool,
        launchAtLoginEnabled: Bool,
        wakeGraceEnabled: Bool,
        visibleWindowDays: Int,
        selectedCalendarIDs: Set<String>,
        disabledGoogleAccountIDs: Set<String>,
        accountNicknames: [String: String],
        calendarAliases: [String: String],
        calendarSettings: [String: CalendarSettings],
        rules: [ReminderRule],
        googleOAuthClientID: String
    ) {
        self.defaultBrowserSelection = defaultBrowserSelection
        self.defaultLeadTime = defaultLeadTime
        self.globalSnoozeDuration = globalSnoozeDuration
        self.visibilityWindow = visibilityWindow
        self.showEventTitlesInMenuBar = showEventTitlesInMenuBar
        self.soundEnabled = soundEnabled
        self.urgentRepeatSoundEnabled = urgentRepeatSoundEnabled
        self.presentationModeDefault = presentationModeDefault
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.wakeGraceEnabled = wakeGraceEnabled
        self.visibleWindowDays = visibleWindowDays
        self.selectedCalendarIDs = selectedCalendarIDs
        self.disabledGoogleAccountIDs = disabledGoogleAccountIDs
        self.accountNicknames = accountNicknames
        self.calendarAliases = calendarAliases
        self.calendarSettings = calendarSettings
        self.rules = rules
        self.googleOAuthClientID = googleOAuthClientID
    }

    init(from decoder: Decoder) throws {
        let defaults = Self.defaults
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultBrowserSelection = try container.decodeIfPresent(BrowserSelection.self, forKey: .defaultBrowserSelection) ?? defaults.defaultBrowserSelection
        defaultLeadTime = try container.decodeIfPresent(TimeInterval.self, forKey: .defaultLeadTime) ?? defaults.defaultLeadTime
        globalSnoozeDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .globalSnoozeDuration) ?? defaults.globalSnoozeDuration
        visibilityWindow = try container.decodeIfPresent(MenuVisibilityWindow.self, forKey: .visibilityWindow) ?? defaults.visibilityWindow
        showEventTitlesInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .showEventTitlesInMenuBar) ?? defaults.showEventTitlesInMenuBar
        soundEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? defaults.soundEnabled
        urgentRepeatSoundEnabled = try container.decodeIfPresent(Bool.self, forKey: .urgentRepeatSoundEnabled) ?? defaults.urgentRepeatSoundEnabled
        presentationModeDefault = try container.decodeIfPresent(Bool.self, forKey: .presentationModeDefault) ?? defaults.presentationModeDefault
        launchAtLoginEnabled = try container.decodeIfPresent(Bool.self, forKey: .launchAtLoginEnabled) ?? defaults.launchAtLoginEnabled
        wakeGraceEnabled = try container.decodeIfPresent(Bool.self, forKey: .wakeGraceEnabled) ?? defaults.wakeGraceEnabled
        visibleWindowDays = try container.decodeIfPresent(Int.self, forKey: .visibleWindowDays) ?? defaults.visibleWindowDays
        selectedCalendarIDs = try container.decodeIfPresent(Set<String>.self, forKey: .selectedCalendarIDs) ?? defaults.selectedCalendarIDs
        disabledGoogleAccountIDs = try container.decodeIfPresent(Set<String>.self, forKey: .disabledGoogleAccountIDs) ?? defaults.disabledGoogleAccountIDs
        accountNicknames = try container.decodeIfPresent([String: String].self, forKey: .accountNicknames) ?? defaults.accountNicknames
        calendarAliases = try container.decodeIfPresent([String: String].self, forKey: .calendarAliases) ?? defaults.calendarAliases
        calendarSettings = try container.decodeIfPresent([String: CalendarSettings].self, forKey: .calendarSettings) ?? defaults.calendarSettings
        rules = try container.decodeIfPresent([ReminderRule].self, forKey: .rules) ?? defaults.rules
        googleOAuthClientID = try container.decodeIfPresent(String.self, forKey: .googleOAuthClientID) ?? defaults.googleOAuthClientID
    }

    func normalized() -> AppSettingsSnapshot {
        var copy = self
        copy.defaultLeadTime = Self.normalizedLeadTime(defaultLeadTime)
        copy.globalSnoozeDuration = Self.normalizedSnoozeDuration(globalSnoozeDuration)
        copy.visibleWindowDays = min(max(visibleWindowDays, 1), 7)
        if copy.defaultBrowserSelection.browser == .systemDefault {
            copy.defaultBrowserSelection.profileID = nil
        }
        copy.accountNicknames = Self.normalizedAliases(accountNicknames)
        copy.calendarAliases = Self.normalizedAliases(calendarAliases)
        return copy
    }

    private static func normalizedAliases(_ aliases: [String: String]) -> [String: String] {
        aliases.reduce(into: [:]) { result, entry in
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty && !value.isEmpty {
                result[key] = value
            }
        }
    }

    static func normalizedLeadTime(_ value: TimeInterval) -> TimeInterval {
        let clamped = min(max(value, defaultLeadTimeRange.lowerBound), defaultLeadTimeRange.upperBound)
        return (clamped / defaultLeadTimeStep).rounded() * defaultLeadTimeStep
    }

    static func normalizedSnoozeDuration(_ value: TimeInterval) -> TimeInterval {
        let clamped = min(max(value, 30), 15 * 60)
        return (clamped / 30).rounded() * 30
    }

    func calendarSettings(for calendarID: String) -> CalendarSettings {
        calendarSettings[calendarID] ?? .defaults(calendarID: calendarID)
    }

    func isCalendarSelected(_ calendarID: String) -> Bool {
        selectedCalendarIDs.isEmpty || selectedCalendarIDs.contains(calendarID)
    }

    func isAccountEnabled(_ accountID: String) -> Bool {
        !disabledGoogleAccountIDs.contains(accountID)
    }

    func protectedCalendars(from calendars: [UserCalendar]) -> [UserCalendar] {
        calendars.filter { calendar in
            calendar.isSelected
                && isAccountEnabled(calendar.accountID)
                && isCalendarSelected(calendar.id)
        }
    }

    func protectsEvent(_ event: CalendarEventOccurrence) -> Bool {
        isAccountEnabled(event.accountID) && isCalendarSelected(event.calendarID)
    }

    func accountNickname(for accountID: String) -> String? {
        nonEmptyAlias(accountNicknames[accountID])
    }

    func calendarAlias(for calendarID: String) -> String? {
        nonEmptyAlias(calendarAliases[calendarID])
    }

    func displayName(for account: ConnectedCalendarAccount) -> String {
        accountNickname(for: account.id) ?? account.displayName
    }

    func displayName(for calendar: UserCalendar) -> String {
        if let alias = calendarAlias(for: calendar.id) {
            return alias
        }
        if calendar.isPrimary, let nickname = accountNickname(for: calendar.accountID) {
            return nickname
        }
        return calendar.displayName
    }

    private func nonEmptyAlias(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
final class AppSettingsStore: ObservableObject {
    static let shared = AppSettingsStore()

    @Published private(set) var snapshot: AppSettingsSnapshot

    private let userDefaults: UserDefaults
    private let key = "meetingShield.settings.v1"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppSettingsSnapshot.self, from: data) {
            snapshot = decoded.normalized()
        } else {
            snapshot = .defaults
        }
    }

    func update(_ change: (inout AppSettingsSnapshot) -> Void) {
        var copy = snapshot
        change(&copy)
        snapshot = copy.normalized()
        persist()
    }

    func restoreDefaults() {
        snapshot = .defaults
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(snapshot)
            userDefaults.set(data, forKey: key)
        } catch {
            AppLog.lifecycle.error("settingsPersistFailed error=\(LogPrivacy.errorClass(error), privacy: .public)")
        }
    }
}
