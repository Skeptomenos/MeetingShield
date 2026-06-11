import Foundation

/// Owns the calendar refresh state machine: auth gating, fetch window,
/// cache fallback, failure counting, status messages, and re-entrancy.
/// Extracted from MeetingShieldController so the most failure-prone logic in
/// the app is deterministic and unit-testable.
@MainActor
final class RefreshCoordinator {
    struct Outcome: Sendable {
        /// New calendars, or nil to keep the controller's current list.
        var calendars: [UserCalendar]?
        /// New events (fresh or cache-loaded), or nil to keep current.
        var events: [CalendarEventOccurrence]?
        var accounts: [ConnectedCalendarAccount]
        var authState: CalendarProviderAuthState
        var statusMessage: String?
        var didSucceed: Bool
        var skipped: Bool
    }

    var provider: any CalendarProvider

    private let cacheStore: EventCacheStore
    private let settings: @MainActor () -> AppSettingsSnapshot
    private let now: @MainActor () -> Date

    private var isRefreshing = false
    private var trailingReason: String?
    private var failedRefreshCount = 0
    private var lastSuccessfulRefresh: Date?
    private var connectionFailureMessage: String?

    init(
        provider: any CalendarProvider,
        cacheStore: EventCacheStore,
        settings: @escaping @MainActor () -> AppSettingsSnapshot,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.provider = provider
        self.cacheStore = cacheStore
        self.settings = settings
        self.now = now
    }

    func recordConnectionFailure(_ message: String?) {
        connectionFailureMessage = message
    }

    /// Runs a refresh, coalescing concurrent requests: while one refresh is in
    /// flight, further requests collapse into a single trailing refresh.
    /// Returns nil for callers whose request was coalesced away.
    func refresh(reason: String) async -> Outcome? {
        if isRefreshing {
            AppLog.refresh.debug("refreshCoalesced reason=\(reason, privacy: .public)")
            trailingReason = reason
            return nil
        }
        isRefreshing = true
        defer { isRefreshing = false }

        var outcome = await performRefresh(reason: reason)
        while let trailing = trailingReason {
            trailingReason = nil
            outcome = await performRefresh(reason: trailing)
        }
        return outcome
    }

    private func performRefresh(reason: String) async -> Outcome {
        DiagnosticsRecorder.record("refresh_started", metadata: ["reason": reason])
        let currentNow = now()
        let snapshot = settings()
        var authState = await provider.authState
        var accounts = await provider.accounts()
        AppLog.refresh.info("refreshStart reason=\(reason, privacy: .public) authState=\(LogPrivacy.authState(authState), privacy: .public) visibleWindowDays=\(snapshot.visibleWindowDays, privacy: .public)")

        if authState.blocksCalendarRefresh {
            failedRefreshCount = 0
            let cached = loadCache(now: currentNow, snapshot: snapshot)
            AppLog.refresh.info("refreshSkipped reason=\(reason, privacy: .public) authState=\(LogPrivacy.authState(authState), privacy: .public) cacheEvents=\(cached?.count ?? 0, privacy: .public)")
            return Outcome(
                calendars: nil,
                events: cached,
                accounts: accounts,
                authState: authState,
                statusMessage: connectionFailureMessage ?? statusMessage(for: authState),
                didSucceed: false,
                skipped: true
            )
        }

        let window = CalendarFetchWindow.protective(now: currentNow, visibilityWindow: snapshot.visibilityWindow)

        do {
            let calendars = try await provider.calendars()
            let protectedCalendars = snapshot.protectedCalendars(from: calendars)
            let events = try await provider.refresh(in: window, calendars: protectedCalendars)
            failedRefreshCount = 0
            connectionFailureMessage = nil
            lastSuccessfulRefresh = currentNow
            authState = await provider.authState
            accounts = await provider.accounts()
            saveCache(events: events, snapshot: snapshot, now: currentNow)
            AppLog.refresh.info("refreshSuccess reason=\(reason, privacy: .public) calendars=\(calendars.count, privacy: .public) events=\(events.count, privacy: .public)")
            DiagnosticsRecorder.record("refresh_succeeded", metadata: [
                "reason": reason,
                "calendars": "\(calendars.count)",
                "events": "\(events.count)"
            ])
            return Outcome(
                calendars: calendars,
                events: events,
                accounts: accounts,
                authState: authState,
                statusMessage: statusMessage(for: authState),
                didSucceed: true,
                skipped: false
            )
        } catch {
            var message: String?
            if let authFailureMessage = authFailureStatusMessage(for: error) {
                if case let CalendarProviderError.authExpired(reason) = error {
                    authState = .expired(reason: reason)
                }
                failedRefreshCount = 0
                message = authFailureMessage
            } else {
                failedRefreshCount += 1
                message = refreshStatusMessage(for: error, now: currentNow)
            }
            var cachedEvents: [CalendarEventOccurrence]?
            if let cached = try? cacheStore.load(
                now: currentNow,
                visibleWindowDays: snapshot.visibleWindowDays,
                settings: snapshot
            ) {
                cachedEvents = cached.events
                if authFailureStatusMessage(for: error) == nil && cacheStore.isStale(cached, now: currentNow) {
                    message = "Calendar cache is older than 24 hours."
                }
            }
            AppLog.refresh.error("refreshFailure reason=\(reason, privacy: .public) error=\(LogPrivacy.errorClass(error), privacy: .public) failedCount=\(self.failedRefreshCount, privacy: .public) cacheLoaded=\(LogPrivacy.bool(cachedEvents != nil), privacy: .public)")
            DiagnosticsRecorder.record("refresh_failed", metadata: [
                "reason": reason,
                "failedCount": "\(failedRefreshCount)",
                "error": LogPrivacy.errorClass(error)
            ])
            return Outcome(
                calendars: nil,
                events: cachedEvents,
                accounts: accounts,
                authState: authState,
                statusMessage: message,
                didSucceed: false,
                skipped: false
            )
        }
    }

    private func loadCache(now: Date, snapshot: AppSettingsSnapshot) -> [CalendarEventOccurrence]? {
        guard let cached = try? cacheStore.load(
            now: now,
            visibleWindowDays: snapshot.visibleWindowDays,
            settings: snapshot
        ) else {
            return nil
        }
        return cached.events
    }

    private func saveCache(events: [CalendarEventOccurrence], snapshot: AppSettingsSnapshot, now: Date) {
        let extractor = MeetingLinkExtractor()
        let detected = Dictionary(
            events.map { event in (event.id, extractor.extractLinks(from: event)) },
            uniquingKeysWith: { first, _ in first }
        )
        do {
            try cacheStore.save(events: events, detectedLinks: detected, settings: snapshot, now: now)
        } catch {
            AppLog.refresh.error("cacheSaveFailed error=\(LogPrivacy.errorClass(error), privacy: .public)")
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
