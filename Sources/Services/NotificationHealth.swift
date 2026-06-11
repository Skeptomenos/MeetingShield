import Foundation
import UserNotifications

/// Tracks whether macOS notifications — the only alert channel during
/// presentation mode and wake grace — can actually reach the user.
/// QUALITY.md: "Disabled notification permission warns because Presentation
/// mode depends on macOS notifications."
@MainActor
final class NotificationHealth: ObservableObject {
    @Published private(set) var authorizationDenied = false
    @Published private(set) var lastDeliveryFailed = false

    func recordAuthorizationStatus(_ status: UNAuthorizationStatus) {
        authorizationDenied = status == .denied
    }

    func recordDeliveryResult(success: Bool) {
        lastDeliveryFailed = !success
    }

    /// A user-visible warning, or nil when notifications are healthy or not
    /// currently load-bearing (full-screen alerts active).
    func warningMessage(notificationsCarryAlerts: Bool) -> String? {
        guard notificationsCarryAlerts else { return nil }
        if authorizationDenied {
            return "Notifications are disabled in System Settings; Presentation mode and wake grace alerts cannot appear."
        }
        if lastDeliveryFailed {
            return "Meeting notification delivery failed; alerts may not be visible."
        }
        return nil
    }
}

/// Delivers meeting notifications and records the outcome instead of
/// swallowing errors (`try?`) like the previous inline implementation did.
@MainActor
struct NotificationDispatcher {
    let notifier: any MeetingNotifying
    let health: NotificationHealth

    func deliver(_ notifications: [MeetingNotification]) async {
        var allSucceeded = true
        for notification in notifications {
            do {
                try await notifier.deliver(notification)
            } catch {
                allSucceeded = false
                AppLog.alert.error("notificationDeliveryFailed id=\(LogPrivacy.redactedID(notification.id), privacy: .public) error=\(LogPrivacy.errorClass(error), privacy: .public)")
            }
        }
        health.recordDeliveryResult(success: allSucceeded)
        if !allSucceeded {
            DiagnosticsRecorder.record("notification_delivery_failed", metadata: [
                "count": "\(notifications.count)"
            ])
        }
    }

    func refreshAuthorizationStatus() async {
        let status = await notifier.authorizationStatus()
        health.recordAuthorizationStatus(status)
        AppLog.alert.debug("notificationAuthorizationStatus denied=\(LogPrivacy.bool(status == .denied), privacy: .public)")
    }
}
