import AppKit
import SwiftUI

@main
struct MeetingShieldApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        ProcessInfo.processInfo.disableAutomaticTermination("Meeting Shield continuously monitors meeting reminders.")
        ProcessInfo.processInfo.disableSuddenTermination()
        AppLog.lifecycle.info("applicationInitialized automaticTerminationDisabled=true suddenTerminationDisabled=true")
        DiagnosticsRecorder.record("app_initialized")
    }

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.lifecycle.info("applicationDidFinishLaunching bundle=\(Bundle.main.bundleIdentifier ?? "missing", privacy: .public) smoke=\(CommandLine.arguments.contains("--smoke-test"), privacy: .public)")
        NSApp.setActivationPolicy(.accessory)
        DiagnosticsRecorder.record("launch_complete")
        if CommandLine.arguments.contains("--smoke-test") {
            AppLog.lifecycle.info("smokeTestLaunch")
            print("Meeting Shield smoke launch OK")
            NSApp.terminate(nil)
            return
        }
        configureMainMenu()
        MenuBarController.shared.configure(controller: MeetingShieldController.shared)
        MeetingShieldController.shared.start()
        DispatchQueue.main.async { [weak self] in
            self?.configureMainMenu()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLog.lifecycle.info("applicationShouldTerminate")
        DiagnosticsRecorder.record("termination_requested")
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.lifecycle.info("applicationWillTerminate")
        DiagnosticsRecorder.record("application_will_terminate")
        MeetingShieldController.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func openSettingsFromMenu(_ sender: Any?) {
        MeetingShieldController.shared.openSettings()
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: AppIdentity.displayName)

        appMenu.addItem(NSMenuItem(
            title: "About \(AppIdentity.displayName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettingsFromMenu(_:)), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(settingsItem)

        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit \(AppIdentity.displayName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }
}

@MainActor
final class MeetingShieldController: ObservableObject {
    static let shared = MeetingShieldController()

    @Published private(set) var calendars: [UserCalendar] = []
    @Published private(set) var accounts: [ConnectedCalendarAccount] = []
    @Published private(set) var events: [CalendarEventOccurrence] = []
    @Published private(set) var scheduledReminders: [ScheduledReminder] = []
    @Published private(set) var activeReminders: [ScheduledReminder] = []
    @Published private(set) var fallback: JoinFallbackState?
    @Published private(set) var statusMessage: String?
    @Published private(set) var authState: CalendarProviderAuthState = .disconnected
    @Published var isPresentationMode: Bool {
        didSet {
            if isPresentationMode != oldValue {
                handlePresentationModeChange()
            }
            MenuBarController.shared.refresh()
        }
    }

    let settingsStore: AppSettingsStore

    private var provider: any CalendarProvider
    private let linkExtractor = MeetingLinkExtractor()
    private let eligibilityEngine = EventEligibilityEngine()
    private let scheduler = ReminderScheduler()
    private let reminderStateStore: ReminderStateStore
    private let cacheStore: EventCacheStore
    private var notificationService: any MeetingNotifying
    private let launcher: MeetingLauncher
    private var nextActionTimer: Timer?
    private var refreshTimer: Timer?
    private var fallbackTimer: Timer?
    private var started = false
    private var failedRefreshCount = 0
    private var lastSuccessfulRefresh: Date?
    private var connectionFailureMessage: String?

    private init(
        settingsStore: AppSettingsStore = .shared,
        provider: any CalendarProvider = DisconnectedCalendarProvider(),
        reminderStateStore: ReminderStateStore = ReminderStateStore(
            fileURL: FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "MeetingShield/reminder-state.json")
        ),
        cacheStore: EventCacheStore = EventCacheStore(),
        notificationService: any MeetingNotifying = NoopNotificationService(),
        launcher: MeetingLauncher = MeetingLauncher()
    ) {
        self.settingsStore = settingsStore
        self.provider = provider
        self.reminderStateStore = reminderStateStore
        self.cacheStore = cacheStore
        self.notificationService = notificationService
        self.launcher = launcher
        self.isPresentationMode = settingsStore.snapshot.presentationModeDefault
    }

    var menuBarTitle: String {
        guard let nextEvent else { return AppIdentity.menuBarTitle }
        let countdown = RelativeDateTimeFormatter.shortString(for: nextEvent.startDate, relativeTo: Date())
        if settingsStore.snapshot.showEventTitlesInMenuBar {
            return "\(countdown) \(nextEvent.title)"
        }
        return countdown
    }

    var menuEvents: [CalendarEventOccurrence] {
        menuEvents(now: Date())
    }

    var menuBarSystemImage: String {
        if isPresentationMode { return "bell.slash.fill" }
        if case .expired = authState { return "exclamationmark.triangle.fill" }
        if statusMessage != nil { return "calendar.badge.exclamationmark" }
        if !activeReminders.isEmpty { return "alarm.fill" }
        if nextEvent?.startDate.timeIntervalSinceNow ?? .greatestFiniteMagnitude < 5 * 60 {
            return "clock.badge.exclamationmark"
        }
        return "calendar.badge.clock"
    }

    var hasGoogleOAuthClientConfiguration: Bool {
        !resolvedGoogleOAuthClientID().isEmpty
    }

    var googleOAuthConfigurationSource: String {
        let snapshotValue = settingsStore.snapshot.googleOAuthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !snapshotValue.isEmpty { return "Developer settings" }
        if !Self.bundledGoogleOAuthClientID().isEmpty { return "This app build" }
        if !Self.environmentGoogleOAuthClientID().isEmpty { return "Local environment" }
        return "Missing"
    }

    var nextEvent: CalendarEventOccurrence? {
        menuEvents.first
    }

    func menuEvents(now: Date) -> [CalendarEventOccurrence] {
        MenuEventFilter.visibleEvents(
            from: events,
            settings: settingsStore.snapshot,
            now: now
        )
    }

    func displayCalendarName(for event: CalendarEventOccurrence) -> String {
        let snapshot = settingsStore.snapshot
        if let calendar = calendars.first(where: { $0.id == event.calendarID }) {
            return snapshot.displayName(for: calendar)
        }
        if let alias = snapshot.calendarAlias(for: event.calendarID) {
            return alias
        }
        if isLikelyPrimaryCalendarEvent(event),
           let nickname = snapshot.accountNickname(for: event.accountID) {
            return nickname
        }
        return event.calendarDisplayName
    }

    func start() {
        guard !started else { return }
        AppLog.lifecycle.info("controllerStart bundlePathExtension=\(Bundle.main.bundleURL.pathExtension, privacy: .public)")
        started = true
        DiagnosticsRecorder.record("controller_start")
        if Bundle.main.bundleURL.pathExtension == "app" {
            notificationService = NotificationService.shared
            AppLog.lifecycle.info("notificationBackend=system")
        } else {
            AppLog.lifecycle.info("notificationBackend=noop")
        }
        configureProviderFromSettings()
        SystemEventMonitor.shared.onWakeOrUnlock = { [weak self] in
            AppLog.refresh.info("wakeUnlockRefreshTriggered")
            Task { await self?.refresh(reason: "wake") }
        }
        SystemEventMonitor.shared.start()
        AppLog.lifecycle.info("systemEventMonitorStarted")
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            AppLog.refresh.info("refreshTimerFired")
            Task { @MainActor in await self?.refresh(reason: "timer") }
        }
        AppLog.refresh.info("refreshTimerInstalled intervalSeconds=60")
        Task {
            _ = try? await notificationService.requestAuthorization()
        }
        Task {
            await refresh(reason: "launch")
        }
    }

    func stop() {
        guard started else { return }
        AppLog.lifecycle.info("controllerStop")
        started = false
        nextActionTimer?.invalidate()
        nextActionTimer = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        SystemEventMonitor.shared.onWakeOrUnlock = nil
        SystemEventMonitor.shared.stop()
        FullScreenAlertWindowController.shared.hide()
        JoinFallbackWindowController.shared.hide()
        DiagnosticsRecorder.record("controller_stop")
    }

    func refresh(reason: String) async {
        DiagnosticsRecorder.record("refresh_started", metadata: ["reason": reason])
        authState = await provider.authState
        accounts = await provider.accounts()
        let now = Date()
        AppLog.refresh.info("refreshStart reason=\(reason, privacy: .public) authState=\(LogPrivacy.authState(self.authState), privacy: .public) visibleWindowDays=\(self.settingsStore.snapshot.visibleWindowDays, privacy: .public)")
        if authState.blocksCalendarRefresh {
            failedRefreshCount = 0
            statusMessage = connectionFailureMessage ?? statusMessageForCurrentAuthState()
            loadCachedEventsIfAvailable(now: now)
            recomputeReminders(now: now)
            MenuBarController.shared.refresh()
            AppLog.refresh.info("refreshSkipped reason=\(reason, privacy: .public) authState=\(LogPrivacy.authState(self.authState), privacy: .public) cacheEvents=\(self.events.count, privacy: .public)")
            return
        }
        let window = CalendarFetchWindow(
            start: now.addingTimeInterval(-2 * 60 * 60),
            end: settingsStore.snapshot.visibilityWindow.endDate(from: now)
        )

        do {
            AppLog.refresh.debug("providerCalendarsStart reason=\(reason, privacy: .public)")
            calendars = try await provider.calendars()
            mergeAccountsFromCalendars()
            AppLog.refresh.debug("providerCalendarsEnd count=\(self.calendars.count, privacy: .public)")
            let protectedCalendars = settingsStore.snapshot.protectedCalendars(from: calendars)
            AppLog.refresh.debug("providerEventsStart reason=\(reason, privacy: .public)")
            events = try await provider.refresh(in: window, calendars: protectedCalendars)
            AppLog.refresh.debug("providerEventsEnd count=\(self.events.count, privacy: .public) protectedCalendars=\(protectedCalendars.count, privacy: .public)")
            failedRefreshCount = 0
            connectionFailureMessage = nil
            lastSuccessfulRefresh = now
            authState = await provider.authState
            accounts = await provider.accounts()
            statusMessage = statusMessageForCurrentAuthState()
            saveCache(now: now)
            AppLog.refresh.info("refreshSuccess reason=\(reason, privacy: .public) calendars=\(self.calendars.count, privacy: .public) events=\(self.events.count, privacy: .public)")
            DiagnosticsRecorder.record("refresh_succeeded", metadata: [
                "reason": reason,
                "calendars": "\(calendars.count)",
                "events": "\(events.count)"
            ])
        } catch {
            let authFailureMessage = authFailureStatusMessage(for: error)
            if let authFailureMessage {
                if case let CalendarProviderError.authExpired(reason) = error {
                    authState = .expired(reason: reason)
                }
                failedRefreshCount = 0
                statusMessage = authFailureMessage
            } else {
                failedRefreshCount += 1
                statusMessage = refreshStatusMessage(for: error, now: now)
            }
            var cacheLoaded = false
            if let cached = try? cacheStore.load(
                now: now,
                visibleWindowDays: settingsStore.snapshot.visibleWindowDays,
                settings: settingsStore.snapshot
            ) {
                cacheLoaded = true
                events = cached.events
                if authFailureMessage == nil && cacheStore.isStale(cached, now: now) {
                    statusMessage = "Calendar cache is older than 24 hours."
                }
            }
            AppLog.refresh.error("refreshFailure reason=\(reason, privacy: .public) error=\(LogPrivacy.errorClass(error), privacy: .public) failedCount=\(self.failedRefreshCount, privacy: .public) cacheLoaded=\(LogPrivacy.bool(cacheLoaded), privacy: .public) events=\(self.events.count, privacy: .public)")
            DiagnosticsRecorder.record("refresh_failed", metadata: [
                "reason": reason,
                "failedCount": "\(failedRefreshCount)",
                "error": error.localizedDescription
            ])
        }

        recomputeReminders(now: now)
        MenuBarController.shared.refresh()
    }

    func reconnectGoogle() {
        guard hasGoogleOAuthClientConfiguration else {
            AppLog.oauth.error("reconnectRequested configuration=missing")
            statusMessage = "Google Calendar connection is not configured for this build."
            openSettings()
            MenuBarController.shared.refresh()
            return
        }
        AppLog.oauth.info("reconnectRequested source=\(LogPrivacy.oauthClientSource(self.googleOAuthConfigurationSource), privacy: .public)")
        connectionFailureMessage = nil
        statusMessage = nil
        authState = .authenticating
        MenuBarController.shared.refresh()
        configureGoogleProvider()
        Task {
            do {
                try await provider.reconnect()
                AppLog.oauth.info("reconnectSucceeded")
                await refresh(reason: "reconnect")
            } catch {
                AppLog.oauth.error("reconnectFailed error=\(LogPrivacy.errorClass(error), privacy: .public)")
                authState = await provider.authState
                connectionFailureMessage = "Google Calendar connection failed: \(error.localizedDescription)"
                statusMessage = connectionFailureMessage
                MenuBarController.shared.refresh()
            }
        }
    }

    func openSettings() {
        AppLog.lifecycle.info("openSettings")
        MenuBarController.shared.closePopover()
        SettingsWindowController.shared.show()
    }

    func openNewGoogleEvent() {
        guard let url = URL(string: "https://calendar.google.com/calendar/u/0/r/eventedit") else { return }
        NSWorkspace.shared.open(url)
    }

    func join(_ reminder: ScheduledReminder) {
        DiagnosticsRecorder.record("join_requested", metadata: [
            "hasLinks": "\(!reminder.detectedLinks.isEmpty)"
        ])
        do {
            AppLog.alert.info("joinRequested reminder=\(LogPrivacy.redactedID(reminder.id), privacy: .public) linkCount=\(reminder.detectedLinks.count, privacy: .public)")
            let result = try launcher.launch(
                event: reminder.event,
                detectedLinks: reminder.detectedLinks,
                browserSelection: reminder.browserSelection,
                urgent: true
            )
            AppLog.alert.info("joinLaunchSucceeded reminder=\(LogPrivacy.redactedID(reminder.id), privacy: .public) fallbackProfile=\(LogPrivacy.bool(result.usedFallbackProfile), privacy: .public)")
            FullScreenAlertWindowController.shared.hide()
            activeReminders = []
            MenuBarController.shared.refresh()
            showFallback(for: reminder, result: result)
        } catch {
            AppLog.alert.error("joinLaunchFailed reminder=\(LogPrivacy.redactedID(reminder.id), privacy: .public) error=\(LogPrivacy.errorClass(error), privacy: .public)")
            DiagnosticsRecorder.record("join_failed", metadata: ["error": error.localizedDescription])
            statusMessage = error.localizedDescription
            MenuBarController.shared.refresh()
        }
    }

    func snooze(_ reminder: ScheduledReminder, choice: SnoozeChoice? = nil) {
        let now = Date()
        let selected = choice ?? .seconds(settingsStore.snapshot.globalSnoozeDuration)
        guard let returnDate = scheduler.snoozeReturnDate(for: reminder.event, now: now, choice: selected) else { return }
        AppLog.alert.info("snoozeRequested reminder=\(LogPrivacy.redactedID(reminder.id), privacy: .public) returnSeconds=\(Int(returnDate.timeIntervalSince(now)), privacy: .public)")
        DiagnosticsRecorder.record("snooze_requested", metadata: ["choice": selected.label])
        reminderStateStore.snooze(reminder.event.occurrenceKey, until: returnDate, now: now)
        FullScreenAlertWindowController.shared.hide()
        activeReminders.removeAll { $0.id == reminder.id }
        recomputeReminders(now: now)
        MenuBarController.shared.refresh()
    }

    func snoozeAllVisible() {
        AppLog.alert.info("snoozeAllRequested count=\(self.activeReminders.count, privacy: .public)")
        activeReminders.forEach { snooze($0) }
    }

    func dismiss(_ reminder: ScheduledReminder) {
        DiagnosticsRecorder.record("dismiss_requested")
        let fingerprint = reminder.event.materialFingerprint(detectedLinks: reminder.detectedLinks)
        AppLog.alert.info("dismissRequested reminder=\(LogPrivacy.redactedID(reminder.id), privacy: .public) fingerprint=\(LogPrivacy.fingerprintPrefix(fingerprint.value), privacy: .public)")
        reminderStateStore.dismiss(reminder.event.occurrenceKey, fingerprint: fingerprint)
        activeReminders.removeAll { $0.id == reminder.id }
        if activeReminders.isEmpty {
            FullScreenAlertWindowController.shared.hide()
        } else {
            presentActiveReminders()
        }
        recomputeReminders(now: Date())
        MenuBarController.shared.refresh()
    }

    func muteCurrentOccurrence(_ reminder: ScheduledReminder) {
        AppLog.alert.info("muteCurrentOccurrence reminder=\(LogPrivacy.redactedID(reminder.id), privacy: .public)")
        DiagnosticsRecorder.record("mute_requested")
        reminderStateStore.muteUntilEventEnd(reminder.event.occurrenceKey)
        activeReminders.removeAll { $0.id == reminder.id }
        if activeReminders.isEmpty {
            FullScreenAlertWindowController.shared.hide()
        } else {
            presentActiveReminders()
        }
        recomputeReminders(now: Date())
        MenuBarController.shared.refresh()
    }

    func openAgainFromFallback() {
        guard let fallback else { return }
        AppLog.fallback.info("openAgainRequested reminder=\(LogPrivacy.redactedID(fallback.reminder.id), privacy: .public)")
        join(fallback.reminder)
    }

    func clearFallback() {
        AppLog.fallback.info("clearFallback hadFallback=\(LogPrivacy.bool(self.fallback != nil), privacy: .public)")
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        fallback = nil
        JoinFallbackWindowController.shared.hide()
    }

    func handleSettingsChanged() {
        recomputeReminders(now: Date())
        MenuBarController.shared.refresh()
    }

    func removeConnectedAccount(_ accountID: String) {
        Task {
            do {
                try await provider.removeAccount(id: accountID)
                let removedCalendarIDs = calendars
                    .filter { $0.accountID == accountID }
                    .map(\.id)
                calendars.removeAll { $0.accountID == accountID }
                accounts.removeAll { $0.id == accountID }
                settingsStore.update { settings in
                    settings.disabledGoogleAccountIDs.remove(accountID)
                    settings.accountNicknames.removeValue(forKey: accountID)
                    removedCalendarIDs.forEach { calendarID in
                        settings.selectedCalendarIDs.remove(calendarID)
                        settings.calendarAliases.removeValue(forKey: calendarID)
                        settings.calendarSettings.removeValue(forKey: calendarID)
                    }
                }
                events.removeAll { $0.accountID == accountID }
                recomputeReminders(now: Date())
                MenuBarController.shared.refresh()
                AppLog.oauth.info("accountRemovedFromSettings account=\(LogPrivacy.redactedID(accountID), privacy: .public)")
            } catch {
                statusMessage = "Could not remove Google account: \(error.localizedDescription)"
                MenuBarController.shared.refresh()
                AppLog.oauth.error("accountRemoveFailed account=\(LogPrivacy.redactedID(accountID), privacy: .public) error=\(LogPrivacy.errorClass(error), privacy: .public)")
            }
        }
    }

    private func configureProviderFromSettings() {
        if let fixtureMode = MockCalendarFixtureMode.selected() {
            AppLog.lifecycle.info("providerConfigured mode=mock fixture=\(fixtureMode.rawValue, privacy: .public)")
            provider = MockCalendarProvider(fixtureMode: fixtureMode)
        } else if !hasGoogleOAuthClientConfiguration {
            AppLog.lifecycle.info("providerConfigured mode=disconnected oauthSource=missing")
            provider = DisconnectedCalendarProvider()
        } else {
            configureGoogleProvider()
        }
    }

    private func mergeAccountsFromCalendars() {
        var byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        for calendar in calendars {
            byID[calendar.accountID] = ConnectedCalendarAccount(
                id: calendar.accountID,
                displayName: calendar.accountDisplayName ?? calendar.accountID
            )
        }
        accounts = byID.values.sorted { first, second in
            first.displayName.localizedCaseInsensitiveCompare(second.displayName) == .orderedAscending
        }
    }

    private func configureGoogleProvider() {
        let snapshot = settingsStore.snapshot
        AppLog.oauth.info("providerConfigured mode=google source=\(LogPrivacy.oauthClientSource(self.googleOAuthConfigurationSource), privacy: .public) expectedClientType=desktop scopeCount=\(AppIdentity.googleScopes.count, privacy: .public)")
        let configuration = GoogleOAuthConfiguration(
            clientID: resolvedGoogleOAuthClientID(snapshot: snapshot),
            clientSecret: resolvedGoogleOAuthClientSecret(),
            redirectURI: snapshot.googleOAuthRedirectURI
        )
        provider = GoogleCalendarProvider(oauthClient: GoogleOAuthClient(configuration: configuration))
    }

    private func resolvedGoogleOAuthClientID(snapshot: AppSettingsSnapshot? = nil) -> String {
        let configured = (snapshot ?? settingsStore.snapshot).googleOAuthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return configured }
        let bundled = Self.bundledGoogleOAuthClientID()
        if !bundled.isEmpty { return bundled }
        return Self.environmentGoogleOAuthClientID()
    }

    private static func bundledGoogleOAuthClientID() -> String {
        (Bundle.main.object(forInfoDictionaryKey: AppIdentity.googleOAuthClientIDInfoKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func environmentGoogleOAuthClientID() -> String {
        ProcessInfo.processInfo.environment["MEETING_SHIELD_GOOGLE_CLIENT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func resolvedGoogleOAuthClientSecret() -> String {
        let bundled = Self.bundledGoogleOAuthClientSecret()
        if !bundled.isEmpty { return bundled }
        return Self.environmentGoogleOAuthClientSecret()
    }

    private static func bundledGoogleOAuthClientSecret() -> String {
        (Bundle.main.object(forInfoDictionaryKey: AppIdentity.googleOAuthClientSecretInfoKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func environmentGoogleOAuthClientSecret() -> String {
        ProcessInfo.processInfo.environment["MEETING_SHIELD_GOOGLE_CLIENT_SECRET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func recomputeReminders(now: Date) {
        AppLog.refresh.debug("recomputeRemindersStart events=\(self.events.count, privacy: .public) active=\(self.activeReminders.count, privacy: .public)")
        DiagnosticsRecorder.record("recompute_started", metadata: ["events": "\(events.count)"])
        let snapshot = settingsStore.snapshot
        let candidates = events.compactMap { event -> ReminderCandidate? in
            let links = linkExtractor.extractLinks(from: event)
            let result = eligibilityEngine.evaluate(
                event: event,
                detectedLinks: links,
                settings: snapshot,
                reminderState: reminderStateStore
            )
            guard result.isEligible else { return nil }
            return ReminderCandidate(
                event: event,
                detectedLinks: links,
                leadTime: result.leadTime,
                browserSelection: result.browserSelection
            )
        }

        scheduledReminders = scheduler.schedule(candidates: candidates, stateStore: reminderStateStore, now: now)
        let due = scheduler.dueReminders(from: scheduledReminders, now: now)
        AppLog.refresh.info("recomputeRemindersEnd candidates=\(candidates.count, privacy: .public) scheduled=\(self.scheduledReminders.count, privacy: .public) due=\(due.count, privacy: .public) dueSet=\(LogPrivacy.redactedIDSet(due.map(\.id)), privacy: .public)")
        DiagnosticsRecorder.record("recompute_finished", metadata: [
            "candidates": "\(candidates.count)",
            "scheduled": "\(scheduledReminders.count)",
            "due": "\(due.count)"
        ])
        if due.isEmpty {
            if !activeReminders.isEmpty {
                AppLog.alert.info("activeRemindersCleared previous=\(self.activeReminders.count, privacy: .public)")
                FullScreenAlertWindowController.shared.hide()
            }
            activeReminders = []
        } else {
            let previousReminderIDs = activeReminders.map(\.id)
            let dueReminderIDs = due.map(\.id)
            activeReminders = due
            let shouldShowFullScreen = !isPresentationMode && !SystemEventMonitor.shared.isInWakeGrace()
            if previousReminderIDs != dueReminderIDs || (shouldShowFullScreen && !FullScreenAlertWindowController.shared.isShowing) {
                AppLog.alert.info("presentActiveRemindersRequired previousSet=\(LogPrivacy.redactedIDSet(previousReminderIDs), privacy: .public) dueSet=\(LogPrivacy.redactedIDSet(dueReminderIDs), privacy: .public) fullScreen=\(LogPrivacy.bool(shouldShowFullScreen), privacy: .public) alertShowing=\(LogPrivacy.bool(FullScreenAlertWindowController.shared.isShowing), privacy: .public)")
                presentActiveReminders()
            } else {
                AppLog.alert.debug("presentActiveRemindersSkipped unchangedDueSet=\(LogPrivacy.redactedIDSet(dueReminderIDs), privacy: .public)")
            }
        }
        scheduleNextAction(now: now)
    }

    private func handlePresentationModeChange() {
        guard !activeReminders.isEmpty else { return }
        AppLog.alert.info("presentationModeChangedWithActiveReminders enabled=\(LogPrivacy.bool(self.isPresentationMode), privacy: .public) active=\(self.activeReminders.count, privacy: .public)")
        FullScreenAlertWindowController.shared.hide()
        presentActiveReminders()
    }

    private func presentActiveReminders() {
        DiagnosticsRecorder.record("present_active_reminders", metadata: [
            "count": "\(activeReminders.count)",
            "presentationMode": "\(isPresentationMode)",
            "wakeGrace": "\(SystemEventMonitor.shared.isInWakeGrace())"
        ])
        if isPresentationMode || SystemEventMonitor.shared.isInWakeGrace() {
            AppLog.alert.info("presentActiveRemindersViaNotifications count=\(self.activeReminders.count, privacy: .public) presentation=\(LogPrivacy.bool(self.isPresentationMode), privacy: .public) wakeGrace=\(LogPrivacy.bool(SystemEventMonitor.shared.isInWakeGrace()), privacy: .public)")
            Task {
                for reminder in activeReminders {
                    try? await notificationService.deliver(MeetingNotification(
                        id: reminder.id,
                        title: reminder.event.title,
                        body: notificationBody(for: reminder),
                        date: nil
                    ))
                }
            }
        } else {
            AppLog.alert.info("presentActiveRemindersViaFullScreen count=\(self.activeReminders.count, privacy: .public)")
            FullScreenAlertWindowController.shared.show(
                reminders: activeReminders,
                availableSnoozeChoices: { [weak self] reminder in
                    guard let self else { return [] }
                    return self.scheduler.availableSnoozeChoices(
                        event: reminder.event,
                        now: Date(),
                        globalDuration: self.settingsStore.snapshot.globalSnoozeDuration
                    )
                },
                onJoin: { [weak self] reminder in self?.join(reminder) },
                onSnooze: { [weak self] reminder, choice in self?.snooze(reminder, choice: choice) },
                onDismiss: { [weak self] reminder in self?.dismiss(reminder) },
                onMute: { [weak self] reminder in self?.muteCurrentOccurrence(reminder) },
                onSnoozeAll: { [weak self] in self?.snoozeAllVisible() }
            )
        }
    }

    private func scheduleNextAction(now: Date) {
        nextActionTimer?.invalidate()
        guard let date = scheduler.nextActionDate(from: scheduledReminders, now: now) else {
            AppLog.refresh.debug("nextActionTimerSkipped scheduled=0")
            return
        }
        let interval = max(1, date.timeIntervalSince(now))
        AppLog.refresh.debug("nextActionTimerScheduled delaySeconds=\(Int(interval), privacy: .public)")
        DiagnosticsRecorder.record("scheduled_next_action", metadata: ["interval": "\(Int(interval))"])
        nextActionTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            AppLog.refresh.info("nextActionTimerFired")
            Task { @MainActor in self?.recomputeReminders(now: Date()) }
        }
    }

    private func saveCache(now: Date) {
        let detected = Dictionary(uniqueKeysWithValues: events.map { event in
            (event.id, linkExtractor.extractLinks(from: event))
        })
        try? cacheStore.save(
            events: events,
            detectedLinks: detected,
            settings: settingsStore.snapshot,
            now: now
        )
    }

    private func loadCachedEventsIfAvailable(now: Date) {
        if let cached = try? cacheStore.load(
            now: now,
            visibleWindowDays: settingsStore.snapshot.visibleWindowDays,
            settings: settingsStore.snapshot
        ) {
            events = cached.events
        }
    }

    private func refreshStatusMessage(for error: Error, now: Date) -> String {
        if failedRefreshCount >= 2 {
            return "Calendar refresh is failing; using local cache."
        }
        if let lastSuccessfulRefresh, now.timeIntervalSince(lastSuccessfulRefresh) > 5 * 60 {
            return "Calendar data may be stale."
        }
        return error.localizedDescription
    }

    private func authFailureStatusMessage(for error: Error) -> String? {
        guard let calendarError = error as? CalendarProviderError else { return nil }
        switch calendarError {
        case .notConfigured:
            return "Google Calendar is not configured."
        case .disconnected:
            return connectionFailureMessage ?? "Connect Google Calendar to start protecting meetings."
        case .authExpired(let reason):
            return "Calendar authorization expired: \(reason)"
        case .invalidResponse, .requestFailed:
            return nil
        }
    }

    private func statusMessageForCurrentAuthState() -> String? {
        switch authState {
        case .disconnected, .needsConfiguration:
            "Connect Google Calendar to start protecting meetings."
        case .authenticating, .connected:
            nil
        case .expired(let reason):
            "Calendar authorization expired: \(reason)"
        }
    }

    private func notificationBody(for reminder: ScheduledReminder) -> String {
        let time = DateFormatter.shortTimeString(from: reminder.event.startDate)
        if reminder.detectedLinks.isEmpty {
            return "Starts at \(time). Open the calendar event."
        }
        return "Starts at \(time). Join is ready."
    }

    private func isLikelyPrimaryCalendarEvent(_ event: CalendarEventOccurrence) -> Bool {
        event.calendarID == event.accountID || event.calendarID == "\(event.accountID)::\(event.accountID)"
    }

    private func showFallback(for reminder: ScheduledReminder, result: MeetingLaunchResult) {
        AppLog.fallback.info("showFallback reminder=\(LogPrivacy.redactedID(reminder.id), privacy: .public) openedIn=\(result.target.browser.rawValue, privacy: .public) warning=\(LogPrivacy.bool(result.warning != nil), privacy: .public)")
        DiagnosticsRecorder.record("fallback_show", metadata: ["hasWarning": "\(result.warning != nil)"])
        fallback = JoinFallbackState(
            reminder: reminder,
            openedIn: result.target.displayName,
            warning: result.warning
        )
        if let fallback {
            JoinFallbackWindowController.shared.show(
                fallback: fallback,
                onOpenAgain: { [weak self] in self?.openAgainFromFallback() },
                onDismiss: { [weak self] in
                    self?.dismiss(reminder)
                    self?.clearFallback()
                },
                onClose: { [weak self] in self?.clearFallback() }
            )
        }
        fallbackTimer?.invalidate()
        AppLog.fallback.debug("fallbackTimerScheduled seconds=10")
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            AppLog.fallback.info("fallbackTimerFired")
            Task { @MainActor in self?.clearFallback() }
        }
    }
}

private extension CalendarProviderAuthState {
    var blocksCalendarRefresh: Bool {
        switch self {
        case .disconnected, .needsConfiguration:
            true
        case .authenticating, .connected, .expired:
            false
        }
    }
}

struct JoinFallbackState: Identifiable {
    var id: String { reminder.id }
    var reminder: ScheduledReminder
    var openedIn: String
    var warning: String?
}

extension RelativeDateTimeFormatter {
    static func shortString(for date: Date, relativeTo referenceDate: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: referenceDate)
    }
}

extension DateFormatter {
    static func shortTimeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
