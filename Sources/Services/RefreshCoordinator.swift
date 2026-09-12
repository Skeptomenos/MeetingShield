import Foundation

@MainActor
final class RefreshCoordinator {
    struct ProtectionSnapshot: Sendable {
        var accounts: [ProtectionHealthSummary.Account]
        var hasCalendarSelection: Bool
        var lastSuccessfulRefresh: Date?
        var oldestCoverage: Date?
        var refreshIssue: Bool
        var cachePersistenceFailed: Bool
        var reconnectAccountIDs: Set<String>
        var requiresGenericReconnect: Bool
    }

    struct Outcome: Sendable {
        var calendars: [UserCalendar]?
        var events: [CalendarEventOccurrence]?
        var accounts: [ConnectedCalendarAccount]
        var authState: CalendarProviderAuthState
        var statusMessage: String?
        var reconnectAccountIDs: Set<String>
        var requiresGenericReconnect: Bool
        var didSucceed: Bool
        var skipped: Bool
        var operationID: String
        fileprivate var revision: UInt64
        fileprivate var inputs: FetchInputs
    }

    fileprivate struct FetchInputs: Equatable, Sendable {
        let selectedCalendarIDs: Set<String>?
        let disabledAccountIDs: Set<String>
        let visibilityWindow: MenuVisibilityWindow

        init(_ settings: AppSettingsSnapshot) {
            selectedCalendarIDs = settings.hasExplicitCalendarSelection ? settings.selectedCalendarIDs : nil
            disabledAccountIDs = settings.disabledGoogleAccountIDs
            visibilityWindow = settings.visibilityWindow
        }
    }

    var provider: any CalendarProvider {
        didSet {
            providerGeneration &+= 1
            authorizationExpiredAccountIDs.removeAll()
            authorizationExpiredWithoutAccount = false
            failedRefreshCountsByAccount.removeAll()
            invalidate(reason: "reconnect")
        }
    }
    private(set) var providerGeneration: UInt64 = 0
    private(set) var legacyIdentityEvidence: [CalendarEventOccurrence] = []

    private let cacheStore: EventCacheStore
    private let diagnostics: DiagnosticsRecorder
    private let settings: @MainActor () -> AppSettingsSnapshot
    private let rememberProviderDefaults: @MainActor (Set<String>) -> Void
    private let now: @MainActor () -> Date

    private var isRefreshing = false
    private var trailingReason: String?
    private var failedRefreshCount = 0
    private var failedRefreshCountsByAccount: [String: Int] = [:]
    private var refreshMessage: String?
    private var authorizationMessage: String?
    private var authorizationExpiredAccountIDs: Set<String> = []
    private var authorizationExpiredWithoutAccount = false
    private var latestSuccessfulSnapshot: EventCacheEnvelope?
    private var latestSnapshotPersisted = false
    private var connectionFailureMessage: String?
    private var shouldCaptureLegacyIdentityEvidence: Bool
    private var legacyStateStore: ReminderStateStore?
    private var revision: UInt64 = 0
    private var fetchInputs: FetchInputs

    init(
        provider: any CalendarProvider,
        cacheStore: EventCacheStore,
        settings: @escaping @MainActor () -> AppSettingsSnapshot,
        now: @escaping @MainActor () -> Date = { Date() },
        diagnostics: DiagnosticsRecorder = .applicationDefault,
        legacyStateStore: ReminderStateStore? = nil,
        rememberProviderDefaults: @escaping @MainActor (Set<String>) -> Void = { _ in }
    ) {
        self.provider = provider
        self.cacheStore = cacheStore
        self.settings = settings
        self.rememberProviderDefaults = rememberProviderDefaults
        self.fetchInputs = FetchInputs(settings())
        self.now = now
        self.diagnostics = diagnostics
        self.legacyStateStore = legacyStateStore
        self.shouldCaptureLegacyIdentityEvidence = legacyStateStore != nil
    }

    func recordConnectionFailure(_ message: String?) {
        connectionFailureMessage = message
    }

    var reconnectAccountIDs: Set<String> {
        let snapshot = settings()
        return authorizationExpiredAccountIDs.filter { snapshot.isAccountEnabled($0) }
    }

    var requiresGenericReconnect: Bool {
        authorizationExpiredWithoutAccount
    }

    var isProtectionStale: Bool {
        let currentNow = now()
        return protectedAccountEntries.contains { entry in
            guard let fetchedAt = entry.fetchedAt else { return false }
            return isStale(accountID: entry.account.id, fetchedAt: fetchedAt, at: currentNow)
        }
    }

    func recordAccountRemoval(_ accountID: String) {
        authorizationExpiredAccountIDs.remove(accountID)
        failedRefreshCountsByAccount.removeValue(forKey: accountID)
    }

