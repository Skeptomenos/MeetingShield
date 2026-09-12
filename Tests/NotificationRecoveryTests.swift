import Combine
import CryptoKit
import Foundation
import Testing
import UserNotifications
@testable import MeetingShield

@Suite("Calendar authorization recovery notifications")
@MainActor
struct NotificationRecoveryTests {
    @Test("An unidentified expired credential warns without inventing an account", arguments: UnscopedExpiry.allCases)
    func unidentifiedAuthorizationFailure(expiry: UnscopedExpiry) async throws {
        let fixture = try Fixture(unscopedExpiry: expiry)
        defer { fixture.cleanup() }
        let notifier = RecordingNotifier(status: .authorized)
        let controller = fixture.makeController(notifier: notifier)
        defer { controller.stop() }

        await controller.refresh(reason: "launch")
        await controller.refresh(reason: "timer")

        expectNotifications(notifier, count: 1)
        #expect(requiresReconnect(controller.statusMessage))
        #expect(controller.accounts.isEmpty)
        #expect(fixture.client.tokenInventory().tokens.map(\.accountID) == [nil])
        #expect(notifier.authorizationRequestCount == 0)
    }

    @Test("Complete discovery clears an unidentified authorization episode")
    func unidentifiedAuthorizationRecovery() async throws {
        let fixture = try Fixture(unscopedExpiry: .invalidGrant)
        defer { fixture.cleanup() }
        let notifier = RecordingNotifier(status: .authorized)
        let controller = fixture.makeController(notifier: notifier)
        defer { controller.stop() }

        await controller.refresh(reason: "launch")
        expectNotifications(notifier, count: 1)
        #expect(requiresReconnect(controller.statusMessage))

        fixture.requests.move(to: .healthy)
        await controller.refresh(reason: "manual")
        await controller.refresh(reason: "timer")

        expectNotifications(notifier, count: 1)
        #expect(!requiresReconnect(controller.statusMessage))
        #expect(controller.accounts.map(\.id) == [fixture.requests.sourceID("a")])
        #expect(fixture.client.tokenInventory().tokens.compactMap(\.accountID) == [fixture.requests.sourceID("a")])
    }

    @Test("Two failed refreshes notify once until recovery", arguments: [false, true])
    func staleFailureEpisodes(completeEmpty: Bool) async throws {
        let fixture = try StaleFixture(includeEvent: !completeEmpty)
        defer { fixture.cleanup() }
        let notifier = RecordingNotifier(status: .authorized)
        let controller = fixture.makeController(notifier: notifier)
        defer { controller.stop() }

        await controller.refresh(reason: "launch")
        #expect(notifier.delivered.isEmpty)

        await fixture.provider.setMode(.failure)
        await controller.refresh(reason: "manual")
        #expect(notifier.delivered.isEmpty)
        await controller.refresh(reason: "timer")
        expectStaleNotifications(notifier, count: 1)
        await controller.refresh(reason: "timer")
        expectStaleNotifications(notifier, count: 1)

        await fixture.provider.setMode(.success)
        await controller.refresh(reason: "manual")
        expectStaleNotifications(notifier, count: 1)
        #expect(controller.statusMessage == nil)

        await fixture.provider.setMode(.failure)
        await controller.refresh(reason: "manual")
        await controller.refresh(reason: "timer")
        expectStaleNotifications(notifier, count: 2)
    }

