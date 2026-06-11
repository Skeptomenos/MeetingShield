import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
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

enum SettingsTheme {
    static let window = LiquidGlassTheme.window
    static let sidebar = LiquidGlassTheme.sidebar
    static let card = LiquidGlassTheme.glassFill
    static let separator = LiquidGlassTheme.separator
    static let border = LiquidGlassTheme.border
    static let selected = LiquidGlassTheme.accent.opacity(0.22)
}

enum SettingsLayout {
    static let titlebarSafeTopPadding: CGFloat = 50
}
struct SettingsView: View {
    @ObservedObject var store = AppSettingsStore.shared
    @ObservedObject var controller = MeetingShieldController.shared
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
                if store.snapshot.defaultBrowserSelection.browser.supportsProfileSelection {
                    SettingsDivider()
                    SettingsRow(title: "Profile") {
                        profilePicker(
                            browser: store.snapshot.defaultBrowserSelection.browser,
                            selection: globalProfileBinding
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    func profilePicker(browser: BrowserKind, selection: Binding<String?>) -> some View {
        let profiles = BrowserProfileService().profiles(for: browser)
        if profiles.isEmpty {
            Text("No profiles found")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LiquidGlassTheme.tertiaryText)
        } else {
            Picker("Profile", selection: selection) {
                Text("Browser default").tag(String?.none)
                ForEach(profiles) { profile in
                    Text(profile.displayName).tag(String?.some(profile.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 150)
        }
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
                if controller.notificationHealth.authorizationDenied {
                    SettingsRow {
                        Label(
                            "Notifications are disabled in System Settings. Presentation mode and wake grace alerts cannot appear.",
                            systemImage: "bell.slash.circle.fill"
                        )
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LiquidGlassTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    SettingsDivider()
                }
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

