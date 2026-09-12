import AppKit
import Foundation
import SwiftUI

@MainActor
final class RuntimeFallbackCheck {
    private enum Scenario: String {
        case timeout, close, reopen, dismiss, overlap
    }

    private struct Failure: Error {
        let code: String
    }

    static let argument = "--runtime-fallback-check"
    static var isRequested: Bool { CommandLine.arguments.contains(argument) }

    private var controller: MeetingShieldController?
    private var defaultsDomain: String?

    static func requireIsolatedHome() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MEETING_SHIELD_RUNTIME_HOME"], path.hasPrefix("/"),
              path == environment["CFFIXED_USER_HOME"],
              URL(fileURLWithPath: path).lastPathComponent.hasPrefix("home."),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: path), contents.isEmpty,
              URL(fileURLWithPath: path).resolvingSymlinksInPath() == FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath() else {
            emit("result=blocked reason=isolated_home_required")
            exit(78)
        }
    }

    func run() async {
        guard let index = CommandLine.arguments.firstIndex(of: Self.argument),
              index + 1 < CommandLine.arguments.count,
              let scenario = Scenario(rawValue: CommandLine.arguments[index + 1]) else {
            Self.emit("result=failed reason=invalid_scenario")
            exit(1)
        }
        guard !NSScreen.screens.isEmpty else {
            Self.emit("result=blocked reason=window_server_required")
            exit(78)
        }
        do {
            try await verify(scenario)
            cleanup()
            try requireReleasedAlertContent()
            try await Task.sleep(for: .milliseconds(500))
            Self.emit("checkpoint=completed")
            Self.emit("result=passed scenario=\(scenario.rawValue)")
            NSApp.terminate(nil)
        } catch {
            cleanup()
            Self.emit("result=failed reason=\((error as? Failure)?.code ?? "runtime_error")")
            exit(1)
        }
    }

    private func verify(_ scenario: Scenario) async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
        let domain = "com.skeptomenos.meetingshield.runtime.\(UUID().uuidString)"
        defaultsDomain = domain
        guard UserDefaults(suiteName: domain) != nil else { throw Failure(code: "settings_unavailable") }
        let settings = AppSettingsStore(domainName: domain)
        settings.update {
            $0.soundEnabled = false
            $0.urgentRepeatSoundEnabled = false
            $0.wakeGraceEnabled = false
        }
        let recording = RuntimeRecordingBrowserLauncher()
        let anchor = Date()
        let laterDelay: TimeInterval = scenario == .reopen ? 16 : 13
        let controller = MeetingShieldController(
            settingsStore: settings,
            provider: RuntimeCalendarProvider(mode: scenario == .overlap ? .overlap : .fallback, anchor: anchor, laterDelay: laterDelay),
            reminderStateStore: ReminderStateStore(fileURL: root.appending(path: "runtime-reminder-state.json")),
            cacheStore: EventCacheStore(fileURL: root.appending(path: "runtime-event-cache.json")),
            notificationService: NoopNotificationService(),
            launcher: MeetingLauncher(profileService: BrowserProfileService(homeDirectory: root), browserLauncher: recording)
        )
        self.controller = controller
        await controller.refresh(reason: "runtime-check")
        try require(controller.activeReminders.count == (scenario == .overlap ? 2 : 1), "initial_count")
        try requireFullScreen("initial_alert")
        guard let reminder = controller.activeReminders.last else { throw Failure(code: "initial_reminder_missing") }
        let remainingIDs = Set(controller.activeReminders.map(\.id)).subtracting([reminder.id])
        let expectedURL = reminder.detectedLinks.first?.url
        let joinedAt = Date()
        controller.join(reminder)
        var lastOpenedAt = Date()
        try require(recording.requests.count == 1 && recording.requests.first == expectedURL, "launch_target")
        Self.emit("checkpoint=launch_recorded")
        try require(controller.fallback?.reminder.id == reminder.id && JoinFallbackWindowController.shared.isShowing, "fallback_missing")
        Self.emit("checkpoint=fallback_visible")
        try require(Set(controller.activeReminders.map(\.id)) == remainingIDs, "join_lost_other_reminders")
        await controller.refresh(reason: "runtime-check")
        try require(Set(controller.activeReminders.map(\.id)) == remainingIDs, "joined_reminder_reappeared")

        switch scenario {
        case .timeout:
            break
        case .close:
            try await Task.sleep(for: .milliseconds(500))
            controller.clearFallback()
        case .dismiss:
            try await Task.sleep(for: .milliseconds(500))
            controller.dismiss(reminder)
            controller.clearFallback()
        case .reopen:
            try await Task.sleep(for: .seconds(2))
            controller.openAgainFromFallback()
            lastOpenedAt = Date()
            try require(recording.requests.count == 2 && recording.requests.last == expectedURL, "reopen_target")
            try await waitUntil(joinedAt.addingTimeInterval(10.5))
            try require(controller.fallback != nil && JoinFallbackWindowController.shared.isShowing, "reopen_timer_not_reset")
            Self.emit("checkpoint=reopen_timer_reset")
        case .overlap:
            try await requireFallbackAboveAlerts()
            for expectedCount in 2...3 {
                try await Task.sleep(for: .milliseconds(250))
                controller.openAgainFromFallback()
                lastOpenedAt = Date()
                try require(recording.requests.count == expectedCount && recording.requests.last == expectedURL, "overlap_reopen_target")
            }
            Self.emit("checkpoint=repeated_overlap_reopen")
        }

        let closeDeadline = lastOpenedAt.addingTimeInterval(12)
        while controller.fallback != nil || JoinFallbackWindowController.shared.isShowing {
            try require(Date() < closeDeadline, "fallback_close_timeout")
            try await Task.sleep(for: .milliseconds(100))
        }
        if scenario == .timeout || scenario == .overlap || scenario == .reopen {
            try require(Date().timeIntervalSince(lastOpenedAt) >= 9.5, "fallback_closed_early")
        }
        try await Task.sleep(for: .milliseconds(500))
        Self.emit("checkpoint=fallback_closed")

        let laterDeadline = anchor.addingTimeInterval(laterDelay + 4)
        while !controller.activeReminders.contains(where: { $0.event.eventID == "runtime-later" }) {
            try require(Date() < laterDeadline, "later_reminder_timeout")
            try await Task.sleep(for: .milliseconds(100))
        }
        try requireFullScreen("later_alert")
        try await Task.sleep(for: .milliseconds(500))
        try require(controller.activeReminders.contains(where: { $0.event.eventID == "runtime-later" }), "later_reminder_lost")
        let laterIDs = Set(controller.activeReminders.filter { $0.event.eventID == "runtime-later" }.map(\.id))
        try require(Set(controller.activeReminders.map(\.id)) == remainingIDs.union(laterIDs), "later_reminder_membership")
        try require(FullScreenAlertWindowController.shared.visibleWindowCount > 0, "later_window_lost")
    }

    private func waitUntil(_ date: Date) async throws {
        while Date() < date { try await Task.sleep(for: .milliseconds(100)) }
    }

    private func requireFallbackAboveAlerts() async throws {
        guard let fallback = NSApp.windows.first(where: {
            $0.isVisible && $0.contentView is NSHostingView<JoinFallbackView>
        }) else { throw Failure(code: "fallback_missing") }
        let alerts = NSApp.windows.compactMap { $0 as? KeyableAlertWindow }
            .filter { $0.isVisible }
            .sorted { $0.windowNumber < $1.windowNumber }
        for alert in alerts {
            alert.makeKeyAndOrderFront(nil)
            alert.orderFrontRegardless()
        }
        try await Task.sleep(for: .milliseconds(200))
        let orderedWindows = NSApp.orderedWindows
        guard fallback.isVisible,
              let fallbackIndex = orderedWindows.firstIndex(where: { $0 === fallback }) else {
            throw Failure(code: "fallback_obscured_by_alert")
        }
        let intersectingAlerts = alerts.filter { $0.isVisible && $0.frame.intersects(fallback.frame) }
        try require(!intersectingAlerts.isEmpty && intersectingAlerts.allSatisfy { alert in
            guard let alertIndex = orderedWindows.firstIndex(where: { $0 === alert }) else { return false }
            return fallbackIndex < alertIndex
        }, "fallback_obscured_by_alert")
        Self.emit("checkpoint=fallback_order_preserved")
    }

    private func requireFullScreen(_ checkpoint: String) throws {
        let count = FullScreenAlertWindowController.shared.visibleWindowCount
        try require(count > 0 && count == NSScreen.screens.count, "native_window_missing")
        Self.emit("checkpoint=\(checkpoint)")
    }

    private func require(_ condition: Bool, _ code: String) throws {
        if !condition { throw Failure(code: code) }
    }

    private func requireReleasedAlertContent() throws {
        let retainedWindows = NSApp.windows.compactMap { $0 as? KeyableAlertWindow }
            .filter { !$0.isVisible }
        try require(retainedWindows.allSatisfy {
            $0.contentView == nil && $0.onDefaultJoin == nil && $0.onDefaultSnooze == nil
        }, "alert_window_content_retained")
    }

    private func cleanup() {
        controller?.clearFallback()
        FullScreenAlertWindowController.shared.hide()
        if let defaultsDomain { UserDefaults.standard.removePersistentDomain(forName: defaultsDomain) }
    }

    private static func emit(_ value: String) {
        FileHandle.standardOutput.write(Data("RUNTIME_CHECK \(value)\n".utf8))
    }
}
