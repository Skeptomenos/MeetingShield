import Foundation
import Testing
@testable import MeetingShield

@Suite("Meeting launcher")
struct MeetingLauncherTests {
    @Test("Urgent missing profile opens browser default with warning")
    func urgentMissingProfileFallsBack() throws {
        let recording = RecordingBrowserLauncher()
        let tempHome = try TestTempDirectory.make()
        let launcher = MeetingLauncher(
            profileService: BrowserProfileService(homeDirectory: tempHome),
            browserLauncher: recording
        )
        let event = CalendarEventOccurrence.sample(eventID: "launch", title: "Launch", startDate: TestDates.start)
        let link = MeetingLink(url: URL(string: "https://meet.google.com/abc")!, kind: .googleMeet, source: .location)

        let result = try launcher.launch(
            event: event,
            detectedLinks: [link],
            browserSelection: BrowserSelection(browser: .chrome, profileID: "Work"),
            urgent: true
        )

        #expect(result.usedFallbackProfile)
        #expect(result.warning != nil)
        #expect(recording.lastTarget?.profileID == nil)
    }

    @Test("Existing Chrome profile is preserved")
    func existingProfileIsUsed() throws {
        let recording = RecordingBrowserLauncher()
        let tempHome = try TestTempDirectory.make()
        try FileManager.default.createDirectory(
            at: tempHome.appending(path: "Library/Application Support/Google/Chrome/Profile 1", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let launcher = MeetingLauncher(
            profileService: BrowserProfileService(homeDirectory: tempHome),
            browserLauncher: recording
        )
        let event = CalendarEventOccurrence.sample(eventID: "launch", title: "Launch", startDate: TestDates.start)

        _ = try launcher.launch(
            event: event,
            detectedLinks: [],
            browserSelection: BrowserSelection(browser: .chrome, profileID: "Profile 1"),
            urgent: true
        )

        #expect(recording.lastTarget?.profileID == "Profile 1")
    }

    @Test("Linkless events open their calendar URL")
    func linklessEventsOpenCalendarURL() throws {
        let recording = RecordingBrowserLauncher()
        let launcher = MeetingLauncher(browserLauncher: recording)
        let calendarURL = URL(string: "https://calendar.google.com/calendar/u/0/r")!
        let event = CalendarEventOccurrence.sample(
            eventID: "linkless",
            title: "Linkless",
            startDate: TestDates.start,
            htmlLink: calendarURL
        )

        let result = try launcher.launch(
            event: event,
            detectedLinks: [],
            browserSelection: .systemDefault,
            urgent: true
        )

        #expect(result.openedURL == calendarURL)
        #expect(recording.lastURL == calendarURL)
    }
}

@Suite("Browser launch commands")
struct BrowserLaunchCommandTests {
    private let url = URL(string: "https://meet.google.com/abc-defg-hij")!
    private let fakeChromeBinary = URL(fileURLWithPath: "/Fake/Chrome.app/Contents/MacOS/Google Chrome")

    private func launcher(executable: URL?) -> ProcessBrowserLauncher {
        ProcessBrowserLauncher(appExecutableResolver: { _ in executable })
    }

    @Test("System default uses workspace open")
    func systemDefaultUsesWorkspace() throws {
        let command = try launcher(executable: nil).command(
            for: url,
            target: BrowserLaunchTarget(browser: .systemDefault, profileID: nil, bundleIdentifier: nil)
        )

        #expect(command == .workspaceOpen(url))
    }

    @Test("Profile launches exec the browser binary directly")
    func profileLaunchExecsBinaryDirectly() throws {
        // `open -b ... --args --profile-directory=X` silently ignores the
        // profile when the browser is already running; direct exec does not.
        let command = try launcher(executable: fakeChromeBinary).command(
            for: url,
            target: BrowserLaunchTarget(browser: .chrome, profileID: "Profile 1", bundleIdentifier: "com.google.Chrome")
        )

        #expect(command == .directExec(
            executable: fakeChromeBinary,
            arguments: ["--profile-directory=Profile 1", url.absoluteString]
        ))
    }

    @Test("Profile launch with missing browser throws browserNotInstalled")
    func missingBrowserThrows() {
        #expect(throws: MeetingLauncherError.browserNotInstalled("Google Chrome")) {
            _ = try launcher(executable: nil).command(
                for: url,
                target: BrowserLaunchTarget(browser: .chrome, profileID: "Profile 1", bundleIdentifier: "com.google.Chrome")
            )
        }
    }

    @Test("Non-profile branded launches use open -b with status checking")
    func nonProfileUsesOpenTool() throws {
        let command = try launcher(executable: nil).command(
            for: url,
            target: BrowserLaunchTarget(browser: .safari, profileID: nil, bundleIdentifier: "com.apple.Safari")
        )

        #expect(command == .openTool(arguments: ["-b", "com.apple.Safari", url.absoluteString]))
    }
}

final class RecordingBrowserLauncher: BrowserLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastTarget: BrowserLaunchTarget?
    private var _lastURL: URL?

    var lastTarget: BrowserLaunchTarget? {
        lock.withLock { _lastTarget }
    }

    var lastURL: URL? {
        lock.withLock { _lastURL }
    }

    func open(_ url: URL, target: BrowserLaunchTarget) throws {
        lock.withLock {
            _lastURL = url
            _lastTarget = target
        }
    }
}
