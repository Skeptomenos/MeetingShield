import Foundation
import Testing
@testable import MeetingShield

@Suite("Refresh health timing")
@MainActor
struct RefreshHealthTimingTests {
    @Test("Timer refreshes age a stalled calendar snapshot and a later success clears the warning")
    func heldRefreshAgesThroughBothWarningThresholds() async throws {
        try await withFixture { fixture, controller in
            await controller.refresh(reason: "launch")
            #expect(controller.events == [fixture.event])
            #expect(controller.statusMessage == nil)
            #expect(try fixture.cache.loadUnfiltered()?.cachedAt == fixture.clock.read())
            let scheduledIDs = controller.scheduledReminders.map(\.id)
            #expect(scheduledIDs.count == 1)

            try await fixture.withHeldRefresh(controller) {
                fixture.clock.advance(by: 299)
                await controller.refresh(reason: "timer")
                #expect(controller.statusMessage == nil)
                await fixture.expectHeldSnapshot(controller, scheduledIDs: scheduledIDs)

                fixture.clock.advance(by: 1)
                await controller.refresh(reason: "timer")
                #expect(controller.statusMessage?.localizedCaseInsensitiveContains("stale") == true)
                let fiveMinuteWarning = controller.statusMessage
                await fixture.expectHeldSnapshot(controller, scheduledIDs: scheduledIDs)

                fixture.clock.advance(by: 24 * 60 * 60 + 1 - 300)
                await controller.refresh(reason: "timer")
                #expect(controller.statusMessage?.localizedCaseInsensitiveContains("24 hours") == true)
                #expect(controller.statusMessage != fiveMinuteWarning)
                #expect(fixture.event.startDate.timeIntervalSince(fixture.clock.read()) > 120)
                await fixture.expectHeldSnapshot(controller, scheduledIDs: scheduledIDs)
            }

            #expect(controller.statusMessage == nil)
            #expect(controller.events == [fixture.event])
            #expect(controller.scheduledReminders.map(\.id) == scheduledIDs)
            #expect(controller.activeReminders.isEmpty)
            #expect(try fixture.cache.loadUnfiltered()?.cachedAt == fixture.clock.read())
            let recovered = await fixture.provider.snapshot()
            #expect(recovered.started == 3)
            #expect(recovered.completed == 3)
            #expect(recovered.inFlight == 0)
            #expect(recovered.maxInFlight == 1)
        }
    }

    @Test("A held successful fetch records its completion time without a trailing refresh")
    func heldSuccessUsesCompletionTimeWithoutTrailingRefresh() async throws {
        try await withFixture { fixture, controller in
            await controller.refresh(reason: "launch")
            let requestStartedAt = fixture.clock.read()
            #expect(try fixture.cache.loadUnfiltered()?.cachedAt == requestStartedAt)
            let scheduledIDs = controller.scheduledReminders.map(\.id)
            #expect(scheduledIDs.count == 1)

            try await fixture.withHeldRefresh(controller) {
                fixture.clock.advance(by: 301)
                let heldEnvelope = try fixture.cache.loadUnfiltered()
                #expect(heldEnvelope?.cachedAt == requestStartedAt)
                await fixture.expectHeldSnapshot(controller, scheduledIDs: scheduledIDs)
            }

            let recoveredCache = try #require(try fixture.cache.loadUnfiltered())
            #expect(recoveredCache.cachedAt == fixture.clock.read())
            #expect(controller.statusMessage == nil)
            #expect(controller.events == [fixture.event])
            #expect(controller.scheduledReminders.map(\.id) == scheduledIDs)
            #expect(controller.activeReminders.isEmpty)
            let recovered = await fixture.provider.snapshot()
            #expect(recovered.started == 2)
            #expect(recovered.completed == 2)
            #expect(recovered.inFlight == 0)
            #expect(recovered.maxInFlight == 1)
        }
    }

