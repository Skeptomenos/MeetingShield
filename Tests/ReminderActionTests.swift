import Foundation
import Testing
@testable import MeetingShield

@Suite("Reminder action integration")
@MainActor
struct ReminderActionTests {
    @Test("Snoozing a true-copy group persists the deadline for every source across restart")
    func snoozePersistsEveryKnownCopy() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let copies = [fixture.copy(0), fixture.copy(1)]
        let provider = fixture.provider(events: copies)
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        let group = try #require(controller.activeReminders.first)
        #expect(controller.activeReminders.count == 1)
        #expect(Set(group.members.map(\.id)) == Set(copies.map(\.id)))
        let fingerprints = group.members.map { $0.event.materialFingerprint(detectedLinks: $0.detectedLinks) }
        #expect(Set(fingerprints).count == 2)

        controller.snooze(group, choice: .seconds(30), now: fixture.now)

        let deadline = fixture.now.addingTimeInterval(30)
        #expect(controller.activeReminders.isEmpty)
        let restartedState = ReminderStateStore(fileURL: fixture.stateFile)
        for copy in copies {
            let state = fixture.state.state(for: copy.occurrenceKey)
            #expect(state?.snoozedUntil == deadline)
            #expect(state?.updatedAt == fixture.now)
            #expect(restartedState.state(for: copy.occurrenceKey) == state)
        }
        let restarted = fixture.controller(provider: fixture.provider(events: copies), state: restartedState)

        await restarted.refresh(reason: "launch")

