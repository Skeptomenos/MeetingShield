import AppKit
import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case accounts
    case calendars
    case alerts
    case browser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .accounts: "Accounts"
        case .calendars: "Calendars"
        case .alerts: "Alerts"
        case .browser: "Browser"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "person"
        case .calendars: "calendar"
        case .alerts: "bell"
        case .browser: "globe"
        }
    }
}

private enum SettingsTheme {
    static let window = LiquidGlassTheme.window
    static let sidebar = LiquidGlassTheme.sidebar
    static let card = LiquidGlassTheme.glassFill
    static let separator = LiquidGlassTheme.separator
    static let border = LiquidGlassTheme.border
    static let selected = LiquidGlassTheme.accent.opacity(0.22)
}

private enum SettingsLayout {
    static let titlebarSafeTopPadding: CGFloat = 50
}

struct SettingsView: View {
    @ObservedObject private var store = AppSettingsStore.shared
    @ObservedObject private var controller = MeetingShieldController.shared
    @State private var selectedPane: SettingsPane = .calendars
    @State private var showDeveloperSetup = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
                .background(SettingsTheme.separator)
            content
        }
        .frame(minWidth: 740, minHeight: 580)
        .background(.regularMaterial)
        .background(SettingsTheme.window)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(SettingsPane.allCases) { pane in
                Button {
                    selectedPane = pane
                } label: {
                    Label(pane.title, systemImage: pane.systemImage)
                        .font(.system(size: 13, weight: selectedPane == pane ? .semibold : .medium))
                        .foregroundStyle(selectedPane == pane ? Color.white.opacity(0.92) : LiquidGlassTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selectedPane == pane ? SettingsTheme.selected : Color.clear)
                        )
                        .overlay {
                            if selectedPane == pane {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.top, SettingsLayout.titlebarSafeTopPadding)
        .padding(.horizontal, 10)
        .frame(width: 194)
        .background(.ultraThinMaterial)
        .background(SettingsTheme.sidebar)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch selectedPane {
                case .general:
                    menuBarSection
                    recoverySection
                case .calendars:
                    calendarsSection
                case .alerts:
                    alertTimingSection
                    recoverySection
                case .browser:
                    browserSection
                case .accounts:
                    accountsSection
                    googleCalendarSection
                    privacySection
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, SettingsLayout.titlebarSafeTopPadding)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .background(SettingsTheme.window)
    }

    private var googleCalendarSection: some View {
        SettingsSection(title: "Google Calendar") {
            SettingsCard {
                SettingsRow(title: "Status", value: googleStatusText)
                SettingsDivider()
                SettingsRow(title: "Connection", value: controller.googleOAuthConfigurationSource)
                SettingsDivider()
                SettingsRow {
                    Button {
                        MeetingShieldController.shared.reconnectGoogle()
                    } label: {
                        Label("Connect Google Calendar", systemImage: "link")
                    }
                    .buttonStyle(SmallGlassButtonStyle(role: .neutral))
                    .disabled(!controller.hasGoogleOAuthClientConfiguration)
                }
                SettingsDivider()
                DisclosureGroup(isExpanded: $showDeveloperSetup) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("OAuth desktop client ID", text: binding(\.googleOAuthClientID))
                            .glassTextField()
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Developer Google setup")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LiquidGlassTheme.secondaryText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private var alertTimingSection: some View {
        SettingsSection(title: "Alert Timing") {
            SettingsCard {
                SettingsRow {
                    Stepper(
                        "Lead time: \(Int(store.snapshot.defaultLeadTime))s",
                        value: doubleBinding(\.defaultLeadTime),
                        in: AppSettingsSnapshot.defaultLeadTimeRange,
                        step: AppSettingsSnapshot.defaultLeadTimeStep
                    )
                }
                SettingsDivider()
                SettingsRow(title: "Snooze") {
                    Picker("Snooze", selection: doubleBinding(\.globalSnoozeDuration)) {
                        Text("30s").tag(TimeInterval(30))
                        Text("1m").tag(TimeInterval(60))
                        Text("2m").tag(TimeInterval(120))
                        Text("5m").tag(TimeInterval(300))
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 72)
                }
                SettingsDivider()
                SettingsRow(title: "Sound") {
                    CompactSwitch(isOn: boolBinding(\.soundEnabled), accessibilityLabel: "Sound")
                }
                SettingsDivider()
                SettingsRow(title: "Urgent repeat sound") {
                    CompactSwitch(isOn: boolBinding(\.urgentRepeatSoundEnabled), accessibilityLabel: "Urgent repeat sound")
                }
            }
        }
    }

    private var browserSection: some View {
        SettingsSection(title: "Browser") {
            SettingsCard {
                SettingsRow(title: "Default browser") {
                    Picker("Default browser", selection: browserBinding) {
                        ForEach(BrowserKind.allCases) { browser in
                            Text(browser.displayName).tag(browser)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 112)
                }
            }
        }
    }

    private var calendarsSection: some View {
        SettingsSection(title: "Calendars") {
            if controller.calendars.isEmpty {
                SettingsCard {
                    SettingsRow(title: "No calendars")
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(calendarsGroupedByAccount, id: \.account.id) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.snapshot.displayName(for: group.account))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(LiquidGlassTheme.secondaryText)
                                .padding(.leading, 2)
                            SettingsCard {
                                ForEach(Array(group.calendars.enumerated()), id: \.element.id) { index, calendar in
                                    calendarRow(calendar)
                                    if index < group.calendars.count - 1 {
                                        SettingsDivider()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var accountsSection: some View {
        SettingsSection(title: "Accounts") {
            SettingsCard {
                if connectedAccounts.isEmpty {
                    SettingsRow(title: "No connected accounts")
                } else {
                    ForEach(Array(connectedAccounts.enumerated()), id: \.element.id) { index, account in
                        accountRow(account)
                        if index < connectedAccounts.count - 1 {
                            SettingsDivider()
                        }
                    }
                }
            }
        }
    }

    private func accountRow(_ account: ConnectedCalendarAccount) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.snapshot.displayName(for: account))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LiquidGlassTheme.primaryText)
                        .lineLimit(1)
                    if store.snapshot.displayName(for: account) != account.displayName {
                        Text(account.displayName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(LiquidGlassTheme.tertiaryText)
                            .lineLimit(1)
                    }
                    Text(store.snapshot.isAccountEnabled(account.id) ? "Active" : "Deactivated")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LiquidGlassTheme.secondaryText)
                }
                Spacer(minLength: 12)
                CompactSwitch(isOn: accountEnabledBinding(account.id), accessibilityLabel: "Account active")
                Button("Remove", role: .destructive) {
                    controller.removeConnectedAccount(account.id)
                }
                .buttonStyle(SmallGlassButtonStyle(role: .destructive, minWidth: 64))
            }
            TextField("Nickname for primary calendar", text: accountNicknameBinding(account.id))
                .glassTextField()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var connectedAccounts: [ConnectedCalendarAccount] {
        var byID = Dictionary(uniqueKeysWithValues: controller.accounts.map { ($0.id, $0) })
        for calendar in controller.calendars {
            byID[calendar.accountID] = ConnectedCalendarAccount(
                id: calendar.accountID,
                displayName: calendar.accountDisplayName ?? calendar.accountID
            )
        }
        return byID.values.sorted { first, second in
            store.snapshot.displayName(for: first).localizedCaseInsensitiveCompare(store.snapshot.displayName(for: second)) == .orderedAscending
        }
    }

    private var calendarsGroupedByAccount: [(account: ConnectedCalendarAccount, calendars: [UserCalendar])] {
        let accounts = connectedAccounts
        return accounts.compactMap { account in
            let calendars = controller.calendars
                .filter { $0.accountID == account.id }
                .sorted { first, second in
                    if first.isPrimary != second.isPrimary {
                        return first.isPrimary
                    }
                    return first.displayName.localizedCaseInsensitiveCompare(second.displayName) == .orderedAscending
                }
            guard !calendars.isEmpty else { return nil }
            return (account, calendars)
        }
    }

    private func calendarRow(_ calendar: UserCalendar) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(calendar.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LiquidGlassTheme.primaryText)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if calendar.isPrimary {
                            Text("Primary")
                        }
                        Text("Alerts enabled")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LiquidGlassTheme.secondaryText)
                    let menuLabel = store.snapshot.displayName(for: calendar)
                    if menuLabel != calendar.displayName {
                        Text("Menu label: \(menuLabel)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(LiquidGlassTheme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 7) {
                    HStack(spacing: 7) {
                        Text("On")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LiquidGlassTheme.tertiaryText)
                        CompactSwitch(isOn: calendarSelectedBinding(calendar.id), accessibilityLabel: "Calendar enabled")
                            .disabled(!store.snapshot.isAccountEnabled(calendar.accountID))
                    }
                    HStack(spacing: 7) {
                        Text("Alerts")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LiquidGlassTheme.tertiaryText)
                        CompactSwitch(isOn: calendarAlertsBinding(calendar.id), accessibilityLabel: "Calendar alerts")
                            .disabled(!store.snapshot.isAccountEnabled(calendar.accountID))
                    }
                }
            }
            TextField(calendar.isPrimary ? "Calendar alias or account nickname" : "Calendar alias", text: calendarAliasBinding(calendar.id))
                .glassTextField()
                .disabled(!store.snapshot.isAccountEnabled(calendar.accountID))
        }
        .opacity(store.snapshot.isAccountEnabled(calendar.accountID) ? 1 : 0.55)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var menuBarSection: some View {
        SettingsSection(title: "Menu Bar") {
            SettingsCard {
                SettingsRow(title: "Visibility") {
                    Picker("Visibility", selection: visibilityKindBinding) {
                        ForEach(MenuVisibilityKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 128)
                }
                SettingsDivider()
                SettingsRow {
                    Stepper("Hours: \(store.snapshot.visibilityWindow.hours)", value: intBinding(\.visibilityWindow.hours), in: 1...12)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow {
                    Stepper("Days: \(store.snapshot.visibleWindowDays)", value: intBinding(\.visibleWindowDays), in: 1...7)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(title: "Show event titles") {
                    CompactSwitch(isOn: boolBinding(\.showEventTitlesInMenuBar), accessibilityLabel: "Show event titles")
                }
            }
        }
    }

    private var recoverySection: some View {
        SettingsSection(title: "Recovery") {
            SettingsCard {
                SettingsRow(title: "Presentation mode by default") {
                    CompactSwitch(isOn: boolBinding(\.presentationModeDefault), accessibilityLabel: "Presentation mode by default")
                }
                SettingsDivider()
                SettingsRow(title: "Launch at login") {
                    CompactSwitch(isOn: launchAtLoginBinding, accessibilityLabel: "Launch at login")
                }
                SettingsDivider()
                SettingsRow(title: "Wake grace notifications") {
                    CompactSwitch(isOn: boolBinding(\.wakeGraceEnabled), accessibilityLabel: "Wake grace notifications")
                }
            }
        }
    }

    private var privacySection: some View {
        SettingsSection(title: "Privacy") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Read-only calendar access")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Tokens stay in Keychain. Calendar cache stays local.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LiquidGlassTheme.secondaryText)
                    Text(AppIdentity.googleScopes.joined(separator: "\n"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LiquidGlassTheme.tertiaryText)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var googleStatusText: String {
        switch controller.authState {
        case .authenticating:
            "Connecting"
        case .connected:
            "Connected"
        case .disconnected:
            "Disconnected"
        case .needsConfiguration:
            "Needs setup"
        case .expired:
            "Needs reconnect"
        }
    }

    private var browserBinding: Binding<BrowserKind> {
        Binding {
            store.snapshot.defaultBrowserSelection.browser
        } set: { browser in
            updateSettings { settings in
                settings.defaultBrowserSelection.browser = browser
                if !browser.supportsProfileSelection {
                    settings.defaultBrowserSelection.profileID = nil
                }
            }
        }
    }

    private var visibilityKindBinding: Binding<MenuVisibilityKind> {
        Binding {
            store.snapshot.visibilityWindow.kind
        } set: { kind in
            updateSettings { $0.visibilityWindow.kind = kind }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding {
            store.snapshot.launchAtLoginEnabled
        } set: { value in
            updateSettings { $0.launchAtLoginEnabled = value }
            try? LaunchAtLoginService.shared.setEnabled(value)
        }
    }

    private func accountEnabledBinding(_ accountID: String) -> Binding<Bool> {
        Binding {
            store.snapshot.isAccountEnabled(accountID)
        } set: { isEnabled in
            updateSettings { settings in
                if isEnabled {
                    settings.disabledGoogleAccountIDs.remove(accountID)
                } else {
                    settings.disabledGoogleAccountIDs.insert(accountID)
                }
            }
        }
    }

    private func calendarSelectedBinding(_ calendarID: String) -> Binding<Bool> {
        Binding {
            store.snapshot.isCalendarSelected(calendarID)
        } set: { isSelected in
            updateSettings { settings in
                if settings.selectedCalendarIDs.isEmpty {
                    settings.selectedCalendarIDs = Set(controller.calendars.map(\.id))
                }
                if isSelected {
                    settings.selectedCalendarIDs.insert(calendarID)
                } else {
                    settings.selectedCalendarIDs.remove(calendarID)
                }
            }
        }
    }

    private func calendarAlertsBinding(_ calendarID: String) -> Binding<Bool> {
        Binding {
            store.snapshot.calendarSettings(for: calendarID).isAlertEnabled
        } set: { isEnabled in
            updateSettings { settings in
                var calendarSettings = settings.calendarSettings(for: calendarID)
                calendarSettings.isAlertEnabled = isEnabled
                settings.calendarSettings[calendarID] = calendarSettings
            }
        }
    }

    private func accountNicknameBinding(_ accountID: String) -> Binding<String> {
        Binding {
            store.snapshot.accountNicknames[accountID] ?? ""
        } set: { nickname in
            updateSettings { settings in
                settings.accountNicknames[accountID] = nickname
            }
        }
    }

    private func calendarAliasBinding(_ calendarID: String) -> Binding<String> {
        Binding {
            store.snapshot.calendarAliases[calendarID] ?? ""
        } set: { alias in
            updateSettings { settings in
                settings.calendarAliases[calendarID] = alias
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<AppSettingsSnapshot, String>) -> Binding<String> {
        Binding {
            store.snapshot[keyPath: keyPath]
        } set: { value in
            updateSettings { $0[keyPath: keyPath] = value }
        }
    }

    private func boolBinding(_ keyPath: WritableKeyPath<AppSettingsSnapshot, Bool>) -> Binding<Bool> {
        Binding {
            store.snapshot[keyPath: keyPath]
        } set: { value in
            updateSettings { $0[keyPath: keyPath] = value }
        }
    }

    private func doubleBinding(_ keyPath: WritableKeyPath<AppSettingsSnapshot, TimeInterval>) -> Binding<TimeInterval> {
        Binding {
            store.snapshot[keyPath: keyPath]
        } set: { value in
            updateSettings { $0[keyPath: keyPath] = value }
        }
    }

    private func intBinding(_ keyPath: WritableKeyPath<AppSettingsSnapshot, Int>) -> Binding<Int> {
        Binding {
            store.snapshot[keyPath: keyPath]
        } set: { value in
            updateSettings { $0[keyPath: keyPath] = value }
        }
    }

    private func updateSettings(_ change: (inout AppSettingsSnapshot) -> Void) {
        store.update(change)
        controller.handleSettingsChanged()
    }
}

private struct SettingsSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(LiquidGlassTheme.secondaryText)
                .tracking(0.6)
                .padding(.leading, 2)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .glassPanel(cornerRadius: 10)
        .frame(maxWidth: .infinity)
    }
}

private struct SettingsRow<Control: View>: View {
    var title: String?
    var value: String?
    @ViewBuilder var control: () -> Control

    init(title: String? = nil, value: String? = nil, @ViewBuilder control: @escaping () -> Control = { EmptyView() }) {
        self.title = title
        self.value = value
        self.control = control
    }

    var body: some View {
        HStack(spacing: 16) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LiquidGlassTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if let value {
                    Text(value)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LiquidGlassTheme.secondaryText)
                        .lineLimit(1)
                }
                control()
            } else {
                control()
                Spacer(minLength: 12)
                if let value {
                    Text(value)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LiquidGlassTheme.secondaryText)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(SettingsTheme.separator)
            .frame(height: 1)
    }
}
