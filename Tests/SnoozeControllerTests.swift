import Foundation
import Testing
@testable import MeetingShield

@Suite("Snooze controller integration")
@MainActor
struct SnoozeControllerTests {
    @Test("Refresh persists an earlier deadline and restart cannot restore the old longer snooze")
    func rescheduleClampsDurablyAcrossRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = fixture.event(startOffset: 7200)
        let originalDeadline = original.startDate.addingTimeInterval(-100)
        let store = ReminderStateStore(fileURL: fixture.stateFile)
        store.snooze(original.occurrenceKey, until: originalDeadline, now: fixture.now)
        let provider = fixture.provider(events: [original])
        let controller = fixture.controller(provider: provider, store: store)

        await controller.refresh(reason: "launch")

        #expect(controller.scheduledReminders.first?.fireDate == originalDeadline)
        #expect(controller.activeReminders.isEmpty)
        var earlier = original
        earlier.startDate = fixture.now.addingTimeInterval(3600)
        earlier.endDate = earlier.startDate.addingTimeInterval(1800)
        let deadline = earlier.startDate.addingTimeInterval(-10)
        provider.eventsValue = [earlier]

        await controller.refresh(reason: "timer")

        #expect(controller.events.first?.startDate == earlier.startDate)
        #expect(controller.scheduledReminders.first?.fireDate == deadline)
        #expect(controller.scheduledReminders.first?.isSnoozed == true)
        #expect(controller.activeReminders.isEmpty)
        #expect(store.state(for: earlier.occurrenceKey)?.snoozedUntil == deadline)
        let restartedStore = ReminderStateStore(fileURL: fixture.stateFile)
        #expect(restartedStore.state(for: earlier.occurrenceKey)?.snoozedUntil == deadline)
        let restarted = fixture.controller(provider: fixture.provider(events: [original]), store: restartedStore)

        await restarted.refresh(reason: "launch")

