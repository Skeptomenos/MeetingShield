import AppKit
import SwiftUI

@main
struct MeetingShieldApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        ProcessInfo.processInfo.disableAutomaticTermination("Meeting Shield continuously monitors meeting reminders.")
        ProcessInfo.processInfo.disableSuddenTermination()
        AppLog.lifecycle.info("applicationInitialized automaticTerminationDisabled=true suddenTerminationDisabled=true")
        DiagnosticsRecorder.record("app_initialized")
    }

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.lifecycle.info("applicationDidFinishLaunching bundle=\(Bundle.main.bundleIdentifier ?? "missing", privacy: .public) smoke=\(CommandLine.arguments.contains("--smoke-test"), privacy: .public)")
        NSApp.setActivationPolicy(.accessory)
        DiagnosticsRecorder.record("launch_complete")
        if CommandLine.arguments.contains("--smoke-test") {
            AppLog.lifecycle.info("smokeTestLaunch")
            print("Meeting Shield smoke launch OK")
            NSApp.terminate(nil)
            return
        }
        configureMainMenu()
        MenuBarController.shared.configure(controller: MeetingShieldController.shared)
        MeetingShieldController.shared.start()
        DispatchQueue.main.async { [weak self] in
            self?.configureMainMenu()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLog.lifecycle.info("applicationShouldTerminate")
        DiagnosticsRecorder.record("termination_requested")
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.lifecycle.info("applicationWillTerminate")
        DiagnosticsRecorder.record("application_will_terminate")
        MeetingShieldController.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func openSettingsFromMenu(_ sender: Any?) {
        MeetingShieldController.shared.openSettings()
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: AppIdentity.displayName)

        appMenu.addItem(NSMenuItem(
            title: "About \(AppIdentity.displayName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettingsFromMenu(_:)), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(settingsItem)

        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit \(AppIdentity.displayName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }
}
