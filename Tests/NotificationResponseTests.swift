import Foundation
import Testing
import UserNotifications
@testable import MeetingShield

@Suite("Notification response routing", .timeLimit(.minutes(1)))
@MainActor
struct NotificationResponseTests {
    @Test("A delivered non-first reminder opens current content and preserves every due group", arguments: [false, true])
    func currentOccurrence(edited: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let overlap = fixture.event("overlap", startsAfter: 240, endsAfter: 3_600)
        let original = fixture.event("target")
        let controller = fixture.controller(events: [original, overlap])
        defer { controller.stop() }
        await fixture.refresh(controller, deliveryCount: 2)
        let delivered = try #require(fixture.notifier.delivered.first { $0.id == original.id })
        #expect(delivered.title == original.title)
        #expect(controller.activeReminders.map(\.id) == [overlap.id, original.id])
        var current = original
        if edited {
            current.title = "Synthetic updated title"
            current.location = "https://meet.google.com/current-target"
            current.meetingRoom = "Synthetic updated room"
            current.updatedAt = fixture.clock.now.addingTimeInterval(1)
            fixture.provider.eventsValue = [overlap, current]
            await fixture.refresh(controller, deliveryCount: 2)
        }
        let deliveryCount = fixture.notifier.delivered.count
        let presentationMode = controller.isPresentationMode

        try fixture.click(delivered.id)

        let presentation = try #require(fixture.alert.presentations.first)
        #expect(fixture.alert.presentations.count == 1)
        #expect(presentation.selectedID == current.id)
        #expect(presentation.reminders.map(\.id) == [overlap.id, current.id])
        let selected = try #require(presentation.reminders.first { $0.id == presentation.selectedID })
        #expect(selected.event == current)
        #expect(selected.detectedLinks == MeetingLinkExtractor().extractLinks(from: current))
        #expect(controller.activeReminders.map(\.id) == [overlap.id, current.id])
        #expect(fixture.notifier.delivered.count == deliveryCount)
        #expect(controller.isPresentationMode == presentationMode)
        #expect(fixture.routes.agendaCount == 0)
        #expect(fixture.routes.settingsCount == 0)
        #expect(fixture.browser.openedURLs.isEmpty)
    }

    @Test("A former representative that remains a group member selects the current group")
    func survivingGroupMember() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let overlap = fixture.event("overlap", startsAfter: 240, endsAfter: 3_600)
        let copies = [
            fixture.event("copy-a", copyIdentity: "shared-copy@fixture"),
            fixture.event("copy-b", copyIdentity: "shared-copy@fixture")
        ].sorted { $0.id < $1.id }
        let added = copies[0]
        let deliveredSource = copies[1]
        let controller = fixture.controller(events: [overlap, deliveredSource])
        defer { controller.stop() }
        await fixture.refresh(controller, deliveryCount: 2)
        let delivered = try #require(fixture.notifier.delivered.first { $0.id == deliveredSource.id })
        fixture.provider.eventsValue = [overlap, deliveredSource, added]
        await fixture.refresh(controller, deliveryCount: 2)
        let currentGroup = try #require(controller.activeReminders.first { $0.members.count == 2 })
        #expect(currentGroup.id == added.id)
        #expect(currentGroup.id != delivered.id)
        #expect(Set(currentGroup.members.map(\.id)) == Set(copies.map(\.id)))

        try fixture.click(delivered.id)

