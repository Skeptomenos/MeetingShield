import AppKit
import SwiftUI

@MainActor
final class KeyableAlertWindow: NSWindow {
    var onDefaultJoin: (() -> Void)?
    var onDefaultSnooze: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            AppLog.alert.info("windowKeyDown action=escapeIgnored")
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            AppLog.alert.info("windowKeyDown action=defaultJoin keyCode=\(event.keyCode, privacy: .public)")
            onDefaultJoin?()
            return
        }
        if event.charactersIgnoringModifiers?.lowercased() == "s" {
            AppLog.alert.info("windowKeyDown action=defaultSnooze")
            onDefaultSnooze?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class FullScreenAlertWindowController {
    static let shared = FullScreenAlertWindowController()

    private var windows: [NSWindow] = []
    private var keyMonitor: Any?
    private var keyTarget: AlertKeyTarget?

    private init() {}

    var isShowing: Bool {
        !windows.isEmpty
    }

    func show(
        reminders: [ScheduledReminder],
        availableSnoozeChoices: @escaping (ScheduledReminder) -> [SnoozeChoice],
        onJoin: @escaping (ScheduledReminder) -> Void,
        onSnooze: @escaping (ScheduledReminder, SnoozeChoice?) -> Void,
        onDismiss: @escaping (ScheduledReminder) -> Void,
        onMute: @escaping (ScheduledReminder) -> Void,
        onSnoozeAll: @escaping () -> Void
    ) {
        AppLog.alert.info("fullScreenShowRequested reminders=\(reminders.count, privacy: .public) existingWindows=\(self.windows.count, privacy: .public)")
        hide()
        guard !reminders.isEmpty else { return }
        let keyTarget = AlertKeyTarget(reminders: reminders)
        self.keyTarget = keyTarget
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppLog.alert.info("fullScreenActivationPolicy regular=true screens=\(NSScreen.screens.count, privacy: .public)")
        installKeyMonitor(
            keyTarget: keyTarget,
            onJoin: onJoin,
            onSnooze: onSnooze
        )
        DiagnosticsRecorder.record("fullscreen_alert_show", metadata: [
            "reminders": "\(reminders.count)",
            "screens": "\(NSScreen.screens.count)"
        ])

        for (index, screen) in NSScreen.screens.enumerated() {
            let view = MeetingAlertView(
                reminders: reminders,
                keyTarget: keyTarget,
                availableSnoozeChoices: availableSnoozeChoices,
                onJoin: onJoin,
                onSnooze: onSnooze,
                onDismiss: onDismiss,
                onMute: onMute,
                onSnoozeAll: onSnoozeAll
            )

            let window = KeyableAlertWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.onDefaultJoin = { [weak keyTarget] in
                guard let reminder = keyTarget?.selectedReminder else { return }
                onJoin(reminder)
            }
            window.onDefaultSnooze = { [weak keyTarget] in
                guard let reminder = keyTarget?.selectedReminder else { return }
                onSnooze(reminder, nil)
            }
            window.contentView = NSHostingView(rootView: view)
            window.setFrame(screen.frame, display: true)
            if index == 0 {
                window.makeKeyAndOrderFront(nil)
                AppLog.alert.debug("fullScreenWindowKey index=\(index, privacy: .public)")
            } else {
                window.orderFrontRegardless()
            }
            window.orderFrontRegardless()
            windows.append(window)
        }
        AppLog.alert.info("fullScreenShowComplete windows=\(self.windows.count, privacy: .public)")
    }

    func hide() {
        AppLog.alert.info("fullScreenHideRequested windows=\(self.windows.count, privacy: .public) keyMonitor=\(LogPrivacy.bool(self.keyMonitor != nil), privacy: .public)")
        if !windows.isEmpty {
            DiagnosticsRecorder.record("fullscreen_alert_hide", metadata: ["windows": "\(windows.count)"])
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
            AppLog.alert.debug("fullScreenKeyMonitorRemoved")
        }
        keyTarget = nil
        windows.forEach { $0.close() }
        windows.removeAll()
        if !SettingsWindowController.shared.isVisible {
            NSApp.setActivationPolicy(.accessory)
            AppLog.alert.debug("fullScreenActivationPolicy accessory=true")
        }
    }

    private func installKeyMonitor(
        keyTarget: AlertKeyTarget,
        onJoin: @escaping (ScheduledReminder) -> Void,
        onSnooze: @escaping (ScheduledReminder, SnoozeChoice?) -> Void
    ) {
        AppLog.alert.debug("fullScreenKeyMonitorInstalled")
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak keyTarget] event in
            if event.keyCode == 53 {
                AppLog.alert.info("localKeyMonitor action=escapeIgnored")
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                guard let reminder = keyTarget?.selectedReminder else { return event }
                AppLog.alert.info("localKeyMonitor action=defaultJoin keyCode=\(event.keyCode, privacy: .public) reminder=\(LogPrivacy.redactedID(reminder.id), privacy: .public)")
                onJoin(reminder)
                return nil
            }
            if event.charactersIgnoringModifiers?.lowercased() == "s" {
                guard let reminder = keyTarget?.selectedReminder else { return event }
                AppLog.alert.info("localKeyMonitor action=defaultSnooze reminder=\(LogPrivacy.redactedID(reminder.id), privacy: .public)")
                onSnooze(reminder, nil)
                return nil
            }
            return event
        }
    }
}