        #expect(restarted.activeReminders.isEmpty)
        #expect(Set(restarted.scheduledReminders.map(\.id)) == Set(copies.map(\.id)))
        #expect(restarted.scheduledReminders.allSatisfy { $0.fireDate == deadline && $0.isSnoozed })
    }

    @Test("Snoozing true copies leaves a distinct meeting with the same link alerting")
    func groupSnoozePreservesDistinctSameLinkMeeting() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let copies = [fixture.copy(0), fixture.copy(1)]
        let distinct = fixture.distinctMeeting()
        #expect(distinct.location == copies[0].location)
        let provider = fixture.provider(events: copies + [distinct])
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        let group = try #require(controller.activeReminders.first { $0.members.count == 2 })
        #expect(controller.activeReminders.count == 2)

        controller.snooze(group, choice: .seconds(30), now: fixture.now)

        #expect(controller.activeReminders.map(\.id) == [distinct.id])
        #expect(fixture.state.state(for: distinct.occurrenceKey) == nil)
        for copy in copies {
            #expect(fixture.state.state(for: copy.occurrenceKey)?.snoozedUntil == fixture.now.addingTimeInterval(30))
        }

        await controller.refresh(reason: "timer")

        #expect(controller.activeReminders.map(\.id) == [distinct.id])
        #expect(ReminderStateStore(fileURL: fixture.stateFile).state(for: distinct.occurrenceKey) == nil)
    }

    @Test("A newly discovered true copy does not inherit an earlier group snooze")
    func newCopyDoesNotInheritSnooze() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let copies = [fixture.copy(0), fixture.copy(1)]
        let newCopy = fixture.copy(2)
        let provider = fixture.provider(events: copies)
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        let group = try #require(controller.activeReminders.first)
        #expect(group.members.count == 2)

        controller.snooze(group, choice: .seconds(30), now: fixture.now)
        provider.eventsValue = copies + [newCopy]
        await controller.refresh(reason: "timer")

        #expect(controller.activeReminders.map(\.id) == [newCopy.id])
        #expect(fixture.state.state(for: newCopy.occurrenceKey) == nil)
        let restartedState = ReminderStateStore(fileURL: fixture.stateFile)
        #expect(restartedState.state(for: newCopy.occurrenceKey) == nil)
        for copy in copies {
            #expect(restartedState.state(for: copy.occurrenceKey)?.snoozedUntil == fixture.now.addingTimeInterval(30))
        }
    }

    @Test("Removing the group representative does not erase the surviving copy snooze")
    func representativeRemovalKeepsSourceState() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let copies = [fixture.copy(0), fixture.copy(1)]
        let provider = fixture.provider(events: copies)
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        let group = try #require(controller.activeReminders.first)
        #expect(group.members.count == 2)
        let survivor = try #require(copies.first { $0.id != group.id })

        controller.snooze(group, choice: .seconds(30), now: fixture.now)
        provider.eventsValue = [survivor]
        await controller.refresh(reason: "timer")

        #expect(controller.events.map(\.id) == [survivor.id])
        #expect(controller.activeReminders.isEmpty)
        #expect(controller.scheduledReminders.map(\.id) == [survivor.id])
        #expect(controller.scheduledReminders.first?.fireDate == fixture.now.addingTimeInterval(30))
        #expect(fixture.state.state(for: survivor.occurrenceKey)?.snoozedUntil == fixture.now.addingTimeInterval(30))
        #expect(ReminderStateStore(fileURL: fixture.stateFile).state(for: survivor.occurrenceKey)?.snoozedUntil == fixture.now.addingTimeInterval(30))
    }

    @Test("A failed Join leaves its true copies and the unrelated overlap alerting")
    func failedJoinDoesNotSuppressAnySource() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let events = [fixture.copy(0), fixture.copy(1), fixture.distinctMeeting()]
        let provider = fixture.provider(events: events)
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        let group = try #require(controller.activeReminders.first { $0.members.count == 2 })
        let activeIDs = Set(controller.activeReminders.map(\.id))
        #expect(activeIDs.count == 2)

        controller.join(group, now: fixture.now)

        #expect(controller.statusMessage == "Synthetic browser launch failed")
        #expect(controller.fallback == nil)
        #expect(Set(controller.activeReminders.map(\.id)) == activeIDs)
        for event in events {
            #expect(fixture.state.state(for: event.occurrenceKey) == nil)
        }

        await controller.refresh(reason: "timer")

        #expect(Set(controller.activeReminders.map(\.id)) == activeIDs)
        #expect(Set(controller.activeReminders.flatMap(\.members).map(\.id)) == Set(events.map(\.id)))
        #expect(controller.fallback == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.stateFile.path))
    }

    @Test("Dismiss and mute preserve each copy's own state when its representative disappears", arguments: [DeliberateAction.dismiss, .mute])
    func deliberateGroupActionPersistsEveryCopy(action: DeliberateAction) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let copies = [fixture.copy(0), fixture.copy(1)]
        let distinct = fixture.distinctMeeting()
        let provider = fixture.provider(events: copies + [distinct])
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        let group = try #require(controller.activeReminders.first { $0.members.count == 2 })
        let survivor = try #require(copies.first { $0.id != group.id })
        #expect(Set(copies.map { fixture.fingerprint($0) }).count == 2)

        apply(action, to: group, controller: controller, now: fixture.now)

        #expect(controller.activeReminders.map(\.id) == [distinct.id])
        let restartedState = ReminderStateStore(fileURL: fixture.stateFile)
        for copy in copies {
            let state = try #require(fixture.state.state(for: copy.occurrenceKey))
            #expect(state.dismissedFingerprint == (action == .dismiss ? fixture.fingerprint(copy) : nil))
            #expect(state.mutedUntilEventEnd == (action == .mute))
            #expect(state.snoozedUntil == nil)
            #expect(state.updatedAt == fixture.now)
            #expect(restartedState.state(for: copy.occurrenceKey) == state)
        }
        #expect(restartedState.state(for: distinct.occurrenceKey) == nil)
        provider.eventsValue = [survivor, distinct]

        await controller.refresh(reason: "timer")

        #expect(controller.activeReminders.map(\.id) == [distinct.id])
        #expect(fixture.state.state(for: survivor.occurrenceKey) == restartedState.state(for: survivor.occurrenceKey))
        let restarted = fixture.controller(provider: fixture.provider(events: [survivor, distinct]), state: restartedState)

        await restarted.refresh(reason: "launch")

        #expect(restarted.activeReminders.map(\.id) == [distinct.id])
    }

    @Test("Newly discovered copies do not inherit dismissal or mute", arguments: [DeliberateAction.dismiss, .mute])
    func newCopyDoesNotInheritDeliberateSuppression(action: DeliberateAction) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let copies = [fixture.copy(0), fixture.copy(1)]
        let newCopy = fixture.copy(2)
        let provider = fixture.provider(events: copies)
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        let group = try #require(controller.activeReminders.first)
        #expect(group.members.count == 2)

        apply(action, to: group, controller: controller, now: fixture.now)
        provider.eventsValue = copies + [newCopy]
        await controller.refresh(reason: "timer")

        #expect(controller.activeReminders.map(\.id) == [newCopy.id])
        #expect(fixture.state.state(for: newCopy.occurrenceKey) == nil)
        #expect(ReminderStateStore(fileURL: fixture.stateFile).state(for: newCopy.occurrenceKey) == nil)
    }

    @Test("A material edit re-alerts only the changed source after a group dismissal")
    func groupDismissalKeepsEachMaterialFingerprint() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let copies = [fixture.copy(0), fixture.copy(1)]
        let provider = fixture.provider(events: copies)
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        let group = try #require(controller.activeReminders.first)
        let unchanged = group.event
        var edited = try #require(copies.first { $0.id != group.id })

        controller.dismiss(group, now: fixture.now)
        edited.title = "Synthetic changed copy"
        edited.location = "https://meet.google.com/synthetic-changed-copy"
        provider.eventsValue = [unchanged, edited]
        await controller.refresh(reason: "timer")

        #expect(controller.activeReminders.map(\.id) == [edited.id])
        #expect(fixture.state.isDismissed(unchanged.occurrenceKey, currentFingerprint: fixture.fingerprint(unchanged)))
        #expect(!fixture.state.isDismissed(edited.occurrenceKey, currentFingerprint: fixture.fingerprint(edited)))
        let restarted = fixture.controller(
            provider: fixture.provider(events: [unchanged, edited]),
            state: ReminderStateStore(fileURL: fixture.stateFile)
        )

        await restarted.refresh(reason: "launch")

        #expect(restarted.activeReminders.map(\.id) == [edited.id])
    }

    @Test("A stale source cannot apply an action to its still-eligible copy", arguments: DeliberateAction.allCases, UnavailableSource.allCases)
    func staleGroupActionRejectsUnavailableSource(action: DeliberateAction, unavailable: UnavailableSource) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let copies = [fixture.copy(0), fixture.copy(1)]
        let distinct = fixture.distinctMeeting()
        let provider = fixture.provider(events: copies + [distinct])
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.activeReminders.first { $0.members.count == 2 })
        let survivor = try #require(copies.first { $0.id != captured.id })
        fixture.makeUnavailable(captured.event, reason: unavailable, provider: provider)
        if unavailable == .removed || unavailable == .cancelled {
            await controller.refresh(reason: "timer")
        }

        apply(action, to: captured, controller: controller, now: fixture.now)
        await controller.refresh(reason: "timer")

        #expect(Set(controller.activeReminders.map(\.id)) == Set([survivor.id, distinct.id]))
        for event in copies + [distinct] {
            #expect(fixture.state.state(for: event.occurrenceKey) == nil)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.stateFile.path))
    }

    @Test("Alert Again clears acknowledgement for the known group without clearing another meeting")
    func alertAgainRestoresOnlyAcknowledgedGroup() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let copies = [fixture.copy(0), fixture.copy(1)]
        let distinct = fixture.distinctMeeting()
        fixture.acknowledge(copies + [distinct])
        let distinctState = fixture.state.state(for: distinct.occurrenceKey)
        let provider = fixture.provider(events: copies + [distinct])
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        #expect(controller.activeReminders.isEmpty)
        #expect(controller.canAlertAgain(copies[1], now: fixture.now))

        controller.alertAgain(copies[1], now: fixture.now)

        #expect(controller.activeReminders.count == 1)
        #expect(Set(controller.activeReminders.flatMap(\.members).map(\.id)) == Set(copies.map(\.id)))
        for copy in copies {
            #expect(fixture.state.state(for: copy.occurrenceKey)?.acknowledgement == nil)
            #expect(!controller.canAlertAgain(copy, now: fixture.now))
        }
        #expect(fixture.state.state(for: distinct.occurrenceKey) == distinctState)
        #expect(controller.canAlertAgain(distinct, now: fixture.now))
        let restartedState = ReminderStateStore(fileURL: fixture.stateFile)
        #expect(restartedState.state(for: distinct.occurrenceKey) == distinctState)
        let restarted = fixture.controller(provider: fixture.provider(events: copies + [distinct]), state: restartedState)

        await restarted.refresh(reason: "launch")

        #expect(restarted.activeReminders.count == 1)
        #expect(Set(restarted.activeReminders.flatMap(\.members).map(\.id)) == Set(copies.map(\.id)))
    }

    @Test("Alert Again clears acknowledgement without shortening a deliberate snooze")
    func alertAgainPreservesSnooze() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let copies = [fixture.copy(0), fixture.copy(1)]
        let deadline = fixture.now.addingTimeInterval(60)
        fixture.acknowledge(copies)
        for copy in copies {
            fixture.state.snooze(copy.occurrenceKey, until: deadline, now: fixture.now)
        }
        let controller = fixture.controller(provider: fixture.provider(events: copies))
        await controller.refresh(reason: "launch")
        #expect(controller.canAlertAgain(copies[0], now: fixture.now))

        controller.alertAgain(copies[0], now: fixture.now)

        #expect(controller.activeReminders.isEmpty)
        #expect(controller.scheduledReminders.count == 2)
        #expect(controller.scheduledReminders.allSatisfy { $0.fireDate == deadline && $0.isSnoozed })
        let restartedState = ReminderStateStore(fileURL: fixture.stateFile)
        for copy in copies {
            #expect(restartedState.state(for: copy.occurrenceKey)?.acknowledgement == nil)
            #expect(restartedState.state(for: copy.occurrenceKey)?.snoozedUntil == deadline)
        }
    }

    @Test("Alert Again cannot undo a deliberate dismissal or mute", arguments: [DeliberateAction.dismiss, .mute])
    func alertAgainRejectsDeliberateSuppression(action: DeliberateAction) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let copies = [fixture.copy(0), fixture.copy(1)]
        fixture.acknowledge(copies)
        for copy in copies {
            if action == .dismiss {
                fixture.state.dismiss(copy.occurrenceKey, fingerprint: fixture.fingerprint(copy), now: fixture.now)
            } else {
                fixture.state.muteUntilEventEnd(copy.occurrenceKey, now: fixture.now)
            }
        }
        let before = copies.map { fixture.state.state(for: $0.occurrenceKey) }
        let controller = fixture.controller(provider: fixture.provider(events: copies))
        await controller.refresh(reason: "launch")
        #expect(!controller.canAlertAgain(copies[0], now: fixture.now))

        controller.alertAgain(copies[0], now: fixture.now.addingTimeInterval(1))

        #expect(controller.activeReminders.isEmpty)
        #expect(controller.scheduledReminders.isEmpty)
        #expect(copies.map { fixture.state.state(for: $0.occurrenceKey) } == before)
        let restartedState = ReminderStateStore(fileURL: fixture.stateFile)
        #expect(copies.map { restartedState.state(for: $0.occurrenceKey) } == before)
    }

    @Test("Alert Again is unavailable for a stale removed, cancelled, or disabled source", arguments: UnavailableSource.allCases)
    func alertAgainRejectsUnavailableSource(unavailable: UnavailableSource) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let copies = [fixture.copy(0), fixture.copy(1)]
        fixture.acknowledge(copies)
        let before = copies.map { fixture.state.state(for: $0.occurrenceKey) }
        let provider = fixture.provider(events: copies)
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        let captured = copies[0]
        #expect(controller.canAlertAgain(captured, now: fixture.now))
        fixture.makeUnavailable(captured, reason: unavailable, provider: provider)
        if unavailable == .removed || unavailable == .cancelled {
            await controller.refresh(reason: "timer")
        }

        #expect(!controller.canAlertAgain(captured, now: fixture.now))
        controller.alertAgain(captured, now: fixture.now.addingTimeInterval(1))

        #expect(controller.activeReminders.isEmpty)
        #expect(copies.map { fixture.state.state(for: $0.occurrenceKey) } == before)
        let restartedState = ReminderStateStore(fileURL: fixture.stateFile)
        #expect(copies.map { restartedState.state(for: $0.occurrenceKey) } == before)
    }

    enum DeliberateAction: CaseIterable, Equatable, Sendable {
        case snooze, dismiss, mute
    }

    enum UnavailableSource: CaseIterable, Equatable, Sendable {
        case removed, cancelled, accountDisabled, calendarDeselected
    }

    private func apply(_ action: DeliberateAction, to reminder: ScheduledReminder, controller: MeetingShieldController, now: Date) {
        switch action {
        case .snooze: controller.snooze(reminder, choice: .seconds(30), now: now)
        case .dismiss: controller.dismiss(reminder, now: now)
        case .mute: controller.muteCurrentOccurrence(reminder, now: now)
        }
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

        init() throws {
            directory = try TestTempDirectory.make()
            domain = "MeetingShieldReminderActionTests.\(UUID().uuidString)"
            _ = try #require(UserDefaults(suiteName: domain))
            settings = AppSettingsStore(domainName: domain)
            settings.update {
                $0.defaultLeadTime = 600
                $0.defaultBrowserSelection = .systemDefault
                $0.selectedCalendarIDs = ["synthetic-calendar-0", "synthetic-calendar-1", "synthetic-calendar-2"]
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

        func acknowledge(_ events: [CalendarEventOccurrence]) {
            for event in events {
                state.acknowledge(event.occurrenceKey, fingerprint: fingerprint(event), eventEnd: event.endDate, now: now)
            }
        }

        func makeUnavailable(_ event: CalendarEventOccurrence, reason: UnavailableSource, provider: FakeCalendarProvider) {
            switch reason {
            case .removed:
                provider.eventsValue.removeAll { $0.id == event.id }
            case .cancelled:
                provider.eventsValue = provider.eventsValue.map { current in
                    guard current.id == event.id else { return current }
                    var cancelled = current
                    cancelled.status = .cancelled
                    return cancelled
                }
            case .accountDisabled:
                settings.update { $0.disabledGoogleAccountIDs.insert(event.accountID) }
            case .calendarDeselected:
                settings.update { $0.selectedCalendarIDs.remove(event.calendarID) }
            }
        }

        func provider(events: [CalendarEventOccurrence]) -> FakeCalendarProvider {
            let provider = FakeCalendarProvider()
            provider.eventsValue = events
            provider.calendarsValue = (0...2).map { index in
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
                refreshMenuBar: {}
            )
        }
    }

    private struct FailingBrowserLauncher: BrowserLaunching {
        func open(_ url: URL, target: BrowserLaunchTarget) throws {
            throw MeetingLauncherError.launchFailed("Synthetic browser launch failed")
        }
    }
}
