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
