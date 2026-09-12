import AppKit
import Combine
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
    @Published private(set) var settingsPersistenceFailure: PersistenceFailure?
    @Published private(set) var reminderPersistenceFailure: PersistenceFailure?
    @Published private(set) var credentialPersistenceFailures: Set<GoogleOAuthPersistenceFailure> = []
    @Published private(set) var isRetryingPersistence = false
    @Published private(set) var notificationWarning: String?
    @Published private(set) var authState: CalendarProviderAuthState = .disconnected
    @Published var isPresentationMode: Bool {
        didSet {
            if isPresentationMode != oldValue {
                handlePresentationModeChange()
            }
            refreshMenuBar()
        }
    }

    let settingsStore: AppSettingsStore
    let notificationHealth = NotificationHealth()

    private let refreshCoordinator: RefreshCoordinator
    private let credentialsResolver: GoogleOAuthCredentialsResolver
    private let makeGoogleProvider: @MainActor (GoogleOAuthConfiguration) -> any CalendarProvider
    private var configuredGoogleClientID: String
    private let reminderPipeline = ReminderPipeline()
    private let scheduler = ReminderScheduler()
    private let reminderStateStore: ReminderStateStore
    private let refreshMenuBar: @MainActor () -> Void
    private let now: @MainActor () -> Date
    private let systemEventMonitor: SystemEventMonitor
    private var notificationService: any MeetingNotifying
    private var notificationResponseGeneration: UInt64 = 0
    private var notificationDeliveryGeneration: UInt64 = 0
    private let alertPresenter: any FullScreenAlertPresenting
    private let fallbackPresenter: any JoinFallbackPresenting
    private let openAgenda: @MainActor () -> Void
    private let presentSettings: @MainActor () -> Void
    private let copyDiagnosticSummary: @MainActor (String) -> Void
    private let diagnostics: DiagnosticsRecorder
    private var lastReminderDecisions: [String: ReminderPipeline.Decision] = [:]
    private var notifiedReconnectAccountIDs: Set<String> = []
    private var notifiedGenericReconnect = false
    private var reconnectNotificationAccounts: Set<String> = []
    private var reconnectNotificationRequiresGeneric = false
    private var reconnectNotificationGeneration: UInt64 = 0
    private var staleNotificationActive = false
    private var staleNotificationPending = false
    private var notifiedStaleProtection = false
    private var staleNotificationGeneration: UInt64 = 0
    private var staleNotificationOwnerGeneration: UInt64 = 0
    private let launcher: MeetingLauncher
    private let soundPlayer: any AlertSoundPlaying
    private let dismissalPresenter: any DismissalConfirming
    private var nextActionTimer: Timer?
    private(set) var nextActionTargetDate: Date?
    private(set) var pendingNextActionTask: Task<Void, Never>?
    private var refreshTimer: Timer?
    private(set) var pendingNotificationTask: Task<Void, Never>?
    private(set) var pendingNotificationAuthorizationTask: Task<Void, Never>?
    private var pendingReconnectTask: Task<Void, Never>?
    private var pendingRefreshTask: Task<Void, Never>?
    private var pendingRefreshGeneration: UInt64 = 0
    private var persistenceRetryGeneration: UInt64 = 0
    private var fallbackTimer: Timer?
    private var fallbackGeneration = 0
    private var fallbackDeadline: Date?
    private var pendingDismissal: PendingDismissal?
    private var urgentSoundTimer: Timer?
    private var urgentSoundTargetDate: Date?
    private var started = false
    private(set) var lastReminderEvaluationDate: Date?
    private var settingsFailureObservation: AnyCancellable?
    private var statusSource: StatusSource = .refresh

    private enum StatusSource {
        case refresh
        case action
    }

    private struct PendingDismissal {
        let id: UUID
        let reminder: ScheduledReminder
        let source: DismissalRequestSource
        let fingerprints: [String: MaterialChangeFingerprint]
        let pausedFallbackGeneration: Int?
        let fallbackTimeRemaining: TimeInterval?
    }

    var provider: any CalendarProvider {
        get { refreshCoordinator.provider }
        set {
            invalidateNotificationDelivery()
            pendingReconnectTask?.cancel()
            pendingReconnectTask = nil
            refreshCoordinator.provider = newValue
            notifiedReconnectAccountIDs.removeAll()
            notifiedGenericReconnect = false
            reconnectNotificationRequiresGeneric = false
            invalidateStaleNotification()
        }
    }

    private var notificationDispatcher: NotificationDispatcher {
        NotificationDispatcher(notifier: notificationService, health: notificationHealth)
    }

    private var wakeGraceActive: Bool {
        settingsStore.snapshot.wakeGraceEnabled && systemEventMonitor.isInWakeGrace(now: now())
    }

    private var notificationsCarryAlerts: Bool {
        isPresentationMode || wakeGraceActive
    }

    init(
        settingsStore: AppSettingsStore = .shared,
        provider: any CalendarProvider = DisconnectedCalendarProvider(),
        credentialsResolver: GoogleOAuthCredentialsResolver = GoogleOAuthCredentialsResolver(),
        makeGoogleProvider: @escaping @MainActor (GoogleOAuthConfiguration) -> any CalendarProvider = {
            GoogleCalendarProvider(oauthClient: GoogleOAuthClient(configuration: $0))
        },
        reminderStateStore: ReminderStateStore = ReminderStateStore(
            fileURL: FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "MeetingShield/reminder-state.json")
        ),
        cacheStore: EventCacheStore = EventCacheStore(),
        notificationService: any MeetingNotifying = NoopNotificationService(),
        launcher: MeetingLauncher = MeetingLauncher(),
        soundPlayer: any AlertSoundPlaying = SystemAlertSoundPlayer(),
        dismissalPresenter: any DismissalConfirming = DismissConfirmationWindowController.shared,
        now: @escaping @MainActor () -> Date = { Date() },
        refreshMenuBar: @escaping @MainActor () -> Void = { MenuBarController.shared.refresh() },
        systemEventMonitor: SystemEventMonitor = .shared,
        alertPresenter: any FullScreenAlertPresenting = FullScreenAlertWindowController.shared,
        fallbackPresenter: any JoinFallbackPresenting = JoinFallbackWindowController.shared,
        openAgenda: @escaping @MainActor () -> Void = { MenuBarController.shared.showPopover() },
        presentSettings: @escaping @MainActor () -> Void = {
            MenuBarController.shared.closePopover()
            SettingsWindowController.shared.show()
        },
        copyDiagnosticSummary: @escaping @MainActor (String) -> Void = { value in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
        },
        diagnostics: DiagnosticsRecorder = .applicationDefault
    ) {
        self.settingsStore = settingsStore
        self.credentialsResolver = credentialsResolver
        self.makeGoogleProvider = makeGoogleProvider
        self.configuredGoogleClientID = credentialsResolver.clientID(settingsValue: settingsStore.snapshot.googleOAuthClientID)
        self.refreshCoordinator = RefreshCoordinator(
            provider: provider,
            cacheStore: cacheStore,
            settings: { settingsStore.snapshot },
            now: now,
            diagnostics: diagnostics,
            legacyStateStore: reminderStateStore.unresolvedLegacyCount > 0 || reminderStateStore.isPersistencePending
                ? reminderStateStore : nil,
            rememberProviderDefaults: { calendarIDs in
                guard settingsStore.snapshot.providerDefaultCalendarIDs != calendarIDs else { return }
                settingsStore.update { $0.recordProviderDefaultCalendarIDs(calendarIDs) }
            }
        )
        self.reminderStateStore = reminderStateStore
        self.now = now
        self.systemEventMonitor = systemEventMonitor
        self.refreshMenuBar = refreshMenuBar
        self.notificationService = notificationService
        self.alertPresenter = alertPresenter
        self.fallbackPresenter = fallbackPresenter
        self.openAgenda = openAgenda
        self.presentSettings = presentSettings
        self.copyDiagnosticSummary = copyDiagnosticSummary
        self.diagnostics = diagnostics
        self.launcher = launcher
        self.soundPlayer = soundPlayer
        self.dismissalPresenter = dismissalPresenter
        self.isPresentationMode = settingsStore.snapshot.presentationModeDefault
        self.settingsPersistenceFailure = settingsStore.persistenceFailure
        self.reminderPersistenceFailure = reminderStateStore.persistenceFailure
        self.settingsFailureObservation = settingsStore.$persistenceFailure.dropFirst().sink { [weak self] failure in
            guard let self, self.settingsPersistenceFailure != failure else { return }
            self.settingsPersistenceFailure = failure
            self.refreshMenuBar()
        }
        bindNotificationResponses()
    }

    func replaceNotificationService(_ service: any MeetingNotifying) {
        invalidateNotificationDelivery()
        invalidateNotificationResponses()
        invalidateStaleNotification()
        notificationService = service
        bindNotificationResponses()
    }

    private func invalidateNotificationDelivery() {
        notificationDeliveryGeneration &+= 1
        pendingNotificationTask?.cancel()
        pendingNotificationTask = nil
    }

    private func invalidateNotificationResponses() {
        notificationResponseGeneration &+= 1
        pendingNotificationAuthorizationTask?.cancel()
        pendingNotificationAuthorizationTask = nil
        notificationService.setResponseHandler(nil)
    }

    private func invalidateStaleNotification() {
        staleNotificationOwnerGeneration &+= 1
        staleNotificationGeneration &+= 1
        staleNotificationActive = false
        staleNotificationPending = false
        notifiedStaleProtection = false
    }

    private func bindNotificationResponses() {
        let generation = notificationResponseGeneration
        notificationService.setResponseHandler { [weak self] identifier in
            guard let self, generation == notificationResponseGeneration else { return }
            handleNotificationResponse(identifier)
        }
    }

    private func handleNotificationResponse(_ identifier: String) {
        let operationID = UUID().uuidString.lowercased()
        let evaluatedAt = now()
        recordReminderOutcome(
            event: "reminder_action", outcome: "response_received", occurrenceIDs: [identifier],
            operationID: operationID, evaluatedAt: evaluatedAt
        )
        if identifier == "meeting-shield.reconnect" {
            AppLog.alert.info("notificationResponse route=settings")
            openSettings()
            return
        }
        let now = evaluatedAt
        let result = currentReminderEvaluation(ignoringAcknowledgements: false, now: now)
        guard let source = result.scheduled.first(where: { $0.id == identifier }),
              source.fireDate <= now,
              let group = result.due.first(where: { $0.members.contains { $0.id == identifier } }) else {
            AppLog.alert.info("notificationResponse route=agenda id=\(LogPrivacy.redactedID(identifier), privacy: .public)")
            openAgenda()
            return
        }
        scheduledReminders = result.scheduled
        activeReminders = result.due
        AppLog.alert.info("notificationResponse route=reminder id=\(LogPrivacy.redactedID(identifier), privacy: .public)")
        showFullScreenReminders(result.due, selectedID: group.id, operationID: operationID, evaluatedAt: now)
        scheduleNextAction(now: now, operationID: operationID)
        refreshMenuBar()
    }

    var pendingUrgentSoundDate: Date? {
        urgentSoundTimer?.isValid == true ? urgentSoundTimer?.fireDate : nil
    }

    var menuBarText: MenuBarText {
        let currentDate = now()
        return MenuBarText.make(
            event: nextEvent(now: currentDate),
            now: currentDate,
            showEventTitle: settingsStore.snapshot.showEventTitlesInMenuBar
        )
    }

    var menuBarTitle: String {
        menuBarText.preferred
    }

    var persistenceWarnings: [String] {
        var warnings: [String] = []
        if let failure = settingsPersistenceFailure {
            warnings.append(failure == .writeFailed
                ? "Settings changes could not be saved."
                : "Saved settings could not be read. New changes are not saved.")
        }
        if let failure = reminderPersistenceFailure {
            warnings.append(failure == .writeFailed
                ? "Reminder actions could not be saved."
                : "Saved reminder state could not be read. New actions are not saved.")
        }
        warnings += credentialPersistenceFailures.map(credentialRecoveryMessage).sorted()
        return warnings
    }

    var protectionHealthSummary: ProtectionHealthSummary {
        let coverage = refreshCoordinator.protectionSnapshot(knownAccounts: accounts)
        return ProtectionHealthSummary.derive(from: .init(
            connection: protectionConnection,
            accounts: coverage.accounts,
            hasCalendarSelection: coverage.hasCalendarSelection,
            lastSuccessfulRefresh: coverage.lastSuccessfulRefresh,
            oldestCoverage: coverage.oldestCoverage,
            refreshIssue: coverage.refreshIssue,
            schedulerLastEvaluation: lastReminderEvaluationDate,
            nextReminder: scheduledReminders.map(\.fireDate).min(),
            notification: notificationHealth.protectionSummaryStatus(notificationsCarryAlerts: notificationsCarryAlerts),
            storageWarningCount: persistenceWarnings.count + (coverage.cachePersistenceFailed ? 1 : 0),
            reconnectAccountIDs: coverage.reconnectAccountIDs,
            requiresGenericReconnect: coverage.requiresGenericReconnect,
            now: now()
        ))
    }

    func copyProtectionSummary() {
        copyDiagnosticSummary(protectionHealthSummary.copyText)
    }

    func performProtectionHealthAction(_ action: ProtectionHealthSummary.Action) {
        switch action {
        case .retry:
            Task { await refresh(reason: "manual") }
        case .reconnect:
            reconnectGoogle()
        case .settings:
            openSettings()
        }
    }

    private var protectionConnection: ProtectionHealthSummary.Connection {
        switch authState {
        case .connected:
            .connected
        case .authenticating:
            .connecting
        case .disconnected:
            .disconnected
        case .needsConfiguration:
            .needsConfiguration
        case .expired:
            .expired
        }
    }

    private func credentialRecoveryMessage(_ failure: GoogleOAuthPersistenceFailure) -> String {
        switch failure {
        case .read:
            "Saved Google credentials could not be read. Check Keychain access, then retry storage."
        case .save(let accountID):
            "Credentials for \(credentialAccountLabel(accountID)) could not be saved. Reconnect that account."
        case .remove(let accountID):
            "Removal of \(credentialAccountLabel(accountID)) could not be saved. Remove that account again to retry."
        case .clear:
            "Removing all Google credentials could not be saved. Repeat the explicit removal action to retry."
        case .migration:
            "Google credentials could not be migrated. Retry storage."
        case .legacyCleanup:
            "Old Google credential cleanup is pending; retry storage."
        }
    }

    private func credentialAccountLabel(_ accountID: String?) -> String {
        guard let accountID else { return "the legacy Google account" }
        if let nickname = settingsStore.snapshot.accountNickname(for: accountID) { return nickname }
        return accounts.first { $0.id == accountID }?.displayName ?? accountID
    }

    func retryPersistence() async {
        guard !isRetryingPersistence else { return }
        isRetryingPersistence = true
        let retryGeneration = persistenceRetryGeneration
        defer { isRetryingPersistence = false }
        settingsStore.retryPersistence()
        let configurationChanged = configuredGoogleClientID != credentialsResolver.clientID(
            settingsValue: settingsStore.snapshot.googleOAuthClientID
        )
        if configurationChanged { configureProviderFromSettings() }
        await reminderStateStore.retryPersistence()
        guard !Task.isCancelled, persistenceRetryGeneration == retryGeneration else { return }
        refreshReminderPersistenceFailure()
        recomputeReminders(now: now())
        refreshMenuBar()
        let fetchSettingsChanged = refreshCoordinator.settingsDidChange()
        let retryProvider = provider
        let generation = refreshCoordinator.providerGeneration
        let previousFailures = await retryProvider.credentialPersistenceFailures
        guard !Task.isCancelled, persistenceRetryGeneration == retryGeneration,
              generation == refreshCoordinator.providerGeneration else { return }
        await retryProvider.retryCredentialPersistence()
        await refreshCredentialPersistenceFailures(from: retryProvider, generation: generation)
        guard !Task.isCancelled, persistenceRetryGeneration == retryGeneration,
              generation == refreshCoordinator.providerGeneration else { return }
        let recoveredCredentials = previousFailures.contains(.read) || previousFailures.contains(.migration)
        if configurationChanged || fetchSettingsChanged || (recoveredCredentials && !credentialPersistenceFailures.contains(.read) && !credentialPersistenceFailures.contains(.migration)) {
            await refresh(reason: "settings")
        }
    }

    private func refreshCredentialPersistenceFailures(from source: any CalendarProvider, generation: UInt64) async {
        let failures = await source.credentialPersistenceFailures
        guard generation == refreshCoordinator.providerGeneration,
              credentialPersistenceFailures != failures else { return }
        credentialPersistenceFailures = failures
        refreshMenuBar()
    }

    private func refreshReminderPersistenceFailure() {
        let failure = reminderStateStore.persistenceFailure
        guard reminderPersistenceFailure != failure else { return }
        reminderPersistenceFailure = failure
        refreshMenuBar()
    }

    var menuEvents: [CalendarEventOccurrence] {
        menuEvents(now: Date())
    }

    var menuBarSystemImage: String {
        if !persistenceWarnings.isEmpty { return "exclamationmark.shield" }
        if notificationWarning != nil { return "bell.slash.circle.fill" }
        if isPresentationMode { return "bell.slash.fill" }
        if case .disconnected = authState { return "exclamationmark.shield" }
        if case .needsConfiguration = authState { return "exclamationmark.shield" }
        if case .expired = authState { return "exclamationmark.shield" }
        if statusMessage != nil { return "exclamationmark.shield" }
        if !activeReminders.isEmpty { return "shield.fill" }
        if nextEvent?.startDate.timeIntervalSinceNow ?? .greatestFiniteMagnitude < 5 * 60 {
            return "checkmark.shield.fill"
        }
        return "shield"
    }

    var hasGoogleOAuthClientConfiguration: Bool {
        credentialsResolver.hasConfiguration(settingsValue: settingsStore.snapshot.googleOAuthClientID)
    }

    var googleOAuthConfigurationSource: String {
        credentialsResolver.clientIDSource(settingsValue: settingsStore.snapshot.googleOAuthClientID).displayName
    }

    var nextEvent: CalendarEventOccurrence? {
        nextEvent(now: now())
    }

    func nextEvent(now: Date) -> CalendarEventOccurrence? {
        MenuEventFilter.nextMeeting(
            from: events,
            settings: settingsStore.snapshot,
            now: now
        )
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
            replaceNotificationService(NotificationService.shared)
            AppLog.lifecycle.info("notificationBackend=system")
        } else {
            replaceNotificationService(notificationService)
            AppLog.lifecycle.info("notificationBackend=noop")
        }
        configureProviderFromSettings()
        systemEventMonitor.onWakeOrUnlock = { [weak self] in
            self?.handleWakeOrUnlock()
        }
        systemEventMonitor.onNetworkReturn = { [weak self] in
            Task { await self?.refresh(reason: "network-return") }
        }
        systemEventMonitor.start()
        AppLog.lifecycle.info("systemEventMonitorStarted")
        refreshTimer = WallClockTimer.scheduled(withTimeInterval: 60, repeats: true) { [weak self] _ in
            AppLog.refresh.info("refreshTimerFired")
            Task { @MainActor in await self?.refresh(reason: "timer") }
        }
        AppLog.refresh.info("refreshTimerInstalled intervalSeconds=60")
        beginNotificationAuthorization()
        Task {
            await refresh(reason: "launch")
        }
    }

    @discardableResult
    func handleWakeOrUnlock() -> Task<Void, Never> {
        AppLog.refresh.info("wakeUnlockRefreshTriggered")
        let generation = pendingRefreshGeneration
        recomputeReminders(now: now())
        return Task { [weak self] in
            guard let self, !Task.isCancelled, pendingRefreshGeneration == generation else { return }
            await refresh(reason: "wake")
        }
    }

    @discardableResult
    func beginNotificationAuthorization() -> Task<Void, Never> {
        if let pendingNotificationAuthorizationTask { return pendingNotificationAuthorizationTask }
        let notifier = notificationService
        let dispatcher = notificationDispatcher
        let generation = notificationResponseGeneration
        let isCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return !Task.isCancelled && notificationResponseGeneration == generation
        }
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if notificationResponseGeneration == generation { pendingNotificationAuthorizationTask = nil }
            }
            guard isCurrent() else { return }
            do {
                let granted = try await notifier.requestAuthorization()
                guard isCurrent() else { return }
                AppLog.lifecycle.info("notificationAuthorizationRequested granted=\(LogPrivacy.bool(granted), privacy: .public)")
            } catch {
                guard isCurrent() else { return }
                AppLog.lifecycle.error("notificationAuthorizationRequestFailed error=\(LogPrivacy.errorClass(error), privacy: .public)")
            }
            await dispatcher.refreshAuthorizationStatus(isCurrent: isCurrent)
            guard isCurrent() else { return }
            refreshNotificationWarning()
        }
        pendingNotificationAuthorizationTask = task
        return task
    }

    func stop() {
        persistenceRetryGeneration &+= 1
        invalidateNextAction()
        invalidateNotificationDelivery()
        invalidateNotificationResponses()
        invalidateStaleNotification()
        pendingReconnectTask?.cancel()
        pendingReconnectTask = nil
        refreshCoordinator.cancelPendingRefreshes()
        pendingRefreshGeneration &+= 1
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        cancelPendingDismissal(resumeFallback: false)
        guard started else { return }
        AppLog.lifecycle.info("controllerStop")
        started = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        fallbackDeadline = nil
        urgentSoundTimer?.invalidate()
        urgentSoundTimer = nil
        urgentSoundTargetDate = nil
        systemEventMonitor.onWakeOrUnlock = nil
        systemEventMonitor.onNetworkReturn = nil
        systemEventMonitor.stop()
        alertPresenter.hide()
        fallbackPresenter.hide()
        DiagnosticsRecorder.record("controller_stop")
    }

    func refresh(reason: String) async {
        guard !Task.isCancelled else { return }
        refreshProtectionStatus()
        let staleOwnerGeneration = staleNotificationOwnerGeneration
        let refreshProvider = provider
        let providerGeneration = refreshCoordinator.providerGeneration
        // Child notification tasks cannot delay calendar publication or the next fetch.
        // Structured ownership propagates cancellation and discards completed child results.
        await withDiscardingTaskGroup { group in
            group.addTask {
                await self.notifyStaleProtectionIfNeeded(ownerGeneration: staleOwnerGeneration)
            }
            let outcome = await refreshCoordinator.refresh(reason: reason) { outcome in
                apply(outcome)
                group.addTask {
                    await self.notifyProtectionChanges(for: outcome)
                }
            }
            if outcome == nil, let pendingReason = refreshCoordinator.takePendingRefreshReason() {
                pendingRefreshGeneration &+= 1
                let generation = pendingRefreshGeneration
                pendingRefreshTask = Task { [weak self] in
                    guard let self, !Task.isCancelled, pendingRefreshGeneration == generation else { return }
                    defer {
                        if pendingRefreshGeneration == generation { pendingRefreshTask = nil }
                    }
                    await refresh(reason: pendingReason)
                }
            }
            await refreshCredentialPersistenceFailures(from: refreshProvider, generation: providerGeneration)
        }
    }

    private func refreshProtectionStatus() {
        guard statusSource == .refresh else { return }
        let message = refreshCoordinator.currentStatusMessage
        guard statusMessage != message else { return }
        statusMessage = message
        refreshMenuBar()
    }

    private func setStatusMessage(_ message: String?, source: StatusSource) {
        statusSource = source
        statusMessage = message
    }

    private func apply(_ outcome: RefreshCoordinator.Outcome) {
        guard refreshCoordinator.isCurrent(outcome) else { return }
        let now = self.now()
        authState = outcome.authState
        accounts = outcome.accounts
        if let newCalendars = outcome.calendars {
            calendars = newCalendars
        }
        mergeAccountsFromCalendars()
        if let newEvents = outcome.events {
            events = newEvents
        }
        setStatusMessage(refreshCoordinator.currentStatusMessage, source: .refresh)
        recomputeReminders(now: now, operationID: outcome.operationID)
        if outcome.didSucceed {
            reminderStateStore.prune(
                endedBefore: now.addingTimeInterval(-8 * 24 * 60 * 60),
                activeKeys: Set(events.map(\.occurrenceKey)),
                now: now
            )
        }
        refreshReminderPersistenceFailure()
        refreshMenuBar()
    }

    private func notifyProtectionChanges(for outcome: RefreshCoordinator.Outcome) async {
        guard refreshCoordinator.isCurrent(outcome) else { return }
        await notifyAuthorizationExpiry(for: outcome)
        guard refreshCoordinator.isCurrent(outcome) else { return }
        await notifyStaleProtectionIfNeeded()
    }

    private func notifyAuthorizationExpiry(for outcome: RefreshCoordinator.Outcome) async {
        guard refreshCoordinator.isCurrent(outcome) else { return }
        let affectedAccounts = outcome.reconnectAccountIDs
        let requiresGenericReconnect = outcome.requiresGenericReconnect
        if reconnectNotificationAccounts != affectedAccounts
            || reconnectNotificationRequiresGeneric != requiresGenericReconnect {
            reconnectNotificationAccounts = affectedAccounts
            reconnectNotificationRequiresGeneric = requiresGenericReconnect
            reconnectNotificationGeneration &+= 1
        }
        notifiedReconnectAccountIDs.formIntersection(affectedAccounts)
        if !requiresGenericReconnect { notifiedGenericReconnect = false }
        let hasUnnotifiedAccounts = !affectedAccounts.subtracting(notifiedReconnectAccountIDs).isEmpty
        guard hasUnnotifiedAccounts || requiresGenericReconnect && !notifiedGenericReconnect else { return }
        reconnectNotificationGeneration &+= 1
        let generation = reconnectNotificationGeneration
        let deliveryGeneration = notificationDeliveryGeneration
        let isCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return generation == reconnectNotificationGeneration
                && deliveryGeneration == notificationDeliveryGeneration
                && refreshCoordinator.isCurrent(outcome)
                && affectedAccounts == refreshCoordinator.reconnectAccountIDs
                && requiresGenericReconnect == refreshCoordinator.requiresGenericReconnect
        }
        let dispatcher = notificationDispatcher
        await dispatcher.refreshAuthorizationStatus(isCurrent: isCurrent)
        guard isCurrent() else { return }
        refreshNotificationWarning()
        let stillHasUnnotifiedAccounts = !affectedAccounts.subtracting(notifiedReconnectAccountIDs).isEmpty
        guard stillHasUnnotifiedAccounts || requiresGenericReconnect && !notifiedGenericReconnect else { return }
        notifiedReconnectAccountIDs.formUnion(affectedAccounts)
        if requiresGenericReconnect { notifiedGenericReconnect = true }
        await dispatcher.deliver([
            MeetingNotification(
                id: "meeting-shield.reconnect",
                title: "Reconnect Google Calendar",
                body: "Open Meeting Shield settings to restore access. Cached meetings remain protected where coverage is available.",
                date: nil,
                withSound: false
            )
        ], isCurrent: isCurrent)
        guard isCurrent() else { return }
        refreshNotificationWarning()
    }

    private func notifyStaleProtectionIfNeeded(ownerGeneration expectedGeneration: UInt64? = nil) async {
        // A queued preflight belongs to the notifier/lifecycle that scheduled it.
        guard !Task.isCancelled, expectedGeneration == nil || expectedGeneration == staleNotificationOwnerGeneration else { return }
        let isStale = refreshCoordinator.isProtectionStale
            && refreshCoordinator.reconnectAccountIDs.isEmpty
            && !refreshCoordinator.requiresGenericReconnect
        if staleNotificationActive != isStale {
            staleNotificationActive = isStale
            staleNotificationPending = false
            notifiedStaleProtection = false
            staleNotificationGeneration &+= 1
        }
        guard isStale, !staleNotificationPending, !notifiedStaleProtection else { return }
        staleNotificationPending = true
        staleNotificationGeneration &+= 1
        let generation = staleNotificationGeneration
        // Reminder recomputation does not end a stale-health attempt; Stop/replacement does.
        let ownerGeneration = staleNotificationOwnerGeneration
        let providerGeneration = refreshCoordinator.providerGeneration
        defer {
            if generation == staleNotificationGeneration { staleNotificationPending = false }
        }
        let isCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self, !Task.isCancelled else { return false }
            return generation == staleNotificationGeneration
                && ownerGeneration == staleNotificationOwnerGeneration
                && providerGeneration == refreshCoordinator.providerGeneration
                && refreshCoordinator.isProtectionStale
                && refreshCoordinator.reconnectAccountIDs.isEmpty
                && !refreshCoordinator.requiresGenericReconnect
        }
        let dispatcher = notificationDispatcher
        await dispatcher.refreshAuthorizationStatus(isCurrent: isCurrent)
        guard isCurrent() else { return }
        refreshNotificationWarning()
        notifiedStaleProtection = true
        await dispatcher.deliver([
            MeetingNotification(
                id: "meeting-shield.stale",
                title: "Meeting protection may be stale",
                body: "Meeting Shield has not refreshed its protected calendar data. Open the app to check coverage.",
                date: nil,
                withSound: false
            )
        ], isCurrent: isCurrent)
        guard isCurrent() else { return }
        refreshNotificationWarning()
    }

    @discardableResult
    func reconnectGoogle() -> Task<Void, Never>? {
        guard hasGoogleOAuthClientConfiguration else {
            AppLog.oauth.error("reconnectRequested configuration=missing")
            setStatusMessage("Google Calendar connection is not configured for this build.", source: .action)
            openSettings()
            refreshMenuBar()
            return nil
        }
        AppLog.oauth.info("reconnectRequested source=\(LogPrivacy.oauthClientSource(self.googleOAuthConfigurationSource), privacy: .public)")
        refreshCoordinator.recordConnectionFailure(nil)
        setStatusMessage(nil, source: .action)
        authState = .authenticating
        refreshMenuBar()
        configureGoogleProvider()
        let connectionProvider = provider
        let generation = refreshCoordinator.providerGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == refreshCoordinator.providerGeneration { pendingReconnectTask = nil }
            }
            guard !Task.isCancelled, generation == refreshCoordinator.providerGeneration else { return }
            do {
                try await connectionProvider.reconnect()
                guard !Task.isCancelled, generation == refreshCoordinator.providerGeneration else { return }
                AppLog.oauth.info("reconnectSucceeded")
                await refresh(reason: "reconnect")
            } catch {
                guard !Task.isCancelled, generation == refreshCoordinator.providerGeneration else { return }
                AppLog.oauth.error("reconnectFailed error=\(LogPrivacy.errorClass(error), privacy: .public)")
                let connectionState = await connectionProvider.authState
                guard !Task.isCancelled, generation == refreshCoordinator.providerGeneration else { return }
                await refreshCredentialPersistenceFailures(from: connectionProvider, generation: generation)
                guard !Task.isCancelled, generation == refreshCoordinator.providerGeneration else { return }
                authState = connectionState
                let failureMessage = "Google Calendar connection failed: \(error.localizedDescription)"
                refreshCoordinator.recordConnectionFailure(failureMessage)
                setStatusMessage(failureMessage, source: .action)
                refreshMenuBar()
            }
        }
        pendingReconnectTask = task
        return task
    }

    func openSettings() {
        AppLog.lifecycle.info("openSettings")
        presentSettings()
    }

    func openNewGoogleEvent() {
        guard let url = URL(string: "https://calendar.google.com/calendar/u/0/r/eventedit") else { return }
        NSWorkspace.shared.open(url)
    }

    func join(_ captured: ScheduledReminder, now: Date = Date()) {
        join(captured, retry: false, now: now)
    }

    private func currentReminderEvaluation(
        ignoringAcknowledgements: Bool, now: Date
    ) -> ReminderPipeline.Result {
        defer { refreshReminderPersistenceFailure() }
        reminderStateStore.reconcileAcknowledgements(events: events, now: now)
        return reminderPipeline.compute(
            events: events, settings: settingsStore.snapshot, stateStore: reminderStateStore, now: now,
            ignoringAcknowledgements: ignoringAcknowledgements
        )
    }

    private func currentActionReminder(
        id: String, ignoringAcknowledgements: Bool, now: Date
    ) -> ScheduledReminder? {
        let current = currentReminderEvaluation(ignoringAcknowledgements: ignoringAcknowledgements, now: now).scheduled
        guard var selected = current.first(where: { $0.id == id }),
              let group = scheduler.groupedReminders(from: current).first(where: {
                  $0.members.contains { $0.id == id }
              }) else { return nil }
        selected.members = group.members
        return selected
    }

    private func join(_ captured: ScheduledReminder, retry: Bool, now: Date) {
        let operationID = UUID().uuidString.lowercased()
        guard let reminder = currentActionReminder(id: captured.id, ignoringAcknowledgements: retry, now: now) else {
            AppLog.alert.info("joinSkipped reason=sourceUnavailable")
            recordReminderOutcome(
                event: "reminder_action", outcome: "launch_failed", occurrenceIDs: [captured.id],
                operationID: operationID, evaluatedAt: now
            )
            if retry { showFallbackFailure("This meeting is unavailable. Refresh calendars or try again.") }
            return
        }
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
            recordReminderOutcome(
                event: "reminder_action", outcome: "launch_accepted",
                occurrenceIDs: reminder.members.map(\.id), operationID: operationID, evaluatedAt: now
            )
            for member in reminder.members {
                reminderStateStore.acknowledge(
                    member.event.occurrenceKey,
                    fingerprint: member.event.materialFingerprint(detectedLinks: member.detectedLinks),
                    eventEnd: member.event.endDate,
                    now: now
                )
            }
            recomputeReminders(now: now, operationID: operationID)
            refreshMenuBar()
            showFallback(for: reminder, result: result)
        } catch {
            AppLog.alert.error("joinLaunchFailed reminder=\(LogPrivacy.redactedID(reminder.id), privacy: .public) error=\(LogPrivacy.errorClass(error), privacy: .public)")
            DiagnosticsRecorder.record("join_failed", metadata: ["error": LogPrivacy.errorClass(error)])
            recordReminderOutcome(
                event: "reminder_action", outcome: "launch_failed",
                occurrenceIDs: reminder.members.map(\.id), operationID: operationID, evaluatedAt: now
            )
            setStatusMessage(error.localizedDescription, source: .action)
            if retry { showFallbackFailure("Could not open this meeting. Try again.") }
            refreshMenuBar()
        }
    }

    func canAlertAgain(_ captured: CalendarEventOccurrence, now: Date = Date()) -> Bool {
        guard let event = events.first(where: { $0.id == captured.id }) else { return false }
        let links = MeetingLinkExtractor().extractLinks(from: event)
        guard event.endDate > now,
              reminderStateStore.state(for: event.occurrenceKey)?.mutedUntilEventEnd != true,
              EventEligibilityEngine().evaluate(
                event: event, detectedLinks: links, settings: settingsStore.snapshot,
                reminderState: reminderStateStore
              ).isEligible else { return false }
        return reminderStateStore.isAcknowledged(
            event.occurrenceKey,
            currentFingerprint: event.materialFingerprint(detectedLinks: links),
            now: now
        )
    }

    func alertAgain(_ event: CalendarEventOccurrence, now: Date = Date()) {
        guard let reminder = currentActionReminder(id: event.id, ignoringAcknowledgements: true, now: now) else { return }
        for member in reminder.members {
            reminderStateStore.clearAcknowledgement(member.event.occurrenceKey, now: now)
        }
        if let fallback, reminder.members.contains(where: { $0.id == fallback.reminder.id }) {
            clearFallback()
        }
        recomputeReminders(now: now)
        refreshMenuBar()
    }

    func snooze(_ reminder: ScheduledReminder, choice: SnoozeChoice? = nil, now: Date = Date()) {
        snooze([reminder], choice: choice, now: now)
    }

    func snoozeAllVisible(now: Date = Date()) {
        AppLog.alert.info("snoozeAllRequested count=\(self.activeReminders.count, privacy: .public)")
        snooze(activeReminders, choice: nil, now: now)
    }

    private func snooze(_ reminders: [ScheduledReminder], choice: SnoozeChoice?, now: Date) {
        let operationID = UUID().uuidString.lowercased()
        let selected = choice ?? .seconds(settingsStore.snapshot.globalSnoozeDuration)
        let diagnosticChoice: [String: String]
        switch selected {
        case .seconds(let seconds):
            diagnosticChoice = ["choice": "seconds", "seconds": String(seconds)]
        case .untilDangerPoint:
            diagnosticChoice = ["choice": "until_danger_point"]
        }
        var snoozedIDs: Set<String> = []
        for captured in reminders {
            guard let reminder = currentActionReminder(id: captured.id, ignoringAcknowledgements: false, now: now),
                  let returnDate = scheduler.snoozeReturnDate(for: reminder.event, now: now, choice: selected) else { continue }
            AppLog.alert.info("snoozeRequested reminder=\(LogPrivacy.redactedID(reminder.id), privacy: .public) returnSeconds=\(Int(returnDate.timeIntervalSince(now)), privacy: .public)")
            DiagnosticsRecorder.record("snooze_requested", metadata: diagnosticChoice)
            for member in reminder.members {
                guard let memberReturn = scheduler.snoozeReturnDate(for: member.event, now: now, choice: selected) else { continue }
                reminderStateStore.snooze(member.event.occurrenceKey, until: memberReturn, now: now)
                snoozedIDs.insert(member.id)
            }
        }
        guard !snoozedIDs.isEmpty else { return }
        recordReminderOutcome(
            event: "reminder_action", outcome: "snooze_accepted", occurrenceIDs: Array(snoozedIDs),
            operationID: operationID, evaluatedAt: now
        )
        recomputeReminders(now: now, operationID: operationID)
        refreshMenuBar()
    }

    func requestDismissal(
        _ captured: ScheduledReminder, source: DismissalRequestSource = .fullScreen, now: Date = Date()
    ) {
        guard pendingDismissal == nil,
              let reminder = currentActionReminder(
                id: captured.id, ignoringAcknowledgements: source == .fallback, now: now
              ), source == .fallback || reminder.fireDate <= now else { return }
        let pausesFallback = source == .fallback && fallback?.id == reminder.id
        let remaining = pausesFallback ? fallbackDeadline.map { max(0, $0.timeIntervalSince(now)) } : nil
        if pausesFallback {
            fallbackGeneration &+= 1
            fallbackTimer?.invalidate()
            fallbackTimer = nil
            fallbackDeadline = nil
        }
        let request = PendingDismissal(
            id: UUID(), reminder: reminder, source: source,
            fingerprints: dismissalFingerprints(for: reminder),
            pausedFallbackGeneration: pausesFallback ? fallbackGeneration : nil,
            fallbackTimeRemaining: remaining
        )
        pendingDismissal = request
        dismissalPresenter.present(requestID: request.id, reminder: reminder, source: source) { [weak self] confirmed in
            self?.resolveDismissal(requestID: request.id, confirmed: confirmed, now: Date())
        }
    }

    private func dismissalFingerprints(for reminder: ScheduledReminder) -> [String: MaterialChangeFingerprint] {
        Dictionary(uniqueKeysWithValues: reminder.members.map { member in
            (member.id, member.event.materialFingerprint(detectedLinks: member.detectedLinks))
        })
    }

    private func currentDismissalTarget(for request: PendingDismissal, now: Date) -> ScheduledReminder? {
        guard let reminder = currentActionReminder(
            id: request.reminder.id, ignoringAcknowledgements: request.source == .fallback, now: now
        ), (request.source == .fallback || reminder.fireDate <= now),
              dismissalFingerprints(for: reminder) == request.fingerprints else { return nil }
        return reminder
    }

    private func resolveDismissal(requestID: UUID, confirmed: Bool, now: Date) {
        guard let request = pendingDismissal, request.id == requestID else { return }
        pendingDismissal = nil
        guard confirmed, let reminder = currentDismissalTarget(for: request, now: now) else {
            resumeFallback(after: request)
            return
        }
        dismiss(reminder, now: now)
        if request.source == .fallback,
           request.pausedFallbackGeneration == fallbackGeneration,
           fallback?.id == request.reminder.id {
            clearFallback()
        }
    }

    private func cancelPendingDismissal(resumeFallback: Bool = true) {
        guard let request = pendingDismissal else { return }
        pendingDismissal = nil
        dismissalPresenter.cancel(requestID: request.id)
        if resumeFallback { self.resumeFallback(after: request) }
    }

    private func resumeFallback(after request: PendingDismissal) {
        guard request.pausedFallbackGeneration == fallbackGeneration,
              fallback?.id == request.reminder.id,
              let remaining = request.fallbackTimeRemaining else { return }
        scheduleFallbackTimeout(after: max(1, remaining))
    }

    private func reconcilePendingDismissal(now: Date) {
        guard let request = pendingDismissal,
              currentDismissalTarget(for: request, now: now) == nil else { return }
        cancelPendingDismissal()
    }

    func dismiss(_ captured: ScheduledReminder, now: Date = Date()) {
        guard let reminder = currentActionReminder(id: captured.id, ignoringAcknowledgements: true, now: now) else { return }
        let operationID = UUID().uuidString.lowercased()
        DiagnosticsRecorder.record("dismiss_requested")
        let fingerprint = reminder.event.materialFingerprint(detectedLinks: reminder.detectedLinks)
        AppLog.alert.info("dismissRequested reminder=\(LogPrivacy.redactedID(reminder.id), privacy: .public) fingerprint=\(LogPrivacy.fingerprintPrefix(fingerprint.value), privacy: .public)")
        for member in reminder.members {
            reminderStateStore.dismiss(
                member.event.occurrenceKey,
                fingerprint: member.event.materialFingerprint(detectedLinks: member.detectedLinks),
                now: now
            )
        }
        recordReminderOutcome(
            event: "reminder_action", outcome: "dismiss_accepted", occurrenceIDs: reminder.members.map(\.id),
            operationID: operationID, evaluatedAt: now
        )
        recomputeReminders(now: now, operationID: operationID)
        refreshMenuBar()
    }

    func muteCurrentOccurrence(_ captured: ScheduledReminder, now: Date = Date()) {
        guard let reminder = currentActionReminder(id: captured.id, ignoringAcknowledgements: false, now: now) else { return }
        let operationID = UUID().uuidString.lowercased()
        AppLog.alert.info("muteCurrentOccurrence reminder=\(LogPrivacy.redactedID(reminder.id), privacy: .public)")
        DiagnosticsRecorder.record("mute_requested")
        for member in reminder.members {
            reminderStateStore.muteUntilEventEnd(member.event.occurrenceKey, now: now)
        }
        recordReminderOutcome(
            event: "reminder_action", outcome: "mute_accepted", occurrenceIDs: reminder.members.map(\.id),
            operationID: operationID, evaluatedAt: now
        )
        recomputeReminders(now: now, operationID: operationID)
        refreshMenuBar()
    }

    func openAgainFromFallback(now: Date = Date()) {
        guard let fallback else { return }
        AppLog.fallback.info("openAgainRequested reminder=\(LogPrivacy.redactedID(fallback.reminder.id), privacy: .public)")
        join(fallback.reminder, retry: true, now: now)
    }

    func fireFallbackTimeoutForRuntimeCheck() {
        guard RuntimePresentationCheck.isRequested else { return }
        fallbackTimer?.fire()
    }

    func clearFallback() {
        if pendingDismissal?.source == .fallback { cancelPendingDismissal(resumeFallback: false) }
        AppLog.fallback.info("clearFallback hadFallback=\(LogPrivacy.bool(self.fallback != nil), privacy: .public)")
        fallbackGeneration &+= 1
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        fallbackDeadline = nil
        fallback = nil
        fallbackPresenter.hide()
    }

    func handleSettingsChanged() {
        recomputeReminders(now: Date())
        refreshMenuBar()
        if refreshCoordinator.settingsDidChange() {
            Task { await refresh(reason: "settings") }
        }
    }

    @discardableResult
    func removeConnectedAccount(_ accountID: String) -> Task<Void, Never> {
        let removalProvider = provider
        let providerGeneration = refreshCoordinator.providerGeneration
        refreshCoordinator.invalidate(reason: "settings")
        return Task {
            guard providerGeneration == refreshCoordinator.providerGeneration else {
                await refresh(reason: "settings")
                return
            }
            do {
                try await removalProvider.removeAccount(id: accountID)
                await refreshCredentialPersistenceFailures(from: removalProvider, generation: providerGeneration)
                guard providerGeneration == refreshCoordinator.providerGeneration else {
                    await refresh(reason: "settings")
                    return
                }
                refreshCoordinator.recordAccountRemoval(accountID)
                let removedCalendarIDs = calendars
                    .filter { $0.accountID == accountID }
                    .map(\.id)
                calendars.removeAll { $0.accountID == accountID }
                accounts.removeAll { $0.id == accountID }
                settingsStore.update { settings in
                    settings.disabledGoogleAccountIDs.insert(accountID)
                    settings.accountNicknames.removeValue(forKey: accountID)
                    removedCalendarIDs.forEach { calendarID in
                        if settings.hasExplicitCalendarSelection {
                            settings.selectedCalendarIDs.remove(calendarID)
                        }
                        settings.calendarAliases.removeValue(forKey: calendarID)
                        settings.calendarSettings.removeValue(forKey: calendarID)
                    }
                }
                refreshCoordinator.settingsDidChange()
                refreshCoordinator.invalidate(reason: "settings")
                events.removeAll { $0.accountID == accountID }
                if fallback?.reminder.event.accountID == accountID { clearFallback() }
                recomputeReminders(now: Date())
                refreshMenuBar()
                AppLog.oauth.info("accountRemovedFromSettings account=\(LogPrivacy.redactedID(accountID), privacy: .public)")
                await refresh(reason: "settings")
            } catch {
                await refreshCredentialPersistenceFailures(from: removalProvider, generation: providerGeneration)
                guard providerGeneration == refreshCoordinator.providerGeneration else {
                    await refresh(reason: "settings")
                    return
                }
                refreshCoordinator.invalidate(reason: "settings")
                await refresh(reason: "settings")
                guard providerGeneration == refreshCoordinator.providerGeneration else { return }
                setStatusMessage("Could not remove Google account: \(error.localizedDescription)", source: .action)
                refreshMenuBar()
                AppLog.oauth.error("accountRemoveFailed account=\(LogPrivacy.redactedID(accountID), privacy: .public) error=\(LogPrivacy.errorClass(error), privacy: .public)")
            }
        }
    }

    private func configureProviderFromSettings() {
        configuredGoogleClientID = credentialsResolver.clientID(settingsValue: settingsStore.snapshot.googleOAuthClientID)
        if let fixtureMode = MockCalendarFixtureMode.selected() {
            AppLog.lifecycle.info("providerConfigured mode=mock fixture=\(fixtureMode.rawValue, privacy: .public)")
            provider = MockCalendarProvider(fixtureMode: fixtureMode)
        } else if !hasGoogleOAuthClientConfiguration {
            AppLog.lifecycle.info("providerConfigured mode=disconnected oauthSource=missing")
            if !(provider is DisconnectedCalendarProvider) {
                provider = DisconnectedCalendarProvider(credentialSource: provider)
            }
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
        provider = makeGoogleProvider(configuration)
        configuredGoogleClientID = configuration.clientID
    }

    private func recomputeReminders(
        now: Date,
        operationID: String = UUID().uuidString.lowercased()
    ) {
        invalidateNotificationDelivery()
        refreshNotificationWarning()
        defer { refreshReminderPersistenceFailure() }
        AppLog.refresh.debug("recomputeRemindersStart events=\(self.events.count, privacy: .public) active=\(self.activeReminders.count, privacy: .public)")
        DiagnosticsRecorder.record("recompute_started", metadata: ["events": "\(events.count)"])
        _ = reminderStateStore.reconcileLegacyStates(
            events: events,
            cachedEvents: refreshCoordinator.legacyIdentityEvidence,
            now: now
        )
        if reminderStateStore.unresolvedLegacyCount == 0, !reminderStateStore.isPersistencePending {
            refreshCoordinator.clearLegacyIdentityEvidence()
        }
        reminderStateStore.reconcileSnoozes(events: events, now: now)
        reminderStateStore.reconcileAcknowledgements(events: events, now: now)
        reconcilePendingDismissal(now: now)
        let result = reminderPipeline.compute(
            events: events,
            settings: settingsStore.snapshot,
            stateStore: reminderStateStore,
            now: now
        )
        lastReminderEvaluationDate = now
        recordChangedReminderDecisions(result.decisions, operationID: operationID, evaluatedAt: now)
        scheduledReminders = result.scheduled
        let due = result.due
        AppLog.refresh.info("recomputeRemindersEnd candidates=\(result.candidateCount, privacy: .public) scheduled=\(self.scheduledReminders.count, privacy: .public) due=\(due.count, privacy: .public) dueSet=\(LogPrivacy.redactedIDSet(due.map(\.id)), privacy: .public)")
        DiagnosticsRecorder.record("recompute_finished", metadata: [
            "candidates": "\(result.candidateCount)",
            "scheduled": "\(scheduledReminders.count)",
            "due": "\(due.count)"
        ])

        let previousReminders = activeReminders
        let alertWasShowing = alertPresenter.isShowing
        let decision = ReminderPresentationDecision.decide(
            due: due,
            previous: previousReminders,
            isPresentationMode: isPresentationMode,
            inWakeGrace: wakeGraceActive,
            alertAlreadyShowing: alertPresenter.isShowing
        )
        activeReminders = due
        switch decision {
        case .keepCurrent:
            AppLog.alert.debug("presentActiveRemindersSkipped unchangedDueSet=\(LogPrivacy.redactedIDSet(due.map(\.id)), privacy: .public)")
            reconcileUrgentSoundTimer(now: now)
        case .updateFullScreen(let playSound):
            alertPresenter.update(reminders: due)
            recordReminderOutcome(
                event: "reminder_presentation", outcome: "window_updated", reminders: due,
                operationID: operationID, evaluatedAt: now
            )
            if playSound { playPresentationSounds() } else { reconcileUrgentSoundTimer(now: now) }
        case .clear:
            AppLog.alert.info("activeRemindersCleared")
            urgentSoundTimer?.invalidate()
            urgentSoundTimer = nil
            urgentSoundTargetDate = nil
            if alertWasShowing {
                alertPresenter.hide()
                recordReminderOutcome(
                    event: "reminder_presentation", outcome: "window_closed", reminders: previousReminders,
                    operationID: operationID, evaluatedAt: now
                )
            }
        case .presentFullScreen, .deliverNotifications:
            AppLog.alert.info("presentActiveRemindersRequired decision=\(String(describing: decision), privacy: .public) dueSet=\(LogPrivacy.redactedIDSet(due.map(\.id)), privacy: .public)")
            presentActiveReminders(operationID: operationID, evaluatedAt: now)
        }
        scheduleNextAction(now: now, operationID: operationID)
        fallbackPresenter.updateLevel(aboveAlerts: alertPresenter.isShowing)
    }

    private func handlePresentationModeChange() {
        let operationID = UUID().uuidString.lowercased()
        let evaluatedAt = now()
        invalidateNotificationDelivery()
        cancelPendingDismissal()
        refreshNotificationWarning()
        guard !activeReminders.isEmpty else { return }
        AppLog.alert.info("presentationModeChangedWithActiveReminders enabled=\(LogPrivacy.bool(self.isPresentationMode), privacy: .public) active=\(self.activeReminders.count, privacy: .public)")
        if alertPresenter.isShowing {
            alertPresenter.hide()
            recordReminderOutcome(
                event: "reminder_presentation", outcome: "window_closed", reminders: activeReminders,
                operationID: operationID, evaluatedAt: evaluatedAt
            )
        }
        presentActiveReminders(operationID: operationID, evaluatedAt: evaluatedAt)
        fallbackPresenter.updateLevel(aboveAlerts: alertPresenter.isShowing)
    }

    private func presentActiveReminders(
        operationID: String = UUID().uuidString.lowercased(),
        evaluatedAt: Date? = nil
    ) {
        let evaluatedAt = evaluatedAt ?? now()
        DiagnosticsRecorder.record("present_active_reminders", metadata: [
            "count": "\(activeReminders.count)",
            "presentationMode": "\(isPresentationMode)",
            "wakeGrace": "\(systemEventMonitor.isInWakeGrace(now: now()))"
        ])
        if isPresentationMode || wakeGraceActive {
            if alertPresenter.isShowing {
                alertPresenter.update(reminders: activeReminders)
                recordReminderOutcome(
                    event: "reminder_presentation", outcome: "window_updated", reminders: activeReminders,
                    operationID: operationID, evaluatedAt: evaluatedAt
                )
            }
            reconcileUrgentSoundTimer(now: evaluatedAt)
            AppLog.alert.info("presentActiveRemindersViaNotifications count=\(self.activeReminders.count, privacy: .public) presentation=\(LogPrivacy.bool(self.isPresentationMode), privacy: .public) wakeGrace=\(LogPrivacy.bool(self.systemEventMonitor.isInWakeGrace(now: self.now())), privacy: .public)")
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
            let dispatcher = notificationDispatcher
            let generation = notificationDeliveryGeneration
            let settings = settingsStore.snapshot
            let reminders = activeReminders
            pendingNotificationTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if notificationDeliveryGeneration == generation { pendingNotificationTask = nil }
                }
                let isCurrent: @MainActor () -> Bool = { [weak self] in
                    guard let self, !Task.isCancelled,
                          notificationDeliveryGeneration == generation,
                          settingsStore.snapshot == settings, notificationsCarryAlerts else { return false }
                    return reminderPipeline.compute(
                        events: events, settings: settings, stateStore: reminderStateStore, now: now()
                    ).due == reminders
                }
                await dispatcher.refreshAuthorizationStatus(isCurrent: isCurrent)
                guard isCurrent() else { return }
                refreshNotificationWarning()
                if notificationWarning != nil {
                    recordReminderOutcome(
                        event: "reminder_notification", outcome: "channel_unavailable", reminders: reminders,
                        operationID: operationID, evaluatedAt: self.now()
                    )
                }
                let outcome = await dispatcher.deliver(notifications, isCurrent: isCurrent)
                guard isCurrent() else { return }
                switch outcome {
                case .submitted:
                    recordReminderOutcome(
                        event: "reminder_notification", outcome: "notification_submitted", reminders: reminders,
                        operationID: operationID, evaluatedAt: self.now()
                    )
                case .failed:
                    recordReminderOutcome(
                        event: "reminder_notification", outcome: "notification_failed", reminders: reminders,
                        operationID: operationID, evaluatedAt: self.now()
                    )
                case .obsolete:
                    return
                }
                refreshNotificationWarning()
            }
        } else {
            AppLog.alert.info("presentActiveRemindersViaFullScreen count=\(self.activeReminders.count, privacy: .public)")
            playPresentationSounds()
            showFullScreenReminders(activeReminders, operationID: operationID, evaluatedAt: evaluatedAt)
        }
    }

    private func showFullScreenReminders(
        _ reminders: [ScheduledReminder],
        selectedID: String? = nil,
        operationID: String = UUID().uuidString.lowercased(),
        evaluatedAt: Date? = nil
    ) {
        let evaluatedAt = evaluatedAt ?? now()
        if pendingDismissal?.source == .fullScreen { cancelPendingDismissal() }
        alertPresenter.show(
            reminders: reminders,
            selectedID: selectedID,
            availableSnoozeChoices: { [weak self] reminder, now in
                guard let self else { return [] }
                return self.scheduler.availableSnoozeChoices(event: reminder.event, now: now)
            },
            onJoin: { [weak self] reminder in self?.join(reminder) },
            onSnooze: { [weak self] reminder, choice in self?.snooze(reminder, choice: choice) },
            onDismiss: { [weak self] reminder in self?.dismiss(reminder) },
            onRequestDismissal: { [weak self] reminder in self?.requestDismissal(reminder) },
            onMute: { [weak self] reminder in self?.muteCurrentOccurrence(reminder) },
            onSnoozeAll: { [weak self] in self?.snoozeAllVisible() }
        )
        recordReminderOutcome(
            event: "reminder_presentation",
            outcome: alertPresenter.isShowing ? "window_constructed" : "window_unavailable",
            reminders: reminders,
            operationID: operationID,
            evaluatedAt: evaluatedAt
        )
        fallbackPresenter.updateLevel(aboveAlerts: alertPresenter.isShowing)
    }

    @discardableResult
    func fireNextAction() -> Task<Void, Never>? {
        guard let nextActionTimer, nextActionTimer.isValid else { return nil }
        nextActionTimer.fire()
        return pendingNextActionTask
    }

    private func invalidateNextAction() {
        nextActionTimer?.invalidate()
        nextActionTimer = nil
        pendingNextActionTask?.cancel()
        pendingNextActionTask = nil
        nextActionTargetDate = nil
    }

    private func scheduleNextAction(
        now: Date,
        operationID: String = UUID().uuidString.lowercased()
    ) {
        invalidateNextAction()
        guard let date = [
            scheduler.nextActionDate(from: scheduledReminders, now: now),
            reminderStateStore.nextAcknowledgementExpiry(after: now),
            wakeGraceActive ? systemEventMonitor.wakeGraceUntil : nil
        ].compactMap({ $0 }).min() else {
            AppLog.refresh.debug("nextActionTimerSkipped scheduled=0")
            return
        }
        nextActionTargetDate = date
        let interval = max(1, date.timeIntervalSince(now))
        AppLog.refresh.debug("nextActionTimerScheduled delaySeconds=\(Int(interval), privacy: .public)")
        DiagnosticsRecorder.record("scheduled_next_action", metadata: ["interval": "\(Int(interval))"])
        diagnostics.recordEvent("reminder_timer_scheduled", metadata: [
            "operation": operationID,
            "target": ISO8601DateFormatter.stableString(from: date),
            "evaluated": ISO8601DateFormatter.stableString(from: now)
        ])
        nextActionTimer = WallClockTimer.scheduled(withTimeInterval: interval, repeats: false) { [weak self] _ in
            AppLog.refresh.info("nextActionTimerFired")
            MainActor.assumeIsolated {
                guard let self else { return }
                let actual = self.now()
                self.diagnostics.recordEvent("reminder_timer_fired", metadata: [
                    "operation": operationID,
                    "target": ISO8601DateFormatter.stableString(from: date),
                    "actual": ISO8601DateFormatter.stableString(from: actual),
                    "delay": String(max(0, actual.timeIntervalSince(date)))
                ])
                self.pendingNextActionTask?.cancel()
                self.pendingNextActionTask = Task { @MainActor [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    self.recomputeReminders(now: actual, operationID: operationID)
                }
            }
        }
    }

    private func recordChangedReminderDecisions(
        _ decisions: [ReminderPipeline.Decision],
        operationID: String,
        evaluatedAt: Date
    ) {
        let current = Dictionary(uniqueKeysWithValues: decisions.map { ($0.occurrenceID, $0) })
        for decision in decisions where lastReminderDecisions[decision.occurrenceID] != decision {
            recordReminderDecision(decision, operationID: operationID, evaluatedAt: evaluatedAt)
        }
        for previous in lastReminderDecisions.values where current[previous.occurrenceID] == nil {
            var removed = previous
            removed.reason = .removed
            removed.targetDate = nil
            recordReminderDecision(removed, operationID: operationID, evaluatedAt: evaluatedAt)
        }
        lastReminderDecisions = current
    }

    private func recordReminderDecision(
        _ decision: ReminderPipeline.Decision,
        operationID: String,
        evaluatedAt: Date
    ) {
        var metadata = [
            "operation": operationID,
            "occurrence": LogPrivacy.redactedID(decision.occurrenceID),
            "account": LogPrivacy.redactedID(decision.accountID),
            "reason": decision.reason.rawValue,
            "evaluated": ISO8601DateFormatter.stableString(from: evaluatedAt)
        ]
        if let targetDate = decision.targetDate {
            metadata["target"] = ISO8601DateFormatter.stableString(from: targetDate)
        }
        diagnostics.recordEvent("reminder_decision", metadata: metadata)
    }

    private func recordReminderOutcome(
        event: String,
        outcome: String,
        reminders: [ScheduledReminder],
        operationID: String,
        evaluatedAt: Date
    ) {
        let occurrenceIDs = Set(reminders.flatMap { $0.members.map(\.id) }).sorted()
        recordReminderOutcome(
            event: event, outcome: outcome, occurrenceIDs: occurrenceIDs,
            operationID: operationID, evaluatedAt: evaluatedAt
        )
    }

    private func recordReminderOutcome(
        event: String,
        outcome: String,
        occurrenceIDs: [String],
        operationID: String,
        evaluatedAt: Date
    ) {
        for occurrenceID in Set(occurrenceIDs).sorted() {
            diagnostics.recordEvent(event, metadata: [
                "operation": operationID,
                "occurrence": LogPrivacy.redactedID(occurrenceID),
                "outcome": outcome,
                "evaluated": ISO8601DateFormatter.stableString(from: evaluatedAt)
            ])
        }
    }

    private func refreshNotificationWarning() {
        let warning = notificationHealth.warningMessage(notificationsCarryAlerts: notificationsCarryAlerts)
        guard warning != notificationWarning else { return }
        notificationWarning = warning
        if warning != nil {
            AppLog.alert.error("notificationChannelUnhealthy")
        }
        refreshMenuBar()
    }

    private func playPresentationSounds() {
        let snapshot = settingsStore.snapshot
        if AlertSoundPolicy.shouldPlayOnPresent(settings: snapshot) {
            soundPlayer.playAlertSound()
        }
        reconcileUrgentSoundTimer(now: Date())
    }

    private func reconcileUrgentSoundTimer(now: Date) {
        let repeatDate = isPresentationMode || wakeGraceActive ? nil : AlertSoundPolicy.urgentRepeatDate(
            reminders: activeReminders,
            settings: settingsStore.snapshot,
            now: now,
            pendingDate: urgentSoundTimer?.isValid == true ? urgentSoundTargetDate : nil
        )
        if let repeatDate, repeatDate == urgentSoundTargetDate, urgentSoundTimer?.isValid == true { return }
        urgentSoundTimer?.invalidate()
        urgentSoundTimer = nil
        urgentSoundTargetDate = nil
        guard let repeatDate else { return }
        urgentSoundTargetDate = repeatDate
        let interval = max(1, repeatDate.timeIntervalSinceNow)
        urgentSoundTimer = WallClockTimer.scheduled(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.urgentSoundTargetDate == repeatDate { self.urgentSoundTargetDate = nil }
                guard self.activeReminders.contains(where: {
                    $0.event.endDate > Date() &&
                    $0.event.startDate.addingTimeInterval(-ReminderScheduler.dangerPointOffset) == repeatDate
                }),
                      !self.isPresentationMode, !self.wakeGraceActive,
                      self.settingsStore.snapshot.soundEnabled,
                      self.settingsStore.snapshot.urgentRepeatSoundEnabled,
                      self.alertPresenter.isShowing else { return }
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
        if pendingDismissal?.source == .fallback { cancelPendingDismissal(resumeFallback: false) }
        fallbackGeneration &+= 1
        AppLog.fallback.info("showFallback reminder=\(LogPrivacy.redactedID(reminder.id), privacy: .public) openedIn=\(result.target.browser.rawValue, privacy: .public) warning=\(LogPrivacy.bool(result.warning != nil), privacy: .public)")
        DiagnosticsRecorder.record("fallback_show", metadata: ["hasWarning": "\(result.warning != nil)"])
        fallback = JoinFallbackState(
            reminder: reminder,
            openedIn: result.target.displayName,
            warning: result.warning
        )
        presentFallback()
        scheduleFallbackTimeout(after: 10)
    }

    private func scheduleFallbackTimeout(after interval: TimeInterval) {
        let generation = fallbackGeneration
        fallbackTimer?.invalidate()
        fallbackDeadline = Date().addingTimeInterval(interval)
        AppLog.fallback.debug("fallbackTimerScheduled seconds=\(Int(interval), privacy: .public)")
        fallbackTimer = WallClockTimer.scheduled(withTimeInterval: interval, repeats: false) { [weak self] _ in
            AppLog.fallback.info("fallbackTimerFired")
            Task { @MainActor in
                guard let self, self.fallbackGeneration == generation else { return }
                self.clearFallback()
            }
        }
    }

    private func showFallbackFailure(_ message: String) {
        guard fallback != nil else { return }
        if pendingDismissal?.source == .fallback { cancelPendingDismissal(resumeFallback: false) }
        fallbackGeneration &+= 1
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        fallbackDeadline = nil
        fallback?.errorMessage = message
        presentFallback()
    }

    private func presentFallback() {
        if let fallback {
            fallbackPresenter.show(
                fallback: fallback,
                aboveAlerts: alertPresenter.isShowing,
                onOpenAgain: { [weak self] in self?.openAgainFromFallback() },
                onDismiss: { [weak self] in
                    self?.requestDismissal(fallback.reminder, source: .fallback)
                },
                onClose: { [weak self] in self?.clearFallback() }
            )
        }
    }
}

struct JoinFallbackState: Identifiable {
    var id: String { reminder.id }
    var reminder: ScheduledReminder
    var openedIn: String
    var warning: String?
    var errorMessage: String? = nil
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
