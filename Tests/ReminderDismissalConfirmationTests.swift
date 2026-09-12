import Foundation
import Testing
@testable import MeetingShield

@Suite("Reminder dismissal confirmation")
@MainActor
struct ReminderDismissalConfirmationTests {
    @Test("The first dismissal request changes no reminder state", arguments: [false, true])
    func firstActivationKeepsCapturedGroupAndOverlap(fromFallback: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let events = [fixture.copy(0), fixture.copy(1), fixture.distinctMeeting()]
        let controller = fixture.controller(provider: fixture.provider(events: events))
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.activeReminders.first { $0.members.count == 2 })
        let eventsBefore = controller.events
        let scheduledBefore = controller.scheduledReminders
        let activeBefore = controller.activeReminders
        #expect(activeBefore.count == 2)
        #expect(Set(activeBefore.flatMap(\.members).map(\.id)) == Set(events.map(\.id)))
        #expect(!FileManager.default.fileExists(atPath: fixture.stateFile.path))

        controller.requestDismissal(captured, source: fromFallback ? .fallback : .fullScreen, now: fixture.now)

        #expect(fixture.presenter.requests.count == 1)
        #expect(fixture.presenter.requests.first?.reminder == captured)
        #expect(controller.events == eventsBefore)
        #expect(controller.scheduledReminders == scheduledBefore)
        #expect(controller.activeReminders == activeBefore)
        #expect(!FileManager.default.fileExists(atPath: fixture.stateFile.path))
        let reloadedState = ReminderStateStore(fileURL: fixture.stateFile)
        for event in events {
            #expect(fixture.state.state(for: event.occurrenceKey) == nil)
            #expect(reloadedState.state(for: event.occurrenceKey) == nil)
        }
    }

    @Test("Cancel retains the captured group and the unrelated overlap", arguments: [false, true])
    func cancellationDoesNotDismiss(fromFallback: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let events = [fixture.copy(0), fixture.copy(1), fixture.distinctMeeting()]
        let controller = fixture.controller(provider: fixture.provider(events: events))
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.activeReminders.first { $0.members.count == 2 })
        let activeBefore = controller.activeReminders
        let scheduledBefore = controller.scheduledReminders
        let eventsBefore = controller.events
        controller.requestDismissal(captured, source: fromFallback ? .fallback : .fullScreen, now: fixture.now)
        let request = try #require(fixture.presenter.requests.first)

        request.completion(false)

        #expect(controller.events == eventsBefore)
        #expect(controller.activeReminders == activeBefore)
        #expect(controller.scheduledReminders == scheduledBefore)
        fixture.expectNoPersistedState(for: events)
    }

    @Test("Confirm dismisses only the captured group and persists each source fingerprint", arguments: [false, true])
    func confirmationPersistsOnlyCapturedGroup(fromFallback: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let copies = [fixture.copy(0), fixture.copy(1)]
        let distinct = fixture.distinctMeeting()
        let events = copies + [distinct]
        let controller = fixture.controller(provider: fixture.provider(events: events))
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.activeReminders.first { $0.members.count == 2 })
        let eventsBefore = controller.events
        controller.requestDismissal(captured, source: fromFallback ? .fallback : .fullScreen, now: fixture.now)
        let request = try #require(fixture.presenter.requests.first)
        fixture.expectNoPersistedState(for: events)
        let beforeResponse = Date()

        request.completion(true)

        let afterResponse = Date()
        #expect(controller.events == eventsBefore)
        #expect(controller.activeReminders.map(\.id) == [distinct.id])
        #expect(controller.scheduledReminders.map(\.id) == [distinct.id])
        let reloadedState = ReminderStateStore(fileURL: fixture.stateFile)
        for copy in copies {
            let state = try #require(fixture.state.state(for: copy.occurrenceKey))
            #expect(state.dismissedFingerprint == fixture.fingerprint(copy))
            #expect(state.snoozedUntil == nil)
            #expect(!state.mutedUntilEventEnd)
            #expect(state.updatedAt >= beforeResponse)
            #expect(state.updatedAt <= afterResponse)
            #expect(reloadedState.state(for: copy.occurrenceKey) == state)
        }
        #expect(fixture.state.state(for: distinct.occurrenceKey) == nil)
        #expect(reloadedState.state(for: distinct.occurrenceKey) == nil)
        let restarted = fixture.controller(provider: fixture.provider(events: events), state: reloadedState)

        await restarted.refresh(reason: "launch")

        #expect(restarted.activeReminders.map(\.id) == [distinct.id])
    }

    @Test("Repeated activation cannot confirm or replace a pending dismissal")
    func repeatedActivationDoesNotConfirm() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let events = [fixture.copy(0), fixture.copy(1), fixture.distinctMeeting()]
        let controller = fixture.controller(provider: fixture.provider(events: events))
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.activeReminders.first { $0.members.count == 2 })
        let overlap = try #require(controller.activeReminders.first { $0.members.count == 1 })
        let activeBefore = controller.activeReminders

        controller.requestDismissal(captured, now: fixture.now)
        controller.requestDismissal(captured, now: fixture.now)
        controller.requestDismissal(captured, source: .fallback, now: fixture.now)
        controller.requestDismissal(overlap, now: fixture.now)

        #expect(fixture.presenter.requests.count == 1)
        #expect(fixture.presenter.requests.first?.reminder.id == captured.id)
        #expect(controller.activeReminders == activeBefore)
        fixture.expectNoPersistedState(for: events)
    }

    @Test("An obsolete response cannot consume a newer request", arguments: [false, true])
    func obsoleteResponseLeavesNewRequestIntact(obsoleteConfirms: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let copies = [fixture.copy(0), fixture.copy(1)]
        let distinct = fixture.distinctMeeting()
        let events = copies + [distinct]
        let controller = fixture.controller(provider: fixture.provider(events: events))
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.activeReminders.first { $0.members.count == 2 })
        let overlap = try #require(controller.activeReminders.first { $0.id == distinct.id })
        let activeBefore = controller.activeReminders
        controller.requestDismissal(captured, now: fixture.now)
        let obsolete = try #require(fixture.presenter.requests.first)
        obsolete.completion(false)
        controller.requestDismissal(overlap, now: fixture.now)
        #expect(fixture.presenter.requests.count == 2)
        let current = try #require(fixture.presenter.requests.last)
        #expect(current.requestID != obsolete.requestID)

        obsolete.completion(obsoleteConfirms)

        #expect(controller.activeReminders == activeBefore)
        fixture.expectNoPersistedState(for: events)

        current.completion(true)

        #expect(controller.activeReminders.count == 1)
        #expect(Set(controller.activeReminders.flatMap(\.members).map(\.id)) == Set(copies.map(\.id)))
        #expect(fixture.state.state(for: distinct.occurrenceKey)?.dismissedFingerprint == fixture.fingerprint(distinct))
        for copy in copies {
            #expect(fixture.state.state(for: copy.occurrenceKey) == nil)
        }
        let persisted = try Data(contentsOf: fixture.stateFile)

        current.completion(true)
        obsolete.completion(true)

        #expect(try Data(contentsOf: fixture.stateFile) == persisted)
        #expect(Set(controller.activeReminders.flatMap(\.members).map(\.id)) == Set(copies.map(\.id)))
    }

    @Test("A refresh cancels a pending request when its captured group changes", arguments: PendingChange.allCases)
    func changedGroupInvalidatesPendingRequest(change: PendingChange) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let copies = [fixture.copy(0), fixture.copy(1)]
        let distinct = fixture.distinctMeeting()
        let provider = fixture.provider(events: copies + [distinct])
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.activeReminders.first { $0.members.count == 2 })
        controller.requestDismissal(captured, now: fixture.now)
        let request = try #require(fixture.presenter.requests.first)
        try fixture.apply(change, to: captured, provider: provider)

        await controller.refresh(reason: "timer")

        #expect(fixture.presenter.cancelledRequestIDs.contains(request.requestID))
        let activeAfterRefresh = controller.activeReminders
        #expect(activeAfterRefresh.contains { $0.id == distinct.id })

        request.completion(true)

        #expect(controller.activeReminders == activeAfterRefresh)
        fixture.expectNoPersistedState(for: copies + [distinct, fixture.copy(3)])
    }

    @Test("Confirmation rechecks current selection without a refresh", arguments: [PendingChange.accountDisabled, .calendarDeselected])
    func selectionChangeBeforeResponseCannotDismiss(change: PendingChange) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let events = [fixture.copy(0), fixture.copy(1), fixture.distinctMeeting()]
        let provider = fixture.provider(events: events)
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.activeReminders.first { $0.members.count == 2 })
        controller.requestDismissal(captured, now: fixture.now)
        let request = try #require(fixture.presenter.requests.first)
        try fixture.apply(change, to: captured, provider: provider)

        request.completion(true)

        fixture.expectNoPersistedState(for: events)
    }

    @Test("Editing then reverting cannot revive an invalidated dismissal request")
    func editThenRevertDoesNotRestorePendingIntent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let events = [fixture.copy(0), fixture.copy(1), fixture.distinctMeeting()]
        let provider = fixture.provider(events: events)
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.activeReminders.first { $0.members.count == 2 })
        controller.requestDismissal(captured, now: fixture.now)
        let request = try #require(fixture.presenter.requests.first)
        try fixture.apply(.materialEdit, to: captured, provider: provider)
        await controller.refresh(reason: "timer")
        #expect(fixture.presenter.cancelledRequestIDs.contains(request.requestID))
        provider.eventsValue = events
        await controller.refresh(reason: "timer")
        let restored = try #require(controller.activeReminders.first { $0.id == captured.id })
        #expect(restored == captured)

        request.completion(true)

        fixture.expectNoPersistedState(for: events)
        #expect(controller.activeReminders.count == 2)
    }

    @Test("A nonmaterial refresh keeps confirmation attached to the same occurrence")
    func nonmaterialRefreshRetainsPendingRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let copies = [fixture.copy(0), fixture.copy(1)]
        let distinct = fixture.distinctMeeting()
        let provider = fixture.provider(events: copies + [distinct])
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.activeReminders.first { $0.members.count == 2 })
        controller.requestDismissal(captured, now: fixture.now)
        let request = try #require(fixture.presenter.requests.first)
        provider.eventsValue = provider.eventsValue.map { event in
            var updated = event
            updated.updatedAt = fixture.now.addingTimeInterval(1)
            updated.accountDisplayName = "Synthetic renamed account"
            updated.calendarDisplayName = "Synthetic renamed calendar"
            updated.eventDescription = "Synthetic note without a meeting link"
            #expect(fixture.fingerprint(updated) == fixture.fingerprint(event))
            return updated
        }

        await controller.refresh(reason: "timer")

        #expect(!fixture.presenter.cancelledRequestIDs.contains(request.requestID))
        #expect(fixture.presenter.requests.count == 1)
        fixture.expectNoPersistedState(for: copies + [distinct])

        request.completion(true)

        #expect(controller.activeReminders.map(\.id) == [distinct.id])
        for copy in copies {
            #expect(fixture.state.state(for: copy.occurrenceKey)?.dismissedFingerprint == fixture.fingerprint(copy))
        }
        #expect(fixture.state.state(for: distinct.occurrenceKey) == nil)
    }

    @Test("Snoozing a pending full-screen dismissal cancels its old confirmation")
    func snoozeInvalidatesPendingFullScreenRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let copies = [fixture.copy(0), fixture.copy(1)]
        let distinct = fixture.distinctMeeting()
        let controller = fixture.controller(provider: fixture.provider(events: copies + [distinct]))
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.activeReminders.first { $0.members.count == 2 })
        controller.requestDismissal(captured, now: fixture.now)
        let request = try #require(fixture.presenter.requests.first)
        let snoozedAt = Date()

        controller.snooze(captured, choice: .seconds(30), now: snoozedAt)

        #expect(fixture.presenter.cancelledRequestIDs.contains(request.requestID))
        #expect(controller.activeReminders.map(\.id) == [distinct.id])
        let statesAfterSnooze = copies.map { fixture.state.state(for: $0.occurrenceKey) }
        for state in statesAfterSnooze {
            #expect(state?.snoozedUntil == snoozedAt.addingTimeInterval(30))
            #expect(state?.dismissedFingerprint == nil)
        }
        let persisted = try Data(contentsOf: fixture.stateFile)

        request.completion(true)

        #expect(try Data(contentsOf: fixture.stateFile) == persisted)
        #expect(copies.map { fixture.state.state(for: $0.occurrenceKey) } == statesAfterSnooze)
        #expect(controller.activeReminders.map(\.id) == [distinct.id])
        #expect(fixture.state.state(for: distinct.occurrenceKey) == nil)
    }

    @Test("Reducing lead time cancels a full-screen request whose meeting is no longer due")
    func leadTimeChangeInvalidatesPendingFullScreenRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let events = [fixture.copy(0), fixture.copy(1), fixture.distinctMeeting()]
        let controller = fixture.controller(provider: fixture.provider(events: events))
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.activeReminders.first { $0.members.count == 2 })
        controller.requestDismissal(captured, now: fixture.now)
        let request = try #require(fixture.presenter.requests.first)
        fixture.settings.update { $0.defaultLeadTime = 60 }

        await controller.refresh(reason: "timer")

        #expect(controller.activeReminders.isEmpty)
        #expect(Set(controller.scheduledReminders.map(\.id)) == Set(events.map(\.id)))
        #expect(controller.scheduledReminders.allSatisfy { $0.fireDate > Date() })
        #expect(fixture.presenter.cancelledRequestIDs.contains(request.requestID))

        request.completion(true)

        fixture.expectNoPersistedState(for: events)
        #expect(controller.activeReminders.isEmpty)
        #expect(Set(controller.scheduledReminders.map(\.id)) == Set(events.map(\.id)))
    }

    @Test("A newly acknowledged source cancels its pending full-screen dismissal")
    func acknowledgementInvalidatesPendingFullScreenRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let copies = [fixture.copy(0), fixture.copy(1)]
        let distinct = fixture.distinctMeeting()
        let controller = fixture.controller(provider: fixture.provider(events: copies + [distinct]))
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.activeReminders.first { $0.members.count == 2 })
        controller.requestDismissal(captured, now: fixture.now)
        let request = try #require(fixture.presenter.requests.first)
        for copy in copies {
            fixture.state.acknowledge(
                copy.occurrenceKey, fingerprint: fixture.fingerprint(copy), eventEnd: copy.endDate, now: fixture.now
            )
        }

        await controller.refresh(reason: "timer")

        #expect(controller.activeReminders.map(\.id) == [distinct.id])
        #expect(fixture.presenter.cancelledRequestIDs.contains(request.requestID))
        let statesAfterAcknowledgement = copies.map { fixture.state.state(for: $0.occurrenceKey) }
        let persisted = try Data(contentsOf: fixture.stateFile)

        request.completion(true)

        #expect(try Data(contentsOf: fixture.stateFile) == persisted)
        #expect(copies.map { fixture.state.state(for: $0.occurrenceKey) } == statesAfterAcknowledgement)
        for copy in copies {
            #expect(fixture.state.state(for: copy.occurrenceKey)?.acknowledgement?.fingerprint == fixture.fingerprint(copy))
            #expect(fixture.state.state(for: copy.occurrenceKey)?.dismissedFingerprint == nil)
        }
        #expect(controller.activeReminders.map(\.id) == [distinct.id])
        #expect(fixture.state.state(for: distinct.occurrenceKey) == nil)
    }

    @Test("A fallback-source confirmation can still dismiss an acknowledged group")
    func fallbackRequestAllowsAcknowledgedSource() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let copies = [fixture.copy(0), fixture.copy(1)]
        let distinct = fixture.distinctMeeting()
        let controller = fixture.controller(provider: fixture.provider(events: copies + [distinct]))
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.activeReminders.first { $0.members.count == 2 })
        for copy in copies {
            fixture.state.acknowledge(
                copy.occurrenceKey, fingerprint: fixture.fingerprint(copy), eventEnd: copy.endDate, now: fixture.now
            )
        }
        await controller.refresh(reason: "timer")
        #expect(controller.activeReminders.map(\.id) == [distinct.id])

        controller.requestDismissal(captured, source: .fallback, now: fixture.now)

        let request = try #require(fixture.presenter.requests.first)
        #expect(!fixture.presenter.cancelledRequestIDs.contains(request.requestID))

        request.completion(true)

        #expect(controller.activeReminders.map(\.id) == [distinct.id])
        let reloadedState = ReminderStateStore(fileURL: fixture.stateFile)
        for copy in copies {
            #expect(fixture.state.state(for: copy.occurrenceKey)?.dismissedFingerprint == fixture.fingerprint(copy))
            #expect(reloadedState.state(for: copy.occurrenceKey) == fixture.state.state(for: copy.occurrenceKey))
        }
        #expect(fixture.state.state(for: distinct.occurrenceKey) == nil)
    }

    @Test("The completed hold action dismisses only the captured true-copy group")
    func completedHoldActionKeepsUnrelatedOverlap() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let copies = [fixture.copy(0), fixture.copy(1)]
        let distinct = fixture.distinctMeeting()
        let controller = fixture.controller(provider: fixture.provider(events: copies + [distinct]))
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.activeReminders.first { $0.members.count == 2 })
        let eventsBefore = controller.events
        #expect(controller.activeReminders.count == 2)
        #expect(Set(copies.map { fixture.fingerprint($0) }).count == 2)
        #expect(distinct.location == copies[0].location)

        controller.dismiss(captured, now: fixture.now)

        #expect(controller.events == eventsBefore)
        #expect(controller.activeReminders.map(\.id) == [distinct.id])
        #expect(controller.scheduledReminders.map(\.id) == [distinct.id])
        #expect(FileManager.default.fileExists(atPath: fixture.stateFile.path))
        let reloadedState = ReminderStateStore(fileURL: fixture.stateFile)
        for copy in copies {
            let state = try #require(fixture.state.state(for: copy.occurrenceKey))
            #expect(state.dismissedFingerprint == fixture.fingerprint(copy))
            #expect(state.snoozedUntil == nil)
            #expect(!state.mutedUntilEventEnd)
            #expect(state.updatedAt == fixture.now)
            #expect(reloadedState.state(for: copy.occurrenceKey) == state)
        }
        #expect(fixture.state.state(for: distinct.occurrenceKey) == nil)
        #expect(reloadedState.state(for: distinct.occurrenceKey) == nil)
    }

    enum PendingChange: CaseIterable, Sendable {
        case removed, cancelled, accountDisabled, calendarDeselected, ended
        case materialEdit, memberRemoved, memberMaterialEdit, newCopy, calendarMoved
        case startTimeChanged, endTimeChanged, locationChanged, conferenceLinkChanged
    }

    @MainActor
    private struct Fixture {
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let directory: URL
        let domain: String
        let settings: AppSettingsStore
        let stateFile: URL
        let state: ReminderStateStore
        let cache: EventCacheStore
        let presenter = RecordingDismissalPresenter()

        init() throws {
            directory = try TestTempDirectory.make()
            domain = "MeetingShieldDismissalConfirmationTests.\(UUID().uuidString)"
            _ = try #require(UserDefaults(suiteName: domain))
            settings = AppSettingsStore(domainName: domain)
            settings.update {
                $0.defaultLeadTime = 600
                $0.defaultBrowserSelection = .systemDefault
                $0.selectedCalendarIDs = Set((0...3).map { "synthetic-calendar-\($0)" })
                $0.presentationModeDefault = true
                $0.soundEnabled = false
                $0.urgentRepeatSoundEnabled = false
                $0.wakeGraceEnabled = false
            }
            stateFile = directory.appending(path: "state.json")
            state = ReminderStateStore(fileURL: stateFile)
            cache = EventCacheStore(fileURL: directory.appending(path: "cache.json"))
        }

        func cleanup() {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }

        func copy(_ index: Int) -> CalendarEventOccurrence {
            var event = CalendarEventOccurrence.sample(
                eventID: "synthetic-copy-occurrence", title: "Synthetic copy \(index)",
                startDate: now.addingTimeInterval(300), calendarID: "synthetic-calendar-\(index)",
                location: "https://meet.google.com/synthetic-copy-\(index)"
            )
            event.accountID = "synthetic-account-\(index)"
            event.accountDisplayName = "Synthetic account \(index)"
            event.iCalUID = "synthetic-shared-occurrence@fixture"
            event.updatedAt = now
            return event
        }

        func distinctMeeting() -> CalendarEventOccurrence {
            var event = copy(2)
            event.eventID = "synthetic-distinct-occurrence"
            event.iCalUID = "synthetic-distinct-occurrence@fixture"
            event.location = copy(0).location
            return event
        }

        func fingerprint(_ event: CalendarEventOccurrence) -> MaterialChangeFingerprint {
            event.materialFingerprint(detectedLinks: MeetingLinkExtractor().extractLinks(from: event))
        }

        func expectNoPersistedState(for events: [CalendarEventOccurrence]) {
            #expect(!FileManager.default.fileExists(atPath: stateFile.path))
            let reloadedState = ReminderStateStore(fileURL: stateFile)
            for event in events {
                #expect(state.state(for: event.occurrenceKey) == nil)
                #expect(reloadedState.state(for: event.occurrenceKey) == nil)
            }
        }

        func apply(_ change: PendingChange, to captured: ScheduledReminder, provider: FakeCalendarProvider) throws {
            switch change {
            case .removed:
                provider.eventsValue.removeAll { $0.id == captured.id }
            case .accountDisabled:
                settings.update { $0.disabledGoogleAccountIDs.insert(captured.event.accountID) }
            case .calendarDeselected:
                settings.update { $0.selectedCalendarIDs.remove(captured.event.calendarID) }
            case .newCopy:
                provider.eventsValue.append(copy(3))
            case .memberRemoved:
                let member = try #require(captured.members.first { $0.id != captured.id })
                provider.eventsValue.removeAll { $0.id == member.id }
            case .memberMaterialEdit:
                let member = try #require(captured.members.first { $0.id != captured.id })
                provider.eventsValue = provider.eventsValue.map { event in
                    guard event.id == member.id else { return event }
                    var edited = event
                    edited.title = "Synthetic edited member"
                    return edited
                }
            case .cancelled, .ended, .materialEdit, .calendarMoved,
                 .startTimeChanged, .endTimeChanged, .locationChanged, .conferenceLinkChanged:
                let updatedLink = try #require(URL(string: "https://meet.google.com/synthetic-updated-conference"))
                provider.eventsValue = provider.eventsValue.map { event in
                    guard event.id == captured.id else { return event }
                    var edited = event
                    switch change {
                    case .cancelled:
                        edited.status = .cancelled
                    case .ended:
                        edited.startDate = now.addingTimeInterval(-120)
                        edited.endDate = now.addingTimeInterval(-1)
                    case .materialEdit:
                        edited.title = "Synthetic edited meeting"
                    case .calendarMoved:
                        edited.calendarID = "synthetic-calendar-3"
                    case .startTimeChanged:
                        edited.startDate = edited.startDate.addingTimeInterval(30)
                    case .endTimeChanged:
                        edited.endDate = edited.endDate.addingTimeInterval(30)
                    case .locationChanged:
                        edited.location = "https://meet.google.com/synthetic-updated-location"
                    case .conferenceLinkChanged:
                        edited.conferenceLinks = [MeetingLink(url: updatedLink, kind: .googleMeet, source: .conferenceMetadata)]
                    default:
                        break
                    }
                    return edited
                }
            }
        }

        func provider(events: [CalendarEventOccurrence]) -> FakeCalendarProvider {
            let provider = FakeCalendarProvider()
            provider.eventsValue = events
            provider.calendarsValue = (0...3).map { index in
                UserCalendar(
                    id: "synthetic-calendar-\(index)", accountID: "synthetic-account-\(index)",
                    displayName: "Synthetic calendar \(index)", isPrimary: true, isSelected: true
                )
            }
            return provider
        }

        func controller(provider: FakeCalendarProvider, state: ReminderStateStore? = nil) -> MeetingShieldController {
            MeetingShieldController(
                settingsStore: settings, provider: provider, reminderStateStore: state ?? self.state,
                cacheStore: cache, notificationService: NoopNotificationService(),
                launcher: MeetingLauncher(
                    profileService: BrowserProfileService(homeDirectory: directory),
                    browserLauncher: FailingBrowserLauncher()
                ),
                dismissalPresenter: presenter, refreshMenuBar: {}
            )
        }
    }

    @MainActor
    private final class RecordingDismissalPresenter: DismissalConfirming {
        struct Request {
            let requestID: UUID
            let reminder: ScheduledReminder
            let source: DismissalRequestSource
            let completion: @MainActor (Bool) -> Void
        }

        private(set) var requests: [Request] = []
        private(set) var cancelledRequestIDs: [UUID] = []

        func present(
            requestID: UUID, reminder: ScheduledReminder, source: DismissalRequestSource,
            completion: @escaping @MainActor (Bool) -> Void
        ) {
            requests.append(Request(requestID: requestID, reminder: reminder, source: source, completion: completion))
        }

        func cancel(requestID: UUID) {
            cancelledRequestIDs.append(requestID)
        }
    }

    private struct FailingBrowserLauncher: BrowserLaunching {
        func open(_ url: URL, target: BrowserLaunchTarget) throws {
            throw MeetingLauncherError.launchFailed("Synthetic browser launch failed")
        }
    }
}
