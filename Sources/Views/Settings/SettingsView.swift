import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case calendars, alerts, menuBar, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .calendars: "Calendars"
        case .alerts: "Alerts"
        case .menuBar: "Menu bar"
        case .general: "General"
        }
    }
    var subtitle: String {
        switch self {
        case .calendars: "Decide what appears, and what gets your attention."
        case .alerts: "A little time to finish what you’re doing."
        case .menuBar: "Your next meeting, at a glance."
        case .general: "Make Meeting Shield feel at home."
        }
    }
    var systemImage: String {
        switch self {
        case .calendars: "calendar"
        case .alerts: "bell"
        case .menuBar: "menubar.rectangle"
        case .general: "gearshape"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store = AppSettingsStore.shared
    @ObservedObject var controller = MeetingShieldController.shared
    @State private var selectedPane: SettingsPane = .calendars
    @State var expandedCalendarIDs: Set<String> = []
    @State var managingAccount: ConnectedCalendarAccount?
    @State var accountPendingRemoval: ConnectedCalendarAccount?
    @State private var showDeveloperSetup = false
    @State private var showAlertPreview = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    pageHeading
                    PersistenceRecoverySection(controller: controller)
                    switch selectedPane {
                    case .calendars:
                        if connectedAccounts.isEmpty || !controller.hasGoogleOAuthClientConfiguration || needsConnectionRecovery {
                            connectionSection
                        }
                        calendarsSection
                        Text("Read-only access. Your calendar events stay unchanged.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        developerSetup
                    case .alerts:
                        alertTimingSection
                        soundSection
                        quietDeliverySection
                    case .menuBar:
                        menuBarSection
                    case .general:
                        SettingsSection(title: "Startup") {
                            SettingsCard {
                                SettingsRow(title: "Launch at login", subtitle: "Ready when you start your day.") {
                                    CompactSwitch(isOn: launchAtLoginBinding, accessibilityLabel: "Launch at login")
                                }
                            }
                        }
                        browserSection
                        privacySection
                    }
                }
                .padding(26)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(ShieldTheme.window)
        }
        .frame(minWidth: 740, minHeight: 540)
        .background(ShieldTheme.window)
        .sheet(item: $managingAccount) { account in accountDetails(account) }
        .sheet(isPresented: $showAlertPreview) { AlertDesignPreview() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(SettingsPane.allCases) { pane in
                Button { selectedPane = pane } label: {
                    Label(pane.title, systemImage: pane.systemImage)
                        .font(.system(size: 13, weight: selectedPane == pane ? .medium : .regular))
                        .foregroundStyle(selectedPane == pane ? ShieldTheme.accent : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(selectedPane == pane ? ShieldTheme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedPane == pane ? .isSelected : [])
            }
            Spacer()
            Label("Meeting Shield", systemImage: "shield")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.bottom, 8)
        }
        .padding(.horizontal, 10).padding(.top, 16)
        .frame(width: 170)
        .background(ShieldTheme.sidebar)
    }

    private var pageHeading: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(selectedPane.title).font(.system(size: 25, weight: .medium))
                    .accessibilityAddTraits(.isHeader)
                Text(selectedPane.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if selectedPane == .calendars {
                Button { controller.reconnectGoogle() } label: { Label("Account", systemImage: "plus") }
                    .buttonStyle(ShieldButtonStyle())
                    .disabled(!controller.hasGoogleOAuthClientConfiguration || isConnecting)
                    .accessibilityLabel("Add Google account")
            } else if selectedPane == .alerts {
                Button("Preview alert") { showAlertPreview = true }.buttonStyle(ShieldButtonStyle())
            } else if selectedPane == .menuBar {
                Button("Preview menu") { MenuBarController.shared.showPopover() }.buttonStyle(ShieldButtonStyle())
            }
        }
    }

    private var isConnecting: Bool {
        if case .authenticating = controller.authState { return true }
        return false
    }

    var connectionSection: some View {
        SettingsSection(title: "Google Calendar") {
            SettingsCard {
                SettingsRow(title: "Connection", value: googleStatusText)
                SettingsDivider()
                SettingsRow {
                    Button(isConnecting ? "Connecting…" : connectedAccounts.isEmpty ? "Connect Google Calendar" : "Reconnect Google Calendar") { controller.reconnectGoogle() }
                        .buttonStyle(ShieldButtonStyle())
                        .disabled(!controller.hasGoogleOAuthClientConfiguration || isConnecting)
                }
            }
        }
    }

    private var developerSetup: some View {
        DisclosureGroup("Developer setup", isExpanded: $showDeveloperSetup) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("OAuth desktop client ID", text: binding(\.googleOAuthClientID))
                    .shieldTextField()
                    .accessibilityLabel("OAuth desktop client ID")
                Text("Leave empty to use the configuration included with the app.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.top, 8)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private var alertTimingSection: some View {
        SettingsSection(title: "Timing") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Remind me before a meeting")
                        Spacer()
                        Text(Self.durationLabel(store.snapshot.defaultLeadTime)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: doubleBinding(\.defaultLeadTime), in: AppSettingsSnapshot.defaultLeadTimeRange, step: AppSettingsSnapshot.defaultLeadTimeStep)
                        .accessibilityLabel("Alert lead time")
                        .accessibilityValue(Self.durationLabel(store.snapshot.defaultLeadTime))
                    HStack { Text("30 seconds"); Spacer(); Text("15 minutes") }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(15).font(.system(size: 13))
                SettingsDivider()
                SettingsRow(title: "Default snooze", subtitle: "Always returns by 10 seconds before the start.") {
                    Picker("Default snooze", selection: doubleBinding(\.globalSnoozeDuration)) {
                        ForEach([30.0, 60, 120, 300], id: \.self) { seconds in
                            Text(Self.durationLabel(seconds)).tag(seconds)
                        }
                    }.labelsHidden().frame(width: 120)
                }
            }
        }
    }

    private var soundSection: some View {
        SettingsSection(title: "Sound") {
            SettingsCard {
                SettingsRow(title: "Play an alert sound", subtitle: "Silent by default.") {
                    CompactSwitch(isOn: boolBinding(\.soundEnabled), accessibilityLabel: "Play an alert sound")
                }
                if store.snapshot.soundEnabled {
                    SettingsDivider()
                    SettingsRow(title: "Repeat near the start", subtitle: "A second cue when the meeting is imminent.") {
                        CompactSwitch(isOn: boolBinding(\.urgentRepeatSoundEnabled), accessibilityLabel: "Urgent repeat sound")
                    }
                }
            }
        }
    }

    private var quietDeliverySection: some View {
        SettingsSection(title: "When to stay quiet") {
            SettingsCard {
                if let warning = controller.notificationWarning {
                    SettingsRow { Label(warning, systemImage: "bell.slash.circle").foregroundStyle(ShieldTheme.warning).fixedSize(horizontal: false, vertical: true) }
                    SettingsDivider()
                }
                SettingsRow(title: "Presentation mode by default", subtitle: "Use notifications instead of full-screen alerts.") {
                    CompactSwitch(isOn: boolBinding(\.presentationModeDefault), accessibilityLabel: "Presentation mode by default")
                }
                SettingsDivider()
                SettingsRow(title: "Give me a minute after waking", subtitle: "Use notifications for the first 60 seconds.") {
                    CompactSwitch(isOn: boolBinding(\.wakeGraceEnabled), accessibilityLabel: "Wake grace notifications")
                }
            }
        }
    }

    private var browserSection: some View {
        SettingsSection(title: "Opening meetings") {
            SettingsCard {
                SettingsRow(title: "Default browser") {
                    Picker("Default browser", selection: browserBinding) {
                        ForEach(BrowserKind.allCases) { browser in Text(browser.displayName).tag(browser) }
                    }.labelsHidden().frame(width: 155)
                }
                if store.snapshot.defaultBrowserSelection.browser.supportsProfileSelection {
                    SettingsDivider()
                    SettingsRow(title: "Profile") { profilePicker(browser: store.snapshot.defaultBrowserSelection.browser, selection: globalProfileBinding) }
                }
            }
        }
    }

    @ViewBuilder
    func profilePicker(browser: BrowserKind, selection: Binding<String?>) -> some View {
        let profiles = BrowserProfileService().profiles(for: browser)
        Picker("Profile", selection: selection) {
            Text("Browser default").tag(String?.none)
            if let selected = selection.wrappedValue, !profiles.contains(where: { $0.id == selected }) {
                Text("Saved profile unavailable").tag(String?.some(selected))
            }
            ForEach(profiles) { profile in Text(profile.displayName).tag(String?.some(profile.id)) }
        }.labelsHidden().frame(width: 165)
    }

    private var menuBarSection: some View {
        SettingsSection(title: "Visible meetings") {
            SettingsCard {
                SettingsRow(title: "Show meetings") {
                    Picker("Show meetings", selection: visibilityKindBinding) {
                        ForEach(MenuVisibilityKind.allCases) { kind in Text(kind.displayName).tag(kind) }
                    }.labelsHidden().frame(width: 135)
                }
                if store.snapshot.visibilityWindow.kind == .nextHours {
                    SettingsDivider()
                    SettingsRow { Stepper("Next \(store.snapshot.visibilityWindow.hours) hours", value: intBinding(\.visibilityWindow.hours), in: 1...12) }
                }
                if store.snapshot.visibilityWindow.kind == .nextDays {
                    SettingsDivider()
                    SettingsRow { Stepper("Next \(store.snapshot.visibilityWindow.days) days", value: intBinding(\.visibilityWindow.days), in: 1...7) }
                }
                SettingsDivider()
                SettingsRow(title: "Show event titles", subtitle: "Turn off to keep meeting names private in the menu bar.") {
                    CompactSwitch(isOn: boolBinding(\.showEventTitlesInMenuBar), accessibilityLabel: "Show event titles")
                }
            }
        }
    }

    private var privacySection: some View {
        SettingsSection(title: "Privacy") {
            VStack(alignment: .leading, spacing: 10) {
                Label("Read-only calendar access", systemImage: "lock.shield")
                Text("Tokens stay in Keychain. The limited calendar cache stays on this Mac. Meeting titles and links are not logged.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Calendar permissions") {
                    Text(AppIdentity.googleScopes.joined(separator: "\n"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 6)
                }.font(.system(size: 12))
            }
        }
    }

    static func durationLabel(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds)) seconds" }
        let minutes = seconds / 60
        return minutes == 1 ? "1 minute" : "\(minutes.formatted(.number.precision(.fractionLength(0...1)))) minutes"
    }

    var needsConnectionRecovery: Bool {
        controller.protectionHealthSummary.actions.contains(.reconnect)
    }

    var googleStatusText: String {
        switch controller.authState {
        case .authenticating: "Connecting"
        case .connected: needsConnectionRecovery ? "Needs reconnect" : "Connected"
        case .disconnected: "Disconnected"
        case .needsConfiguration: "Needs setup"
        case .expired: "Needs reconnect"
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
            // The registration is the source of truth when running as a bundle;
            // the stored flag alone can drift from reality.
            if Bundle.main.bundleURL.pathExtension == "app" {
                return LaunchAtLoginService.shared.isEnabled
            }
            return store.snapshot.launchAtLoginEnabled
        } set: { value in
            updateSettings { $0.launchAtLoginEnabled = value }
            do {
                try LaunchAtLoginService.shared.setEnabled(value)
            } catch {
                AppLog.lifecycle.error("launchAtLoginUpdateFailed error=\(LogPrivacy.errorClass(error), privacy: .public)")
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

    func updateSettings(_ change: (inout AppSettingsSnapshot) -> Void) {
        store.update(change)
        controller.handleSettingsChanged()
    }
}