    @Test("Stale health ticks during a held refresh preserve the current Join error")
    func heldRefreshAgeDoesNotReplaceJoinFailure() async throws {
        try await withFixture { fixture, controller in
            await controller.refresh(reason: "launch")
            #expect(controller.statusMessage == nil)
            let reminder = try #require(controller.scheduledReminders.first)
            let scheduledIDs = controller.scheduledReminders.map(\.id)

            try await fixture.withHeldRefresh(controller) {
                controller.join(reminder, now: fixture.clock.read())
                let actionError = try #require(controller.statusMessage)
                #expect(actionError == RefreshHealthFailingBrowser.message)
                #expect(controller.fallback == nil)

                fixture.clock.advance(by: 299)
                await controller.refresh(reason: "timer")
                #expect(controller.statusMessage == actionError)
                await fixture.expectHeldSnapshot(controller, scheduledIDs: scheduledIDs)

                fixture.clock.advance(by: 1)
                await controller.refresh(reason: "timer")
                #expect(controller.statusMessage == actionError)
                #expect(controller.fallback == nil)
                await fixture.expectHeldSnapshot(controller, scheduledIDs: scheduledIDs)

                fixture.clock.advance(by: 24 * 60 * 60 + 1 - 300)
                await controller.refresh(reason: "timer")
                #expect(controller.statusMessage == actionError)
                #expect(controller.fallback == nil)
                await fixture.expectHeldSnapshot(controller, scheduledIDs: scheduledIDs)
            }
        }
    }

