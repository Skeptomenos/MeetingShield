import Foundation
import Testing
@testable import MeetingShield

@Suite("Refresh selection", .serialized)
@MainActor
struct RefreshSelectionTests {
    @Test("Obsolete success cannot replace cache while the latest selection waits", arguments: SelectionChange.allCases)
    func obsoleteSuccessCannotWriteCache(change: SelectionChange) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = RefreshSelectionStep(ignoresCancellation: true)
        let latest = RefreshSelectionStep()
        let provider = fixture.provider(eventSteps: [first, latest])
        fixture.settings.snapshot.selectedCalendarIDs = change == .calendar
            ? [fixture.calendarA.id] : [fixture.calendarA.id, fixture.calendarB.id]
        let baseline = try fixture.seedCache([fixture.event("seed", calendar: fixture.calendarB)])
        let coordinator = fixture.coordinator(provider: provider)
        let running = Task { await coordinator.refresh(reason: "timer") }
        defer { running.cancel() }

        let firstEntered = await first.entered.wait()
        #expect(firstEntered)
        switch change {
        case .calendar:
            fixture.settings.snapshot.selectedCalendarIDs = [fixture.calendarB.id]
        case .account:
            fixture.settings.snapshot.disabledGoogleAccountIDs = [fixture.calendarA.accountID]
        }
        let second = await coordinator.refresh(reason: "settings")
        let third = await coordinator.refresh(reason: "settings")
        #expect(second == nil)
        #expect(third == nil)
        await first.release.open()

        let latestEntered = await latest.entered.wait(timeout: .seconds(10))
        #expect(latestEntered)
        #expect((try? Data(contentsOf: fixture.cache.fileURL)) == baseline)
        let requestsWhileSuspended = await provider.eventRequests
        let expectedFirst: Set<String> = change == .calendar
            ? [fixture.calendarA.id] : [fixture.calendarA.id, fixture.calendarB.id]
        #expect(requestsWhileSuspended == [expectedFirst, [fixture.calendarB.id]])

