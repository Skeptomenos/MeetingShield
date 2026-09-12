import Foundation
import Testing
import UserNotifications
@testable import MeetingShield

@Suite("Protection health summary")
@MainActor
struct ProtectionHealthSummaryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Healthy protection reports current coverage and scheduler liveness")
    func healthy() {
        let summary = makeSummary(accounts: [account("a", .protected), account("b", .protected)])

        #expect(summary.level == .healthy)
        #expect(summary.title == "Protection healthy")
        #expect(summary.coverageText == "2 of 2 accounts protected · checked 1m ago")
        #expect(summary.scheduleText == "Next alert in 5m · scheduler current")
        #expect(summary.actions.isEmpty)
    }

    @Test("One unavailable account makes protection partial")
    func partialAccount() {
        let summary = makeSummary(accounts: [account("a", .protected), account("b", .unavailable)])

        #expect(summary.level == .partial)
        #expect(summary.coverageText == "1 of 2 accounts protected · checked 1m ago")
        #expect(summary.actions == [.retry])
    }

    @Test("No usable cache makes protection unavailable")
    func noCache() {
        let summary = ProtectionHealthSummary.derive(from: .init(
            connection: .connected,
            accounts: [account("a", .unavailable)],
            hasCalendarSelection: true,
            lastSuccessfulRefresh: nil,
            oldestCoverage: nil,
            refreshIssue: true,
            schedulerLastEvaluation: now.addingTimeInterval(-30),
            nextReminder: nil,
            notification: .available,
            storageWarningCount: 0,
            now: now
        ))

        #expect(summary.level == .unavailable)
        #expect(summary.title == "Protection unavailable")
        #expect(summary.coverageText == "No protected calendar coverage")
        #expect(summary.actions == [.retry])
    }

    @Test("Stale coverage is visible even when every account has retained data")
    func staleCoverage() {
        let summary = makeSummary(
            accounts: [account("a", .stale)], oldestCoverage: now.addingTimeInterval(-600), refreshIssue: true
        )

        #expect(summary.level == .partial)
        #expect(summary.coverageText == "1 of 1 account protected · checked 10m ago")
        #expect(summary.actions == [.retry])
    }

    @Test("A stalled scheduler degrades otherwise healthy protection")
    func stalledScheduler() {
        let summary = makeSummary(
            accounts: [account("a", .protected)], schedulerLastEvaluation: now.addingTimeInterval(-121)
        )

        #expect(summary.level == .partial)
        #expect(summary.scheduleText == "Next alert in 5m · scheduler delayed")
        #expect(summary.actions == [.retry])
    }

    @Test("Storage failure routes to Settings")
    func storageFailure() {
        let summary = makeSummary(accounts: [account("a", .protected)], storageWarningCount: 2)

        #expect(summary.level == .partial)
        #expect(summary.actions == [.settings])
        #expect(summary.copyText.contains("Storage: 2 warnings"))
    }

    @Test("A blocked required notification channel routes to Settings")
    func blockedNotification() {
        let summary = makeSummary(accounts: [account("a", .protected)], notification: .blocked)

        #expect(summary.level == .partial)
        #expect(summary.actions == [.settings])
        #expect(summary.copyText.contains("Notifications: Blocked"))
    }

    @Test("Partial account authorization routes to Reconnect and identifies the affected account safely")
    func partialAccountAuthorization() {
        let summary = makeSummary(accounts: [
            account("private-a@example.com", .stale),
            account("private-b@example.com", .protected)
        ], reconnectAccountIDs: ["private-a@example.com"])

        #expect(summary.level == .partial)
        #expect(summary.actions == [.reconnect, .retry])
        #expect(summary.copyText.contains("Authorization: Reconnect required for 1 account"))
        #expect(summary.copyText.contains("Account \(LogPrivacy.redactedID("private-a@example.com")): stale; reconnect required"))
        #expect(!summary.copyText.contains("private-a@example.com"))
    }

    @Test("Connection and Settings faults keep both recovery routes")
    func combinedRecoveryRoutes() {
        let summary = makeSummary(
            connection: .expired,
            accounts: [account("a", .unavailable)],
            notification: .blocked,
            storageWarningCount: 1
        )

        #expect(summary.actions == [.reconnect, .retry, .settings])
    }

    @Test("Disconnected and empty-selection states offer the correct recovery route", arguments: [true, false])
    func unavailableRoutes(disconnected: Bool) {
        let summary = makeSummary(
            connection: disconnected ? .disconnected : .connected,
            accounts: [], hasCalendarSelection: disconnected
        )

        #expect(summary.level == .unavailable)
        #expect(summary.actions == [disconnected ? .reconnect : .settings])
    }

    @Test("Copied output is bounded and excludes private account, meeting, and link values")
    func copiedOutputIsBoundedAndPrivate() {
        let privateValues = [
            "private.person@example.com", "Executive acquisition discussion",
            "https://meet.google.com/private-room"
        ]
        let accounts = (0..<20).map { account("private.person+\($0)@example.com", $0 == 0 ? .unavailable : .protected) }
        let summary = makeSummary(accounts: accounts)

        #expect(summary.copyText.utf8.count <= ProtectionHealthSummary.maximumCopyBytes)
        #expect(summary.copyText.contains("12 more accounts omitted"))
        #expect(summary.copyText.contains("Visible delivery, Focus behavior, user attention, browser launch, and attendance are not observable here."))
        for value in privateValues + accounts.map(\.accountID) {
            #expect(!summary.copyText.contains(value))
        }
    }

    @Test("The bounded copy keeps a reconnect-affected account visible")
    func copiedOutputPrioritizesReconnectAccount() throws {
        let accounts = (0..<20).map { account("private.person+\($0)@example.com", .protected) }
        let affectedID = try #require(accounts.map(\.accountID).max {
            LogPrivacy.redactedID($0) < LogPrivacy.redactedID($1)
        })
        let summary = makeSummary(accounts: accounts, reconnectAccountIDs: [affectedID])

        #expect(summary.copyText.contains("Account \(LogPrivacy.redactedID(affectedID)): protected; reconnect required"))
        #expect(summary.copyText.split(separator: "\n").count { $0.hasPrefix("Account ") } == 8)
        #expect(summary.copyText.utf8.count <= ProtectionHealthSummary.maximumCopyBytes)
        #expect(!summary.copyText.contains(affectedID))
    }

    @Test("The controller copy action writes exactly the current safe summary")
    func controllerCopiesCurrentSummary() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let domain = "ProtectionHealthSummaryTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let settings = AppSettingsStore(domainName: domain)
        let capture = ClipboardCapture()
        let controller = MeetingShieldController(
            settingsStore: settings,
            provider: DisconnectedCalendarProvider(),
            reminderStateStore: ReminderStateStore(fileURL: directory.appending(path: "state.json")),
            cacheStore: EventCacheStore(fileURL: directory.appending(path: "cache.json")),
            notificationService: NoopNotificationService(),
            now: { now }, refreshMenuBar: {},
            copyDiagnosticSummary: { capture.value = $0 }
        )

        controller.copyProtectionSummary()

        #expect(capture.value == controller.protectionHealthSummary.copyText)
        #expect(capture.value?.contains("@") == false)
    }

    @Test("The controller derives healthy coverage and later detects a stalled scheduler")
    func controllerDerivesRefreshAndSchedulerHealth() async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let domain = "ProtectionHealthControllerTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let clock = AdvancingTestClock(now)
        let settings = AppSettingsStore(domainName: domain)
        settings.update {
            $0.defaultLeadTime = 30
            $0.wakeGraceEnabled = false
        }
        let controller = MeetingShieldController(
            settingsStore: settings,
            provider: MockCalendarProvider(fixtureMode: .single, now: { clock.read() }),
            reminderStateStore: ReminderStateStore(fileURL: directory.appending(path: "state.json")),
            cacheStore: EventCacheStore(fileURL: directory.appending(path: "cache.json")),
            notificationService: NoopNotificationService(),
            now: { clock.read() }, refreshMenuBar: {}
        )

        await controller.refresh(reason: "launch")

        #expect(controller.protectionHealthSummary.level == .healthy)
        #expect(controller.protectionHealthSummary.coverageText == "1 of 1 account protected · checked 0s ago")
        #expect(controller.protectionHealthSummary.scheduleText == "Next alert in 1m · scheduler current")
        clock.advance(by: 121)
        #expect(controller.protectionHealthSummary.level == .partial)
        #expect(controller.protectionHealthSummary.scheduleText.hasSuffix("scheduler delayed"))
        #expect(controller.protectionHealthSummary.actions == [.retry])
    }

    @Test("A real cache write failure appears in the controller summary")
    func controllerSurfacesCachePersistenceFailure() async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blockedParent = directory.appending(path: "blocked")
        try Data("occupied".utf8).write(to: blockedParent)
        let domain = "ProtectionHealthCacheTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let settings = AppSettingsStore(domainName: domain)
        let controller = MeetingShieldController(
            settingsStore: settings,
            provider: MockCalendarProvider(fixtureMode: .single, now: { now }),
            reminderStateStore: ReminderStateStore(fileURL: directory.appending(path: "state.json")),
            cacheStore: EventCacheStore(fileURL: blockedParent.appending(path: "cache.json")),
            notificationService: NoopNotificationService(),
            now: { now }, refreshMenuBar: {}
        )

        await controller.refresh(reason: "launch")

        #expect(controller.protectionHealthSummary.level == .partial)
        #expect(controller.protectionHealthSummary.copyText.contains("Storage: 1 warning"))
        #expect(controller.protectionHealthSummary.actions == [.retry, .settings])
    }

    @Test("The controller derives a blocked required notification channel")
    func controllerSurfacesBlockedNotifications() async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let domain = "ProtectionHealthNotificationTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let settings = AppSettingsStore(domainName: domain)
        settings.update { $0.presentationModeDefault = true }
        let controller = MeetingShieldController(
            settingsStore: settings,
            provider: MockCalendarProvider(fixtureMode: .single, now: { now }),
            reminderStateStore: ReminderStateStore(fileURL: directory.appending(path: "state.json")),
            cacheStore: EventCacheStore(fileURL: directory.appending(path: "cache.json")),
            notificationService: NoopNotificationService(),
            now: { now }, refreshMenuBar: {}
        )
        await controller.refresh(reason: "launch")
        controller.notificationHealth.recordAuthorizationStatus(.denied)

        #expect(controller.protectionHealthSummary.level == .partial)
        #expect(controller.protectionHealthSummary.copyText.contains("Notifications: Blocked"))
        #expect(controller.protectionHealthSummary.actions == [.settings])
    }

    @Test("The coordinator derives protected and unavailable accounts from retained coverage")
    func coordinatorDerivesPerAccountCoverage() async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let domain = "ProtectionHealthCoverageTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let settings = AppSettingsStore(domainName: domain)
        let accountA = ConnectedCalendarAccount(id: "private-a@example.com", displayName: "Private A")
        let accountB = ConnectedCalendarAccount(id: "private-b@example.com", displayName: "Private B")
        let calendarA = healthCalendar(account: accountA, sourceID: "primary")
        let calendarB = healthCalendar(account: accountB, sourceID: "primary")
        settings.update { $0.selectedCalendarIDs = [calendarA.id, calendarB.id] }
        let window = CalendarFetchWindow.protective(now: now, visibilityWindow: settings.snapshot.visibilityWindow)
        let cache = EventCacheStore(fileURL: directory.appending(path: "cache.json"))
        try cache.save(envelope: EventCacheEnvelope(
            cachedAt: now,
            events: [],
            accounts: [
                accountA.id: CalendarAccountCache(
                    account: accountA, calendars: [calendarA], fetchedAt: now,
                    coverage: .init(calendarIDs: [calendarA.id], window: window)
                ),
                accountB.id: CalendarAccountCache(
                    account: accountB, calendars: [calendarB], fetchedAt: nil, coverage: nil
                )
            ]
        ), settings: settings.snapshot)
        let coordinator = RefreshCoordinator(
            provider: DisconnectedCalendarProvider(), cacheStore: cache,
            settings: { settings.snapshot }, now: { now }
        )
        _ = await coordinator.refresh(reason: "launch")

        let snapshot = coordinator.protectionSnapshot(knownAccounts: [accountA, accountB])
        #expect(snapshot.accounts == [
            account(accountA.id, .protected),
            account(accountB.id, .unavailable)
        ])
        #expect(snapshot.lastSuccessfulRefresh == now)
        #expect(snapshot.oldestCoverage == now)
    }

    private func makeSummary(
        connection: ProtectionHealthSummary.Connection = .connected,
        accounts: [ProtectionHealthSummary.Account],
        hasCalendarSelection: Bool = true,
        lastSuccessfulRefresh: Date? = nil,
        oldestCoverage: Date? = nil,
        refreshIssue: Bool = false,
        schedulerLastEvaluation: Date? = nil,
        nextReminder: Date? = nil,
        notification: ProtectionHealthSummary.Notification = .available,
        storageWarningCount: Int = 0,
        reconnectAccountIDs: Set<String> = [],
        requiresGenericReconnect: Bool = false
    ) -> ProtectionHealthSummary {
        ProtectionHealthSummary.derive(from: .init(
            connection: connection,
            accounts: accounts,
            hasCalendarSelection: hasCalendarSelection,
            lastSuccessfulRefresh: lastSuccessfulRefresh ?? now.addingTimeInterval(-30),
            oldestCoverage: oldestCoverage ?? now.addingTimeInterval(-60),
            refreshIssue: refreshIssue,
            schedulerLastEvaluation: schedulerLastEvaluation ?? now.addingTimeInterval(-30),
            nextReminder: nextReminder ?? now.addingTimeInterval(300),
            notification: notification,
            storageWarningCount: storageWarningCount,
            reconnectAccountIDs: reconnectAccountIDs,
            requiresGenericReconnect: requiresGenericReconnect,
            now: now
        ))
    }

    private func account(
        _ id: String, _ state: ProtectionHealthSummary.Account.State
    ) -> ProtectionHealthSummary.Account {
        .init(accountID: id, state: state)
    }

    private func healthCalendar(account: ConnectedCalendarAccount, sourceID: String) -> UserCalendar {
        UserCalendar(
            id: "\(account.id)::\(sourceID)", sourceCalendarID: sourceID,
            accountID: account.id, accountDisplayName: account.displayName,
            displayName: "Private calendar", isPrimary: true, isSelected: true, colorHex: nil
        )
    }
}

@MainActor
private final class ClipboardCapture {
    var value: String?
}
