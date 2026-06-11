import Foundation
import Testing
import UserNotifications
@testable import MeetingShield

private final class RecordingNotifier: MeetingNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var deliveredIDs: [String] = []
    var deliveryError: Error?
    var status: UNAuthorizationStatus = .authorized

    var delivered: [String] {
        lock.withLock { deliveredIDs }
    }

    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async throws -> Bool { status == .authorized }

    func deliver(_ notification: MeetingNotification) async throws {
        if let deliveryError { throw deliveryError }
        lock.withLock { deliveredIDs.append(notification.id) }
    }
}

@Suite("Notification health and dispatch")
@MainActor
struct NotificationDispatchTests {
    @Test("Denied authorization produces a visible warning when notifications carry the alerts")
    func deniedAuthorizationWarns() {
        let health = NotificationHealth()
        health.recordAuthorizationStatus(.denied)

        #expect(health.authorizationDenied)
        let warning = try? #require(health.warningMessage(notificationsCarryAlerts: true))
        #expect(warning?.localizedCaseInsensitiveContains("notification") == true)
    }

    @Test("Denied authorization stays quiet while full-screen alerts are active")
    func deniedAuthorizationQuietWhenFullScreenActive() {
        let health = NotificationHealth()
        health.recordAuthorizationStatus(.denied)

        #expect(health.warningMessage(notificationsCarryAlerts: false) == nil)
    }

    @Test("Authorized status produces no warning")
    func authorizedProducesNoWarning() {
        let health = NotificationHealth()
        health.recordAuthorizationStatus(.authorized)

        #expect(!health.authorizationDenied)
        #expect(health.warningMessage(notificationsCarryAlerts: true) == nil)
    }

    @Test("Delivery failure is recorded and surfaces a warning")
    func deliveryFailureSurfacesWarning() async {
        let notifier = RecordingNotifier()
        notifier.deliveryError = URLError(.unknown)
        let health = NotificationHealth()
        let dispatcher = NotificationDispatcher(notifier: notifier, health: health)

        await dispatcher.deliver([
            MeetingNotification(id: "a", title: "Meeting", body: "Starts soon", date: nil)
        ])

        #expect(health.lastDeliveryFailed)
        #expect(health.warningMessage(notificationsCarryAlerts: true) != nil)
    }

    @Test("Successful delivery clears prior failures and reaches the notifier")
    func successfulDeliveryClearsFailure() async {
        let notifier = RecordingNotifier()
        let health = NotificationHealth()
        let dispatcher = NotificationDispatcher(notifier: notifier, health: health)

        notifier.deliveryError = URLError(.unknown)
        await dispatcher.deliver([MeetingNotification(id: "fails", title: "T", body: "B", date: nil)])
        #expect(health.lastDeliveryFailed)

        notifier.deliveryError = nil
        await dispatcher.deliver([
            MeetingNotification(id: "a", title: "T", body: "B", date: nil),
            MeetingNotification(id: "b", title: "T", body: "B", date: nil)
        ])

        #expect(!health.lastDeliveryFailed)
        #expect(notifier.delivered == ["a", "b"])
    }
}