        await provider.releaseAll()
        let outcome = await running.value
        let requests = await provider.eventRequests
        let maximum = await provider.maxConcurrentRefreshes
        #expect(requests.count == 2)
        #expect(maximum == 1)
        #expect(outcome?.didSucceed == true)
        #expect(outcome?.statusMessage == nil)
        #expect(outcome?.events?.map(\.eventID) == ["event-b"])
        #expect(try fixture.cache.loadUnfiltered()?.events.map(\.eventID) == ["event-b"])
    }

    @Test("An obsolete failure does not count toward the latest failure or replace its cache")
    func obsoleteFailureDoesNotPoisonLatestStatus() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = RefreshSelectionStep(error: .requestFailed(503), ignoresCancellation: true)
        let latest = RefreshSelectionStep(error: .requestFailed(502))
        let provider = fixture.provider(eventSteps: [first, latest])
        fixture.settings.snapshot.selectedCalendarIDs = [fixture.calendarA.id]
        let baseline = try fixture.seedCache([
            fixture.event("cached-a", calendar: fixture.calendarA),
            fixture.event("cached-b", calendar: fixture.calendarB)
        ])
        let coordinator = fixture.coordinator(provider: provider)
        let running = Task { await coordinator.refresh(reason: "timer") }
        defer { running.cancel() }

        let firstEntered = await first.entered.wait()
        #expect(firstEntered)
        fixture.settings.snapshot.selectedCalendarIDs = [fixture.calendarB.id]
        let coalesced = await coordinator.refresh(reason: "settings")
        #expect(coalesced == nil)
        await first.release.open()
        let latestEntered = await latest.entered.wait()
        #expect(latestEntered)
        #expect((try? Data(contentsOf: fixture.cache.fileURL)) == baseline)

        await provider.releaseAll()
        let outcome = await running.value
        #expect(outcome?.didSucceed == false)
        #expect(outcome?.statusMessage?.hasPrefix(CalendarProviderError.requestFailed(502).localizedDescription) == true)
        #expect(outcome?.statusMessage?.contains("Coverage for some selected calendars is unknown.") == true)
        #expect(outcome?.events?.map(\.eventID) == ["cached-b"])
        #expect(outcome?.events?.allSatisfy(\.isFromCache) == true)
        #expect(try Data(contentsOf: fixture.cache.fileURL) == baseline)
    }

    @Test("Replacing a provider during its calendar await never sends its calendars to the replacement")
    func replacementDoesNotMixProviderStages() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let oldCalendarStep = RefreshSelectionStep(ignoresCancellation: true)
        let replacementEventStep = RefreshSelectionStep()
        let original = RefreshSelectionProvider(
            calendars: [fixture.calendarA], events: [fixture.event("original", calendar: fixture.calendarA)],
            calendarSteps: [oldCalendarStep]
        )
        let replacement = RefreshSelectionProvider(
            calendars: [fixture.calendarB], events: [fixture.event("replacement", calendar: fixture.calendarB)],
            eventSteps: [replacementEventStep]
        )
        let coordinator = fixture.coordinator(provider: original)
        let running = Task { await coordinator.refresh(reason: "timer") }
        defer { running.cancel() }

        let oldCalendarEntered = await oldCalendarStep.entered.wait()
        #expect(oldCalendarEntered)
        coordinator.provider = replacement
        let coalesced = await coordinator.refresh(reason: "reconnect")
        #expect(coalesced == nil)
        await oldCalendarStep.release.open()
        let replacementEntered = await replacementEventStep.entered.wait()
        #expect(replacementEntered)
        let requestsWhileSuspended = await replacement.eventRequests
        #expect(requestsWhileSuspended == [[fixture.calendarB.id]])

        await original.releaseAll()
        await replacement.releaseAll()
        let outcome = await running.value
        let originalRequests = await original.eventRequests
        let replacementRequests = await replacement.eventRequests
        #expect(originalRequests.allSatisfy { $0 == [fixture.calendarA.id] })
        #expect(replacementRequests == [[fixture.calendarB.id]])
        #expect(outcome?.didSucceed == true)
        #expect(outcome?.calendars?.map(\.id) == [fixture.calendarB.id])
        #expect(outcome?.accounts.map(\.id) == [fixture.calendarB.accountID])
        #expect(outcome?.events?.map(\.eventID) == ["replacement"])
        #expect(try fixture.cache.loadUnfiltered()?.events.map(\.eventID) == ["replacement"])
    }

    @Test("Default, explicit all, and explicit none reach the provider unchanged", arguments: SelectionMode.allCases)
    func selectionModesReachProvider(mode: SelectionMode) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let provider = fixture.provider()
        switch mode {
        case .providerDefaults:
            break
        case .all:
            fixture.settings.snapshot.selectedCalendarIDs = [fixture.calendarA.id, fixture.calendarB.id]
        case .none:
            fixture.settings.snapshot.selectedCalendarIDs = []
        }
        let coordinator = fixture.coordinator(provider: provider)

        let outcome = await coordinator.refresh(reason: "settings")

        let expectedIDs: Set<String> = mode == .none ? [] : [fixture.calendarA.id, fixture.calendarB.id]
        let requests = await provider.eventRequests
        #expect(requests == [expectedIDs])
        #expect(outcome?.didSucceed == true)
        #expect(Set(outcome?.events?.map(\.calendarID) ?? []) == expectedIDs)
        #expect(Set(try fixture.cache.loadUnfiltered()?.events.map(\.calendarID) ?? []) == expectedIDs)
    }

    @Test("Removing the last selected account cannot adopt a remaining account or cache its late response")
    func removingLastSelectedAccountPreservesNone() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = RefreshSelectionStep(ignoresCancellation: true)
        let latest = RefreshSelectionStep()
        let provider = fixture.provider(eventSteps: [first, latest])
        fixture.settings.snapshot.selectedCalendarIDs = [fixture.calendarA.id]
        let baseline = try fixture.seedCache([])
        let coordinator = fixture.coordinator(provider: provider)
        let running = Task { await coordinator.refresh(reason: "timer") }
        defer { running.cancel() }

        let firstEntered = await first.entered.wait()
        #expect(firstEntered)
        await provider.removeSyntheticAccount(fixture.calendarA.accountID)
        fixture.settings.snapshot.selectedCalendarIDs.remove(fixture.calendarA.id)
        let coalesced = await coordinator.refresh(reason: "settings")
        #expect(coalesced == nil)
        await first.release.open()
        let latestEntered = await latest.entered.wait()
        #expect(latestEntered)
        #expect((try? Data(contentsOf: fixture.cache.fileURL)) == baseline)
        let requestsWhileSuspended = await provider.eventRequests
        #expect(requestsWhileSuspended == [[fixture.calendarA.id], []])

        await provider.releaseAll()
        let outcome = await running.value
        #expect(outcome?.didSucceed == true)
        #expect(outcome?.accounts.map(\.id) == [fixture.calendarB.accountID])
        #expect(outcome?.calendars?.map(\.id) == [fixture.calendarB.id])
        #expect(outcome?.events?.isEmpty == true)
        #expect(try fixture.cache.loadUnfiltered()?.events.isEmpty == true)
    }

    @Test("Returning to the original selection still rejects the older request generation")
    func selectionRoundTripRejectsObsoleteGeneration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = RefreshSelectionStep(ignoresCancellation: true)
        let latest = RefreshSelectionStep()
        let provider = fixture.provider(eventSteps: [first, latest])
        fixture.settings.snapshot.selectedCalendarIDs = [fixture.calendarA.id]
        let baseline = try fixture.seedCache([fixture.event("seed", calendar: fixture.calendarA)])
        let coordinator = fixture.coordinator(provider: provider)
        let running = Task { await coordinator.refresh(reason: "timer") }
        defer { running.cancel() }

        let firstEntered = await first.entered.wait()
        #expect(firstEntered)
        fixture.settings.snapshot.selectedCalendarIDs = [fixture.calendarB.id]
        let changedToB = coordinator.settingsDidChange()
        fixture.settings.snapshot.selectedCalendarIDs = [fixture.calendarA.id]
        let changedBackToA = coordinator.settingsDidChange()
        #expect(changedToB)
        #expect(changedBackToA)
        await provider.replaceEvents([fixture.event("latest-a", calendar: fixture.calendarA)])
        await first.release.open()

        let latestEntered = await latest.entered.wait()
        #expect(latestEntered)
        #expect((try? Data(contentsOf: fixture.cache.fileURL)) == baseline)
        let requestsWhileSuspended = await provider.eventRequests
        #expect(requestsWhileSuspended == [[fixture.calendarA.id], [fixture.calendarA.id]])

        await provider.releaseAll()
        let outcome = await running.value
        let maximum = await provider.maxConcurrentRefreshes
        #expect(maximum == 1)
        #expect(outcome?.didSucceed == true)
        #expect(outcome?.events?.map(\.eventID) == ["latest-a"])
        #expect(try fixture.cache.loadUnfiltered()?.events.map(\.eventID) == ["latest-a"])
    }

    @Test("A cancelled refresh cannot publish or cache and a later independent request still succeeds")
    func cancellationPreservesCacheAndAllowsRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let cancelled = RefreshSelectionStep(ignoresCancellation: true)
        let recovery = RefreshSelectionStep()
        let provider = fixture.provider(eventSteps: [cancelled, recovery])
        fixture.settings.snapshot.selectedCalendarIDs = [fixture.calendarA.id]
        let baseline = try fixture.seedCache([fixture.event("seed", calendar: fixture.calendarA)])
        let coordinator = fixture.coordinator(provider: provider)
        let running = Task { await coordinator.refresh(reason: "timer") }
        defer { running.cancel() }

        let cancelledRequestEntered = await cancelled.entered.wait()
        #expect(cancelledRequestEntered)
        running.cancel()
        await cancelled.release.open()
        let cancelledOutcome = await running.value
        #expect(cancelledOutcome == nil)
        #expect((try? Data(contentsOf: fixture.cache.fileURL)) == baseline)

        await provider.replaceEvents([fixture.event("recovered-a", calendar: fixture.calendarA)])
        let restarted = Task { await coordinator.refresh(reason: "settings") }
        defer { restarted.cancel() }
        let recoveryEntered = await recovery.entered.wait()
        #expect(recoveryEntered)
        #expect((try? Data(contentsOf: fixture.cache.fileURL)) == baseline)
        await provider.releaseAll()
        let recoveryOutcome = await restarted.value
        let requests = await provider.eventRequests
        let maximum = await provider.maxConcurrentRefreshes
        #expect(requests == [[fixture.calendarA.id], [fixture.calendarA.id]])
        #expect(maximum == 1)
        #expect(recoveryOutcome?.didSucceed == true)
        #expect(recoveryOutcome?.statusMessage == nil)
        #expect(recoveryOutcome?.events?.map(\.eventID) == ["recovered-a"])
        #expect(try fixture.cache.loadUnfiltered()?.events.map(\.eventID) == ["recovered-a"])
    }

    @Test("Non-fetch settings leave the held request current without a trailing fetch", arguments: NonFetchChange.allCases)
    func nonFetchSettingsPreserveCurrentRefresh(change: NonFetchChange) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let held = RefreshSelectionStep(ignoresCancellation: true)
        let provider = fixture.provider(eventSteps: [held])
        let coordinator = fixture.coordinator(provider: provider)
        let running = Task { await coordinator.refresh(reason: "timer") }
        defer { running.cancel() }

        let entered = await held.entered.wait()
        #expect(entered)
        switch change {
        case .leadTime:
            fixture.settings.snapshot.defaultLeadTime = 300
        case .appearance:
            fixture.settings.snapshot.showEventTitlesInMenuBar = false
        case .providerDefaults:
            fixture.settings.snapshot.recordProviderDefaultCalendarIDs([fixture.calendarA.id, fixture.calendarB.id])
        }
        let requiresFetch = coordinator.settingsDidChange()
        #expect(requiresFetch == false)

        await provider.releaseAll()
        let outcome = await running.value
        let requests = await provider.eventRequests
        #expect(requests == [[fixture.calendarA.id, fixture.calendarB.id]])
        #expect(outcome?.didSucceed == true)
        #expect(outcome?.events?.map(\.eventID) == ["event-a", "event-b"])
        if let outcome { #expect(coordinator.isCurrent(outcome)) }
        #expect(try fixture.cache.loadUnfiltered()?.events.map(\.eventID) == ["event-a", "event-b"])
    }

    enum NonFetchChange: CaseIterable, Sendable {
        case leadTime, appearance, providerDefaults
    }

    enum SelectionChange: CaseIterable, Sendable {
        case calendar, account
    }

    enum SelectionMode: CaseIterable, Sendable {
        case providerDefaults, all, none
    }

    @MainActor
    private final class SettingsBox {
        var snapshot = AppSettingsSnapshot.defaults
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let cache: EventCacheStore
        let settings = SettingsBox()
        let calendarA = UserCalendar(
            id: "synthetic-a::calendar", accountID: "synthetic-a", displayName: "Synthetic A",
            isPrimary: true, isSelected: true
        )
        let calendarB = UserCalendar(
            id: "synthetic-b::calendar", accountID: "synthetic-b", displayName: "Synthetic B",
            isPrimary: true, isSelected: true
        )

        init() throws {
            directory = try TestTempDirectory.make()
            cache = EventCacheStore(fileURL: directory.appending(path: "event-cache.json"))
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }

        func event(_ id: String, calendar: UserCalendar) -> CalendarEventOccurrence {
            var event = CalendarEventOccurrence.sample(
                eventID: id, title: "Synthetic refresh event", startDate: TestDates.start,
                calendarID: calendar.id, htmlLink: nil
            )
            event.providerID = "synthetic"
            event.accountID = calendar.accountID
            event.updatedAt = TestDates.now
            return event
        }

        func provider(eventSteps: [RefreshSelectionStep] = []) -> RefreshSelectionProvider {
            RefreshSelectionProvider(
                calendars: [calendarA, calendarB],
                events: [event("event-a", calendar: calendarA), event("event-b", calendar: calendarB)],
                eventSteps: eventSteps
            )
        }

        func coordinator(provider: RefreshSelectionProvider) -> RefreshCoordinator {
            let settings = settings
            return RefreshCoordinator(
                provider: provider, cacheStore: cache, settings: { settings.snapshot },
                now: { TestDates.now }, diagnostics: DiagnosticsRecorder(directory: directory, nativeSink: { _, _ in })
            )
        }

        func seedCache(_ events: [CalendarEventOccurrence]) throws -> Data {
            try cache.save(events: events, detectedLinks: [:], now: TestDates.now)
            return try Data(contentsOf: cache.fileURL)
        }
    }
}

