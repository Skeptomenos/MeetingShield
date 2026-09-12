import AppKit

@MainActor
final class DismissConfirmationWindowController: DismissalConfirming {
    static let shared = DismissConfirmationWindowController()

    private var requestID: UUID?
    private var alert: NSAlert?
    private var parent: NSWindow?
    private var completion: (@MainActor (Bool) -> Void)?
    private var keyMonitor: Any?

    private init() {}

    var isShowing: Bool { requestID != nil }

    func present(
        requestID: UUID,
        reminder: ScheduledReminder,
        source: DismissalRequestSource,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let parent: NSWindow?
        switch source {
        case .fullScreen:
            parent = FullScreenAlertWindowController.shared.dismissalConfirmationParent(for: reminder)
        case .fallback:
            parent = JoinFallbackWindowController.shared.dismissalConfirmationParent(for: reminder)
        }
        guard self.requestID == nil, let parent, parent.isVisible,
              parent.attachedSheet == nil, parent.sheets.isEmpty else {
            completion(false)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Dismiss this meeting?"
        alert.informativeText = "\(reminder.event.title) will not alert again unless it materially changes. Other meetings stay protected."
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\r"
        cancelButton.keyEquivalentModifierMask = []
        let dismissButton = alert.addButton(withTitle: "Dismiss this meeting")
        dismissButton.keyEquivalent = ""
        dismissButton.hasDestructiveAction = true
        alert.window.isReleasedWhenClosed = false
        let ownedLevels = [
            parent.level.rawValue,
            FullScreenAlertWindowController.shared.highestVisibleWindowLevel?.rawValue,
            JoinFallbackWindowController.shared.visibleWindowLevel?.rawValue
        ].compactMap { $0 }
        alert.window.level = NSWindow.Level(rawValue: (ownedLevels.max() ?? parent.level.rawValue) + 1)

        self.requestID = requestID
        self.alert = alert
        self.parent = parent
        self.completion = completion
        installKeyMonitor(requestID: requestID)
        alert.beginSheetModal(for: parent) { [weak self, alert, parent] response in
            withExtendedLifetime((alert, parent)) {
                self?.resolve(requestID: requestID, confirmed: response == .alertSecondButtonReturn)
            }
        }
    }

    func cancel(requestID: UUID) {
        resolve(requestID: requestID, confirmed: false, endSheet: true)
    }

    private func resolve(requestID: UUID, confirmed: Bool, endSheet: Bool = false) {
        guard self.requestID == requestID, let alert, let parent, let completion else { return }
        self.requestID = nil
        self.alert = nil
        self.parent = nil
        self.completion = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if endSheet, alert.window.sheetParent === parent {
            parent.endSheet(alert.window, returnCode: .cancel)
        }
        alert.window.orderOut(nil)
        completion(confirmed && parent.isVisible)
    }

    private func installKeyMonitor(requestID: UUID) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.requestID == requestID, let alert = self.alert else { return event }
            if (event.window ?? NSApp.keyWindow) === alert.window {
                if event.keyCode == 53 {
                    self.cancel(requestID: requestID)
                    return nil
                }
                return event
            }
            if event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 76
                || event.charactersIgnoringModifiers?.lowercased() == "s" {
                return nil
            }
            return event
        }
    }
}
