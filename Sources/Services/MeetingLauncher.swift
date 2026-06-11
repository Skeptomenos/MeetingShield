import AppKit
import Foundation

protocol BrowserLaunching: Sendable {
    func open(_ url: URL, target: BrowserLaunchTarget) throws
}

/// The resolved way to launch a URL. Split from execution so argv and
/// executable selection are unit-testable.
enum BrowserLaunchCommand: Equatable, Sendable {
    case workspaceOpen(URL)
    case openTool(arguments: [String])
    case directExec(executable: URL, arguments: [String])
}

struct ProcessBrowserLauncher: BrowserLaunching {
    /// Resolves a bundle identifier to the app's main executable.
    var appExecutableResolver: @Sendable (String) -> URL?

    init(appExecutableResolver: (@Sendable (String) -> URL?)? = nil) {
        self.appExecutableResolver = appExecutableResolver ?? { bundleIdentifier in
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                return nil
            }
            return Bundle(url: appURL)?.executableURL
        }
    }

    func command(for url: URL, target: BrowserLaunchTarget) throws -> BrowserLaunchCommand {
        guard target.browser != .systemDefault, let bundleIdentifier = target.bundleIdentifier else {
            return .workspaceOpen(url)
        }
        if let profileID = target.profileID, target.browser.supportsProfileSelection {
            // `open -b <id> <url> --args --profile-directory=X` only applies the
            // profile when the browser is NOT already running — otherwise the URL
            // silently opens in the last-used profile (forbidden by TECH.md).
            // Direct binary exec forwards the profile to a running instance too.
            guard let executable = appExecutableResolver(bundleIdentifier) else {
                throw MeetingLauncherError.browserNotInstalled(target.browser.displayName)
            }
            return .directExec(
                executable: executable,
                arguments: ["--profile-directory=\(profileID)", url.absoluteString]
            )
        }
        return .openTool(arguments: ["-b", bundleIdentifier, url.absoluteString])
    }

    func open(_ url: URL, target: BrowserLaunchTarget) throws {
        switch try command(for: url, target: target) {
        case .workspaceOpen(let url):
            guard NSWorkspace.shared.open(url) else {
                throw MeetingLauncherError.launchFailed("System default browser refused the URL.")
            }
        case .openTool(let arguments):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                AppLog.alert.error("browserOpenToolFailed status=\(process.terminationStatus, privacy: .public)")
                throw MeetingLauncherError.launchFailed("\(target.browser.displayName) could not be opened (open exited \(process.terminationStatus)).")
            }
        case .directExec(let executable, let arguments):
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            // Do not wait: a fresh browser process keeps running; an already-
            // running browser makes this forwarder exit immediately.
            try process.run()
        }
    }
}

struct MeetingLaunchResult: Equatable, Sendable {
    var openedURL: URL
    var target: BrowserLaunchTarget
    var usedFallbackProfile: Bool
    var warning: String?
}

struct MeetingLauncher: Sendable {
    var profileService: BrowserProfileService
    var browserLauncher: any BrowserLaunching

    init(
        profileService: BrowserProfileService = BrowserProfileService(),
        browserLauncher: any BrowserLaunching = ProcessBrowserLauncher()
    ) {
        self.profileService = profileService
        self.browserLauncher = browserLauncher
    }

    func launch(
        event: CalendarEventOccurrence,
        detectedLinks: [MeetingLink],
        browserSelection: BrowserSelection,
        urgent: Bool
    ) throws -> MeetingLaunchResult {
        let url = detectedLinks.first?.url ?? event.htmlLink ?? AppIdentity.googleCalendarBaseURL
        var target = profileService.resolve(selection: browserSelection)
        var warning: String?
        var usedFallback = false

        if let profileID = target.profileID,
           !profileService.hasProfile(profileID, for: target.browser) {
            if urgent {
                target.profileID = nil
                usedFallback = true
                warning = "Couldn't open \(profileID); opened \(target.browser.displayName) default."
            } else {
                throw MeetingLauncherError.profileNotFound(profileID)
            }
        }

        do {
            try browserLauncher.open(url, target: target)
        } catch {
            // Urgent joins must not dead-end on a broken branded-browser
            // setup; fall back to the system default browser visibly.
            guard urgent, target.browser != .systemDefault else { throw error }
            AppLog.alert.error("brandedBrowserLaunchFailedFallingBack error=\(LogPrivacy.errorClass(error), privacy: .public)")
            let fallbackTarget = BrowserLaunchTarget(browser: .systemDefault, profileID: nil, bundleIdentifier: nil)
            try browserLauncher.open(url, target: fallbackTarget)
            return MeetingLaunchResult(
                openedURL: url,
                target: fallbackTarget,
                usedFallbackProfile: true,
                warning: "Couldn't open \(target.browser.displayName); opened your default browser instead."
            )
        }
        return MeetingLaunchResult(openedURL: url, target: target, usedFallbackProfile: usedFallback, warning: warning)
    }
}

enum MeetingLauncherError: Error, LocalizedError, Equatable {
    case profileNotFound(String)
    case browserNotInstalled(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .profileNotFound(let profile):
            "Browser profile not found: \(profile)"
        case .browserNotInstalled(let browser):
            "\(browser) is not installed."
        case .launchFailed(let reason):
            reason
        }
    }
}