        let presentation = try #require(fixture.alert.presentations.first)
        #expect(fixture.alert.presentations.count == 1)
        #expect(presentation.selectedID == currentGroup.id)
        #expect(presentation.reminders.map(\.id) == [overlap.id, currentGroup.id])
        #expect(presentation.reminders.last == currentGroup)
        #expect(controller.activeReminders.map(\.id) == [overlap.id, currentGroup.id])
        #expect(fixture.routes.agendaCount == 0)
        #expect(fixture.routes.settingsCount == 0)
        #expect(fixture.browser.openedURLs.isEmpty)
    }

    @Test("A deferred clicked source stays deferred while its true-copy peer is due", arguments: [false, true])
    func deferredSourceInDueGroup(snoozed: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let overlap = fixture.event("overlap", startsAfter: 240, endsAfter: 3_600)
        let clicked = fixture.event("clicked-copy", copyIdentity: "shared-copy@fixture")
        let peer = fixture.event("due-copy", copyIdentity: "shared-copy@fixture")
        let controller = fixture.controller(events: [overlap, clicked])
        defer { controller.stop() }
        await fixture.refresh(controller, deliveryCount: 2)
        let delivered = try #require(fixture.notifier.delivered.first { $0.id == clicked.id })
        if snoozed {
            fixture.state.snooze(clicked.occurrenceKey, until: fixture.clock.now.addingTimeInterval(60), now: fixture.clock.now)
        } else {
            fixture.deferReminderForCalendar(clicked.calendarID)
        }
        fixture.provider.eventsValue = [overlap, clicked, peer]
        await fixture.refresh(controller, deliveryCount: 2)
        let scheduledSource = try #require(controller.scheduledReminders.first { $0.id == clicked.id })
        let dueGroup = try #require(controller.activeReminders.first { $0.members.count == 2 })
        #expect(scheduledSource.fireDate > fixture.clock.now)
        #expect(dueGroup.id == peer.id)
        #expect(dueGroup.members.contains { $0.id == clicked.id })

        try fixture.click(delivered.id)

        #expect(fixture.alert.presentations.isEmpty)
        #expect(fixture.routes.agendaCount == 1)
        #expect(fixture.routes.settingsCount == 0)
        #expect(fixture.browser.openedURLs.isEmpty)
        #expect(controller.activeReminders.map(\.id) == [overlap.id, peer.id])
    }

    @Test("A delivered occurrence that is no longer due opens only the agenda", arguments: Invalidation.allCases)
    func staleOccurrence(reason: Invalidation) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let overlap = fixture.event("overlap", startsAfter: 240, endsAfter: 3_600)
        let target = fixture.event("target")
        let controller = fixture.controller(events: [overlap, target])
        defer { controller.stop() }
        await fixture.refresh(controller, deliveryCount: 2)
        let delivered = try #require(fixture.notifier.delivered.first { $0.id == target.id })
        let fetchCount = fixture.provider.refreshCount
        switch reason {
        case .removed:
            fixture.provider.eventsValue = [overlap]
            await fixture.refresh(controller, deliveryCount: 1)
        case .moved:
            var moved = target
            moved.startDate = target.startDate.addingTimeInterval(3_600)
            moved.endDate = target.endDate.addingTimeInterval(3_600)
            #expect(moved.id == delivered.id)
            fixture.provider.eventsValue = [overlap, moved]
            await fixture.refresh(controller, deliveryCount: 1)
        case .calendarMoved:
            var moved = target
            moved.accountID = overlap.accountID
            moved.calendarID = overlap.calendarID
            #expect(moved.eventID == target.eventID)
            #expect(moved.id != delivered.id)
            fixture.provider.eventsValue = [overlap, moved]
            await fixture.refresh(controller, deliveryCount: 2)
        case .ended:
            fixture.clock.now = target.endDate.addingTimeInterval(1)
        case .cancelled:
            var cancelled = target
            cancelled.status = .cancelled
            fixture.provider.eventsValue = [overlap, cancelled]
            await fixture.refresh(controller, deliveryCount: 1)
        case .acknowledged:
            fixture.state.acknowledge(
                target.occurrenceKey, fingerprint: fixture.fingerprint(target),
                eventEnd: target.endDate, now: fixture.clock.now
            )
        case .dismissed:
            fixture.state.dismiss(target.occurrenceKey, fingerprint: fixture.fingerprint(target), now: fixture.clock.now)
        case .muted:
            fixture.state.muteUntilEventEnd(target.occurrenceKey, now: fixture.clock.now)
        case .future:
            fixture.deferReminderForCalendar(target.calendarID)
        case .snoozed:
            fixture.state.snooze(target.occurrenceKey, until: fixture.clock.now.addingTimeInterval(60), now: fixture.clock.now)
        case .calendarDeselected:
            fixture.settings.update { $0.selectedCalendarIDs.remove(target.calendarID) }
            #expect(fixture.settings.snapshot.hasExplicitCalendarSelection)
        case .accountDisabled:
            fixture.settings.update { $0.disabledGoogleAccountIDs.insert(target.accountID) }
        }
        let fetchesBeforeClick = fixture.provider.refreshCount

        try fixture.click(delivered.id)

        #expect(fixture.alert.presentations.isEmpty)
        #expect(fixture.routes.agendaCount == 1)
        #expect(fixture.routes.settingsCount == 0)
        #expect(fixture.browser.openedURLs.isEmpty)
        #expect(fixture.provider.refreshCount == fetchesBeforeClick)
        if reason == .ended {
            #expect(fixture.provider.refreshCount == fetchCount)
            #expect(controller.events.contains { $0.id == delivered.id })
        }
    }

    @Test("Unknown and unscoped event identifiers cannot select a scoped occurrence", arguments: UnknownIdentifier.allCases)
    func unknownIdentifier(kind: UnknownIdentifier) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = fixture.event("target")
        let controller = fixture.controller(events: [target])
        defer { controller.stop() }
        await fixture.refresh(controller, deliveryCount: 1)
        let identifier: String
        switch kind {
        case .rawEventID: identifier = target.eventID
        case .legacyOccurrenceID: identifier = target.occurrenceKey.legacyKey.description
        case .unknown: identifier = "synthetic-unknown-notification"
        }
        #expect(identifier != target.id)

        try fixture.click(identifier)

        #expect(fixture.alert.presentations.isEmpty)
        #expect(fixture.routes.agendaCount == 1)
        #expect(fixture.routes.settingsCount == 0)
        #expect(fixture.browser.openedURLs.isEmpty)
        #expect(controller.activeReminders.map(\.id) == [target.id])
    }

    @Test("Reconnect notification opens only Settings without starting authorization")
    func reconnectOpensSettings() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = fixture.event("target")
        let controller = fixture.controller(events: [target])
        defer { controller.stop() }
        await fixture.refresh(controller, deliveryCount: 1)

        try fixture.click("meeting-shield.reconnect")

        #expect(fixture.alert.presentations.isEmpty)
        #expect(fixture.routes.agendaCount == 0)
        #expect(fixture.routes.settingsCount == 1)
        #expect(fixture.browser.openedURLs.isEmpty)
        #expect(controller.activeReminders.map(\.id) == [target.id])
        #expect(fixture.provider.refreshCount == 1)
    }

    @Test("Stop detaches the notifier and invalidates an already captured callback before start")
    func stoppedControllerRejectsCapturedResponse() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = fixture.event("target")
        let controller = fixture.controller(events: [target])
        defer { controller.stop() }
        await fixture.refresh(controller, deliveryCount: 1)
        let captured = try #require(fixture.notifier.responseHandler)

        controller.stop()
        try fixture.click(target.id, using: captured)
        try fixture.click("meeting-shield.reconnect", using: captured)

        #expect(fixture.notifier.responseHandler == nil)
        #expect(fixture.notifier.detachmentCount == 1)
        #expect(fixture.alert.presentations.isEmpty)
        #expect(fixture.routes.agendaCount == 0)
        #expect(fixture.routes.settingsCount == 0)
        #expect(fixture.browser.openedURLs.isEmpty)
    }

    @Test("Replacing the notifier invalidates captured old callbacks and binds the current backend")
    func replacedNotifierRejectsCapturedResponse() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = fixture.event("target")
        let controller = fixture.controller(events: [target])
        defer { controller.stop() }
        await fixture.refresh(controller, deliveryCount: 1)
        let captured = try #require(fixture.notifier.responseHandler)
        let replacement = RecordingNotifier()

        controller.replaceNotificationService(replacement)
        try fixture.click(target.id, using: captured)
        try fixture.click("meeting-shield.reconnect", using: captured)

        #expect(fixture.notifier.responseHandler == nil)
        #expect(fixture.notifier.detachmentCount == 1)
        #expect(fixture.alert.presentations.isEmpty)
        #expect(fixture.routes.agendaCount == 0)
        #expect(fixture.routes.settingsCount == 0)
        #expect(fixture.browser.openedURLs.isEmpty)
        let current = try #require(replacement.responseHandler)

        try fixture.click(target.id, using: current)

        #expect(fixture.alert.presentations.count == 1)
        #expect(fixture.alert.presentations.first?.selectedID == target.id)
        #expect(fixture.alert.presentations.first?.reminders.map(\.id) == [target.id])
        #expect(fixture.routes.agendaCount == 0)
        #expect(fixture.routes.settingsCount == 0)
        #expect(fixture.browser.openedURLs.isEmpty)
    }

    @Test("Refresh updates current selected content in a notification-opened window without showing it again")
    func refreshUpdatesNotificationOpenedWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let overlap = fixture.event("overlap", startsAfter: 240, endsAfter: 3_600)
        let original = fixture.event("target")
        let controller = fixture.controller(events: [overlap, original])
        defer { controller.stop() }
        await fixture.refresh(controller, deliveryCount: 2)
        try fixture.click(original.id)
        let keyTarget = try #require(fixture.alert.keyTarget)
        #expect(keyTarget.selectedReminder?.event == original)
        #expect(fixture.alert.showCount == 1)
        let deliveredBeforeRefresh = fixture.notifier.delivered.count
        var edited = original
        edited.title = "Synthetic edited after notification click"
        edited.location = "https://meet.google.com/current-window-target"
        edited.meetingRoom = "Synthetic current room"
        edited.updatedAt = fixture.clock.now.addingTimeInterval(1)
        fixture.provider.eventsValue = [overlap, edited]

        await fixture.refresh(controller, deliveryCount: 2)

        #expect(fixture.alert.isShowing)
        #expect(fixture.alert.keyTarget === keyTarget)
        #expect(fixture.alert.showCount == 1)
        #expect(fixture.alert.updateCount == 1)
        #expect(keyTarget.reminders.map(\.id) == [overlap.id, edited.id])
        #expect(keyTarget.selectedID == edited.id)
        #expect(keyTarget.selectedReminder?.event == edited)
        #expect(keyTarget.selectedReminder?.detectedLinks == MeetingLinkExtractor().extractLinks(from: edited))
        #expect(fixture.notifier.delivered.count == deliveredBeforeRefresh + 2)
        #expect(fixture.notifier.delivered.last?.title == edited.title)
        #expect(controller.isPresentationMode)
        #expect(fixture.browser.openedURLs.isEmpty)
        #expect(fixture.state.state(for: original.occurrenceKey)?.acknowledgement == nil)
        #expect(fixture.state.state(for: overlap.occurrenceKey)?.acknowledgement == nil)
    }

    @Test("Explicit Join updates the notification-opened window to the remaining meeting and raises fallback")
    func partialJoinUpdatesWindowAndFallback() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let remaining = fixture.event("remaining", startsAfter: 240, endsAfter: 3_600)
        let joined = fixture.event("joined")
        let controller = fixture.controller(events: [remaining, joined])
        defer {
            controller.clearFallback()
            controller.stop()
        }
        await fixture.refresh(controller, deliveryCount: 2)
        try fixture.click(joined.id)
        let keyTarget = try #require(fixture.alert.keyTarget)
        #expect(keyTarget.selectedReminder?.id == joined.id)
        let location = try #require(joined.location)
        let openedURL = try #require(URL(string: location))
        fixture.notifier.prepareBatch(count: 1)

        try fixture.alert.joinSelected()
        await fixture.finishNotifications(deliveryCount: 1)

        #expect(fixture.browser.openedURLs == [openedURL])
        #expect(fixture.state.state(for: joined.occurrenceKey)?.acknowledgement != nil)
        #expect(fixture.state.state(for: remaining.occurrenceKey)?.acknowledgement == nil)
        #expect(controller.activeReminders.map(\.id) == [remaining.id])
        #expect(fixture.alert.isShowing)
        #expect(fixture.alert.keyTarget === keyTarget)
        #expect(fixture.alert.showCount == 1)
        #expect(fixture.alert.updateCount == 1)
        #expect(keyTarget.reminders.map(\.id) == [remaining.id])
        #expect(keyTarget.selectedID == remaining.id)
        #expect(keyTarget.selectedReminder?.event == remaining)
        #expect(fixture.fallback.isShowing)
        #expect(fixture.fallback.showCount == 1)
        #expect(fixture.fallback.currentFallback?.reminder.id == joined.id)
        #expect(fixture.fallback.aboveAlerts == true)
        #expect(fixture.notifier.delivered.count == 3)
        #expect(controller.isPresentationMode)
    }

    @Test("A notification click raises an existing floating fallback without opening another meeting")
    func clickRaisesExistingFallback() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let remaining = fixture.event("remaining", startsAfter: 240, endsAfter: 3_600)
        let joined = fixture.event("joined")
        let controller = fixture.controller(events: [remaining, joined])
        defer {
            controller.clearFallback()
            controller.stop()
        }
        await fixture.refresh(controller, deliveryCount: 2)
        let joinTarget = try #require(controller.activeReminders.first { $0.id == joined.id })
        let location = try #require(joined.location)
        let openedURL = try #require(URL(string: location))
        fixture.notifier.prepareBatch(count: 1)
        controller.join(joinTarget, now: fixture.clock.now)
        await fixture.finishNotifications(deliveryCount: 1)
        #expect(fixture.browser.openedURLs == [openedURL])
        #expect(fixture.fallback.isShowing)
        #expect(fixture.fallback.aboveAlerts == false)
        #expect(!fixture.alert.isShowing)
        #expect(fixture.alert.showCount == 0)
        let deliveredBeforeClick = fixture.notifier.delivered.count

        try fixture.click(remaining.id)

        #expect(fixture.alert.isShowing)
        #expect(fixture.alert.showCount == 1)
        #expect(fixture.alert.keyTarget?.selectedReminder?.id == remaining.id)
        #expect(fixture.fallback.isShowing)
        #expect(fixture.fallback.showCount == 1)
        #expect(fixture.fallback.currentFallback?.reminder.id == joined.id)
        #expect(fixture.fallback.aboveAlerts == true)
        #expect(fixture.fallback.levelUpdates.last == true)
        #expect(fixture.notifier.delivered.count == deliveredBeforeClick)
        #expect(fixture.browser.openedURLs == [openedURL])
        #expect(fixture.state.state(for: remaining.occurrenceKey)?.acknowledgement == nil)
        #expect(controller.isPresentationMode)
    }

    @Test("Removing the final due meeting closes a notification-opened window")
    func finalDueRemovalClosesWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = fixture.event("target")
        let controller = fixture.controller(events: [target])
        defer { controller.stop() }
        await fixture.refresh(controller, deliveryCount: 1)
        try fixture.click(target.id)
        #expect(fixture.alert.isShowing)
        let hideCount = fixture.alert.hideCount
        let deliveryCount = fixture.notifier.delivered.count
        fixture.provider.eventsValue = []

        await fixture.refresh(controller, deliveryCount: 0)

        #expect(controller.activeReminders.isEmpty)
        #expect(!fixture.alert.isShowing)
        #expect(fixture.alert.keyTarget == nil)
        #expect(fixture.alert.hideCount == hideCount + 1)
        #expect(fixture.alert.showCount == 1)
        #expect(fixture.notifier.delivered.count == deliveryCount)
        #expect(fixture.browser.openedURLs.isEmpty)
        #expect(!fixture.fallback.isShowing)
        #expect(controller.isPresentationMode)
    }

    @Test("Presentation-mode refresh without a notification click never opens fullscreen", arguments: [false, true])
    func refreshWithoutClickDoesNotOpenWindow(hasDueMeeting: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = fixture.event(
            "target", startsAfter: hasDueMeeting ? 300 : 3_600,
            endsAfter: hasDueMeeting ? 900 : 4_500
        )
        let controller = fixture.controller(events: [target])
        defer { controller.stop() }
        let deliveryCount = hasDueMeeting ? 1 : 0

        await fixture.refresh(controller, deliveryCount: deliveryCount)
        await fixture.refresh(controller, deliveryCount: deliveryCount)

        #expect(fixture.alert.showCount == 0)
        #expect(fixture.alert.updateCount == 0)
        #expect(!fixture.alert.isShowing)
        #expect(!fixture.fallback.isShowing)
        #expect(fixture.routes.agendaCount == 0)
        #expect(fixture.routes.settingsCount == 0)
        #expect(fixture.notifier.delivered.count == deliveryCount * 2)
        #expect(fixture.browser.openedURLs.isEmpty)
        #expect(fixture.state.state(for: target.occurrenceKey)?.acknowledgement == nil)
        #expect(controller.isPresentationMode)
    }

    enum Invalidation: CaseIterable, Sendable {
        case removed, moved, calendarMoved, ended, cancelled, acknowledged, dismissed, muted, future, snoozed
        case calendarDeselected, accountDisabled
    }

    enum UnknownIdentifier: CaseIterable, Sendable {
        case rawEventID, legacyOccurrenceID, unknown
    }

    private typealias ResponseHandler = @MainActor @Sendable (String) -> Void

    @MainActor
    private final class Clock {
        var now = Date()
    }

    @MainActor
    private final class Routes {
        var agendaCount = 0
        var settingsCount = 0
        var authorizationProviderCount = 0
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let domain = "NotificationResponseTests.\(UUID().uuidString)"
        let clock = Clock()
        let routes = Routes()
        let alert = RecordingAlertPresenter()
        let fallback = RecordingFallbackPresenter()
        let notifier = RecordingNotifier()
        let browser = RecordingBrowser()
        let provider = FixtureProvider()
        let settings: AppSettingsStore
        let state: ReminderStateStore
        private var knownEvents: [OccurrenceKey: CalendarEventOccurrence] = [:]

        init() throws {
            directory = try TestTempDirectory.make()
            settings = AppSettingsStore(domainName: domain)
            state = ReminderStateStore(
                fileURL: directory.appending(path: "state.json"),
                diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "diagnostics"), nativeSink: { _, _ in })
            )
            settings.update {
                $0.defaultLeadTime = 600
                $0.defaultBrowserSelection = .systemDefault
                $0.googleOAuthClientID = "synthetic-notification-response-client"
                $0.presentationModeDefault = true
                $0.soundEnabled = false
                $0.urgentRepeatSoundEnabled = false
                $0.wakeGraceEnabled = false
            }
        }

        func event(
            _ name: String, startsAfter: TimeInterval = 300,
            endsAfter: TimeInterval = 900, copyIdentity: String? = nil
        ) -> CalendarEventOccurrence {
            var event = CalendarEventOccurrence.sample(
                eventID: name, title: "Synthetic \(name)",
                startDate: clock.now.addingTimeInterval(startsAfter),
                endDate: clock.now.addingTimeInterval(endsAfter),
                calendarID: "calendar-\(name)", location: "https://meet.google.com/\(name)"
            )
            event.accountID = "account-\(name)"
            event.iCalUID = copyIdentity ?? "\(name)@fixture"
            event.updatedAt = clock.now
            knownEvents[event.occurrenceKey] = event
            return event
        }

        func controller(events: [CalendarEventOccurrence]) -> MeetingShieldController {
            provider.eventsValue = events
            provider.calendarsValue = knownEvents.values.map {
                UserCalendar(
                    id: $0.calendarID, accountID: $0.accountID,
                    displayName: "Synthetic calendar", isPrimary: true, isSelected: true
                )
            }
            let providerForController = provider
            let selectedCalendarIDs = Set(providerForController.calendarsValue.map(\.id))
            settings.update { $0.selectedCalendarIDs = selectedCalendarIDs }
            let routes = routes
            let clock = clock
            return MeetingShieldController(
                settingsStore: settings, provider: providerForController,
                credentialsResolver: GoogleOAuthCredentialsResolver(bundleInfoValue: { _ in nil }, environment: [:]),
                makeGoogleProvider: { _ in
                    routes.authorizationProviderCount += 1
                    return providerForController
                },
                reminderStateStore: state,
                cacheStore: EventCacheStore(fileURL: directory.appending(path: "cache.json")),
                notificationService: notifier,
                launcher: MeetingLauncher(
                    profileService: BrowserProfileService(homeDirectory: directory), browserLauncher: browser
                ),
                soundPlayer: NoSound(), dismissalPresenter: NoDismissal(), now: { clock.now },
                refreshMenuBar: {},
                alertPresenter: alert, fallbackPresenter: fallback,
                openAgenda: { routes.agendaCount += 1 },
                presentSettings: { routes.settingsCount += 1 }
            )
        }

        func refresh(_ controller: MeetingShieldController, deliveryCount: Int) async {
            let previousDeliveryCount = notifier.delivered.count
            if deliveryCount > 0 { notifier.prepareBatch(count: deliveryCount) }
            await controller.refresh(reason: "timer")
            if deliveryCount > 0 {
                await finishNotifications(deliveryCount: deliveryCount)
            } else {
                #expect(notifier.delivered.count == previousDeliveryCount)
            }
            #expect(controller.activeReminders.count == deliveryCount)
        }

        func finishNotifications(deliveryCount: Int) async {
            await notifier.waitForDelivery()
            notifier.releaseDelivery()
            await notifier.waitForReturn()
            #expect(notifier.lastBatchCount == deliveryCount)
        }

        func click(_ identifier: String, using captured: ResponseHandler? = nil) throws {
            let handler = try #require(captured ?? notifier.responseHandler)
            let keys = Set(knownEvents.keys).union(provider.eventsValue.map(\.occurrenceKey))
            let previousAcknowledgements = keys.reduce(into: [OccurrenceKey: OccurrenceReminderState.Acknowledgement]()) {
                $0[$1] = state.state(for: $1)?.acknowledgement
            }
            let previousBrowserRequests = browser.openedURLs
            handler(identifier)
            #expect(browser.openedURLs == previousBrowserRequests)
            #expect(routes.authorizationProviderCount == 0)
            #expect(provider.reconnectCount == 0)
            #expect(notifier.authorizationRequestCount == 0)
            for key in keys {
                if let current = state.state(for: key)?.acknowledgement {
                    #expect(current == previousAcknowledgements[key])
                }
            }
        }

        func fingerprint(_ event: CalendarEventOccurrence) -> MaterialChangeFingerprint {
            event.materialFingerprint(detectedLinks: MeetingLinkExtractor().extractLinks(from: event))
        }

        func deferReminderForCalendar(_ calendarID: String) {
            settings.update {
                var calendar = $0.calendarSettings(for: calendarID)
                calendar.leadTimeOverride = 30
                $0.calendarSettings[calendarID] = calendar
            }
        }

        func cleanup() {
            #expect(notifier.hasPendingDelivery == false)
            notifier.releaseDelivery()
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor
    private final class RecordingAlertPresenter: FullScreenAlertPresenting {
        struct Presentation {
            var reminders: [ScheduledReminder]
            var selectedID: String?
        }

        private(set) var presentations: [Presentation] = []
        private(set) var keyTarget: AlertKeyTarget?
        private(set) var updateCount = 0
        private(set) var hideCount = 0
        private var onJoin: ((ScheduledReminder) -> Void)?

        var isShowing: Bool { keyTarget != nil }
        var showCount: Int { presentations.count }

        func show(
            reminders: [ScheduledReminder], selectedID: String?,
            availableSnoozeChoices: @escaping (ScheduledReminder, Date) -> [SnoozeChoice],
            onJoin: @escaping (ScheduledReminder) -> Void,
            onSnooze: @escaping (ScheduledReminder, SnoozeChoice?) -> Void,
            onDismiss: @escaping (ScheduledReminder) -> Void,
            onRequestDismissal: @escaping (ScheduledReminder) -> Void,
            onMute: @escaping (ScheduledReminder) -> Void,
            onSnoozeAll: @escaping () -> Void
        ) {
            presentations.append(.init(reminders: reminders, selectedID: selectedID))
            keyTarget = nil
            self.onJoin = nil
            guard !reminders.isEmpty else { return }
            let target = AlertKeyTarget(reminders: reminders)
            if let selectedID, reminders.contains(where: { $0.id == selectedID }) {
                target.selectedID = selectedID
            }
            keyTarget = target
            self.onJoin = onJoin
        }

        func update(reminders: [ScheduledReminder]) {
            updateCount += 1
            guard !reminders.isEmpty else {
                hide()
                return
            }
            keyTarget?.update(reminders: reminders)
        }

        func hide() {
            hideCount += 1
            keyTarget = nil
            onJoin = nil
        }

        func joinSelected() throws {
            let reminder = try #require(keyTarget?.selectedReminder)
            let action = try #require(onJoin)
            action(reminder)
        }
    }

    @MainActor
    private final class RecordingFallbackPresenter: JoinFallbackPresenting {
        private(set) var currentFallback: JoinFallbackState?
        private(set) var aboveAlerts: Bool?
        private(set) var showCount = 0
        private(set) var hideCount = 0
        private(set) var levelUpdates: [Bool] = []

        var isShowing: Bool { currentFallback != nil }

        func show(
            fallback: JoinFallbackState, aboveAlerts: Bool,
            onOpenAgain: @escaping () -> Void,
            onDismiss: @escaping () -> Void,
            onClose: @escaping () -> Void
        ) {
            showCount += 1
            currentFallback = fallback
            self.aboveAlerts = aboveAlerts
        }

        func updateLevel(aboveAlerts: Bool) {
            guard isShowing else { return }
            levelUpdates.append(aboveAlerts)
            self.aboveAlerts = aboveAlerts
        }

        func hide() {
            hideCount += 1
            currentFallback = nil
            aboveAlerts = nil
        }
    }

    @MainActor
    private final class RecordingNotifier: MeetingNotifying {
        private(set) var responseHandler: ResponseHandler?
        private(set) var detachmentCount = 0
        private(set) var authorizationRequestCount = 0
        private(set) var delivered: [MeetingNotification] = []
        private(set) var lastBatchCount = 0
        private var expectedCount = 0
        private var batchStart = 0
        private var entered = false
        private var returned = false
        private var deliverySignal: CheckedContinuation<Void, Never>?
        private var deliveryGate: CheckedContinuation<Void, Never>?
        private var returnSignal: CheckedContinuation<Void, Never>?

        var hasPendingDelivery: Bool { deliveryGate != nil || deliverySignal != nil || returnSignal != nil }

        func setResponseHandler(_ handler: ResponseHandler?) {
            if handler == nil { detachmentCount += 1 }
            responseHandler = handler
        }

        func authorizationStatus() async -> UNAuthorizationStatus { .authorized }

        func requestAuthorization() async throws -> Bool {
            authorizationRequestCount += 1
            return true
        }

        func prepareBatch(count: Int) {
            #expect(!hasPendingDelivery)
            expectedCount = count
            batchStart = delivered.count
            entered = false
            returned = false
        }

        func deliver(_ notification: MeetingNotification) async throws {
            delivered.append(notification)
            guard delivered.count - batchStart == expectedCount else { return }
            await withCheckedContinuation { continuation in
                deliveryGate = continuation
                entered = true
                deliverySignal?.resume()
                deliverySignal = nil
            }
            lastBatchCount = delivered.count - batchStart
            returned = true
            returnSignal?.resume()
            returnSignal = nil
        }

        func waitForDelivery() async {
            guard !entered else { return }
            await withCheckedContinuation { deliverySignal = $0 }
        }

        func releaseDelivery() {
            deliveryGate?.resume()
            deliveryGate = nil
        }

        func waitForReturn() async {
            guard !returned else { return }
            await withCheckedContinuation { returnSignal = $0 }
        }
    }

    @MainActor
    private final class FixtureProvider: CalendarProvider {
        nonisolated let providerID = "mock"
        var eventsValue: [CalendarEventOccurrence] = []
        var calendarsValue: [UserCalendar] = []
        private(set) var refreshCount = 0
        private(set) var reconnectCount = 0

        var authState: CalendarProviderAuthState {
            get async { .connected(accountEmail: "synthetic@example.invalid") }
        }

        func accounts() async -> [ConnectedCalendarAccount] {
            calendarsValue.map { ConnectedCalendarAccount(id: $0.accountID, displayName: "Synthetic account") }
        }

        func calendars() async throws -> [UserCalendar] { calendarsValue }

        func events(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
            eventsValue.filter { $0.endDate >= window.start && $0.startDate <= window.end }
        }

        func refresh(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
            try await refresh(in: window, calendars: calendarsValue)
        }

        func refresh(in window: CalendarFetchWindow, calendars: [UserCalendar]) async throws -> [CalendarEventOccurrence] {
            refreshCount += 1
            let selectedIDs = Set(calendars.map(\.id))
            return try await events(in: window).filter { selectedIDs.contains($0.calendarID) }
        }

        func reconnect() async throws { reconnectCount += 1 }
        func removeAccount(id: String) async throws {}
    }

    private final class RecordingBrowser: BrowserLaunching, @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URL] = []

        var openedURLs: [URL] { lock.withLock { requests } }

        func open(_ url: URL, target: BrowserLaunchTarget) throws {
            lock.withLock { requests.append(url) }
        }
    }

    private struct NoSound: AlertSoundPlaying {
        func playAlertSound() {}
    }

    @MainActor
    private final class NoDismissal: DismissalConfirming {
        func present(
            requestID: UUID, reminder: ScheduledReminder, source: DismissalRequestSource,
            completion: @escaping @MainActor (Bool) -> Void
        ) {
            completion(false)
        }

        func cancel(requestID: UUID) {}
    }
}
