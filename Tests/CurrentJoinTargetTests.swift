import Foundation
import Testing
@testable import MeetingShield

@Suite("Current Join target")
@MainActor
struct CurrentJoinTargetTests {
    @Test("Join resolves refreshed source links instead of the captured alert", arguments: LinkUpdate.allCases)
    func capturedJoinUsesCurrentURL(update: LinkUpdate) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var original = fixture.event()
        original.htmlLink = try #require(URL(string: "https://calendar.google.com/calendar/u/0/r/event?eid=synthetic-old"))
        original.location = update == .calendarURL ? nil : "https://meet.google.com/synthetic-old"
        let provider = fixture.provider(events: [original])
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.scheduledReminders.first)
        var updated = original
        let expectedURL: URL
        switch update {
        case .meetingURL:
            expectedURL = try #require(URL(string: "https://meet.google.com/synthetic-new"))
            updated.location = expectedURL.absoluteString
        case .calendarURL:
            expectedURL = try #require(URL(string: "https://calendar.google.com/calendar/u/0/r/event?eid=synthetic-new"))
            updated.htmlLink = expectedURL
        case .removedMeetingURL:
            expectedURL = try #require(URL(string: "https://calendar.google.com/calendar/u/0/r/event?eid=synthetic-current"))
            updated.location = nil
            updated.htmlLink = expectedURL
        }
        provider.eventsValue = [updated]
        await controller.refresh(reason: "timer")
        #expect(controller.scheduledReminders.first?.id == captured.id)
        #expect(controller.events.first?.htmlLink == updated.htmlLink)

        controller.join(captured, now: fixture.now)

        #expect(fixture.browser.urls == [expectedURL])
        #expect(fixture.browser.targets == [fixture.systemTarget])
        #expect(controller.fallback == nil)
    }

    @Test("Join rejects a captured occurrence removed by refresh")
    func capturedJoinRejectsRemovedSource() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let provider = fixture.provider(events: [fixture.event()])
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.scheduledReminders.first)
        provider.eventsValue = []
        await controller.refresh(reason: "timer")
        #expect(controller.events.isEmpty)
        #expect(controller.scheduledReminders.isEmpty)

        controller.join(captured, now: fixture.now)

        #expect(fixture.browser.urls.isEmpty)
        #expect(controller.fallback == nil)
    }

    @Test("Join rejects a captured occurrence cancelled by refresh")
    func capturedJoinRejectsCancelledSource() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var event = fixture.event()
        let provider = fixture.provider(events: [event])
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.scheduledReminders.first)
        event.status = .cancelled
        provider.eventsValue = [event]
        await controller.refresh(reason: "timer")
        #expect(controller.events.first?.isCancelled == true)
        #expect(controller.scheduledReminders.isEmpty)

        controller.join(captured, now: fixture.now)

        #expect(fixture.browser.urls.isEmpty)
        #expect(controller.fallback == nil)
    }

    @Test("Join uses current account and calendar selection without another refresh", arguments: [true, false])
    func capturedJoinRejectsDisabledSource(disableAccount: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let event = fixture.event()
        let controller = fixture.controller(provider: fixture.provider(events: [event]))
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.scheduledReminders.first)
        fixture.settings.update {
            if disableAccount {
                $0.disabledGoogleAccountIDs = [event.accountID]
            } else {
                $0.selectedCalendarIDs = ["synthetic-other-calendar"]
            }
        }
        #expect(controller.scheduledReminders.first?.id == captured.id)

        controller.join(captured, now: fixture.now)

        #expect(fixture.browser.urls.isEmpty)
        #expect(controller.fallback == nil)
    }

    @Test("A calendar move cannot redirect the old scoped Join target to the same raw event ID")
    func capturedJoinRejectsCalendarMove() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = fixture.event()
        let provider = fixture.provider(events: [original])
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.scheduledReminders.first)
        var moved = original
        moved.calendarID = "synthetic-other-calendar"
        moved.location = "https://meet.google.com/synthetic-moved"
        provider.eventsValue = [moved]
        await controller.refresh(reason: "timer")
        let current = try #require(controller.scheduledReminders.first)
        #expect(current.event.eventID == captured.event.eventID)
        #expect(current.id != captured.id)

        controller.join(captured, now: fixture.now)

        #expect(fixture.browser.urls.isEmpty)
        #expect(controller.fallback == nil)
    }

    @Test("Join rejects an ended occurrence at action time without requiring refresh", arguments: [0.0, 1.0])
    func capturedJoinRejectsEndedSource(secondsAfterEnd: TimeInterval) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let event = fixture.event()
        let controller = fixture.controller(provider: fixture.provider(events: [event]))
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.scheduledReminders.first)

        controller.join(captured, now: event.endDate.addingTimeInterval(secondsAfterEnd))

        #expect(fixture.browser.urls.isEmpty)
        #expect(controller.fallback == nil)
    }

    @Test("A current eligible occurrence still launches before its end", arguments: [false, true])
    func unchangedCurrentSourceRemainsJoinable(atLastSecond: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let event = fixture.event()
        let controller = fixture.controller(provider: fixture.provider(events: [event]))
        await controller.refresh(reason: "launch")
        let current = try #require(controller.scheduledReminders.first)
        let expectedURL = try #require(current.detectedLinks.first?.url)
        let actionTime = atLastSecond ? event.endDate.addingTimeInterval(-1) : fixture.now

        controller.join(current, now: actionTime)

        #expect(fixture.browser.urls == [expectedURL])
        #expect(fixture.browser.targets == [fixture.systemTarget])
        #expect(controller.fallback == nil)
    }

    enum LinkUpdate: CaseIterable, Equatable, Sendable {
        case meetingURL, calendarURL, removedMeetingURL
    }

    @MainActor
    private struct Fixture {
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let directory: URL
        let domain: String
        let settings: AppSettingsStore
        let state: ReminderStateStore
        let cache: EventCacheStore
        let browser = FailingBrowserRecorder()
        let systemTarget = BrowserLaunchTarget(browser: .systemDefault, profileID: nil, bundleIdentifier: nil)

        init() throws {
            directory = try TestTempDirectory.make()
            domain = "MeetingShieldCurrentJoinTargetTests.\(UUID().uuidString)"
            _ = try #require(UserDefaults(suiteName: domain))
            settings = AppSettingsStore(domainName: domain)
            settings.update {
                $0.defaultLeadTime = 120
                $0.defaultBrowserSelection = .systemDefault
                $0.selectedCalendarIDs = ["synthetic-calendar", "synthetic-other-calendar"]
                $0.presentationModeDefault = true
                $0.soundEnabled = false
                $0.urgentRepeatSoundEnabled = false
                $0.wakeGraceEnabled = false
            }
            state = ReminderStateStore(fileURL: directory.appending(path: "state.json"))
            cache = EventCacheStore(fileURL: directory.appending(path: "cache.json"))
        }

        func cleanup() {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }

        func event() -> CalendarEventOccurrence {
            CalendarEventOccurrence.sample(
                eventID: "synthetic-join", title: "Synthetic Join meeting",
                startDate: now.addingTimeInterval(3600), calendarID: "synthetic-calendar",
                location: "https://meet.google.com/synthetic-original"
            )
        }

        func provider(events: [CalendarEventOccurrence]) -> FakeCalendarProvider {
            let provider = FakeCalendarProvider()
            provider.eventsValue = events
            provider.calendarsValue = ["synthetic-calendar", "synthetic-other-calendar"].map { id in
                UserCalendar(
                    id: id, accountID: "mock-account", displayName: "Synthetic calendar",
                    isPrimary: id == "synthetic-calendar", isSelected: true
                )
            }
            return provider
        }

        func controller(provider: FakeCalendarProvider) -> MeetingShieldController {
            MeetingShieldController(
                settingsStore: settings, provider: provider, reminderStateStore: state, cacheStore: cache,
                notificationService: NoopNotificationService(),
                launcher: MeetingLauncher(
                    profileService: BrowserProfileService(homeDirectory: directory), browserLauncher: browser
                ),
                refreshMenuBar: {}
            )
        }
    }

    private final class FailingBrowserRecorder: BrowserLaunching, @unchecked Sendable {
        private let lock = NSLock()
        private var recordedURLs: [URL] = []
        private var recordedTargets: [BrowserLaunchTarget] = []

        var urls: [URL] { lock.withLock { recordedURLs } }
        var targets: [BrowserLaunchTarget] { lock.withLock { recordedTargets } }

        func open(_ url: URL, target: BrowserLaunchTarget) throws {
            lock.withLock {
                recordedURLs.append(url)
                recordedTargets.append(target)
            }
            throw SyntheticLaunchError.recordedWithoutOpening
        }

        private enum SyntheticLaunchError: Error {
            case recordedWithoutOpening
        }
    }
}
