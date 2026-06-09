import AppKit
import Foundation

protocol BrowserLaunching: Sendable {
    func open(_ url: URL, target: BrowserLaunchTarget) throws
}

struct ProcessBrowserLauncher: BrowserLaunching {
    func open(_ url: URL, target: BrowserLaunchTarget) throws {
        if target.browser == .systemDefault {
            NSWorkspace.shared.open(url)
            return
        }

        var arguments: [String] = []
        if let bundleIdentifier = target.bundleIdentifier {
            arguments += ["-b", bundleIdentifier]
        }
        arguments.append(url.absoluteString)
        if let profileID = target.profileID, target.browser.supportsProfileSelection {
            arguments += ["--args", "--profile-directory=\(profileID)"]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        try process.run()
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

        try browserLauncher.open(url, target: target)
        return MeetingLaunchResult(openedURL: url, target: target, usedFallbackProfile: usedFallback, warning: warning)
    }
}

enum MeetingLauncherError: Error, LocalizedError, Equatable {
    case profileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .profileNotFound(let profile):
            "Browser profile not found: \(profile)"
        }
    }
}
