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

protocol MeetingNotifying: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func deliver(_ notification: MeetingNotification) async throws
}

struct NoopNotificationService: MeetingNotifying {
    func authorizationStatus() async -> UNAuthorizationStatus { .notDetermined }
    func requestAuthorization() async throws -> Bool { false }
    func deliver(_ notification: MeetingNotification) async throws {}
}

final class NotificationService: NSObject, UNUserNotificationCenterDelegate, MeetingNotifying, @unchecked Sendable {
    static let shared = NotificationService()

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
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
        // Clicking a meeting notification brings Meeting Shield forward so the
        // user can act on the reminder. Deep-link join is a tracked follow-up.
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