private struct RefreshSelectionStep: Sendable {
    let entered = RefreshSelectionGate()
    let release = RefreshSelectionGate()
    var error: CalendarProviderError?
    var ignoresCancellation = false

    func wait() async throws {
        await entered.open()
        let wasReleased: Bool
        if ignoresCancellation {
            let gate = release
            wasReleased = await Task { await gate.wait() }.value
        } else {
            wasReleased = await release.wait()
        }
        if let error { throw error }
        if !wasReleased && !ignoresCancellation { throw CancellationError() }
    }
}

private actor RefreshSelectionProvider: CalendarProvider {
    nonisolated let providerID = "synthetic"
    private var calendarValues: [UserCalendar]
    private var eventValues: [CalendarEventOccurrence]
    private let calendarSteps: [RefreshSelectionStep]
    private let eventSteps: [RefreshSelectionStep]
    private let authStateValue: CalendarProviderAuthState
    private var calendarCalls = 0
    private var concurrentRefreshes = 0
    private(set) var maxConcurrentRefreshes = 0
    private(set) var eventRequests: [Set<String>] = []
    private(set) var eventWindows: [CalendarFetchWindow] = []

    init(
        calendars: [UserCalendar], events: [CalendarEventOccurrence],
        calendarSteps: [RefreshSelectionStep] = [], eventSteps: [RefreshSelectionStep] = [],
        authState: CalendarProviderAuthState = .connected(accountEmail: "Synthetic accounts")
    ) {
        calendarValues = calendars
        eventValues = events
        self.calendarSteps = calendarSteps
        self.eventSteps = eventSteps
        authStateValue = authState
    }

    var authState: CalendarProviderAuthState {
        get async { authStateValue }
    }

    func accounts() async -> [ConnectedCalendarAccount] {
        calendarValues.map { ConnectedCalendarAccount(id: $0.accountID, displayName: $0.displayName) }
    }

    func calendars() async throws -> [UserCalendar] {
        let snapshot = calendarValues
        let index = calendarCalls
        calendarCalls += 1
        if index < calendarSteps.count { try await calendarSteps[index].wait() }
        return snapshot
    }

    func events(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        try await refresh(in: window)
    }

    func refresh(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
        try await refresh(in: window, calendars: calendarValues)
    }

    func refresh(in window: CalendarFetchWindow, calendars: [UserCalendar]) async throws -> [CalendarEventOccurrence] {
        let requested = Set(calendars.map(\.id))
        let snapshot = eventValues.filter { requested.contains($0.calendarID) }
        let index = eventRequests.count
        eventRequests.append(requested)
        eventWindows.append(window)
        concurrentRefreshes += 1
        maxConcurrentRefreshes = max(maxConcurrentRefreshes, concurrentRefreshes)
        defer { concurrentRefreshes -= 1 }
        if index < eventSteps.count { try await eventSteps[index].wait() }
        return snapshot
    }

    func reconnect() async throws {}

    func removeAccount(id: String) async throws {
        removeSyntheticAccount(id)
    }

    func removeSyntheticAccount(_ id: String) {
        calendarValues.removeAll { $0.accountID == id }
        eventValues.removeAll { $0.accountID == id }
    }

    func replaceEvents(_ events: [CalendarEventOccurrence]) {
        eventValues = events
    }

    func releaseAll() async {
        for step in calendarSteps + eventSteps { await step.release.open() }
    }
}

