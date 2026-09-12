import AppKit
import SwiftUI

@main
struct MeetingShieldApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if RuntimeFallbackCheck.isRequested || RuntimePresentationCheck.isRequested {
            RuntimeFallbackCheck.requireIsolatedHome()
        }
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
    private var runtimeCheck: RuntimeFallbackCheck?
    private var presentationCheck: RuntimePresentationCheck?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.lifecycle.info("applicationDidFinishLaunching bundle=\(Bundle.main.bundleIdentifier ?? "missing", privacy: .public) smoke=\(CommandLine.arguments.contains("--smoke-test"), privacy: .public)")
        NSApp.setActivationPolicy(.accessory)
        DiagnosticsRecorder.record("launch_complete")
        if RuntimePresentationCheck.isRequested {
            let check = RuntimePresentationCheck()
            presentationCheck = check
            Task { await check.run() }
            return
        }
        if RuntimeFallbackCheck.isRequested {
            let check = RuntimeFallbackCheck()
            runtimeCheck = check
            Task { await check.run() }
            return
        }
        if CommandLine.arguments.contains("--smoke-test") {
            AppLog.lifecycle.info("smokeTestLaunch")
            print("Meeting Shield smoke launch OK")
            NSApp.terminate(nil)
            return
        }
        configureMainMenu()
        MenuBarController.shared.configure(controller: MeetingShieldController.shared)
        MeetingShieldController.shared.start()
#if DEBUG
        if CommandLine.arguments.contains("--show-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MenuBarController.shared.showPopover() }
        }
#endif
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
        if !RuntimeFallbackCheck.isRequested && !RuntimePresentationCheck.isRequested {
            MeetingShieldController.shared.stop()
        }
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