    var currentStatusMessage: String? {
        let needsReconnectMessage = !reconnectAccountIDs.isEmpty || requiresGenericReconnect
        let reconnectMessage = needsReconnectMessage && authorizationMessage == nil
            ? "Reconnect Google Calendar. Account authorization has expired."
            : nil
        let messages = [reconnectMessage, refreshHealthMessage, coverageStatusMessage].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    func protectionSnapshot(knownAccounts: [ConnectedCalendarAccount]) -> ProtectionSnapshot {
        let settings = settings()
        let currentNow = now()
        let retainedAccounts = latestSuccessfulSnapshot?.accounts ?? [:]
        let selectedCalendarIDs = settings.hasExplicitCalendarSelection
            ? settings.selectedCalendarIDs
            : settings.providerDefaultCalendarIDs
        let hasCalendarSelection = selectedCalendarIDs.map { !$0.isEmpty } ?? true
        let enabledKnownIDs = Set(knownAccounts.map(\.id)).union(retainedAccounts.keys).filter(settings.isAccountEnabled)
        var selectedCalendarIDsByAccount: [String: Set<String>] = [:]
        for accountID in enabledKnownIDs {
            let retainedCalendars = retainedAccounts[accountID]?.calendars ?? []
            let selectedForAccount = selectedCalendarIDs.map { selectedIDs in
                selectedIDs.filter { selectedID in
                    selectedID.hasPrefix("\(accountID)::") || retainedCalendars.contains { $0.id == selectedID }
                }
            } ?? Set(settings.protectedCalendars(from: retainedCalendars).map(\.id))
            selectedCalendarIDsByAccount[accountID] = selectedForAccount
        }
        var selectedAccountIDs = Set(selectedCalendarIDsByAccount.compactMap { $0.value.isEmpty ? nil : $0.key })
        if hasCalendarSelection && selectedAccountIDs.isEmpty && selectedCalendarIDs == nil {
            selectedAccountIDs = enabledKnownIDs
        }

        let accounts = selectedAccountIDs.sorted().map { accountID -> ProtectionHealthSummary.Account in
            guard let entry = retainedAccounts[accountID],
                  let fetchedAt = entry.fetchedAt,
                  let coverage = entry.coverage else {
                return .init(accountID: accountID, state: .unavailable)
            }
            let selectedIDs = selectedCalendarIDsByAccount[accountID] ?? []
            guard !selectedIDs.isEmpty,
                  selectedIDs.isSubset(of: coverage.calendarIDs),
                  currentNow >= coverage.window.start,
                  currentNow < coverage.window.end else {
                return .init(accountID: accountID, state: .unavailable)
            }
            let isStale = isStale(accountID: accountID, fetchedAt: fetchedAt, at: currentNow)
            return .init(accountID: accountID, state: isStale ? .stale : .protected)
        }
        let enabledEntries = retainedAccounts.values.filter { settings.isAccountEnabled($0.account.id) }
        let protectedIDs = Set(accounts.filter { $0.state != .unavailable }.map(\.accountID))
        return ProtectionSnapshot(
            accounts: accounts,
            hasCalendarSelection: hasCalendarSelection,
            lastSuccessfulRefresh: enabledEntries.compactMap(\.fetchedAt).max(),
            oldestCoverage: protectedIDs.compactMap { retainedAccounts[$0]?.fetchedAt }.min(),
            refreshIssue: currentStatusMessage != nil,
            cachePersistenceFailed: latestSuccessfulSnapshot != nil && !latestSnapshotPersisted,
            reconnectAccountIDs: reconnectAccountIDs,
            requiresGenericReconnect: requiresGenericReconnect
        )
    }

    private var refreshHealthMessage: String? {
        if let authorizationMessage { return authorizationMessage }
        if let protectedCoverageDate {
            let age = now().timeIntervalSince(protectedCoverageDate)
            let ageMessage: String?
            if age > 24 * 60 * 60 {
                ageMessage = "Calendar data is older than 24 hours."
            } else if age >= 5 * 60 {
                ageMessage = "Calendar data may be stale."
            } else {
                ageMessage = nil
            }
            if let ageMessage {
                if let refreshMessage { return "\(refreshMessage) \(ageMessage)" }
                return statusWithDurabilityWarning(ageMessage)
            }
        }
        return refreshMessage
    }

    private var protectedCoverageDate: Date? {
        protectedAccountEntries.compactMap(\.fetchedAt).min()
    }

    private func isStale(accountID: String, fetchedAt: Date, at date: Date) -> Bool {
        failedRefreshCountsByAccount[accountID, default: 0] >= 2 || date.timeIntervalSince(fetchedAt) >= 5 * 60
    }

    private var protectedAccountEntries: [CalendarAccountCache] {
        guard let retained = latestSuccessfulSnapshot else { return [] }
        let snapshot = settings()
        let requestedIDs = (snapshot.hasExplicitCalendarSelection
            ? snapshot.selectedCalendarIDs : snapshot.providerDefaultCalendarIDs
        )?.filter { calendarID in
            !snapshot.disabledGoogleAccountIDs.contains { calendarID.hasPrefix("\($0)::") }
        }
        if requestedIDs?.isEmpty == true { return [] }
        let currentNow = now()
        return retained.accounts.values.filter { entry in
            guard snapshot.isAccountEnabled(entry.account.id),
                  entry.fetchedAt != nil,
                  let coverage = entry.coverage,
                  currentNow >= coverage.window.start,
                  currentNow < coverage.window.end else { return false }
            let selectedIDs = Set(snapshot.protectedCalendars(from: entry.calendars).map(\.id))
            return !selectedIDs.isDisjoint(with: coverage.calendarIDs)
        }
    }

    private var coverageStatusMessage: String? {
        guard let retained = latestSuccessfulSnapshot else { return nil }
        let snapshot = settings()
        let requestedIDs = (snapshot.hasExplicitCalendarSelection
            ? snapshot.selectedCalendarIDs : snapshot.providerDefaultCalendarIDs
        )?.filter { calendarID in
            !snapshot.disabledGoogleAccountIDs.contains { calendarID.hasPrefix("\($0)::") }
        }
        if requestedIDs?.isEmpty == true { return nil }
        guard !retained.accounts.isEmpty else {
            return "Coverage for some selected calendars is unknown."
        }
        let knownCalendarIDs = Set(retained.accounts.values.flatMap { $0.calendars.map(\.id) })
        let unresolvedSelection = requestedIDs.map { !$0.subtracting(knownCalendarIDs).isEmpty } ?? false
        let currentNow = now()
        var unknown = unresolvedSelection
        var unfetched = false
        var outsideWindow = false
        for entry in retained.accounts.values where snapshot.isAccountEnabled(entry.account.id) {
            let selected = Set(snapshot.protectedCalendars(from: entry.calendars).map(\.id))
            guard !selected.isEmpty else {
                if entry.calendars.isEmpty && entry.coverage == nil && unresolvedSelection { unknown = true }
                continue
            }
            guard let coverage = entry.coverage else {
                unknown = true
                continue
            }
            if !selected.isSubset(of: coverage.calendarIDs) { unfetched = true }
            if !selected.isDisjoint(with: coverage.calendarIDs),
               currentNow < coverage.window.start || currentNow >= coverage.window.end {
                outsideWindow = true
            }
        }
        var messages: [String] = []
        if unfetched { messages.append("Some selected calendars have no fetched coverage.") }
        if unknown { messages.append("Coverage for some selected calendars is unknown.") }
        if outsideWindow { messages.append("The fetched coverage window does not cover the current time for some selected calendars.") }
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    private func statusWithDurabilityWarning(_ message: String) -> String {
        guard latestSuccessfulSnapshot != nil, !latestSnapshotPersisted else { return message }
        return "\(message) Offline protection could not be saved."
    }

    @discardableResult
    func settingsDidChange() -> Bool {
        let inputs = FetchInputs(settings())
        guard inputs != fetchInputs else { return false }
        fetchInputs = inputs
        invalidate(reason: "settings")
        return true
    }

    func invalidate(reason: String) {
        revision &+= 1
        if isRefreshing { trailingReason = LogPrivacy.refreshReason(reason) }
    }

    func cancelPendingRefreshes() {
        revision &+= 1
        trailingReason = nil
    }

    func isCurrent(_ outcome: Outcome) -> Bool {
        isCurrent(revision: outcome.revision, inputs: outcome.inputs)
    }

    private func isCurrent(revision: UInt64, inputs: FetchInputs) -> Bool {
        !Task.isCancelled && revision == self.revision && inputs == FetchInputs(settings())
    }

    func clearLegacyIdentityEvidence() {
        if let legacyStateStore {
            guard legacyStateStore.unresolvedLegacyCount == 0,
                  !legacyStateStore.isPersistencePending else { return }
        }
        legacyIdentityEvidence = []
        shouldCaptureLegacyIdentityEvidence = false
        legacyStateStore = nil
    }

    func refresh(
        reason: String,
        onOutcome: @MainActor (Outcome) -> Void = { _ in }
    ) async -> Outcome? {
        settingsDidChange()
        let reason = LogPrivacy.refreshReason(reason)
        if isRefreshing {
            AppLog.refresh.debug("refreshCoalesced reason=\(reason, privacy: .public)")
            trailingReason = reason
            return nil
        }
        isRefreshing = true
        trailingReason = nil
        defer { isRefreshing = false }

        if shouldCaptureLegacyIdentityEvidence {
            let evidence = await Self.readLegacyIdentityEvidence(from: cacheStore)
            if shouldCaptureLegacyIdentityEvidence {
                legacyIdentityEvidence = evidence
            }
            shouldCaptureLegacyIdentityEvidence = false
        }
        var outcome = await performRefresh(reason: reason)
        // A slow trailing cycle must not withhold completed protection from the scheduler.
        if let outcome, isCurrent(outcome) { onOutcome(outcome) }
        while !Task.isCancelled, let trailing = trailingReason {
            let trailingRevision = revision
            trailingReason = nil
            outcome = await performRefresh(reason: trailing)
            if let outcome, isCurrent(outcome) { onOutcome(outcome) }
            if Task.isCancelled, trailingReason == nil, revision == trailingRevision {
                trailingReason = trailing
            }
        }
        return Task.isCancelled ? nil : outcome
    }

    func takePendingRefreshReason() -> String? {
        guard !isRefreshing else { return nil }
        defer { trailingReason = nil }
        return trailingReason
    }

    nonisolated private static func readLegacyIdentityEvidence(from store: EventCacheStore) async -> [CalendarEventOccurrence] {
        (try? store.loadLegacyIdentityEvidence()) ?? []
    }

    private func performRefresh(reason: String) async -> Outcome? {
        guard !Task.isCancelled else { return nil }
        let operationID = UUID().uuidString.lowercased()
        let currentNow = now()
        var terminalOutcomeRecorded = false
        defer {
            if !terminalOutcomeRecorded {
                let abandonedAt = now()
                diagnostics.recordEvent("refresh_abandoned", metadata: [
                    "reason": reason,
                    "outcome": Task.isCancelled ? "cancelled" : "obsolete",
                    "operation": operationID,
                    "duration": elapsed(from: currentNow, to: abandonedAt),
                    "evaluated": ISO8601DateFormatter.stableString(from: abandonedAt)
                ])
            }
        }
        diagnostics.recordEvent("refresh_started", metadata: [
            "reason": reason,
            "operation": operationID,
            "evaluated": ISO8601DateFormatter.stableString(from: currentNow)
        ])
        var snapshot = settings()
        let requestRevision = revision
        let requestInputs = FetchInputs(snapshot)
        let provider = provider
        var authState = await provider.authState
        guard isCurrent(revision: requestRevision, inputs: requestInputs) else { return nil }
        var accounts = await provider.accounts()
        guard isCurrent(revision: requestRevision, inputs: requestInputs) else { return nil }
        AppLog.refresh.info("refreshStart reason=\(reason, privacy: .public) authState=\(LogPrivacy.authState(authState), privacy: .public) visibilityDays=\(snapshot.visibilityWindow.days, privacy: .public)")

        if authState.blocksCalendarRefresh {
            let completedAt = now()
            failedRefreshCount = 0
            let cached = loadCache(now: completedAt, snapshot: snapshot)
            authorizationMessage = connectionFailureMessage ?? statusMessage(for: authState)
            refreshMessage = nil
            AppLog.refresh.info("refreshSkipped reason=\(reason, privacy: .public) authState=\(LogPrivacy.authState(authState), privacy: .public) cacheEvents=\(cached?.events.count ?? 0, privacy: .public)")
            diagnostics.recordEvent("refresh_failed", metadata: [
                "reason": reason,
                "failedCount": "0",
                "error": blockedRefreshError(for: authState),
                "operation": operationID,
                "duration": elapsed(from: currentNow, to: completedAt),
                "evaluated": ISO8601DateFormatter.stableString(from: completedAt)
            ])
            terminalOutcomeRecorded = true
            return Outcome(
                calendars: nil,
                events: cached?.events,
                accounts: accounts,
                authState: authState,
                statusMessage: currentStatusMessage,
                reconnectAccountIDs: reconnectAccountIDs,
                requiresGenericReconnect: requiresGenericReconnect,
                didSucceed: false,
                skipped: true,
                operationID: operationID,
                revision: requestRevision,
                inputs: requestInputs
            )
        }

        let window = CalendarFetchWindow.protective(now: currentNow, visibilityWindow: snapshot.visibilityWindow)

        do {
            let catalog = try await provider.calendarCatalog()
            guard isCurrent(revision: requestRevision, inputs: requestInputs) else { return nil }
            let previous = catalog.accountResults == nil ? nil : loadUnfilteredCache()
            let hadMemory = latestSuccessfulSnapshot != nil
            let calendars = retainedCalendars(catalog: catalog, previous: previous)
            if let defaults = providerDefaults(catalog: catalog, previous: previous, snapshot: snapshot) {
                snapshot.recordProviderDefaultCalendarIDs(defaults)
                rememberProviderDefaults(defaults)
            }
            let protectedCalendars = snapshot.protectedCalendars(from: calendars)
            let readyAccounts = Set((catalog.accountResults ?? []).compactMap { result -> String? in
                guard snapshot.isAccountEnabled(result.account.id), case .success = result.result else { return nil }
                return result.account.id
            })
            let result = try await provider.refreshResult(in: window, calendars: protectedCalendars, accountIDs: readyAccounts)
            guard isCurrent(revision: requestRevision, inputs: requestInputs) else { return nil }
            authState = await provider.authState
            guard isCurrent(revision: requestRevision, inputs: requestInputs) else { return nil }
            accounts = await provider.accounts()
            guard isCurrent(revision: requestRevision, inputs: requestInputs) else { return nil }
            let completedAt = now()
            if case .accounts(let results) = result {
                let outcome = acceptAccountRefresh(
                    results, catalog: catalog, previous: previous, hadMemory: hadMemory,
                    calendars: calendars, snapshot: snapshot, authState: authState,
                    completedAt: completedAt, startedAt: currentNow, operationID: operationID,
                    reason: reason, requestRevision: requestRevision, requestInputs: requestInputs
                )
                terminalOutcomeRecorded = true
                return outcome
            }
            guard case .complete(let events) = result else { return nil }
            if catalog.isComplete {
                authorizationExpiredAccountIDs.removeAll()
                authorizationExpiredWithoutAccount = false
            }
            failedRefreshCount = 0
            connectionFailureMessage = nil
            let extractor = MeetingLinkExtractor()
            let selectedIDs = Set(protectedCalendars.map(\.id))
            var accountCoverage: [String: CalendarAccountCache] = [:]
            for account in accounts where snapshot.isAccountEnabled(account.id) {
                failedRefreshCountsByAccount.removeValue(forKey: account.id)
                let ownedCalendars = calendars.filter { $0.accountID == account.id }
                accountCoverage[account.id] = CalendarAccountCache(
                    account: account, calendars: ownedCalendars, fetchedAt: completedAt,
                    coverage: .init(calendarIDs: Set(ownedCalendars.map(\.id)).intersection(selectedIDs), window: window)
                )
            }
            let completed = EventCacheEnvelope(
                cachedAt: completedAt,
                events: events.map { $0.privacyPreservingCacheCopy(detectedLinks: extractor.extractLinks(from: $0)) },
                accounts: accountCoverage
            )
            latestSuccessfulSnapshot = completed
            latestSnapshotPersisted = saveCache(envelope: completed, snapshot: snapshot)
            authorizationMessage = statusMessage(for: authState)
            refreshMessage = latestSnapshotPersisted
                ? nil
                : "Calendar is current, but offline protection could not be saved."
            AppLog.refresh.info("refreshSuccess reason=\(reason, privacy: .public) calendars=\(calendars.count, privacy: .public) events=\(events.count, privacy: .public)")
            diagnostics.recordEvent("refresh_succeeded", metadata: [
                "reason": reason,
                "calendars": "\(calendars.count)",
                "events": "\(events.count)",
                "operation": operationID,
                "duration": elapsed(from: currentNow, to: completedAt),
                "evaluated": ISO8601DateFormatter.stableString(from: completedAt)
            ])
            terminalOutcomeRecorded = true
            return Outcome(
                calendars: calendars,
                events: events,
                accounts: accounts,
                authState: authState,
                statusMessage: currentStatusMessage,
                reconnectAccountIDs: reconnectAccountIDs,
                requiresGenericReconnect: requiresGenericReconnect,
                didSucceed: true,
                skipped: false,
                operationID: operationID,
                revision: requestRevision,
                inputs: requestInputs
            )
        } catch {
            guard isCurrent(revision: requestRevision, inputs: requestInputs) else { return nil }
            let failedAt = now()
            let cached = loadCache(now: failedAt, snapshot: snapshot)
            authorizationMessage = authFailureStatusMessage(for: error)
            if authorizationMessage != nil {
                if case let CalendarProviderError.authExpired(reason) = error {
                    authState = .expired(reason: reason)
                    authorizationExpiredWithoutAccount = true
                }
                failedRefreshCount = 0
                refreshMessage = nil
            } else {
                failedRefreshCount += 1
                let affectedIDs = Set(accounts.map(\.id)).union(latestSuccessfulSnapshot?.accounts.keys.map { $0 } ?? [])
                for accountID in affectedIDs where snapshot.isAccountEnabled(accountID) {
                    failedRefreshCountsByAccount[accountID, default: 0] += 1
                }
                refreshMessage = refreshStatusMessage(for: error, cached: cached)
            }
            let cachedEvents = cached?.events
            AppLog.refresh.error("refreshFailure reason=\(reason, privacy: .public) error=\(LogPrivacy.errorClass(error), privacy: .public) failedCount=\(self.failedRefreshCount, privacy: .public) cacheLoaded=\(LogPrivacy.bool(cachedEvents != nil), privacy: .public)")
            diagnostics.recordEvent("refresh_failed", metadata: [
                "reason": reason,
                "failedCount": "\(failedRefreshCount)",
                "error": LogPrivacy.errorClass(error),
                "operation": operationID,
                "duration": elapsed(from: currentNow, to: failedAt),
                "evaluated": ISO8601DateFormatter.stableString(from: failedAt)
            ])
            terminalOutcomeRecorded = true
            return Outcome(
                calendars: nil,
                events: cachedEvents,
                accounts: accounts,
                authState: authState,
                statusMessage: currentStatusMessage,
                reconnectAccountIDs: reconnectAccountIDs,
                requiresGenericReconnect: requiresGenericReconnect,
                didSucceed: false,
                skipped: false,
                operationID: operationID,
                revision: requestRevision,
                inputs: requestInputs
            )
        }
    }

    private func providerDefaults(
        catalog: CalendarCatalog,
        previous: EventCacheEnvelope?,
        snapshot: AppSettingsSnapshot
    ) -> Set<String>? {
        if catalog.isComplete { return Set(catalog.calendars.filter(\.isSelected).map(\.id)) }
        guard let results = catalog.accountResults else { return nil }
        let priorCalendars = (previous?.accounts.values.flatMap(\.calendars) ?? [])
        var defaults = snapshot.providerDefaultCalendarIDs
            ?? Set((previous?.events ?? []).map(\.calendarID)).union(priorCalendars.filter(\.isSelected).map(\.id))
        var hasCompleteAccount = false
        for item in results {
            guard case .success(let calendars) = item.result else { continue }
            let priorIDs = Set(priorCalendars.filter { $0.accountID == item.account.id }.map(\.id))
                .union((previous?.events ?? []).filter { $0.accountID == item.account.id }.map(\.calendarID))
            defaults.subtract(priorIDs.union(calendars.map(\.id)))
            defaults.formUnion(calendars.filter(\.isSelected).map(\.id))
            hasCompleteAccount = true
        }
        return hasCompleteAccount ? defaults : nil
    }

    private func retainedCalendars(catalog: CalendarCatalog, previous: EventCacheEnvelope?) -> [UserCalendar] {
        guard let results = catalog.accountResults else { return catalog.calendars }
        let completeIDs = Set(results.compactMap { item -> String? in
            if case .success = item.result { return item.account.id }
            return nil
        })
        let knownIDs = Set(results.map { $0.account.id })
        var calendars = catalog.calendars
        var identifiers = Set(calendars.map(\.id))
        for (accountID, entry) in previous?.accounts ?? [:] {
            guard !completeIDs.contains(accountID),
                  catalog.inventoryFailure != nil || knownIDs.contains(accountID) else { continue }
            for calendar in entry.calendars where identifiers.insert(calendar.id).inserted {
                calendars.append(calendar)
            }
        }
        return calendars
    }

    private func acceptAccountRefresh(
        _ results: [CalendarRefreshResult.Account],
        catalog: CalendarCatalog,
        previous: EventCacheEnvelope?,
        hadMemory: Bool,
        calendars: [UserCalendar],
        snapshot: AppSettingsSnapshot,
        authState: CalendarProviderAuthState,
        completedAt: Date,
        startedAt: Date,
        operationID: String,
        reason: String,
        requestRevision: UInt64,
        requestInputs: FetchInputs
    ) -> Outcome {
        let discovery = (catalog.accountResults ?? []).filter { snapshot.isAccountEnabled($0.account.id) }
        let knownIDs = Set(discovery.map { $0.account.id })
        var merged = previous ?? EventCacheEnvelope(cachedAt: completedAt, events: [])
        for event in merged.events where merged.accounts[event.accountID] == nil {
            merged.accounts[event.accountID] = CalendarAccountCache(
                account: ConnectedCalendarAccount(id: event.accountID, displayName: event.accountID),
                calendars: [], fetchedAt: merged.cachedAt, coverage: nil
            )
        }
        if catalog.inventoryFailure == nil {
            merged.events.removeAll { !knownIDs.contains($0.accountID) }
            merged.accounts = merged.accounts.filter { knownIDs.contains($0.key) }
        }
        var failedIDs: Set<String> = []
        var expiredIDs: Set<String> = []
        var readyIDs: Set<String> = []
        for item in discovery {
            var entry = merged.accounts[item.account.id] ?? CalendarAccountCache(
                account: item.account, calendars: [], fetchedAt: nil, coverage: nil
            )
            switch item.result {
            case .success(let currentCalendars):
                entry.account = item.account
                entry.calendars = currentCalendars
                readyIDs.insert(item.account.id)
            case .failure(let failure):
                failedIDs.insert(item.account.id)
                if failure.authorizationExpired { expiredIDs.insert(item.account.id) }
            }
            merged.accounts[item.account.id] = entry
        }
        var completedIDs: Set<String> = []
        for item in results where knownIDs.contains(item.accountID) {
            switch item.result {
            case .success(let value):
                guard readyIDs.contains(item.accountID), var entry = merged.accounts[item.accountID] else { continue }
                merged.events.removeAll { $0.accountID == item.accountID }
                merged.events += value.events
                entry.fetchedAt = completedAt
                entry.coverage = .init(calendarIDs: value.fetchedCalendarIDs, window: value.window)
                merged.accounts[item.accountID] = entry
                completedIDs.insert(item.accountID)
            case .failure(let failure):
                failedIDs.insert(item.accountID)
                if failure.authorizationExpired { expiredIDs.insert(item.accountID) }
            }
        }
        failedIDs.formUnion(readyIDs.subtracting(completedIDs))
        if catalog.inventoryFailure != nil {
            failedIDs.formUnion(merged.accounts.keys.filter(snapshot.isAccountEnabled))
        } else {
            failedRefreshCountsByAccount = failedRefreshCountsByAccount.filter { knownIDs.contains($0.key) }
        }
        // A complete account result is independent of other accounts or an incomplete inventory.
        failedIDs.subtract(completedIDs)
        for accountID in completedIDs {
            failedRefreshCountsByAccount.removeValue(forKey: accountID)
        }
        for accountID in failedIDs {
            failedRefreshCountsByAccount[accountID, default: 0] += 1
        }
        if let membership = catalog.accountResults, catalog.inventoryFailure == nil {
            authorizationExpiredAccountIDs.formIntersection(Set(membership.map { $0.account.id }))
        }
        authorizationExpiredAccountIDs.subtract(completedIDs)
        authorizationExpiredAccountIDs.formUnion(expiredIDs)
        let incomplete = !failedIDs.isEmpty || catalog.inventoryFailure != nil
        if catalog.inventoryFailure?.authorizationExpired == true {
            authorizationExpiredWithoutAccount = true
        } else if !incomplete && catalog.isComplete {
            authorizationExpiredWithoutAccount = false
        }
        var accountIdentities = Dictionary((catalog.accountResults ?? []).map { ($0.account.id, $0.account) }, uniquingKeysWith: { first, _ in first })
        for item in catalog.accountResults ?? [] {
            if case .failure = item.result, let previousAccount = previous?.accounts[item.account.id]?.account {
                accountIdentities[item.account.id] = previousAccount
            }
        }
        if catalog.inventoryFailure != nil {
            for (accountID, entry) in previous?.accounts ?? [:] where accountIdentities[accountID] == nil {
                accountIdentities[accountID] = entry.account
            }
        }
        let accounts = accountIdentities.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        if incomplete && completedIDs.isEmpty && previous == nil {
            failedRefreshCount += 1
            authorizationMessage = statusMessage(for: authState)
            refreshMessage = "Calendar refresh failed; no usable local cache is available."
            diagnostics.recordEvent("refresh_failed", metadata: [
                "reason": reason, "failedCount": "\(failedRefreshCount)", "error": "calendar_request_failed",
                "operation": operationID, "duration": elapsed(from: startedAt, to: completedAt),
                "evaluated": ISO8601DateFormatter.stableString(from: completedAt)
            ])
            return Outcome(
                calendars: calendars, events: nil, accounts: accounts, authState: authState,
                statusMessage: currentStatusMessage, reconnectAccountIDs: reconnectAccountIDs,
                requiresGenericReconnect: requiresGenericReconnect,
                didSucceed: false, skipped: false,
                operationID: operationID,
                revision: requestRevision, inputs: requestInputs
            )
        }
        merged = cacheStore.retainedSnapshot(
            merged, now: completedAt, retentionDays: snapshot.visibilityWindow.days, settings: snapshot
        )
        merged.events.sort { $0.id < $1.id }
        merged.cachedAt = merged.accounts.values.compactMap(\.fetchedAt).min() ?? previous?.cachedAt ?? completedAt
        let events = merged.events
        let extractor = MeetingLinkExtractor()
        merged.events = events.map { $0.privacyPreservingCacheCopy(detectedLinks: extractor.extractLinks(from: $0)) }
        let wasPersisted = hadMemory ? latestSnapshotPersisted : previous != nil
        let needsSave = merged != previous || !wasPersisted
        latestSuccessfulSnapshot = merged
        latestSnapshotPersisted = needsSave ? saveCache(envelope: merged, snapshot: snapshot) : wasPersisted
        failedRefreshCount = incomplete ? failedRefreshCount + 1 : 0
        if !incomplete { connectionFailureMessage = nil }
        authorizationMessage = statusMessage(for: authState)
        if incomplete {
            refreshMessage = statusWithDurabilityWarning("Some calendar accounts could not refresh; protection is incomplete.")
        } else {
            refreshMessage = latestSnapshotPersisted ? nil : "Calendar is current, but offline protection could not be saved."
        }
        diagnostics.recordEvent(incomplete ? "refresh_failed" : "refresh_succeeded", metadata: incomplete ? [
            "reason": reason, "failedCount": "\(failedRefreshCount)", "error": "calendar_request_failed",
            "operation": operationID, "duration": elapsed(from: startedAt, to: completedAt),
            "evaluated": ISO8601DateFormatter.stableString(from: completedAt)
        ] : [
            "reason": reason, "calendars": "\(calendars.count)", "events": "\(events.count)",
            "operation": operationID, "duration": elapsed(from: startedAt, to: completedAt),
            "evaluated": ISO8601DateFormatter.stableString(from: completedAt)
        ])
        return Outcome(
            calendars: calendars, events: events, accounts: accounts, authState: authState,
            statusMessage: currentStatusMessage, reconnectAccountIDs: reconnectAccountIDs,
            requiresGenericReconnect: requiresGenericReconnect,
            didSucceed: !incomplete, skipped: false,
            operationID: operationID,
            revision: requestRevision, inputs: requestInputs
        )
    }

    private func elapsed(from start: Date, to end: Date) -> String {
        String(max(0, end.timeIntervalSince(start)))
    }

    private func blockedRefreshError(for authState: CalendarProviderAuthState) -> String {
        switch authState {
        case .needsConfiguration:
            "calendar_not_configured"
        case .expired:
            "calendar_auth_expired"
        case .authenticating, .disconnected, .connected:
            "calendar_disconnected"
        }
    }

    private func loadCache(now: Date, snapshot: AppSettingsSnapshot) -> EventCacheEnvelope? {
        guard let previous = loadUnfilteredCache() else { return nil }
        return cacheStore.retainedSnapshot(
            previous, now: now, retentionDays: snapshot.visibilityWindow.days, settings: snapshot
        )
    }

    private func loadUnfilteredCache() -> EventCacheEnvelope? {
        if let latestSuccessfulSnapshot { return latestSuccessfulSnapshot }
        do {
            let loaded = try cacheStore.loadUnfiltered()
            latestSuccessfulSnapshot = loaded
            latestSnapshotPersisted = loaded != nil
            return loaded
        } catch {
            diagnostics.recordEvent("cache_load_failed", metadata: ["error": LogPrivacy.errorClass(error)])
            return nil
        }
    }

    private func saveCache(envelope: EventCacheEnvelope, snapshot: AppSettingsSnapshot) -> Bool {
        let events = envelope.events
        if let legacyStateStore {
            _ = legacyStateStore.reconcileLegacyStates(
                events: events,
                cachedEvents: legacyIdentityEvidence,
                now: now()
            )
            guard !legacyStateStore.isPersistencePending else {
                diagnostics.recordEvent("legacy_state_cache_deferred")
                return false
            }
        }
        do {
            try cacheStore.save(envelope: envelope, settings: snapshot)
            return true
        } catch {
            diagnostics.recordEvent("cache_save_failed", metadata: ["error": LogPrivacy.errorClass(error)])
            return false
        }
    }

    private func refreshStatusMessage(for error: Error, cached: EventCacheEnvelope?) -> String {
        if cached == nil {
            return "Calendar refresh failed; no usable local cache is available."
        }
        if latestSuccessfulSnapshot != nil && !latestSnapshotPersisted {
            return "Calendar refresh failed; using meetings held in memory. Offline protection could not be saved."
        }
        if failedRefreshCount >= 2 {
            return "Calendar refresh is failing; using local cache."
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

    private func statusMessage(for authState: CalendarProviderAuthState) -> String? {
        switch authState {
        case .disconnected, .needsConfiguration:
            "Connect Google Calendar to start protecting meetings."
        case .authenticating, .connected:
            nil
        case .expired(let reason):
            "Calendar authorization expired: \(reason)"
        }
    }
}

extension CalendarProviderAuthState {
    var blocksCalendarRefresh: Bool {
        switch self {
        case .disconnected, .needsConfiguration:
            true
        case .authenticating, .connected, .expired:
            false
        }
    }
}