private actor RefreshSelectionGate {
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]

    func wait(timeout: Duration = .seconds(3)) async -> Bool {
        if isOpen { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            if Task.isCancelled { return false }
            return await withCheckedContinuation { continuation in
                waiters[id] = continuation
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
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

@Suite("Controller refresh selection", .serialized)
@MainActor
struct ControllerRefreshSelectionTests {
    @Test("Stopping the controller prevents an old owner from restarting pending work", arguments: [false, true])
    func stopPreventsOldOwnerHandoff(cancelOwner: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let initial = RefreshSelectionStep()
        let cancelled = RefreshSelectionStep(ignoresCancellation: true)
        let unexpected = RefreshSelectionStep()
        await initial.release.open()
        let provider = fixture.provider(eventSteps: [initial, cancelled, unexpected])
        fixture.settings.update { $0.selectedCalendarIDs = [fixture.calendarA.id] }
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        let originalCache = try Data(contentsOf: fixture.cache.fileURL)
        let running = Task { await controller.refresh(reason: "timer") }
        defer { running.cancel() }
        let entered = await cancelled.entered.wait()
        try #require(entered)
        fixture.settings.update { $0.selectedCalendarIDs = [fixture.calendarB.id] }
        await controller.refresh(reason: "settings")

        if cancelOwner { running.cancel() }
        controller.stop()
        await provider.releaseAll()
        await running.value
        let restarted = await unexpected.entered.wait()

        #expect(!restarted)
        #expect(await provider.eventRequests == [[fixture.calendarA.id], [fixture.calendarA.id]])
        #expect(controller.events.map(\.eventID) == ["event-a"])
        #expect(try Data(contentsOf: fixture.cache.fileURL) == originalCache)
    }

    @Test("A new request after stop survives a cancelled handoff owner")
    func newRequestAfterStopSurvivesCancelledHandoff() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let initial = RefreshSelectionStep()
        let cancelled = RefreshSelectionStep(ignoresCancellation: true)
        let handoff = RefreshSelectionStep(ignoresCancellation: true)
        let latest = RefreshSelectionStep()
        await initial.release.open()
        let provider = fixture.provider(eventSteps: [initial, cancelled, handoff, latest])
        fixture.settings.update { $0.selectedCalendarIDs = [fixture.calendarA.id] }
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        let running = Task { await controller.refresh(reason: "timer") }
        defer { running.cancel() }
        let entered = await cancelled.entered.wait()
        try #require(entered)
        fixture.settings.update { $0.selectedCalendarIDs = [fixture.calendarB.id] }
        await controller.refresh(reason: "settings")
        running.cancel()
        await cancelled.release.open()
        await running.value
        let handoffEntered = await handoff.entered.wait()
        try #require(handoffEntered)

        controller.stop()
        fixture.settings.update { $0.selectedCalendarIDs = [fixture.calendarA.id] }
        await provider.replaceEvents([fixture.event("after-stop-a", calendar: fixture.calendarA)])
        await controller.refresh(reason: "launch")
        await handoff.release.open()
        let latestEntered = await latest.entered.wait()

        #expect(latestEntered)
        let completed = fixture.callbacks.next()
        await provider.releaseAll()
        if latestEntered { #expect(await completed.wait()) }
        #expect(await provider.eventRequests == [[fixture.calendarA.id], [fixture.calendarA.id], [fixture.calendarB.id], [fixture.calendarA.id]])
        #expect(await provider.maxConcurrentRefreshes == 1)
        #expect(controller.events.map(\.eventID) == ["after-stop-a"])
        #expect(try fixture.cache.loadUnfiltered()?.events.map(\.eventID) == ["after-stop-a"])
    }

    @Test("A newer coalesced request survives cancellation of the active refresh owner", arguments: [false, true])
    func cancelledOwnerDoesNotConsumeNewerRequest(duringTrailingFetch: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let initial = RefreshSelectionStep()
        let cancelled = RefreshSelectionStep(ignoresCancellation: true)
        let trailing = RefreshSelectionStep(ignoresCancellation: true)
        let latest = RefreshSelectionStep()
        await initial.release.open()
        let provider = fixture.provider(eventSteps: duringTrailingFetch ? [initial, cancelled, trailing, latest] : [initial, cancelled, latest])
        fixture.settings.update { $0.selectedCalendarIDs = [fixture.calendarA.id] }
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        let running = Task { await controller.refresh(reason: "timer") }
        defer { running.cancel() }
        let ownerEntered = await cancelled.entered.wait()
        try #require(ownerEntered)
        await provider.replaceEvents([fixture.event("latest-b", calendar: fixture.calendarB)])
        fixture.settings.update { $0.selectedCalendarIDs = [fixture.calendarB.id] }

        await controller.refresh(reason: "settings")
        if duringTrailingFetch {
            await cancelled.release.open()
            let trailingEntered = await trailing.entered.wait()
            try #require(trailingEntered)
        }
        running.cancel()
        await cancelled.release.open()
        await trailing.release.open()
        await running.value
        let newerRequestStarted = await latest.entered.wait()

        #expect(newerRequestStarted)
        let completed = fixture.callbacks.next()
        await provider.releaseAll()
        if newerRequestStarted {
            let published = await completed.wait()
            #expect(published)
        }
        let requests = await provider.eventRequests
        let maximum = await provider.maxConcurrentRefreshes
        var expectedRequests: [Set<String>] = [[fixture.calendarA.id], [fixture.calendarA.id], [fixture.calendarB.id]]
        if duringTrailingFetch { expectedRequests.append([fixture.calendarB.id]) }
        #expect(requests == expectedRequests)
        #expect(maximum == 1)
        #expect(controller.events.map(\.eventID) == ["latest-b"])
        #expect(try fixture.cache.loadUnfiltered()?.events.map(\.eventID) == ["latest-b"])
    }

    @Test("Settings changes request a provider refresh without the timer", arguments: FetchChange.allCases)
    func settingsChangesRequestRefresh(change: FetchChange) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let initial = RefreshSelectionStep()
        let changed = RefreshSelectionStep()
        await initial.release.open()
        let provider = fixture.provider(eventSteps: [initial, changed])
        fixture.settings.update {
            $0.selectedCalendarIDs = change == .calendar
                ? [fixture.calendarA.id] : [fixture.calendarA.id, fixture.calendarB.id]
        }
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        await provider.replaceEvents([
            fixture.event("updated-a", calendar: fixture.calendarA),
            fixture.event("updated-b", calendar: fixture.calendarB)
        ])
        fixture.settings.update { settings in
            switch change {
            case .calendar:
                settings.selectedCalendarIDs = [fixture.calendarB.id]
            case .account:
                settings.disabledGoogleAccountIDs = [fixture.calendarA.accountID]
            case .visibility:
                settings.visibilityWindow = MenuVisibilityWindow(kind: .nextDays, hours: 4, days: 7)
            }
        }

        controller.handleSettingsChanged()

        let enteredWithoutTimer = await changed.entered.wait()
        #expect(enteredWithoutTimer)
        let requestsBeforeCleanup = await provider.eventRequests
        let expectedIDs: Set<String> = change == .visibility
            ? [fixture.calendarA.id, fixture.calendarB.id] : [fixture.calendarB.id]
        #expect(requestsBeforeCleanup.count == 2)
        #expect(requestsBeforeCleanup.last == expectedIDs)
        if change == .visibility {
            let windows = await provider.eventWindows
            #expect((windows.last?.end ?? .distantPast) > fixture.now.addingTimeInterval(6 * 24 * 60 * 60))
        }

        let completed = fixture.callbacks.next()
        await provider.releaseAll()
        if !enteredWithoutTimer { await controller.refresh(reason: "settings") }
        let didComplete = await completed.wait()
        #expect(didComplete)
        #expect(Set(controller.events.map(\.calendarID)) == expectedIDs)
        #expect(controller.events.allSatisfy { $0.eventID.hasPrefix("updated-") })
        #expect(controller.activeReminders.isEmpty)
    }

    @Test("A completed calendar list persists default selection through store reconstruction")
    func successfulListPersistsDefaults() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var hidden = fixture.calendarB
        hidden.isSelected = false
        let provider = RefreshSelectionProvider(
            calendars: [fixture.calendarA, hidden],
            events: [fixture.event("selected", calendar: fixture.calendarA), fixture.event("hidden", calendar: hidden)]
        )
        let controller = fixture.controller(provider: provider)

        await controller.refresh(reason: "launch")

        let reloaded = fixture.reloadedSettings()
        #expect(fixture.settings.snapshot.hasExplicitCalendarSelection == false)
        #expect(fixture.settings.snapshot.providerDefaultCalendarIDs == [fixture.calendarA.id])
        #expect(reloaded.snapshot.providerDefaultCalendarIDs == [fixture.calendarA.id])
        #expect(reloaded.snapshot.isCalendarSelected(hidden.id) == false)
        #expect(controller.events.map(\.eventID) == ["selected"])
    }

    @Test("Only a completed calendar list replaces remembered defaults on failure", arguments: FailureBoundary.allCases)
    func failedRefreshUsesCorrectDefaults(boundary: FailureBoundary) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.settings.update { $0.recordProviderDefaultCalendarIDs([fixture.calendarB.id]) }
        var unselected = fixture.calendarB
        unselected.isSelected = false
        let calendars = [fixture.calendarA, unselected]
        let failure = RefreshSelectionStep(error: .requestFailed(503))
        await failure.release.open()
        let provider = RefreshSelectionProvider(
            calendars: calendars,
            events: [],
            calendarSteps: boundary == .calendarList ? [failure] : [],
            eventSteps: boundary == .events ? [failure] : [],
            authState: boundary == .authUnavailable ? .disconnected : .connected(accountEmail: "Synthetic accounts")
        )
        try fixture.cache.save(
            events: [fixture.event("cached-a", calendar: fixture.calendarA), fixture.event("cached-b", calendar: fixture.calendarB)],
            detectedLinks: [:], now: fixture.now
        )
        let controller = fixture.controller(provider: provider)

        await controller.refresh(reason: "launch")

        let expectedID = boundary == .events ? fixture.calendarA.id : fixture.calendarB.id
        #expect(fixture.settings.snapshot.providerDefaultCalendarIDs == [expectedID])
        #expect(fixture.reloadedSettings().snapshot.providerDefaultCalendarIDs == [expectedID])
        #expect(fixture.settings.snapshot.hasExplicitCalendarSelection == false)
        #expect(controller.events.map(\.calendarID) == [expectedID])
        #expect(controller.events.allSatisfy { $0.isFromCache })
        #expect(controller.statusMessage != nil)
    }

    @Test("Removing an account rejects its held response at the controller boundary", arguments: RemovalMode.allCases)
    func removeAccountRejectsLatePublish(mode: RemovalMode) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let initial = RefreshSelectionStep()
        let obsolete = RefreshSelectionStep(ignoresCancellation: true)
        let latest = RefreshSelectionStep()
        await initial.release.open()
        let provider = fixture.provider(eventSteps: [initial, obsolete, latest])
        if mode == .lastExplicit {
            fixture.settings.update { $0.selectedCalendarIDs = [fixture.calendarA.id] }
        }
        let controller = fixture.controller(provider: provider)
        await controller.refresh(reason: "launch")
        await provider.replaceEvents([
            fixture.event("late-removed-a", calendar: fixture.calendarA),
            fixture.event("remaining-b", calendar: fixture.calendarB)
        ])
        let running = Task { await controller.refresh(reason: "timer") }
        defer { running.cancel() }
        let oldRequestEntered = await obsolete.entered.wait()
        #expect(oldRequestEntered)
        let removed = fixture.callbacks.next()

        controller.removeConnectedAccount(fixture.calendarA.accountID)

        let removalCompleted = await removed.wait()
        #expect(removalCompleted)
        #expect(controller.accounts.allSatisfy { $0.id != fixture.calendarA.accountID })
        #expect(controller.calendars.allSatisfy { $0.accountID != fixture.calendarA.accountID })
        #expect(controller.events.allSatisfy { $0.accountID != fixture.calendarA.accountID })
        #expect(fixture.settings.snapshot.hasExplicitCalendarSelection == (mode == .lastExplicit))
        let cacheAfterRemoval = try? Data(contentsOf: fixture.cache.fileURL)
        var republishedRemovedAccount = false
        fixture.callbacks.onRefresh = { [weak controller] in
            guard let controller else { return }
            if controller.accounts.contains(where: { $0.id == fixture.calendarA.accountID })
                || controller.calendars.contains(where: { $0.accountID == fixture.calendarA.accountID })
                || controller.events.contains(where: { $0.accountID == fixture.calendarA.accountID }) {
                republishedRemovedAccount = true
            }
        }
        await obsolete.release.open()
        let latestEntered = await latest.entered.wait()
        #expect(latestEntered)
        #expect((try? Data(contentsOf: fixture.cache.fileURL)) == cacheAfterRemoval)
        let requestsWhileSuspended = await provider.eventRequests
        let expectedIDs: Set<String> = mode == .lastExplicit ? [] : [fixture.calendarB.id]
        #expect(requestsWhileSuspended.count == 3)
        #expect(requestsWhileSuspended.last == expectedIDs)

        await provider.releaseAll()
        await running.value
        fixture.callbacks.onRefresh = nil
        #expect(republishedRemovedAccount == false)
        #expect(controller.accounts.map(\.id) == [fixture.calendarB.accountID])
        #expect(controller.calendars.map(\.id) == [fixture.calendarB.id])
        #expect(Set(controller.events.map(\.calendarID)) == expectedIDs)
        #expect(Set(try fixture.cache.loadUnfiltered()?.events.map(\.calendarID) ?? []) == expectedIDs)
        #expect(fixture.reloadedSettings().snapshot.hasExplicitCalendarSelection == (mode == .lastExplicit))
    }

    @Test("Replacing the provider before queued removal starts preserves both providers and current settings")
    func providerReplacementBeforeRemovalStartsPreservesAccounts() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.settings.update {
            $0.selectedCalendarIDs = [fixture.calendarA.id, fixture.calendarB.id]
            $0.accountNicknames[fixture.calendarA.accountID] = "Synthetic account alias"
            $0.calendarAliases[fixture.calendarA.id] = "Synthetic calendar alias"
        }
        let original = fixture.provider()
        let replacement = RefreshSelectionProvider(
            calendars: [fixture.calendarA, fixture.calendarB],
            events: [
                fixture.event("replacement-a", calendar: fixture.calendarA),
                fixture.event("replacement-b", calendar: fixture.calendarB)
            ]
        )
        let controller = fixture.controller(provider: original)
        await controller.refresh(reason: "launch")
        let settingsBeforeRemoval = fixture.settings.snapshot
        let completed = fixture.callbacks.next()

        controller.removeConnectedAccount(fixture.calendarA.accountID)
        controller.provider = replacement

        let operationDrained = await completed.wait()
        #expect(operationDrained)
        let originalAccounts = await original.accounts()
        let replacementAccounts = await replacement.accounts()
        let expectedAccounts: Set<String> = [fixture.calendarA.accountID, fixture.calendarB.accountID]
        #expect(Set(originalAccounts.map(\.id)) == expectedAccounts)
        #expect(Set(replacementAccounts.map(\.id)) == expectedAccounts)
        #expect(Set(controller.accounts.map(\.id)) == expectedAccounts)
        #expect(Set(controller.calendars.map(\.id)) == [fixture.calendarA.id, fixture.calendarB.id])
        #expect(controller.events.map(\.eventID) == ["replacement-a", "replacement-b"])
        #expect(fixture.settings.snapshot == settingsBeforeRemoval)
        #expect(fixture.reloadedSettings().snapshot == settingsBeforeRemoval)
    }

    enum FetchChange: CaseIterable, Sendable {
        case calendar, account, visibility
    }

    enum FailureBoundary: CaseIterable, Sendable {
        case events, calendarList, authUnavailable
    }

    enum RemovalMode: CaseIterable, Sendable {
        case providerDefaults, lastExplicit
    }

    @MainActor
    private final class Callbacks {
        var onRefresh: (@MainActor () -> Void)?
        private var pending: RefreshSelectionGate?

        func next() -> RefreshSelectionGate {
            let gate = RefreshSelectionGate()
            pending = gate
            return gate
        }

        func record() {
            onRefresh?()
            if let gate = pending {
                pending = nil
                Task { await gate.open() }
            }
        }
    }

    @MainActor
    private struct Fixture {
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let directory: URL
        let domain: String
        let defaults: UserDefaults
        let settings: AppSettingsStore
        let cache: EventCacheStore
        let state: ReminderStateStore
        let callbacks = Callbacks()
        let calendarA = UserCalendar(
            id: "synthetic-controller-a::calendar", accountID: "synthetic-controller-a", displayName: "Synthetic A",
            isPrimary: true, isSelected: true
        )
        let calendarB = UserCalendar(
            id: "synthetic-controller-b::calendar", accountID: "synthetic-controller-b", displayName: "Synthetic B",
            isPrimary: true, isSelected: true
        )

        init() throws {
            directory = try TestTempDirectory.make()
            domain = "MeetingShieldControllerRefreshSelectionTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: domain))
            settings = AppSettingsStore(domainName: domain)
            settings.update {
                $0.presentationModeDefault = true
                $0.soundEnabled = false
                $0.urgentRepeatSoundEnabled = false
                $0.wakeGraceEnabled = false
            }
            cache = EventCacheStore(fileURL: directory.appending(path: "event-cache.json"))
            state = ReminderStateStore(fileURL: directory.appending(path: "reminder-state.json"))
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }

        func reloadedSettings() -> AppSettingsStore {
            AppSettingsStore(domainName: domain)
        }

        func event(_ id: String, calendar: UserCalendar) -> CalendarEventOccurrence {
            var event = CalendarEventOccurrence.sample(
                eventID: id, title: "Synthetic controller refresh", startDate: now.addingTimeInterval(3600),
                calendarID: calendar.id, htmlLink: nil
            )
            event.providerID = "synthetic"
            event.accountID = calendar.accountID
            event.updatedAt = now
            return event
        }

        func provider(eventSteps: [RefreshSelectionStep] = []) -> RefreshSelectionProvider {
            RefreshSelectionProvider(
                calendars: [calendarA, calendarB],
                events: [event("event-a", calendar: calendarA), event("event-b", calendar: calendarB)],
                eventSteps: eventSteps
            )
        }

        func controller(provider: RefreshSelectionProvider) -> MeetingShieldController {
            let callbacks = callbacks
            return MeetingShieldController(
                settingsStore: settings, provider: provider, reminderStateStore: state, cacheStore: cache,
                notificationService: NoopNotificationService(), soundPlayer: UnexpectedSound(),
                dismissalPresenter: UnexpectedDismissal(), refreshMenuBar: { callbacks.record() }
            )
        }
    }

    private struct UnexpectedSound: AlertSoundPlaying {
        func playAlertSound() { Issue.record("Controller refresh must not play sound") }
    }

    @MainActor
    private final class UnexpectedDismissal: DismissalConfirming {
        func present(
            requestID: UUID, reminder: ScheduledReminder, source: DismissalRequestSource,
            completion: @escaping @MainActor (Bool) -> Void
        ) {
            Issue.record("Controller refresh must not request dismissal UI")
            completion(false)
        }

        func cancel(requestID: UUID) {}
    }
}