        #expect(restarted.events.first?.startDate == original.startDate)
        #expect(restarted.scheduledReminders.first?.fireDate == deadline)
        #expect(restarted.activeReminders.isEmpty)
        #expect(restartedStore.state(for: original.occurrenceKey)?.snoozedUntil == deadline)
        #expect(ReminderStateStore(fileURL: fixture.stateFile).state(for: original.occurrenceKey)?.snoozedUntil == deadline)
    }

    @Test("A captured reminder uses the refreshed source start when snoozed")
    func staleActionUsesCurrentStart() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = fixture.event(startOffset: 7200)
        let store = ReminderStateStore(fileURL: fixture.stateFile)
        let provider = fixture.provider(events: [original])
        let controller = fixture.controller(provider: provider, store: store)
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.scheduledReminders.first)
        var earlier = original
        earlier.startDate = fixture.now.addingTimeInterval(3600)
        earlier.endDate = earlier.startDate.addingTimeInterval(1800)
        provider.eventsValue = [earlier]
        await controller.refresh(reason: "timer")
        let actionTime = earlier.startDate.addingTimeInterval(-11)

        controller.snooze(captured, choice: .seconds(300), now: actionTime)

        let deadline = earlier.startDate.addingTimeInterval(-10)
        #expect(store.state(for: earlier.occurrenceKey)?.snoozedUntil == deadline)
        #expect(store.state(for: earlier.occurrenceKey)?.updatedAt == actionTime)
        #expect(controller.scheduledReminders.first?.fireDate == deadline)
        #expect(controller.activeReminders.isEmpty)
        #expect(ReminderStateStore(fileURL: fixture.stateFile).state(for: earlier.occurrenceKey)?.snoozedUntil == deadline)
    }

    @Test("A captured reminder cannot create snooze state after its source disappears")
    func staleActionRejectsMissingSource() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let event = fixture.event()
        let store = ReminderStateStore(fileURL: fixture.stateFile)
        let provider = fixture.provider(events: [event])
        let controller = fixture.controller(provider: provider, store: store)
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.scheduledReminders.first)
        provider.eventsValue = []
        await controller.refresh(reason: "timer")

        controller.snooze(captured, choice: .seconds(60), now: fixture.now)

        #expect(controller.events.isEmpty)
        #expect(controller.scheduledReminders.isEmpty)
        #expect(controller.activeReminders.isEmpty)
        #expect(store.state(for: event.occurrenceKey) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.stateFile.path))
    }

    @Test("A captured reminder cannot snooze a source cancelled by refresh")
    func staleActionRejectsCancelledSource() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var event = fixture.event()
        let store = ReminderStateStore(fileURL: fixture.stateFile)
        let provider = fixture.provider(events: [event])
        let controller = fixture.controller(provider: provider, store: store)
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.scheduledReminders.first)
        event.status = .cancelled
        provider.eventsValue = [event]
        await controller.refresh(reason: "timer")

        controller.snooze(captured, choice: .seconds(60), now: fixture.now)

        #expect(controller.events.first?.isCancelled == true)
        #expect(controller.scheduledReminders.isEmpty)
        #expect(store.state(for: event.occurrenceKey) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.stateFile.path))
    }

    @Test("A captured reminder respects account selection changed since the last refresh")
    func staleActionUsesCurrentEligibility() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let event = fixture.event()
        let store = ReminderStateStore(fileURL: fixture.stateFile)
        let controller = fixture.controller(provider: fixture.provider(events: [event]), store: store)
        await controller.refresh(reason: "launch")
        let captured = try #require(controller.scheduledReminders.first)
        fixture.settings.update { $0.disabledGoogleAccountIDs = [event.accountID] }

        controller.snooze(captured, choice: .seconds(60), now: fixture.now)

        #expect(store.state(for: event.occurrenceKey) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.stateFile.path))
    }

    @Test("The global duration controls default snooze without changing an explicit fixed choice", arguments: [true, false])
    func unclampedDefaultAndFixedChoice(useDefault: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.settings.update { $0.globalSnoozeDuration = 90 }
        let event = fixture.event()
        let store = ReminderStateStore(fileURL: fixture.stateFile)
        let controller = fixture.controller(provider: fixture.provider(events: [event]), store: store)
        await controller.refresh(reason: "launch")
        let reminder = try #require(controller.scheduledReminders.first)
        let choice: SnoozeChoice? = useDefault ? nil : .seconds(120)
        let deadline = fixture.now.addingTimeInterval(useDefault ? 90 : 120)

        controller.snooze(reminder, choice: choice, now: fixture.now)

        #expect(store.state(for: event.occurrenceKey)?.snoozedUntil == deadline)
        #expect(controller.scheduledReminders.first?.fireDate == deadline)
        #expect(ReminderStateStore(fileURL: fixture.stateFile).state(for: event.occurrenceKey)?.snoozedUntil == deadline)
        #expect(ReminderScheduler().availableSnoozeChoices(event: event, now: fixture.now)
            == [.seconds(30), .seconds(60), .seconds(120), .seconds(300), .untilDangerPoint])
    }

    @Test("Default snooze accepts start minus 11 seconds and rejects the danger point and later", arguments: [11.0, 10.0, 9.0])
    func exactBoundaryGuards(secondsBeforeStart: TimeInterval) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let event = fixture.event()
        let store = ReminderStateStore(fileURL: fixture.stateFile)
        let controller = fixture.controller(provider: fixture.provider(events: [event]), store: store)
        await controller.refresh(reason: "launch")
        let reminder = try #require(controller.scheduledReminders.first)
        let actionTime = event.startDate.addingTimeInterval(-secondsBeforeStart)

        controller.snooze(reminder, now: actionTime)

        if secondsBeforeStart == 11 {
            let deadline = event.startDate.addingTimeInterval(-10)
            #expect(store.state(for: event.occurrenceKey)?.snoozedUntil == deadline)
            #expect(controller.scheduledReminders.first?.fireDate == deadline)
            #expect(ReminderStateStore(fileURL: fixture.stateFile).state(for: event.occurrenceKey)?.snoozedUntil == deadline)
        } else {
            #expect(store.state(for: event.occurrenceKey) == nil)
            #expect(!FileManager.default.fileExists(atPath: fixture.stateFile.path))
        }
    }

    @Test("Snooze All clamps each deadline independently and retains the meeting at the danger point")
    func snoozeAllPreservesIndependentDeadlines() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.settings.update { $0.defaultLeadTime = 900 }
        let first = fixture.event(id: "first", startOffset: 670)
        let second = fixture.event(id: "second", startOffset: 790)
        let urgent = fixture.event(id: "urgent", startOffset: 610)
        let store = ReminderStateStore(fileURL: fixture.stateFile)
        let controller = fixture.controller(provider: fixture.provider(events: [first, second, urgent]), store: store)
        await controller.refresh(reason: "launch")
        #expect(Set(controller.activeReminders.map(\.id)) == Set([first.id, second.id, urgent.id]))
        let actionTime = fixture.now.addingTimeInterval(600)

        controller.snoozeAllVisible(now: actionTime)

        #expect(store.state(for: first.occurrenceKey)?.snoozedUntil == actionTime.addingTimeInterval(60))
        #expect(store.state(for: second.occurrenceKey)?.snoozedUntil == actionTime.addingTimeInterval(180))
        #expect(store.state(for: urgent.occurrenceKey) == nil)
        #expect(controller.activeReminders.map(\.id) == [urgent.id])
        let restarted = ReminderStateStore(fileURL: fixture.stateFile)
        #expect(restarted.state(for: first.occurrenceKey)?.snoozedUntil == actionTime.addingTimeInterval(60))
        #expect(restarted.state(for: second.occurrenceKey)?.snoozedUntil == actionTime.addingTimeInterval(180))
        #expect(restarted.state(for: urgent.occurrenceKey) == nil)
    }

    @MainActor
    private struct Fixture {
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let directory: URL
        let domain: String
        let settings: AppSettingsStore
        let stateFile: URL
        let cache: EventCacheStore

        init() throws {
            directory = try TestTempDirectory.make()
            domain = "MeetingShieldSnoozeControllerTests.\(UUID().uuidString)"
            _ = try #require(UserDefaults(suiteName: domain))
            settings = AppSettingsStore(domainName: domain)
            settings.update {
                $0.defaultLeadTime = 120
                $0.globalSnoozeDuration = 300
                $0.selectedCalendarIDs = ["synthetic-calendar"]
                $0.presentationModeDefault = true
                $0.soundEnabled = false
                $0.urgentRepeatSoundEnabled = false
                $0.wakeGraceEnabled = false
            }
            stateFile = directory.appending(path: "state.json")
            cache = EventCacheStore(fileURL: directory.appending(path: "cache.json"))
        }

        func cleanup() {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }

        func event(id: String = "synthetic-event", startOffset: TimeInterval = 3600) -> CalendarEventOccurrence {
            CalendarEventOccurrence.sample(
                eventID: id, title: "Synthetic meeting", startDate: now.addingTimeInterval(startOffset),
                calendarID: "synthetic-calendar"
            )
        }

        func provider(events: [CalendarEventOccurrence]) -> FakeCalendarProvider {
            let provider = FakeCalendarProvider()
            provider.eventsValue = events
            provider.calendarsValue = [UserCalendar(
                id: "synthetic-calendar", accountID: "mock-account", displayName: "Synthetic calendar",
                isPrimary: true, isSelected: true
            )]
            return provider
        }

        func controller(provider: FakeCalendarProvider, store: ReminderStateStore) -> MeetingShieldController {
            MeetingShieldController(
                settingsStore: settings, provider: provider, reminderStateStore: store, cacheStore: cache,
                notificationService: NoopNotificationService(), refreshMenuBar: {}
            )
        }
    }
}