    @Test("Stale notification status cannot block acquisition or restart scheduling after Stop", arguments: [false, true])
    func stalePreflightRefreshOwnership(stopWhileHeld: Bool) async throws {
        let fixture = try StaleFixture(includeEvent: true)
        defer { fixture.cleanup() }
        let notifier = GatedNotifier(boundary: .authorizationRead)
        let controller = fixture.makeController(notifier: notifier)
        defer { controller.stop() }
        await controller.refresh(reason: "launch")
        let baseline = controller.lastReminderEvaluationDate
        try #require(controller.nextActionTargetDate != nil)
        fixture.clock.advance(by: 300)
        await fixture.provider.setMode(.heldSuccess)
        let refresh = Task {
            await controller.refresh(reason: "timer")
            notifier.refreshDidFinish()
        }
        defer { notifier.release(); refresh.cancel() }
        try #require(await notifier.waitForEntry())
        if stopWhileHeld { controller.stop() }
        await fixture.provider.release.open()
        if !stopWhileHeld {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while controller.lastReminderEvaluationDate != fixture.clock.read(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(controller.lastReminderEvaluationDate == fixture.clock.read(), "Healthy acquisition must publish while notification status is held")
            #expect(notifier.authorizationReturnCount == 0)
        }
        notifier.release()
        await refresh.value
        if stopWhileHeld {
            #expect(controller.nextActionTargetDate == nil, "Stop must not be undone by a late status callback")
            #expect(controller.lastReminderEvaluationDate == baseline, "Invalidated acquisition must not publish")
        } else {
            #expect(controller.lastReminderEvaluationDate == fixture.clock.read())
            #expect(controller.nextActionTargetDate != nil)
        }
        #expect(notifier.deliveryCount == 0, "Recovered or stopped coverage must not send an obsolete stale warning")
    }

    @Test("Concurrent stale preflight preserves later episodes and warnings after failure", arguments: [false, true])
    func stalePreflightEpisodes(recovers: Bool) async throws {
        let fixture = try StaleFixture(includeEvent: true)
        defer { fixture.cleanup() }
        let notifier = GatedNotifier(boundary: .authorizationRead)
        let controller = fixture.makeController(notifier: notifier)
        defer { controller.stop() }
        await controller.refresh(reason: "launch")
        fixture.clock.advance(by: 300)
        await fixture.provider.setMode(recovers ? .heldSuccess : .heldFailure)
        let refresh = Task {
            await controller.refresh(reason: "timer")
            notifier.refreshDidFinish()
        }
        defer { notifier.release(); refresh.cancel() }
        try #require(await notifier.waitForEntry())
        await fixture.provider.release.open()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while controller.lastReminderEvaluationDate != fixture.clock.read(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(controller.lastReminderEvaluationDate == fixture.clock.read())
        // A completed second refresh proves post-fetch reconciliation ran with the old status held.
        await controller.refresh(reason: "manual")
        #expect(notifier.authorizationReturnCount == 0)
        notifier.release()
        await refresh.value
        if recovers {
            #expect(notifier.deliveryCount == 0)
            fixture.clock.advance(by: 300)
            await fixture.provider.setMode(.failure)
            await controller.refresh(reason: "timer")
        }
        #expect(notifier.deliveryCount == 1, "Current stale episode must warn despite the earlier held preflight")
        await controller.refresh(reason: "timer")
        #expect(notifier.deliveryCount == 1, "An episode must still deduplicate")
    }

    @Test("A stalled refresh notifies at 300 seconds from a complete empty snapshot")
    func stalledRefreshAgeNotification() async throws {
        let fixture = try StaleFixture(includeEvent: false)
        defer { fixture.cleanup() }
        let notifier = RecordingNotifier(status: .authorized)
        let controller = fixture.makeController(notifier: notifier)
        defer { controller.stop() }

        await controller.refresh(reason: "launch")
        await fixture.provider.setMode(.heldFailure)
        let held = Task { await controller.refresh(reason: "timer") }
        try #require(await fixture.provider.entered.wait())

        fixture.clock.advance(by: 300)
        await controller.refresh(reason: "timer")
        expectStaleNotifications(notifier, count: 1)
        await controller.refresh(reason: "timer")
        expectStaleNotifications(notifier, count: 1)

        await fixture.provider.release.open()
        await held.value
        expectStaleNotifications(notifier, count: 1)
    }

    @Test("Repeated failures without a usable snapshot do not claim stale cache")
    func noCacheDoesNotClaimStaleProtection() async throws {
        let fixture = try StaleFixture(includeEvent: false, initialMode: .failure)
        defer { fixture.cleanup() }
        let notifier = RecordingNotifier(status: .authorized)
        let controller = fixture.makeController(notifier: notifier)
        defer { controller.stop() }

        await controller.refresh(reason: "launch")
        await controller.refresh(reason: "manual")
        await controller.refresh(reason: "timer")

        #expect(notifier.delivered.isEmpty)
        #expect(controller.statusMessage?.localizedCaseInsensitiveContains("no usable") == true)
        #expect(controller.statusMessage?.localizedCaseInsensitiveContains("stale") == false)
    }

    @Test("Failures after selecting an unfetched calendar do not claim stale protection")
    func unfetchedSelectionDoesNotClaimStaleProtection() async throws {
        let fixture = try StaleFixture(includeEvent: true)
        defer { fixture.cleanup() }
        let notifier = RecordingNotifier(status: .authorized)
        let controller = fixture.makeController(notifier: notifier)
        defer { controller.stop() }

        await controller.refresh(reason: "launch")
        fixture.settings.update {
            $0.selectedCalendarIDs = ["synthetic-stale-account::unfetched-calendar"]
        }
        await fixture.provider.setMode(.failure)
        await controller.refresh(reason: "settings")
        await controller.refresh(reason: "timer")

        #expect(notifier.delivered.isEmpty)
        #expect(controller.statusMessage?.localizedCaseInsensitiveContains("coverage") == true)
        #expect(controller.statusMessage?.localizedCaseInsensitiveContains("stale") == false)
    }

    @Test("An old unselected account does not age fresh selected coverage")
    func unrelatedAccountDoesNotAgeSelectedCoverage() async throws {
        let fixture = try StaleFixture(includeEvent: false, initialMode: .failure)
        defer { fixture.cleanup() }
        let notifier = RecordingNotifier(status: .authorized)
        let controller = fixture.makeController(notifier: notifier)
        defer { controller.stop() }
        let oldAccount = ConnectedCalendarAccount(id: "synthetic-old-account", displayName: "Synthetic old account")
        let freshAccount = ConnectedCalendarAccount(id: "synthetic-fresh-account", displayName: "Synthetic fresh account")
        let oldCalendar = UserCalendar(
            id: "synthetic-old-account::calendar", accountID: oldAccount.id,
            displayName: "Synthetic old calendar", isPrimary: true, isSelected: true
        )
        let freshCalendar = UserCalendar(
            id: "synthetic-fresh-account::calendar", accountID: freshAccount.id,
            displayName: "Synthetic fresh calendar", isPrimary: true, isSelected: true
        )
        let freshDate = fixture.clock.read()
        let oldDate = freshDate.addingTimeInterval(-301)
        let window = CalendarFetchWindow.protective(
            now: freshDate,
            visibilityWindow: MenuVisibilityWindow(kind: .nextDays, hours: 4, days: 7)
        )
        try fixture.cache.save(envelope: EventCacheEnvelope(
            cachedAt: oldDate,
            events: [],
            accounts: [
                oldAccount.id: CalendarAccountCache(
                    account: oldAccount, calendars: [oldCalendar], fetchedAt: oldDate,
                    coverage: .init(calendarIDs: [oldCalendar.id], window: window)
                ),
                freshAccount.id: CalendarAccountCache(
                    account: freshAccount, calendars: [freshCalendar], fetchedAt: freshDate,
                    coverage: .init(calendarIDs: [freshCalendar.id], window: window)
                )
            ]
        ))
        fixture.settings.update { $0.selectedCalendarIDs = [freshCalendar.id] }

        await controller.refresh(reason: "launch")

        #expect(notifier.delivered.isEmpty)
        #expect(controller.statusMessage?.localizedCaseInsensitiveContains("stale") == false)
    }

    @Test("An expired account warns once until complete recovery while another account stays healthy")
    func authorizationFailureEpisodes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let notifier = RecordingNotifier(status: .authorized)
        let controller = fixture.makeController(notifier: notifier)
        defer { controller.stop() }
        let settingsView = SettingsView(store: fixture.settings, controller: controller)

        await controller.refresh(reason: "launch")
        #expect(notifier.delivered.isEmpty)
        #expect(!requiresReconnect(controller.statusMessage))
        #expect(!settingsView.needsConnectionRecovery)
        #expect(settingsView.googleStatusText == "Connected")
        fixture.expectHealthyAccountB(controller, refreshes: 1)

        try fixture.expireAccountA()
        fixture.requests.move(to: .authorizationExpired)
        await controller.refresh(reason: "manual")
        expectNotifications(notifier, count: 1)
        #expect(requiresReconnect(controller.statusMessage))
        #expect(settingsView.needsConnectionRecovery)
        #expect(settingsView.googleStatusText == "Needs reconnect")
        #expect(controller.protectionHealthSummary.actions.contains(.reconnect))
        #expect(controller.protectionHealthSummary.copyText.contains("Authorization: Reconnect required for 1 account"))
        #expect(!controller.protectionHealthSummary.copyText.contains(fixture.requests.accountID("a")))
        #expect(fixture.requests.count("token") == 1)
        fixture.expectHealthyAccountB(controller, refreshes: 2)

        await controller.refresh(reason: "timer")
        expectNotifications(notifier, count: 1)
        #expect(requiresReconnect(controller.statusMessage))
        #expect(settingsView.needsConnectionRecovery)
        #expect(settingsView.googleStatusText == "Needs reconnect")
        fixture.expectHealthyAccountB(controller, refreshes: 3)

        fixture.requests.move(to: .networkFailure)
        await controller.refresh(reason: "manual")
        expectNotifications(notifier, count: 1)
        #expect(requiresReconnect(controller.statusMessage))
        #expect(settingsView.needsConnectionRecovery)
        #expect(settingsView.googleStatusText == "Needs reconnect")
        fixture.expectHealthyAccountB(controller, refreshes: 4)

        fixture.requests.move(to: .authorizationExpired)
        await controller.refresh(reason: "manual")
        expectNotifications(notifier, count: 1)
        #expect(requiresReconnect(controller.statusMessage))
        #expect(settingsView.needsConnectionRecovery)
        #expect(settingsView.googleStatusText == "Needs reconnect")
        fixture.expectHealthyAccountB(controller, refreshes: 5)

        fixture.keychain.denyReads(for: "google.oauth.tokens")
        await controller.refresh(reason: "manual")
        expectNotifications(notifier, count: 1)
        #expect(requiresReconnect(controller.statusMessage))
        #expect(settingsView.needsConnectionRecovery)
        #expect(settingsView.googleStatusText == "Needs reconnect")
        #expect(!fixture.client.tokenInventory().isComplete)

        fixture.keychain.denyReads(for: nil)
        await controller.refresh(reason: "manual")
        expectNotifications(notifier, count: 1)
        #expect(requiresReconnect(controller.statusMessage))
        #expect(settingsView.needsConnectionRecovery)
        #expect(settingsView.googleStatusText == "Needs reconnect")
        fixture.expectHealthyAccountB(controller, refreshes: 6)

        fixture.requests.move(to: .healthy)
        await controller.refresh(reason: "manual")
        expectNotifications(notifier, count: 1)
        #expect(!requiresReconnect(controller.statusMessage))
        #expect(!settingsView.needsConnectionRecovery)
        #expect(settingsView.googleStatusText == "Connected")
        #expect(controller.events.contains { $0.accountID == fixture.requests.accountID("a") && !$0.isFromCache })
        #expect(fixture.client.tokenInventory().isComplete)
        fixture.expectHealthyAccountB(controller, refreshes: 7)

        try fixture.expireAccountA()
        fixture.requests.move(to: .authorizationExpired)
        await controller.refresh(reason: "manual")
        expectNotifications(notifier, count: 2)
        #expect(requiresReconnect(controller.statusMessage))
        #expect(settingsView.needsConnectionRecovery)
        #expect(settingsView.googleStatusText == "Needs reconnect")
        fixture.expectHealthyAccountB(controller, refreshes: 8)
        #expect(notifier.authorizationRequestCount == 0)
    }

    @Test("A token transport failure does not claim authorization expired")
    func networkFailureIsNotAuthorizationExpiry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let notifier = RecordingNotifier(status: .authorized)
        let controller = fixture.makeController(notifier: notifier)
        defer { controller.stop() }
        try fixture.expireAccountA()
        fixture.requests.move(to: .networkFailure)

        await controller.refresh(reason: "launch")

        #expect(notifier.delivered.isEmpty)
        #expect(controller.statusMessage?.isEmpty == false)
        #expect(!requiresReconnect(controller.statusMessage))
        #expect(fixture.requests.count("token") > 0)
        fixture.expectHealthyAccountB(controller, refreshes: 1)
        #expect(notifier.authorizationRequestCount == 0)
    }

