import AppKit
import SwiftUI

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
    @Published private(set) var notificationWarning: String?
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
    let notificationHealth = NotificationHealth()

    private let refreshCoordinator: RefreshCoordinator
    private let credentialsResolver = GoogleOAuthCredentialsResolver()
    private let reminderPipeline = ReminderPipeline()
    private let scheduler = ReminderScheduler()
    private let reminderStateStore: ReminderStateStore
    private var notificationService: any MeetingNotifying
    private let launcher: MeetingLauncher
    private let soundPlayer: any AlertSoundPlaying = SystemAlertSoundPlayer()
    private var nextActionTimer: Timer?
    private var refreshTimer: Timer?
    private var fallbackTimer: Timer?
    private var urgentSoundTimer: Timer?
    private var started = false

    private var provider: any CalendarProvider {
        get { refreshCoordinator.provider }
        set { refreshCoordinator.provider = newValue }
    }

    private var notificationDispatcher: NotificationDispatcher {
        NotificationDispatcher(notifier: notificationService, health: notificationHealth)
    }

    /// Wake grace only applies while the user has it enabled (the toggle was
    /// previously dead — grace was unconditional).
    private var wakeGraceActive: Bool {
        settingsStore.snapshot.wakeGraceEnabled && SystemEventMonitor.shared.isInWakeGrace()
    }

    /// True when macOS notifications are the active alert channel.
    private var notificationsCarryAlerts: Bool {
        isPresentationMode || wakeGraceActive
    }

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
        self.refreshCoordinator = RefreshCoordinator(
            provider: provider,
            cacheStore: cacheStore,
            settings: { settingsStore.snapshot }
        )
        self.reminderStateStore = reminderStateStore
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
        if notificationWarning != nil { return "bell.slash.circle.fill" }
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
        credentialsResolver.hasConfiguration(settingsValue: settingsStore.snapshot.googleOAuthClientID)
    }

    var googleOAuthConfigurationSource: String {
        credentialsResolver.clientIDSource(settingsValue: settingsStore.snapshot.googleOAuthClientID).displayName
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
        SystemEventMonitor.shared.onNetworkReturn = { [weak self] in
            Task { await self?.refresh(reason: "network-return") }
        }
        SystemEventMonitor.shared.start()
        AppLog.lifecycle.info("systemEventMonitorStarted")
        refreshTimer = WallClockTimer.scheduled(withTimeInterval: 60, repeats: true) { [weak self] _ in
            AppLog.refresh.info("refreshTimerFired")
            Task { @MainActor in await self?.refresh(reason: "timer") }
        }
        AppLog.refresh.info("refreshTimerInstalled intervalSeconds=60")
        Task {
            do {
                let granted = try await notificationService.requestAuthorization()
                AppLog.lifecycle.info("notificationAuthorizationRequested granted=\(LogPrivacy.bool(granted), privacy: .public)")
            } catch {
                AppLog.lifecycle.error("notificationAuthorizationRequestFailed error=\(LogPrivacy.errorClass(error), privacy: .public)")
            }
            await notificationDispatcher.refreshAuthorizationStatus()
            refreshNotificationWarning()
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
        urgentSoundTimer?.invalidate()
        urgentSoundTimer = nil
        SystemEventMonitor.shared.onWakeOrUnlock = nil
        SystemEventMonitor.shared.onNetworkReturn = nil
        SystemEventMonitor.shared.stop()
        FullScreenAlertWindowController.shared.hide()
        JoinFallbackWindowController.shared.hide()
        DiagnosticsRecorder.record("controller_stop")
    }

    func refresh(reason: String) async {
        guard let outcome = await refreshCoordinator.refresh(reason: reason) else {
            // Coalesced into an in-flight refresh; that refresh applies the outcome.
            return
        }
        apply(outcome)
    }

    private func apply(_ outcome: RefreshCoordinator.Outcome) {
        let now = Date()
        authState = outcome.authState
        accounts = outcome.accounts
        if let newCalendars = outcome.calendars {
            calendars = newCalendars
        }
        mergeAccountsFromCalendars()
        if let newEvents = outcome.events {
            events = newEvents
        }
        statusMessage = outcome.statusMessage
        if outcome.didSucceed {
            // Reminder state would otherwise grow forever (one entry per
            // snoozed/dismissed occurrence). Keep active occurrences plus a
            // retention buffer beyond the maximum visible window.
            reminderStateStore.prune(
                endedBefore: now.addingTimeInterval(-8 * 24 * 60 * 60),
                activeKeys: Set(events.map(\.occurrenceKey))
            )
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
        refreshCoordinator.recordConnectionFailure(nil)
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
                let failureMessage = "Google Calendar connection failed: \(error.localizedDescription)"
                refreshCoordinator.recordConnectionFailure(failureMessage)
                statusMessage = failureMessage
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
            DiagnosticsRecorder.record("join_failed", metadata: ["error": LogPrivacy.errorClass(error)])
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
        var byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
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
            clientID: credentialsResolver.clientID(settingsValue: snapshot.googleOAuthClientID),
            clientSecret: credentialsResolver.clientSecret()
        )
        provider = GoogleCalendarProvider(oauthClient: GoogleOAuthClient(configuration: configuration))
    }

    private func recomputeReminders(now: Date) {
        AppLog.refresh.debug("recomputeRemindersStart events=\(self.events.count, privacy: .public) active=\(self.activeReminders.count, privacy: .public)")
        DiagnosticsRecorder.record("recompute_started", metadata: ["events": "\(events.count)"])
        let result = reminderPipeline.compute(
            events: events,
            settings: settingsStore.snapshot,
            stateStore: reminderStateStore,
            now: now
        )
        scheduledReminders = result.scheduled
        let due = result.due
        AppLog.refresh.info("recomputeRemindersEnd candidates=\(result.candidateCount, privacy: .public) scheduled=\(self.scheduledReminders.count, privacy: .public) due=\(due.count, privacy: .public) dueSet=\(LogPrivacy.redactedIDSet(due.map(\.id)), privacy: .public)")
        DiagnosticsRecorder.record("recompute_finished", metadata: [
            "candidates": "\(result.candidateCount)",
            "scheduled": "\(scheduledReminders.count)",
            "due": "\(due.count)"
        ])

        let decision = ReminderPresentationDecision.decide(
            due: due,
            previousIDs: activeReminders.map(\.id),
            isPresentationMode: isPresentationMode,
            inWakeGrace: wakeGraceActive,
            alertAlreadyShowing: FullScreenAlertWindowController.shared.isShowing
        )
        activeReminders = due
        switch decision {
        case .keepCurrent:
            AppLog.alert.debug("presentActiveRemindersSkipped unchangedDueSet=\(LogPrivacy.redactedIDSet(due.map(\.id)), privacy: .public)")
        case .clear:
            AppLog.alert.info("activeRemindersCleared")
            FullScreenAlertWindowController.shared.hide()
        case .presentFullScreen, .deliverNotifications:
            AppLog.alert.info("presentActiveRemindersRequired decision=\(String(describing: decision), privacy: .public) dueSet=\(LogPrivacy.redactedIDSet(due.map(\.id)), privacy: .public)")
            presentActiveReminders()
        }
        scheduleNextAction(now: now)
    }

    private func handlePresentationModeChange() {
        refreshNotificationWarning()
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
        if isPresentationMode || wakeGraceActive {
            AppLog.alert.info("presentActiveRemindersViaNotifications count=\(self.activeReminders.count, privacy: .public) presentation=\(LogPrivacy.bool(self.isPresentationMode), privacy: .public) wakeGrace=\(LogPrivacy.bool(SystemEventMonitor.shared.isInWakeGrace()), privacy: .public)")
            let withSound = AlertSoundPolicy.shouldPlayOnPresent(settings: settingsStore.snapshot)
            let notifications = activeReminders.map { reminder in
                MeetingNotification(
                    id: reminder.id,
                    title: reminder.event.title,
                    body: notificationBody(for: reminder),
                    date: nil,
                    withSound: withSound
                )
            }
            Task {
                await notificationDispatcher.refreshAuthorizationStatus()
                await notificationDispatcher.deliver(notifications)
                refreshNotificationWarning()
            }
        } else {
            AppLog.alert.info("presentActiveRemindersViaFullScreen count=\(self.activeReminders.count, privacy: .public)")
            playPresentationSounds()
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
        nextActionTimer = WallClockTimer.scheduled(withTimeInterval: interval, repeats: false) { [weak self] _ in
            AppLog.refresh.info("nextActionTimerFired")
            Task { @MainActor in self?.recomputeReminders(now: Date()) }
        }
    }

    private func refreshNotificationWarning() {
        let warning = notificationHealth.warningMessage(notificationsCarryAlerts: notificationsCarryAlerts)
        guard warning != notificationWarning else { return }
        notificationWarning = warning
        if let warning {
            AppLog.alert.error("notificationChannelUnhealthy warning=\(warning, privacy: .public)")
        }
        MenuBarController.shared.refresh()
    }

    private func playPresentationSounds() {
        let snapshot = settingsStore.snapshot
        if AlertSoundPolicy.shouldPlayOnPresent(settings: snapshot) {
            soundPlayer.playAlertSound()
        }
        urgentSoundTimer?.invalidate()
        urgentSoundTimer = nil
        guard let repeatDate = AlertSoundPolicy.urgentRepeatDate(
            reminders: activeReminders,
            settings: snapshot,
            now: Date()
        ) else { return }
        let interval = max(1, repeatDate.timeIntervalSinceNow)
        urgentSoundTimer = WallClockTimer.scheduled(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.activeReminders.isEmpty else { return }
                AppLog.alert.info("urgentRepeatSound")
                self.soundPlayer.playAlertSound()
            }
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
        fallbackTimer = WallClockTimer.scheduled(withTimeInterval: 10, repeats: false) { [weak self] _ in
            AppLog.fallback.info("fallbackTimerFired")
            Task { @MainActor in self?.clearFallback() }
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
