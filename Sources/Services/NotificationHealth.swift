import Foundation
import UserNotifications

@MainActor
final class NotificationHealth: ObservableObject {
    @Published private(set) var authorizationDenied = false
    @Published private(set) var lastDeliveryFailed = false

    private var notificationSettings: NotificationSettingsSnapshot?

    func recordNotificationSettings(_ settings: NotificationSettingsSnapshot) {
        notificationSettings = settings
        authorizationDenied = settings.authorizationStatus == .denied
    }

    func recordAuthorizationStatus(_ status: UNAuthorizationStatus) {
        recordNotificationSettings(NotificationSettingsSnapshot(authorizationStatus: status))
    }

    func recordDeliveryResult(success: Bool) {
        lastDeliveryFailed = !success
    }

    func warningMessage(notificationsCarryAlerts: Bool) -> String? {
        guard notificationsCarryAlerts else { return nil }
        if authorizationDenied {
            return "Notifications are disabled in System Settings; Presentation mode and wake grace alerts cannot appear."
        }
        if notificationSettings?.authorizationStatus == .notDetermined {
            return "Notification permission is not granted; Presentation mode and wake grace alerts may not appear."
        }
        if notificationSettings?.authorizationStatus == .authorized,
           notificationSettings?.alertSetting == .disabled || notificationSettings?.alertStyle == UNAlertStyle.none {
            return "Notification banners are disabled in System Settings; Presentation mode and wake grace alerts may not appear."
        }
        if lastDeliveryFailed {
            return "Meeting notification delivery failed; alerts may not be visible."
        }
        if notificationSettings?.authorizationStatus == .provisional {
            return "Notifications use quiet delivery; Presentation mode and wake grace alerts may not be visible."
        }
        if notificationSettings?.scheduledDeliverySetting == .enabled {
            return "Notifications may be delayed by scheduled delivery; Presentation mode and wake grace alerts may arrive late."
        }
        return nil
    }

    func protectionSummaryStatus(notificationsCarryAlerts: Bool) -> ProtectionHealthSummary.Notification {
        guard notificationsCarryAlerts else { return .notRequired }
        guard let notificationSettings else { return .unknown }
        if warningMessage(notificationsCarryAlerts: true) != nil { return .blocked }
        return notificationSettings.authorizationStatus == .authorized ? .available : .unknown
    }
}

enum NotificationDeliveryOutcome: Sendable {
    case submitted
    case failed
    case obsolete
}

@MainActor
struct NotificationDispatcher {
    let notifier: any MeetingNotifying
    let health: NotificationHealth

    @discardableResult
    func deliver(
        _ notifications: [MeetingNotification],
        isCurrent: @MainActor () -> Bool = { true }
    ) async -> NotificationDeliveryOutcome {
        guard isCurrent() else { return .obsolete }
        var allSucceeded = true
        for notification in notifications {
            guard isCurrent() else { return .obsolete }
            do {
                try await notifier.deliver(notification)
            } catch {
                guard isCurrent() else { return .obsolete }
                allSucceeded = false
                AppLog.alert.error("notificationDeliveryFailed id=\(LogPrivacy.redactedID(notification.id), privacy: .public) error=\(LogPrivacy.errorClass(error), privacy: .public)")
            }
        }
        guard isCurrent() else { return .obsolete }
        health.recordDeliveryResult(success: allSucceeded)
        if !allSucceeded {
            DiagnosticsRecorder.record("notification_delivery_failed", metadata: [
                "count": "\(notifications.count)"
            ])
        }
        return allSucceeded ? .submitted : .failed
    }

    func refreshAuthorizationStatus(isCurrent: @MainActor () -> Bool = { true }) async {
        guard isCurrent() else { return }
        let settings = await notifier.notificationSettings()
        guard isCurrent() else { return }
        health.recordNotificationSettings(settings)
        AppLog.alert.debug("notificationAuthorizationStatus denied=\(LogPrivacy.bool(settings.authorizationStatus == .denied), privacy: .public)")
    }
}