    private func withFixture(
        _ operation: @MainActor (Fixture, MeetingShieldController) async throws -> Void
    ) async throws {
        let fixture = try Fixture()
        let controller = fixture.controller()
        do {
            try await operation(fixture, controller)
        } catch {
            await fixture.cleanup(controller)
            throw error
        }
        await fixture.cleanup(controller)
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let domain: String
        let clock: AdvancingTestClock
        let settings: AppSettingsStore
        let state: ReminderStateStore
        let cache: EventCacheStore
        let event: CalendarEventOccurrence
        let provider: RefreshHealthProvider

        init() throws {
            directory = try TestTempDirectory.make()
            domain = "MeetingShieldRefreshHealthTimingTests.\(UUID().uuidString)"
            clock = AdvancingTestClock(Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
            _ = try #require(UserDefaults(suiteName: domain))
            settings = AppSettingsStore(domainName: domain)
            settings.update {
                $0.defaultLeadTime = 120
                $0.defaultBrowserSelection = .systemDefault
                $0.selectedCalendarIDs = ["synthetic-health-calendar"]
                $0.visibilityWindow = MenuVisibilityWindow(kind: .nextDays, hours: 4, days: 7)
                $0.presentationModeDefault = true
                $0.soundEnabled = false
                $0.urgentRepeatSoundEnabled = false
                $0.wakeGraceEnabled = false
            }
            state = ReminderStateStore(fileURL: directory.appending(path: "state.json"))
            cache = EventCacheStore(fileURL: directory.appending(path: "cache.json"))
            event = CalendarEventOccurrence.sample(
                eventID: "synthetic-health-event", title: "Synthetic health meeting",
                startDate: clock.read().addingTimeInterval(48 * 60 * 60),
                calendarID: "synthetic-health-calendar",
                location: "https://meet.google.com/synthetic-health"
            )
            provider = RefreshHealthProvider(event: event)
        }

        func controller() -> MeetingShieldController {
            MeetingShieldController(
                settingsStore: settings, provider: provider, reminderStateStore: state, cacheStore: cache,
                notificationService: NoopNotificationService(),
                launcher: MeetingLauncher(
                    profileService: BrowserProfileService(homeDirectory: directory),
                    browserLauncher: RefreshHealthFailingBrowser()
                ),
                now: { clock.read() }, refreshMenuBar: {}
            )
        }

        func withHeldRefresh(
            _ controller: MeetingShieldController,
            operation: @MainActor () async throws -> Void
        ) async throws {
            let refresh = Task { await controller.refresh(reason: "timer") }
            do {
                try #require(await provider.entered.wait(), "The second event fetch did not reach its gate.")
                try await operation()
            } catch {
                await provider.release.open()
                await refresh.value
                throw error
            }
            await provider.release.open()
            await refresh.value
        }

        func expectHeldSnapshot(_ controller: MeetingShieldController, scheduledIDs: [String]) async {
            let snapshot = await provider.snapshot()
            #expect(snapshot.started == 2)
            #expect(snapshot.completed == 1)
            #expect(snapshot.inFlight == 1)
            #expect(snapshot.maxInFlight == 1)
            #expect(controller.events == [event])
            #expect(controller.scheduledReminders.map(\.id) == scheduledIDs)
            #expect(controller.activeReminders.isEmpty)
        }

        func cleanup(_ controller: MeetingShieldController) async {
            await provider.release.open()
            await provider.entered.open()
            await provider.clearEvents()
            await controller.refresh(reason: "timer")
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

private struct RefreshHealthFailingBrowser: BrowserLaunching {
    static let message = "Synthetic browser launch refused."

    func open(_ url: URL, target: BrowserLaunchTarget) throws {
        throw MeetingLauncherError.launchFailed(Self.message)
    }
}

private actor RefreshHealthProvider: CalendarProvider {
    struct Snapshot: Sendable {
        let started: Int
        let completed: Int
        let inFlight: Int
        let maxInFlight: Int
    }

    nonisolated let providerID = "synthetic-health"
    let entered = RefreshHealthGate()
    let release = RefreshHealthGate()
    private let calendar: UserCalendar
    private var eventValues: [CalendarEventOccurrence]
    private var started = 0
    private var completed = 0
    private var inFlight = 0
    private var maxInFlight = 0

    init(event: CalendarEventOccurrence) {
        eventValues = [event]
        calendar = UserCalendar(
            id: event.calendarID, accountID: event.accountID, displayName: "Synthetic health calendar",
            isPrimary: true, isSelected: true
        )
    }

    var authState: CalendarProviderAuthState {
        get async { .connected(accountEmail: "synthetic-health@example.com") }
    }

    func accounts() async -> [ConnectedCalendarAccount] {
        [ConnectedCalendarAccount(id: calendar.accountID, displayName: "Synthetic health account")]
    }

    func calendars() async throws -> [UserCalendar] { [calendar] }

    func events(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        try await refresh(in: window)
    }

    func refresh(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        try await refresh(in: window, calendars: [calendar])
    }

    func refresh(in window: CalendarFetchWindow, calendars: [UserCalendar]) async throws -> [CalendarEventOccurrence] {
        started += 1
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer {
            completed += 1
            inFlight -= 1
        }
        let requested = Set(calendars.map(\.id))
        let events = eventValues.filter {
            requested.contains($0.calendarID) && $0.startDate <= window.end && $0.endDate >= window.start
        }
        if started == 2 {
            await entered.open()
            guard await release.wait() else { throw CancellationError() }
        }
        return events
    }

    func reconnect() async throws {}
    func removeAccount(id: String) async throws {}
    func clearEvents() { eventValues = [] }

    func snapshot() -> Snapshot {
        Snapshot(started: started, completed: completed, inFlight: inFlight, maxInFlight: maxInFlight)
    }
}

private actor RefreshHealthGate {
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]

    func wait() async -> Bool {
        if isOpen { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            if Task.isCancelled { return false }
            return await withCheckedContinuation { continuation in
                waiters[id] = continuation
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    await self?.finish(id, result: false)
                }
            }
        } onCancel: {
            Task { await self.finish(id, result: false) }
        }
    }

    func open() {
        isOpen = true
        for id in Array(waiters.keys) { finish(id, result: true) }
    }

    private func finish(_ id: UUID, result: Bool) {
        timeouts.removeValue(forKey: id)?.cancel()
        waiters.removeValue(forKey: id)?.resume(returning: result)
    }
}