extension ControllerRefreshSelectionTests {
    @Test("Completed refresh cycles publish while ordinary refreshes keep trailing")
    func completedCyclesPublishBeforeTrailingRefreshes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = RefreshSelectionStep()
        let second = RefreshSelectionStep()
        let third = RefreshSelectionStep()
        let provider = fixture.provider(eventSteps: [first, second, third])
        fixture.settings.update { $0.selectedCalendarIDs = [fixture.calendarA.id] }
        let controller = fixture.controller(provider: provider)
        defer { controller.stop() }
        let owner = Task { await controller.refresh(reason: "launch") }
        defer { owner.cancel() }
        try #require(await first.entered.wait())
        await controller.refresh(reason: "timer")
        await provider.replaceEvents([fixture.event("cycle-two", calendar: fixture.calendarA)])
        await first.release.open()
        try #require(await second.entered.wait())
        #expect(try fixture.cache.loadUnfiltered()?.events.map(\.eventID) == ["event-a"])
        #expect(controller.events.map(\.eventID) == ["event-a"])
        #expect(controller.scheduledReminders.count == 1)
        await controller.refresh(reason: "timer")
        await provider.replaceEvents([fixture.event("cycle-three", calendar: fixture.calendarA)])
        await second.release.open()
        try #require(await third.entered.wait())
        #expect(try fixture.cache.loadUnfiltered()?.events.map(\.eventID) == ["cycle-two"])
        #expect(controller.events.map(\.eventID) == ["cycle-two"])
        #expect(controller.scheduledReminders.count == 1)
        await third.release.open()
        await owner.value
        #expect(controller.events.map(\.eventID) == ["cycle-three"])
        #expect(controller.scheduledReminders.count == 1)
    }
}
