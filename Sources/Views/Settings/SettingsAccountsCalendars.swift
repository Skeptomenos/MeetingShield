import AppKit
import SwiftUI

extension SettingsView {
    var calendarsSection: some View {
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

    var accountsSection: some View {
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

    func accountRow(_ account: ConnectedCalendarAccount) -> some View {
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

    var connectedAccounts: [ConnectedCalendarAccount] {
        var byID = Dictionary(controller.accounts.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
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

    var calendarsGroupedByAccount: [(account: ConnectedCalendarAccount, calendars: [UserCalendar])] {
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

    func calendarRow(_ calendar: UserCalendar) -> some View {
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
                        Text(store.snapshot.calendarSettings(for: calendar.id).isAlertEnabled ? "Alerts enabled" : "Alerts off")
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
            HStack(spacing: 8) {
                Text("Browser")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LiquidGlassTheme.tertiaryText)
                Picker("Browser override", selection: calendarBrowserBinding(calendar.id)) {
                    Text("Use default").tag(BrowserKind?.none)
                    ForEach(BrowserKind.allCases) { browser in
                        Text(browser.displayName).tag(BrowserKind?.some(browser))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 124)
                if let overrideBrowser = store.snapshot.calendarSettings(for: calendar.id).browserSelection?.browser,
                   overrideBrowser.supportsProfileSelection {
                    profilePicker(browser: overrideBrowser, selection: calendarProfileBinding(calendar.id))
                }
                Spacer(minLength: 0)
            }
            .disabled(!store.snapshot.isAccountEnabled(calendar.accountID))
        }
        .opacity(store.snapshot.isAccountEnabled(calendar.accountID) ? 1 : 0.55)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    func accountEnabledBinding(_ accountID: String) -> Binding<Bool> {
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

    func calendarSelectedBinding(_ calendarID: String) -> Binding<Bool> {
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

    func calendarAlertsBinding(_ calendarID: String) -> Binding<Bool> {
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

    func accountNicknameBinding(_ accountID: String) -> Binding<String> {
        Binding {
            store.snapshot.accountNicknames[accountID] ?? ""
        } set: { nickname in
            updateSettings { settings in
                settings.accountNicknames[accountID] = nickname
            }
        }
    }

    func calendarAliasBinding(_ calendarID: String) -> Binding<String> {
        Binding {
            store.snapshot.calendarAliases[calendarID] ?? ""
        } set: { alias in
            updateSettings { settings in
                settings.calendarAliases[calendarID] = alias
            }
        }
    }

    var globalProfileBinding: Binding<String?> {
        Binding {
            store.snapshot.defaultBrowserSelection.profileID
        } set: { profileID in
            updateSettings { $0.defaultBrowserSelection.profileID = profileID }
        }
    }

    func calendarBrowserBinding(_ calendarID: String) -> Binding<BrowserKind?> {
        Binding {
            store.snapshot.calendarSettings(for: calendarID).browserSelection?.browser
        } set: { browser in
            updateSettings { settings in
                var calendarSettings = settings.calendarSettings(for: calendarID)
                if let browser {
                    let existing = calendarSettings.browserSelection
                    calendarSettings.browserSelection = BrowserSelection(
                        browser: browser,
                        profileID: browser.supportsProfileSelection ? existing?.profileID : nil
                    )
                } else {
                    calendarSettings.browserSelection = nil
                }
                settings.calendarSettings[calendarID] = calendarSettings
            }
        }
    }

    func calendarProfileBinding(_ calendarID: String) -> Binding<String?> {
        Binding {
            store.snapshot.calendarSettings(for: calendarID).browserSelection?.profileID
        } set: { profileID in
            updateSettings { settings in
                var calendarSettings = settings.calendarSettings(for: calendarID)
                if var selection = calendarSettings.browserSelection {
                    selection.profileID = profileID
                    calendarSettings.browserSelection = selection
                }
                settings.calendarSettings[calendarID] = calendarSettings
            }
        }
    }}