    @Test("Denied notifications cannot erase the reconnect warning even when delivery returns success")
    func deniedDeliveryRetainsMenuWarning() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.settings.update { $0.presentationModeDefault = true }
        let notifier = RecordingNotifier(status: .denied)
        let controller = fixture.makeController(notifier: notifier)
        defer { controller.stop() }
        try fixture.expireAccountA()
        fixture.requests.move(to: .authorizationExpired)

        await controller.refresh(reason: "launch")

        expectNotifications(notifier, count: 1)
        #expect(notifier.authorizationReadCount > 0)
        #expect(controller.notificationHealth.authorizationDenied)
        #expect(!controller.notificationHealth.lastDeliveryFailed)
        #expect(controller.notificationWarning?.isEmpty == false)
        #expect(requiresReconnect(controller.statusMessage))
        fixture.expectHealthyAccountB(controller, refreshes: 1)

        await controller.refresh(reason: "timer")

        expectNotifications(notifier, count: 1)
        #expect(controller.notificationWarning?.isEmpty == false)
        #expect(requiresReconnect(controller.statusMessage))
        fixture.expectHealthyAccountB(controller, refreshes: 2)
        #expect(notifier.authorizationRequestCount == 0)
    }

    @Test("Unreadable account credentials do not invent authorization expiry for a partial inventory", arguments: InventoryDamage.allCases)
    func inventoryFailureIsNotAuthorizationExpiry(damage: InventoryDamage) async throws {
        let fixture = try Fixture(inventoryDamage: damage)
        defer { fixture.cleanup() }
        let notifier = RecordingNotifier(status: .authorized)
        let controller = fixture.makeController(notifier: notifier)
        defer { controller.stop() }
        let originalCredentials = fixture.keychain.snapshot
        let inventory = fixture.client.tokenInventory()
        #expect(!inventory.isComplete)
        #expect(inventory.tokens.compactMap(\.accountID) == [fixture.requests.accountID("b")])

        await controller.refresh(reason: "launch")

        #expect(notifier.delivered.isEmpty)
        #expect(controller.statusMessage?.isEmpty == false)
        #expect(!requiresReconnect(controller.statusMessage))
        fixture.expectHealthyAccountB(controller, refreshes: 1)
        #expect(fixture.requests.count("token") == 0)
        #expect(fixture.keychain.snapshot == originalCredentials)
        #expect(fixture.keychain.writeCount == 0)
        #expect(notifier.authorizationRequestCount == 0)
    }

    @Test("An obsolete authorization read cannot publish denied health or submit a notification", arguments: OwnerInvalidation.allCases)
    func staleAuthorizationRead(invalidation: OwnerInvalidation) async throws {
        try await exerciseStaleNotifier(boundary: .authorizationRead, invalidation: invalidation)
    }

    @Test("An obsolete delivery result cannot publish notification failure", arguments: OwnerInvalidation.allCases)
    func staleDeliveryResult(invalidation: OwnerInvalidation) async throws {
        try await exerciseStaleNotifier(boundary: .delivery, invalidation: invalidation)
    }

    @Test("An old delivery failure cannot overwrite success from a later authorization failure episode")
    func staleDeliveryAfterRecoveryAndNewExpiry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.settings.update { $0.presentationModeDefault = true }
        let notifier = GatedNotifier(boundary: .delivery)
        let controller = fixture.makeController(notifier: notifier)
        defer { controller.stop() }
        try fixture.expireAccountA()
        fixture.requests.move(to: .authorizationExpired)
        var failedDeliveryPublications: [Bool] = []
        var warningPublications: [String?] = []
        let observations = [
            controller.notificationHealth.$lastDeliveryFailed.sink { failedDeliveryPublications.append($0) },
            controller.$notificationWarning.sink { warningPublications.append($0) }
        ]
        defer { observations.forEach { $0.cancel() } }
        let oldRefresh = Task {
            await controller.refresh(reason: "manual")
            notifier.refreshDidFinish()
        }
        let entered = await notifier.waitForEntry()
        #expect(entered)
        #expect(notifier.deliveryCount == 1)
        #expect(notifier.deliveryReturnCount == 0)

        do {
            fixture.requests.move(to: .healthy)
            await controller.refresh(reason: "manual")
            #expect(!requiresReconnect(controller.statusMessage))
            #expect(controller.events.contains { $0.accountID == fixture.requests.accountID("a") && !$0.isFromCache })

            try fixture.expireAccountA()
            fixture.requests.move(to: .authorizationExpired)
            await controller.refresh(reason: "manual")
            #expect(requiresReconnect(controller.statusMessage))
            #expect(notifier.deliveryCount == 2)
            #expect(notifier.deliveryReturnCount == 1)
            #expect(!controller.notificationHealth.lastDeliveryFailed)
            #expect(controller.notificationWarning == nil)
            fixture.expectHealthyAccountB(controller, refreshes: 3)
        } catch {
            notifier.release()
            await oldRefresh.value
            throw error
        }
        notifier.release()
        await oldRefresh.value

        #expect(notifier.deliveryCount == 2)
        #expect(notifier.deliveryReturnCount == 2)
        #expect(notifier.authorizationReadCount == 2)
        #expect(notifier.authorizationRequestCount == 0)
        #expect(!controller.notificationHealth.authorizationDenied)
        #expect(!controller.notificationHealth.lastDeliveryFailed)
        #expect(controller.notificationWarning == nil)
        #expect(!failedDeliveryPublications.contains(true))
        #expect(warningPublications.compactMap { $0 }.isEmpty)
    }

    private func exerciseStaleNotifier(boundary: NotificationBoundary, invalidation: OwnerInvalidation) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.settings.update { $0.presentationModeDefault = true }
        let notifier = GatedNotifier(boundary: boundary)
        let controller = fixture.makeController(notifier: notifier)
        defer { controller.stop() }
        try fixture.expireAccountA()
        fixture.requests.move(to: .authorizationExpired)
        #expect(!controller.notificationHealth.authorizationDenied)
        #expect(!controller.notificationHealth.lastDeliveryFailed)
        #expect(controller.notificationWarning == nil)

        var deniedPublications: [Bool] = []
        var failedDeliveryPublications: [Bool] = []
        var warningPublications: [String?] = []
        let observations = [
            controller.notificationHealth.$authorizationDenied.sink { deniedPublications.append($0) },
            controller.notificationHealth.$lastDeliveryFailed.sink { failedDeliveryPublications.append($0) },
            controller.$notificationWarning.sink { warningPublications.append($0) }
        ]
        defer { observations.forEach { $0.cancel() } }
        let refresh = Task {
            await controller.refresh(reason: "manual")
            notifier.refreshDidFinish()
        }
        let entered = await notifier.waitForEntry()
        #expect(entered)
        #expect(notifier.authorizationReadCount == 1)
        #expect(notifier.deliveryCount == (boundary == .delivery ? 1 : 0))
        fixture.expectHealthyAccountB(controller, refreshes: 1)

        switch invalidation {
        case .providerReplacement:
            controller.provider = DisconnectedCalendarProvider()
        case .stop:
            controller.stop()
        case .disabledAccount:
            fixture.settings.update { $0.disabledGoogleAccountIDs.insert(fixture.requests.accountID("a")) }
        }
        notifier.release()
        await refresh.value

        #expect(notifier.authorizationReturnCount == 1)
        #expect(notifier.deliveryCount == (boundary == .delivery ? 1 : 0))
        #expect(notifier.deliveryReturnCount == (boundary == .delivery ? 1 : 0))
        #expect(notifier.authorizationRequestCount == 0)
        #expect(!controller.notificationHealth.authorizationDenied)
        #expect(!controller.notificationHealth.lastDeliveryFailed)
        #expect(controller.notificationWarning == nil)
        #expect(!deniedPublications.contains(true))
        #expect(!failedDeliveryPublications.contains(true))
        #expect(warningPublications.compactMap { $0 }.isEmpty)
        #expect(controller.activeReminders.isEmpty)
        #expect(fixture.requests.count("unexpected") == 0)
    }

    private func requiresReconnect(_ message: String?) -> Bool {
        guard let message else { return false }
        return ["reconnect", "authorization", "sign in", "connect again"].contains {
            message.localizedCaseInsensitiveContains($0)
        }
    }

    private func expectNotifications(_ notifier: RecordingNotifier, count: Int) {
        let notifications = notifier.delivered
        #expect(notifications.count == count)
        for notification in notifications {
            #expect(requiresReconnect("\(notification.title) \(notification.body)"))
            #expect(!notification.withSound)
            #expect(notification.date == nil)
        }
    }

    private func expectStaleNotifications(_ notifier: RecordingNotifier, count: Int) {
        let notifications = notifier.delivered
        #expect(notifications.count == count)
        for notification in notifications {
            #expect("\(notification.title) \(notification.body)".localizedCaseInsensitiveContains("stale"))
            #expect(!notification.withSound)
            #expect(notification.date == nil)
        }
    }

    enum UnscopedExpiry: CaseIterable, Equatable, Sendable {
        case missingRefreshToken
        case invalidGrant
        case calendarUnauthorized
    }

    enum InventoryDamage: CaseIterable, Sendable {
        case denied
        case corrupt
    }

    enum OwnerInvalidation: CaseIterable, Sendable {
        case providerReplacement
        case stop
        case disabledAccount
    }

    private enum NotificationBoundary {
        case authorizationRead
        case delivery
    }

    private enum ResponseMode: Equatable, Sendable {
        case healthy
        case authorizationExpired
        case calendarUnauthorized
        case networkFailure
    }

    private struct NoSound: AlertSoundPlaying {
        func playAlertSound() {}
    }

    @MainActor
    private final class NoDismissal: DismissalConfirming {
        func present(
            requestID: UUID, reminder: ScheduledReminder, source: DismissalRequestSource,
            completion: @escaping @MainActor (Bool) -> Void
        ) {
            completion(false)
        }

        func cancel(requestID: UUID) {}
    }

    private final class RecordingNotifier: MeetingNotifying, @unchecked Sendable {
        private let lock = NSLock()
        private let status: UNAuthorizationStatus
        private var notifications: [MeetingNotification] = []
        private var authorizationReads = 0
        private var authorizationRequests = 0

        init(status: UNAuthorizationStatus) { self.status = status }
        var delivered: [MeetingNotification] { lock.withLock { notifications } }
        var authorizationReadCount: Int { lock.withLock { authorizationReads } }
        var authorizationRequestCount: Int { lock.withLock { authorizationRequests } }

        func authorizationStatus() async -> UNAuthorizationStatus {
            lock.withLock { authorizationReads += 1 }
            return status
        }

        func requestAuthorization() async throws -> Bool {
            lock.withLock { authorizationRequests += 1 }
            return status == .authorized
        }

        func deliver(_ notification: MeetingNotification) async throws {
            lock.withLock { notifications.append(notification) }
        }
    }

    @MainActor
    private final class GatedNotifier: MeetingNotifying {
        private let boundary: NotificationBoundary
        private var entry: CheckedContinuation<Bool, Never>?
        private var pendingResult: CheckedContinuation<Void, Never>?
        private var entered = false
        private var released = false
        private var refreshFinished = false
        private(set) var authorizationReadCount = 0
        private(set) var authorizationReturnCount = 0
        private(set) var authorizationRequestCount = 0
        private(set) var deliveryCount = 0
        private(set) var deliveryReturnCount = 0

        init(boundary: NotificationBoundary) { self.boundary = boundary }

        func authorizationStatus() async -> UNAuthorizationStatus {
            authorizationReadCount += 1
            if boundary == .authorizationRead { await hold() }
            authorizationReturnCount += 1
            return boundary == .authorizationRead ? .denied : .authorized
        }

        func requestAuthorization() async throws -> Bool {
            authorizationRequestCount += 1
            return false
        }

        func deliver(_ notification: MeetingNotification) async throws {
            deliveryCount += 1
            let held = boundary == .delivery && deliveryCount == 1
            if held { await hold() }
            deliveryReturnCount += 1
            if held { throw URLError(.cannotConnectToHost) }
        }

        func waitForEntry() async -> Bool {
            if entered { return true }
            if refreshFinished { return false }
            return await withCheckedContinuation { entry = $0 }
        }

        func release() {
            released = true
            pendingResult?.resume()
            pendingResult = nil
        }

        func refreshDidFinish() {
            refreshFinished = true
            entry?.resume(returning: entered)
            entry = nil
        }

        private func hold() async {
            await withCheckedContinuation { continuation in
                entered = true
                pendingResult = continuation
                entry?.resume(returning: true)
                entry = nil
                if released { release() }
            }
        }
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let domain = "NotificationRecoveryTests.\(UUID().uuidString)"
        let requests = Requests()
        let settings: AppSettingsStore
        let cache: EventCacheStore
        let keychain = SyntheticKeychain()
        let session: URLSession
        let client: GoogleOAuthClient

        init(inventoryDamage: InventoryDamage? = nil, unscopedExpiry: UnscopedExpiry? = nil) throws {
            directory = try TestTempDirectory.make()
            settings = AppSettingsStore(domainName: domain)
            cache = EventCacheStore(fileURL: directory.appending(path: "cache.json"))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SyntheticURLProtocol.self]
            configuration.httpAdditionalHeaders = [SyntheticURLProtocol.markerHeader: requests.marker]
            session = URLSession(configuration: configuration)
            client = GoogleOAuthClient(
                configuration: GoogleOAuthConfiguration(clientID: requests.clientID),
                keychain: keychain, session: session,
                diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "oauth"), nativeSink: { _, _ in })
            )
            settings.update {
                $0.googleOAuthClientID = requests.clientID
                $0.selectedCalendarIDs = Set(["a", "b"].map { requests.calendarID($0) })
                $0.visibilityWindow = MenuVisibilityWindow(kind: .nextHours, hours: 4, days: 1)
                $0.wakeGraceEnabled = false
                $0.soundEnabled = false
                $0.urgentRepeatSoundEnabled = false
            }
            if let unscopedExpiry {
                let token = GoogleOAuthToken(
                    accessToken: requests.accessToken("a"),
                    refreshToken: unscopedExpiry == .missingRefreshToken ? nil : requests.refreshToken("a"),
                    expiresAt: unscopedExpiry == .calendarUnauthorized ? .distantFuture : .distantPast,
                    scope: AppIdentity.googleScopes.joined(separator: " "), tokenType: "Bearer"
                )
                try client.saveToken(token)
                requests.move(to: unscopedExpiry == .calendarUnauthorized ? .calendarUnauthorized : .authorizationExpired)
            } else if let inventoryDamage {
                let index = try JSONSerialization.data(withJSONObject: ["accountIDs": [requests.accountID("a"), requests.accountID("b")]])
                var values = [
                    "google.oauth.tokens.index": String(decoding: index, as: UTF8.self),
                    tokenKey("b"): String(decoding: try JSONEncoder().encode(token("b")), as: UTF8.self)
                ]
                values[tokenKey("a")] = inventoryDamage == .corrupt
                    ? "{\"accessToken\":\"synthetic-incomplete-record\"}"
                    : String(decoding: try JSONEncoder().encode(token("a")), as: UTF8.self)
                keychain.seed(values)
                if inventoryDamage == .denied { keychain.denyReads(for: tokenKey("a")) }
            } else {
                try client.saveToken(token("a"))
                try client.saveToken(token("b"))
            }
            SyntheticURLProtocol.register(requests)
        }

        func makeController(notifier: any MeetingNotifying) -> MeetingShieldController {
            let now = requests.now
            return MeetingShieldController(
                settingsStore: settings, provider: GoogleCalendarProvider(oauthClient: client),
                credentialsResolver: GoogleOAuthCredentialsResolver(bundleInfoValue: { _ in nil }, environment: [:]),
                reminderStateStore: ReminderStateStore(fileURL: directory.appending(path: "reminders.json")),
                cacheStore: cache, notificationService: notifier,
                soundPlayer: NoSound(), dismissalPresenter: NoDismissal(), now: { now }, refreshMenuBar: {}
            )
        }

        func expireAccountA() throws {
            var expired = token("a")
            expired.expiresAt = .distantPast
            try client.saveToken(expired)
        }

        func expectHealthyAccountB(_ controller: MeetingShieldController, refreshes: Int) {
            if case .connected = controller.authState {} else {
                Issue.record("Healthy account B did not keep the provider connected")
            }
            #expect(controller.events.contains { $0.accountID == requests.accountID("b") && !$0.isFromCache })
            #expect(controller.scheduledReminders.contains { $0.event.accountID == requests.accountID("b") })
            #expect(controller.activeReminders.isEmpty)
            #expect(controller.events.allSatisfy { $0.startDate > requests.now })
            #expect(requests.count("b.events") == refreshes)
            #expect(requests.count("unexpected") == 0)
        }

        private func token(_ account: String) -> GoogleOAuthToken {
            GoogleOAuthToken(
                accessToken: requests.accessToken(account), refreshToken: requests.refreshToken(account),
                expiresAt: .distantFuture, scope: AppIdentity.googleScopes.joined(separator: " "), tokenType: "Bearer",
                accountID: requests.accountID(account), accountDisplayName: "Synthetic account \(account)"
            )
        }

        private func tokenKey(_ account: String) -> String {
            let digest = SHA256.hash(data: Data(requests.accountID(account).utf8))
            return "google.oauth.token.\(digest.map { String(format: "%02x", $0) }.joined().prefix(16))"
        }

        func cleanup() {
            session.invalidateAndCancel()
            SyntheticURLProtocol.remove(marker: requests.marker)
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private final class SyntheticKeychain: KeychainStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        private var deniedKey: String?
        private var writes = 0

        var snapshot: [String: String] { lock.withLock { values } }
        var writeCount: Int { lock.withLock { writes } }
        func seed(_ values: [String: String]) { lock.withLock { self.values = values } }
        func denyReads(for key: String?) { lock.withLock { deniedKey = key } }
        func retrieve(forKey key: String) -> String? { try? read(forKey: key) }

        func read(forKey key: String) throws -> String? {
            try lock.withLock {
                if deniedKey == key { throw KeychainError.readFailed(-25308) }
                return values[key]
            }
        }

        func save(_ value: String, forKey key: String) throws {
            lock.withLock {
                writes += 1
                values[key] = value
            }
        }

        func delete(forKey key: String) throws {
            lock.withLock {
                writes += 1
                values.removeValue(forKey: key)
            }
        }
    }

    private enum Response {
        case json(String, status: Int = 200)
        case failure(URLError.Code)
    }

    private final class Requests: @unchecked Sendable {
        let marker = "p12-notification-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        private let lock = NSLock()
        private var mode = ResponseMode.healthy
        private var counts: [String: Int] = [:]

        var clientID: String { "\(marker)-client" }
        func accountID(_ account: String) -> String { "\(marker)-\(account)@example.invalid" }
        func sourceID(_ account: String) -> String { "\(marker)-calendar-\(account)" }
        func calendarID(_ account: String) -> String { "\(accountID(account))::\(sourceID(account))" }
        func accessToken(_ account: String) -> String { "\(marker)-access-\(account)" }
        func refreshToken(_ account: String) -> String { "\(marker)-refresh-\(account)" }
        func move(to mode: ResponseMode) { lock.withLock { self.mode = mode } }
        func count(_ key: String) -> Int { lock.withLock { counts[key, default: 0] } }

        func response(for request: URLRequest) -> Response {
            lock.withLock {
                guard let url = request.url else { return reject() }
                if url == AppIdentity.googleOAuthTokenURL, request.httpMethod == "POST" {
                    guard let data = Self.body(of: request),
                          let items = URLComponents(string: "?" + String(decoding: data, as: UTF8.self))?.queryItems else { return reject() }
                    let fields = Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } },
                                            uniquingKeysWith: { _, new in new })
                    guard fields == ["client_id": clientID, "refresh_token": refreshToken("a"), "grant_type": "refresh_token"] else { return reject() }
                    counts["token", default: 0] += 1
                    switch mode {
                    case .authorizationExpired:
                        return .json("{\"error\":\"invalid_grant\"}", status: 400)
                    case .calendarUnauthorized:
                        return reject()
                    case .networkFailure:
                        return .failure(.networkConnectionLost)
                    case .healthy:
                        return .json("{\"access_token\":\"\(accessToken("a"))-refreshed\",\"expires_in\":3600,\"token_type\":\"Bearer\"}")
                    }
                }
                guard request.httpMethod == "GET",
                      let account = ["a", "b"].first(where: {
                          let authorization = request.value(forHTTPHeaderField: "Authorization")
                          return authorization == "Bearer \(accessToken($0))"
                              || ($0 == "a" && authorization == "Bearer \(accessToken($0))-refreshed")
                      }) else { return reject() }
                let catalog = AppIdentity.googleCalendarBaseURL.appending(path: "users/me/calendarList")
                if url.host == catalog.host, url.path == catalog.path {
                    counts["\(account).catalog", default: 0] += 1
                    if mode == .calendarUnauthorized {
                        return .json("{\"error\":\"unauthorized\"}", status: 401)
                    }
                    return .json("{\"items\":[{\"id\":\"\(sourceID(account))\",\"summary\":\"Synthetic calendar\",\"primary\":true,\"selected\":true,\"accessRole\":\"reader\"}]}")
                }
                let events = AppIdentity.googleCalendarBaseURL.appending(path: "calendars").appending(path: sourceID(account)).appending(path: "events")
                if url.host == events.host, url.path == events.path {
                    counts["\(account).events", default: 0] += 1
                    let start = ISO8601DateFormatter.stableString(from: now.addingTimeInterval(3600))
                    let end = ISO8601DateFormatter.stableString(from: now.addingTimeInterval(5400))
                    return .json("{\"items\":[{\"id\":\"\(marker)-event-\(account)\",\"summary\":\"Synthetic future meeting\",\"status\":\"confirmed\",\"start\":{\"dateTime\":\"\(start)\"},\"end\":{\"dateTime\":\"\(end)\"}}]}")
                }
                return reject()
            }
        }

        private func reject() -> Response {
            counts["unexpected", default: 0] += 1
            return .failure(.unsupportedURL)
        }

        private static func body(of request: URLRequest) -> Data? {
            if let data = request.httpBody { return data }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { return nil }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= 65_536 else { return nil }
            }
            return stream.streamError == nil ? data : nil
        }
    }

    @MainActor
    private final class StaleFixture {
        let directory: URL
        let domain = "NotificationStaleRecoveryTests.\(UUID().uuidString)"
        let clock = AdvancingTestClock(Date(timeIntervalSince1970: 2_000_000_000))
        let settings: AppSettingsStore
        let cache: EventCacheStore
        let provider: StaleProvider

        init(includeEvent: Bool, initialMode: StaleProvider.Mode = .success) throws {
            directory = try TestTempDirectory.make()
            settings = AppSettingsStore(domainName: domain)
            cache = EventCacheStore(fileURL: directory.appending(path: "cache.json"))
            let account = ConnectedCalendarAccount(id: "synthetic-stale-account", displayName: "Synthetic stale account")
            let calendar = UserCalendar(
                id: "synthetic-stale-account::calendar", accountID: account.id,
                displayName: "Synthetic stale calendar", isPrimary: true, isSelected: true
            )
            let events = includeEvent ? [CalendarEventOccurrence.sample(
                eventID: "synthetic-stale-event", title: "Synthetic stale meeting",
                startDate: clock.read().addingTimeInterval(60 * 60), calendarID: calendar.id,
                location: "https://meet.google.com/synthetic-stale"
            )] : []
            provider = StaleProvider(account: account, calendar: calendar, events: events, mode: initialMode)
            settings.update {
                $0.selectedCalendarIDs = [calendar.id]
                $0.visibilityWindow = MenuVisibilityWindow(kind: .nextDays, hours: 4, days: 7)
                $0.presentationModeDefault = false
                $0.wakeGraceEnabled = false
                $0.soundEnabled = false
                $0.urgentRepeatSoundEnabled = false
            }
        }

        func makeController(notifier: any MeetingNotifying) -> MeetingShieldController {
            MeetingShieldController(
                settingsStore: settings, provider: provider,
                reminderStateStore: ReminderStateStore(fileURL: directory.appending(path: "reminders.json")),
                cacheStore: cache, notificationService: notifier,
                soundPlayer: NoSound(), dismissalPresenter: NoDismissal(),
                now: { self.clock.read() }, refreshMenuBar: {}
            )
        }

        func cleanup() {
            Task { await provider.release.open() }
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private actor StaleProvider: CalendarProvider {
        enum Mode: Sendable {
            case success
            case failure
            case heldFailure
            case heldSuccess
        }

        nonisolated let providerID = "synthetic-stale"
        let entered = RefreshHealthGate()
        let release = RefreshHealthGate()
        private let account: ConnectedCalendarAccount
        private let calendar: UserCalendar
        private let events: [CalendarEventOccurrence]
        private var mode: Mode

        init(account: ConnectedCalendarAccount, calendar: UserCalendar, events: [CalendarEventOccurrence], mode: Mode) {
            self.account = account
            self.calendar = calendar
            self.events = events
            self.mode = mode
        }

        var authState: CalendarProviderAuthState { get async { .connected(accountEmail: account.displayName) } }
        func accounts() async -> [ConnectedCalendarAccount] { [account] }
        func calendars() async throws -> [UserCalendar] { [calendar] }
        func events(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
            try await refresh(in: window, calendars: [calendar])
        }
        func refresh(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
            try await refresh(in: window, calendars: [calendar])
        }
        func refresh(in window: CalendarFetchWindow, calendars: [UserCalendar]) async throws -> [CalendarEventOccurrence] {
            switch mode {
            case .success:
                return events
            case .failure:
                throw CalendarProviderError.requestFailed(503)
            case .heldSuccess:
                await entered.open()
                guard await release.wait() else { throw CancellationError() }
                return events
            case .heldFailure:
                await entered.open()
                guard await release.wait() else { throw CancellationError() }
                throw CalendarProviderError.requestFailed(503)
            }
        }
        func reconnect() async throws {}
        func removeAccount(id: String) async throws {}
        func setMode(_ mode: Mode) { self.mode = mode }
    }

    private actor RefreshHealthGate {
        private var isOpen = false
        private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
        private var timeouts: [UUID: Task<Void, Never>] = [:]

        func wait() async -> Bool {
            if isOpen { return true }
            let id = UUID()
            return await withTaskCancellationHandler {
                if Task.isCancelled { return false }
                return await withCheckedContinuation { continuation in
                    waiters[id] = continuation
                    timeouts[id] = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                        await self?.finish(id, result: false)
                    }
                }
            } onCancel: {
                Task { await self.finish(id, result: false) }
            }
        }

        func open() {
            isOpen = true
            for id in Array(waiters.keys) { finish(id, result: true) }
        }

        private func finish(_ id: UUID, result: Bool) {
            timeouts.removeValue(forKey: id)?.cancel()
            waiters.removeValue(forKey: id)?.resume(returning: result)
        }
    }

    private final class SyntheticURLProtocol: URLProtocol {
        static let markerHeader = "X-MeetingShield-Notification-Recovery"
        private static let lock = NSLock()
        nonisolated(unsafe) private static var registrations: [String: Requests] = [:]

        static func register(_ requests: Requests) { lock.withLock { registrations[requests.marker] = requests } }
        static func remove(marker: String) { lock.withLock { _ = registrations.removeValue(forKey: marker) } }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let marker = request.value(forHTTPHeaderField: Self.markerHeader),
                  let requests = Self.lock.withLock({ Self.registrations[marker] }) else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            switch requests.response(for: request) {
            case .failure(let code):
                client?.urlProtocol(self, didFailWithError: URLError(code))
            case .json(let body, let status):
                guard let url = request.url,
                      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                    return
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }

        override func stopLoading() {}
    }
}
