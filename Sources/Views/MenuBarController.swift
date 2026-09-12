import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    static let shared = MenuBarController()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let presentation = MenuPresentationState()
    private var controller: MeetingShieldController?

    private override init() {
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    func configure(controller: MeetingShieldController) {
        self.controller = controller
        updatePopoverSize()
        updateButton()
    }

    func refresh() {
        updatePopoverSize()
        updateButton()
    }

    func closePopover() {
        popover.performClose(nil)
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        updatePopoverSize()
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(from: sender)
            return
        }

        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func updateButton() {
        guard let controller, let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: controller.menuBarSystemImage, accessibilityDescription: "Meeting Shield")
        button.image?.isTemplate = true
        let text = controller.menuBarText.resolved { value in
            let font = button.font ?? NSFont.menuBarFont(ofSize: 0)
            return NSString(string: " \(value)").size(withAttributes: [.font: font]).width
        }
        button.title = text == AppIdentity.menuBarTitle ? "" : " \(text)"
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("Meeting Shield")
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        closePopover()
        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Restart \(AppIdentity.displayName)",
            action: #selector(restartApp(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit \(AppIdentity.displayName)",
            action: #selector(quitApp(_:)),
            keyEquivalent: ""
        ))
        menu.items.forEach { $0.target = self }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func restartApp(_ sender: Any?) {
        closePopover()
        AppLog.lifecycle.info("restartRequested")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        do {
            try process.run()
        } catch {
            AppLog.lifecycle.error("restartOpenFailed error=\(LogPrivacy.errorClass(error), privacy: .public)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }

    @objc private func quitApp(_ sender: Any?) {
        closePopover()
        AppLog.lifecycle.info("quitRequested")
        NSApp.terminate(nil)
    }

    private func updatePopoverSize() {
        let eventCount = controller?.menuEvents.count ?? 0
        let preferredHeight = MenuContentView.preferredHeight(
            eventCount: eventCount, hasPersistenceWarning: controller?.persistenceWarnings.isEmpty == false,
            hasNotificationWarning: controller?.notificationWarning != nil || controller?.statusMessage != nil,
            showsMonth: presentation.showsMonth,
            showsHealth: presentation.showsHealth || controller?.protectionHealthSummary.level != .healthy
        )
        let height = min(preferredHeight, maximumVisiblePopoverHeight())
        popover.contentSize = NSSize(
            width: MenuContentView.preferredWidth,
            height: height
        )
        updatePopoverContent(height: height)
    }

    private func updatePopoverContent(height: CGFloat) {
        guard let controller else { return }
        if let hostingController = popover.contentViewController as? NSHostingController<MenuContentView> {
            hostingController.rootView = content(controller: controller, height: height)
        } else {
            popover.contentViewController = NSHostingController(
                rootView: content(controller: controller, height: height)
            )
        }
    }

    private func content(controller: MeetingShieldController, height: CGFloat) -> MenuContentView {
        MenuContentView(controller: controller, popoverHeight: height, presentation: presentation,
                        onExpansionChange: { [weak self] in self?.updatePopoverSize() })
    }

    private func maximumVisiblePopoverHeight() -> CGFloat {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        guard let visibleHeight = screen?.visibleFrame.height else {
            return 560
        }
        return max(320, visibleHeight * 2 / 3)
    }
}
