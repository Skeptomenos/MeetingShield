import AppKit
import Foundation
@preconcurrency import UserNotifications

struct MeetingNotification: Sendable {
    var id: String
    var title: String
    var body: String
    var date: Date?
    var withSound: Bool = false
}

struct NotificationSettingsSnapshot: Equatable, Sendable {
    var authorizationStatus: UNAuthorizationStatus
    var alertSetting: UNNotificationSetting? = nil
    var alertStyle: UNAlertStyle? = nil
    var scheduledDeliverySetting: UNNotificationSetting? = nil
}

protocol MeetingNotifying: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func notificationSettings() async -> NotificationSettingsSnapshot
    func requestAuthorization() async throws -> Bool
    func deliver(_ notification: MeetingNotification) async throws
    @MainActor func setResponseHandler(_ handler: (@MainActor @Sendable (String) -> Void)?)
}

extension MeetingNotifying {
    func notificationSettings() async -> NotificationSettingsSnapshot {
        NotificationSettingsSnapshot(authorizationStatus: await authorizationStatus())
    }

    @MainActor func setResponseHandler(_ handler: (@MainActor @Sendable (String) -> Void)?) {}
}

struct NoopNotificationService: MeetingNotifying {
    func authorizationStatus() async -> UNAuthorizationStatus { .notDetermined }
    func requestAuthorization() async throws -> Bool { false }
    func deliver(_ notification: MeetingNotification) async throws {}
}

final class NotificationService: NSObject, UNUserNotificationCenterDelegate, MeetingNotifying, @unchecked Sendable {
    static let shared = NotificationService()

    private let center: UNUserNotificationCenter
    private let responseLock = NSLock()
    private var responseHandler: (@MainActor @Sendable (String) -> Void)?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    @MainActor
    func setResponseHandler(_ handler: (@MainActor @Sendable (String) -> Void)?) {
        responseLock.withLock { responseHandler = handler }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func notificationSettings() async -> NotificationSettingsSnapshot {
        let settings = await center.notificationSettings()
        return NotificationSettingsSnapshot(
            authorizationStatus: settings.authorizationStatus,
            alertSetting: settings.alertSetting,
            alertStyle: settings.alertStyle,
            scheduledDeliverySetting: settings.scheduledDeliverySetting
        )
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func deliver(_ notification: MeetingNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = notification.withSound ? .default : nil

        let trigger: UNNotificationTrigger?
        if let date = notification.date, date > Date() {
            let interval = max(1, date.timeIntervalSinceNow)
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        } else {
            trigger = nil
        }

        let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: trigger)
        try await center.add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let identifier = response.notification.request.identifier
        let handler = responseLock.withLock { responseHandler }
        await handler?(identifier)
    }
}
