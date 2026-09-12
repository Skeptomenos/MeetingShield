import AppKit
import SwiftUI

@MainActor
final class KeyableAlertWindow: NSWindow {
    var onDefaultJoin: (() -> Void)?
    var onDefaultSnooze: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard !DismissConfirmationWindowController.shared.isShowing else { return }
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
final class FullScreenAlertWindowController: FullScreenAlertPresenting {
    static let shared = FullScreenAlertWindowController()

    private var windows: [NSWindow] = []
    private var keyMonitor: Any?
    private var keyTarget: AlertKeyTarget?

    private init() {}

    var isShowing: Bool {
        !windows.isEmpty
    }

    var visibleWindowCount: Int { windows.filter(\.isVisible).count }
    var selectedReminderID: String? { keyTarget?.selectedReminder?.id }
    var highestVisibleWindowLevel: NSWindow.Level? {
        windows.filter(\.isVisible).map(\.level).max { $0.rawValue < $1.rawValue }
    }

    func dismissalConfirmationParent(for reminder: ScheduledReminder) -> NSWindow? {
        guard keyTarget?.reminders.contains(where: { $0.id == reminder.id }) == true else { return nil }
        let visibleWindows = windows.filter(\.isVisible)
        if let keyWindow = NSApp.keyWindow, visibleWindows.contains(where: { $0 === keyWindow }) {
            return keyWindow
        }
        if let eventWindow = NSApp.currentEvent?.window, visibleWindows.contains(where: { $0 === eventWindow }) {
            return eventWindow
        }
        return visibleWindows.first
    }

    func show(
        reminders: [ScheduledReminder],
        selectedID: String? = nil,
        availableSnoozeChoices: @escaping (ScheduledReminder, Date) -> [SnoozeChoice],
        onJoin: @escaping (ScheduledReminder) -> Void,
        onSnooze: @escaping (ScheduledReminder, SnoozeChoice?) -> Void,
        onDismiss: @escaping (ScheduledReminder) -> Void,
        onRequestDismissal: @escaping (ScheduledReminder) -> Void,
        onMute: @escaping (ScheduledReminder) -> Void,
        onSnoozeAll: @escaping () -> Void
    ) {
        AppLog.alert.info("fullScreenShowRequested reminders=\(reminders.count, privacy: .public) existingWindows=\(self.windows.count, privacy: .public)")
        hide()
        guard !reminders.isEmpty else { return }
        let keyTarget = AlertKeyTarget(reminders: reminders)
        if let selectedID, reminders.contains(where: { $0.id == selectedID }) {
            keyTarget.selectedID = selectedID
        }
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
                keyTarget: keyTarget,
                availableSnoozeChoices: availableSnoozeChoices,
                onJoin: onJoin,
                onSnooze: onSnooze,
                onDismiss: onDismiss,
                onRequestDismissal: onRequestDismissal,
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

    func update(reminders: [ScheduledReminder]) {
        guard !reminders.isEmpty else {
            hide()
            return
        }
        guard isShowing, let keyTarget else { return }
        keyTarget.update(reminders: reminders)
        DiagnosticsRecorder.record("fullscreen_alert_update", metadata: [
            "reminders": "\(reminders.count)", "windows": "\(windows.count)"
        ])
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
        windows.forEach { window in
            if let alertWindow = window as? KeyableAlertWindow {
                alertWindow.onDefaultJoin = nil
                alertWindow.onDefaultSnooze = nil
            }
            window.contentView = nil
            window.close()
        }
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
            if DismissConfirmationWindowController.shared.isShowing { return event }
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
