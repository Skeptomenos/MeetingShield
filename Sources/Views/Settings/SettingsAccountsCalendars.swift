import AppKit
import SwiftUI

extension SettingsView {
    var calendarsSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if connectedAccounts.isEmpty {
                SettingsCard {
                    SettingsRow(title: "Your calendars will appear here", subtitle: "Connect a Google account to start protecting your meetings.")
                }
            }
            ForEach(calendarsGroupedByAccount, id: \.account.id) { group in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.snapshot.displayName(for: group.account)).font(.system(size: 15, weight: .medium))
                            Text(accountSubtitle(group.account)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Manage") { managingAccount = group.account }
                            .buttonStyle(.plain).foregroundStyle(ShieldTheme.accent)
                            .accessibilityLabel("Manage \(store.snapshot.displayName(for: group.account))")
                    }
                    SettingsCard {
                        if group.calendars.isEmpty {
                            SettingsRow(title: "No calendars available", subtitle: "Reconnect or check this account’s calendar access.")
                        }
                        ForEach(Array(group.calendars.enumerated()), id: \.element.id) { index, calendar in
                            calendarRow(calendar)
                            if index < group.calendars.count - 1 { SettingsDivider() }
                        }
                    }
                }
            }
        }
    }

    private func accountSubtitle(_ account: ConnectedCalendarAccount) -> String {
        let status = store.snapshot.isAccountEnabled(account.id) ? "Active" : "Account paused"
        return "\(status) · \(account.displayName)"
    }

    func accountDetails(_ account: ConnectedCalendarAccount) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(store.snapshot.displayName(for: account)).font(.title2.weight(.medium))
                Text(account.displayName).font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Account name").font(.system(size: 12))
                TextField("Account name", text: accountNicknameBinding(account.id)).shieldTextField()
            }
            SettingsCard {
                SettingsRow(title: "Use this account", subtitle: "Pausing keeps its calendar choices for later.") {
                    CompactSwitch(isOn: accountEnabledBinding(account.id), accessibilityLabel: "Account active")
                }
            }
            Button("Reconnect Google Calendar") { managingAccount = nil; controller.reconnectGoogle() }
                .disabled(!controller.hasGoogleOAuthClientConfiguration)
            DisclosureGroup("Remove account") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Stops reminders from this account. Your Google calendars are unchanged.").font(.callout).foregroundStyle(.secondary)
                    Button("Remove this account…", role: .destructive) { accountPendingRemoval = account }
                }.padding(.top, 8)
            }
            HStack { Spacer(); Button("Done") { managingAccount = nil }.keyboardShortcut(.defaultAction) }
        }
        .padding(26).frame(width: 420).background(ShieldTheme.window)
        .alert("Remove this account?", isPresented: Binding(get: { accountPendingRemoval != nil }, set: { if !$0 { accountPendingRemoval = nil } })) {
            Button("Cancel", role: .cancel) { accountPendingRemoval = nil }
            Button("Remove account", role: .destructive) {
                if let account = accountPendingRemoval { controller.removeConnectedAccount(account.id) }
                accountPendingRemoval = nil
                managingAccount = nil
            }
        } message: {
            Text("Meeting Shield will stop protecting its calendars. Your Google calendars will stay unchanged.")
        }
    }

    var connectedAccounts: [ConnectedCalendarAccount] {
        var byID = Dictionary(controller.accounts.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for calendar in controller.calendars where byID[calendar.accountID] == nil {
            byID[calendar.accountID] = ConnectedCalendarAccount(id: calendar.accountID, displayName: calendar.accountDisplayName ?? calendar.accountID)
        }
        return byID.values.sorted {
            store.snapshot.displayName(for: $0).localizedCaseInsensitiveCompare(store.snapshot.displayName(for: $1)) == .orderedAscending
        }
    }

    var calendarsGroupedByAccount: [(account: ConnectedCalendarAccount, calendars: [UserCalendar])] {
        connectedAccounts.map { account in
            (account, controller.calendars.filter { $0.accountID == account.id }.sorted {
                if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            })
        }
    }

    func calendarRow(_ calendar: UserCalendar) -> some View {
        let isEnabled = store.snapshot.isAccountEnabled(calendar.accountID)
        let expanded = expandedCalendarIDs.contains(calendar.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "calendar").font(.system(size: 17)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.snapshot.displayName(for: calendar))
                        .font(.system(size: 13, weight: .medium)).lineLimit(2)
                    if calendar.isPrimary { Text("Primary calendar").font(.system(size: 11)).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Picker("Calendar mode", selection: calendarModeBinding(calendar)) {
                    ForEach(CalendarDisplayMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .labelsHidden().frame(width: 144).disabled(!isEnabled)
                .accessibilityLabel("\(calendar.displayName) mode")
                Button {
                    if expanded { expandedCalendarIDs.remove(calendar.id) } else { expandedCalendarIDs.insert(calendar.id) }
                } label: { Image(systemName: "slider.horizontal.3").frame(width: 26, height: 26) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("\(calendar.displayName) details")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }.padding(15)
            if let warning = calendar.eventAccessWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(ShieldTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 15).padding(.bottom, 12)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Display name").font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField(calendar.isPrimary ? "Calendar alias or account name" : "Calendar alias", text: calendarAliasBinding(calendar.id)).shieldTextField()
                    }
                    HStack {
                        Text("Open meetings with").font(.system(size: 12))
                        Spacer()
                        Picker("Browser override", selection: calendarBrowserBinding(calendar.id)) {
                            Text("Use default browser").tag(BrowserKind?.none)
                            ForEach(BrowserKind.allCases) { browser in Text(browser.displayName).tag(BrowserKind?.some(browser)) }
                        }.labelsHidden().frame(width: 165)
                    }
                    if let browser = store.snapshot.calendarSettings(for: calendar.id).browserSelection?.browser, browser.supportsProfileSelection {
                        HStack { Text("Profile").font(.system(size: 12)); Spacer(); profilePicker(browser: browser, selection: calendarProfileBinding(calendar.id)) }
                    }
                }
                .padding(15).background(ShieldTheme.window).disabled(!isEnabled)
            }
        }
    }

    func calendarModeBinding(_ calendar: UserCalendar) -> Binding<CalendarDisplayMode> {
        Binding { store.snapshot.displayMode(for: calendar) } set: { mode in
            updateSettings { $0.setDisplayMode(mode, for: calendar, availableCalendars: controller.calendars) }
        }
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
    }
}
