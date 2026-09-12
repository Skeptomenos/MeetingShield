import AppKit
import Foundation
import Testing
import UserNotifications
@testable import MeetingShield

@Suite("Reminder decision diagnostics")
@MainActor
struct ReminderDiagnosticsTests {
    @Test("Reminder decisions keep only bounded causal fields")
    func boundedDecisionRecord() {
        let safe = DiagnosticsSchema.sanitize("reminder_decision", metadata: [
            "operation": "8a3d40c1-88cc-44b8-a338-7a03316dff7e",
            "occurrence": "id:0123456789ab",
            "account": "id:abcdef012345",
            "reason": "rule_suppressed",
            "target": "2033-05-18T03:33:20.000Z",
            "evaluated": "2033-05-18T03:30:00.000Z",
            "private-title-canary": "Synthetic private meeting"
        ])

        #expect(safe.event == "reminder_decision")
        #expect(safe.metadata == [
            "operation": "8a3d40c1-88cc-44b8-a338-7a03316dff7e",
            "occurrence": "id:0123456789ab",
            "account": "id:abcdef012345",
            "reason": "rule_suppressed",
            "target": "2033-05-18T03:33:20.000Z",
            "evaluated": "2033-05-18T03:30:00.000Z"
        ])
    }

    @Test("Reminder outcomes reject private values and unknown codes")
    func privateOutcomeValuesAreRejected() {
        let safe = DiagnosticsSchema.sanitize("reminder_action", metadata: [
            "operation": "private-operation@example.invalid",
            "occurrence": "https://meet.google.com/private-room",
            "outcome": "private-response-body",
            "evaluated": "private-time"
        ])

        #expect(safe.event == "reminder_action")
        #expect(safe.metadata.isEmpty)
    }

    @Test("Refresh completion retains correlation and elapsed time")
    func refreshCorrelationFieldsRemain() {
        let safe = DiagnosticsSchema.sanitize("refresh_succeeded", metadata: [
            "reason": "timer",
            "calendars": "2",
            "events": "3",
            "operation": "8a3d40c1-88cc-44b8-a338-7a03316dff7e",
            "duration": "12.5",
            "evaluated": "2033-05-18T03:30:12.500Z"
        ])

        #expect(safe.metadata["operation"] == "8a3d40c1-88cc-44b8-a338-7a03316dff7e")
        #expect(safe.metadata["duration"] == "12.5")
        #expect(safe.metadata["evaluated"] == "2033-05-18T03:30:12.500Z")
    }

    @Test("Settings refresh and abandoned refresh outcomes remain explicit")
    func settingsAndAbandonedRefreshCodesRemain() {
        let safe = DiagnosticsSchema.sanitize("refresh_abandoned", metadata: [
            "reason": "settings",
            "outcome": "obsolete",
            "operation": "8a3d40c1-88cc-44b8-a338-7a03316dff7e",
            "duration": "1.25",
            "evaluated": "2033-05-18T03:30:01.250Z"
        ])

        #expect(safe.metadata["reason"] == "settings")
        #expect(safe.metadata["outcome"] == "obsolete")
        #expect(safe.metadata["duration"] == "1.25")
    }

    @Test("The pure pipeline explains eligibility, state, schedule and duplicate decisions")
    func pureDecisionReasons() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var cancelled = event("cancelled", start: 600, now: now)
        cancelled.status = .cancelled
        let ended = event("ended", start: -600, end: -1, now: now)
        let muted = event("muted", start: 600, now: now)
        let acknowledged = event("acknowledged", start: 600, now: now)
        let scheduled = event("scheduled", start: 600, now: now)
        let snoozed = event("snoozed", start: 600, now: now)
        let due = event("due-a", start: 30, now: now)
        var duplicate = due
        duplicate.eventID = "due-b"
        duplicate.calendarID = "synthetic-account::secondary"
        let store = ReminderStateStore()
        store.muteUntilEventEnd(muted.occurrenceKey, now: now)
        store.acknowledge(
            acknowledged.occurrenceKey,
            fingerprint: acknowledged.materialFingerprint(
                detectedLinks: MeetingLinkExtractor().extractLinks(from: acknowledged)
            ),
            eventEnd: acknowledged.endDate,
            now: now
        )
        store.snooze(snoozed.occurrenceKey, until: now.addingTimeInterval(300), now: now)

        let result = ReminderPipeline().compute(
            events: [cancelled, ended, muted, acknowledged, scheduled, snoozed, duplicate, due],
            settings: .defaults,
            stateStore: store,
            now: now
        )
        let reasons = Dictionary(uniqueKeysWithValues: result.decisions.map { ($0.occurrenceID, $0.reason) })
        let dueRepresentative = try #require(result.due.first?.id)
        let duplicateID = dueRepresentative == due.id ? duplicate.id : due.id

        #expect(reasons[cancelled.id] == .cancelled)
        #expect(reasons[ended.id] == .ended)
        #expect(reasons[muted.id] == .muted)
        #expect(reasons[acknowledged.id] == .acknowledged)
        #expect(reasons[scheduled.id] == .scheduled)
        #expect(reasons[snoozed.id] == .snoozed)
        #expect(reasons[dueRepresentative] == .due)
        #expect(reasons[duplicateID] == .groupedDuplicate)
    }

    @Test("One controller operation links refresh, changed decisions, timer delay, presentation and launch")
    func controllerTrace() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let due = fixture.event("due", start: 30)
        let future = fixture.event("future", start: 600)
        await fixture.provider.setEvents([due, future])
        let controller = fixture.controller()
        defer { controller.stop() }

        await controller.refresh(reason: "launch")
        let initial = try fixture.records()
        #expect(initial.allSatisfy { record in
            record.buildID == "test-build"
                && record.sessionID == "f60082cb-e01d-4a6a-90c5-881e8aba36d4"
        })
        let refresh = try #require(initial.last { $0.event == "refresh_succeeded" })
        let operation = try #require(refresh.metadata["operation"])
        let decisions = initial.filter { $0.event == "reminder_decision" }
        #expect(decisions.contains {
            $0.metadata["occurrence"] == LogPrivacy.redactedID(due.id)
                && $0.metadata["reason"] == "due"
                && $0.metadata["operation"] == operation
        })
        #expect(decisions.contains {
            $0.metadata["occurrence"] == LogPrivacy.redactedID(future.id)
                && $0.metadata["reason"] == "scheduled"
                && $0.metadata["operation"] == operation
        })
        #expect(initial.contains {
            $0.event == "reminder_presentation"
                && $0.metadata["outcome"] == "window_constructed"
                && $0.metadata["operation"] == operation
        })
        #expect(controller.nextActionTargetDate == future.startDate.addingTimeInterval(-120))

        let unchangedCount = decisions.count
        await controller.refresh(reason: "timer")
        #expect(try fixture.records().filter { $0.event == "reminder_decision" }.count == unchangedCount)

        fixture.clock.advance(by: 500)
        let timerTask = try #require(controller.fireNextAction())
        await timerTask.value
        let afterTimer = try fixture.records()
        #expect(afterTimer.contains {
            $0.event == "reminder_timer_fired"
                && $0.metadata["target"] == ISO8601DateFormatter.stableString(from: future.startDate.addingTimeInterval(-120))
                && $0.metadata["actual"] == ISO8601DateFormatter.stableString(from: fixture.clock.read())
                && $0.metadata["delay"] == "20.0"
        })
        #expect(afterTimer.contains {
            $0.event == "reminder_decision"
                && $0.metadata["occurrence"] == LogPrivacy.redactedID(future.id)
                && $0.metadata["reason"] == "due"
        })

        let currentDue = try #require(controller.activeReminders.first { $0.id == due.id })
        controller.join(currentDue, now: fixture.clock.read())
        let final = try fixture.records()
        #expect(final.contains {
            $0.event == "reminder_action"
                && $0.metadata["occurrence"] == LogPrivacy.redactedID(due.id)
                && $0.metadata["outcome"] == "launch_accepted"
        })
        #expect(final.contains {
            $0.event == "reminder_decision"
                && $0.metadata["occurrence"] == LogPrivacy.redactedID(due.id)
                && $0.metadata["reason"] == "acknowledged"
        })
        fixture.expectPrivateValuesAbsent([due.title, future.title, due.accountID, due.calendarID, due.location ?? ""])
    }

    @Test("A stalled refresh records duration and a blocked notification records truthful outcomes")
    func stalledRefreshAndNotificationFailure() async throws {
        let fixture = try Fixture(presentationMode: true)
        defer { fixture.cleanup() }
        let due = fixture.event("notification", start: 30)
        await fixture.provider.setEvents([due])
        let notifier = GatedFailingNotifier()
        let controller = fixture.controller(notifier: notifier)
        defer { controller.stop() }

        await controller.refresh(reason: "launch")
        try #require(await notifier.entered.wait())
        let notificationTask = try #require(controller.pendingNotificationTask)
        await notifier.release.open()
        await notificationTask.value

        let delivery = try fixture.records().filter { $0.event == "reminder_notification" }
        #expect(delivery.contains { $0.metadata["outcome"] == "channel_unavailable" })
        #expect(delivery.contains { $0.metadata["outcome"] == "notification_failed" })

        await fixture.provider.holdNextRefresh()
        let refreshTask = Task { await controller.refresh(reason: "timer") }
        try #require(await fixture.provider.entered.wait())
        fixture.clock.advance(by: 12.5)
        await fixture.provider.release.open()
        await refreshTask.value

        let failure = try #require(try fixture.records().last { $0.event == "refresh_failed" })
        #expect(failure.metadata["duration"] == "12.5")
        #expect(failure.metadata["operation"] != nil)
        #expect(failure.metadata["evaluated"] == ISO8601DateFormatter.stableString(from: fixture.clock.read()))
        fixture.expectPrivateValuesAbsent([due.title, due.accountID, due.calendarID, due.location ?? ""])
    }

    @Test("An invalidated refresh closes its diagnostic operation as obsolete")
    func invalidatedRefreshIsNotReportedAsStalled() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let controller = fixture.controller()
        defer { controller.stop() }
        await fixture.provider.holdNextRefresh()

        let refreshTask = Task { await controller.refresh(reason: "settings") }
        try #require(await fixture.provider.entered.wait())
        controller.provider = DiagnosticProvider()
        await fixture.provider.release.open()
        await refreshTask.value

        let records = try fixture.records()
        let started = try #require(records.first {
            $0.event == "refresh_started" && $0.metadata["reason"] == "settings"
        })
        let operation = try #require(started.metadata["operation"])
        #expect(records.contains {
            $0.event == "refresh_abandoned"
                && $0.metadata["operation"] == operation
                && $0.metadata["outcome"] == "obsolete"
        })
        #expect(!records.contains {
            $0.metadata["operation"] == operation
                && ["refresh_succeeded", "refresh_failed"].contains($0.event)
        })
    }

    private func event(_ id: String, start: TimeInterval, end: TimeInterval? = nil, now: Date) -> CalendarEventOccurrence {
        var event = CalendarEventOccurrence.sample(
            eventID: id,
            title: "Synthetic private \(id)",
            startDate: now.addingTimeInterval(start),
            endDate: now.addingTimeInterval(end ?? start + 1800),
            calendarID: "synthetic-account::calendar",
            location: "https://meet.google.com/private-\(id)"
        )
        event.accountID = "synthetic-account@example.invalid"
        event.iCalUID = id == "due-b" ? "due-a@mock" : event.iCalUID
        return event
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let domain = "ReminderDiagnosticsTests.\(UUID().uuidString)"
        let clock = AdvancingTestClock(Date(timeIntervalSince1970: 2_000_000_000))
        let settings: AppSettingsStore
        let provider = DiagnosticProvider()
        let alert = RecordingAlert()
        let browser = RecordingBrowser()
        let diagnostics: DiagnosticsRecorder

        init(presentationMode: Bool = false) throws {
            directory = try TestTempDirectory.make()
            settings = AppSettingsStore(domainName: domain)
            settings.update {
                $0.selectedCalendarIDs = ["synthetic-account::calendar"]
                $0.defaultLeadTime = 120
                $0.visibilityWindow = MenuVisibilityWindow(kind: .nextDays, hours: 4, days: 7)
                $0.presentationModeDefault = presentationMode
                $0.wakeGraceEnabled = false
                $0.soundEnabled = false
                $0.urgentRepeatSoundEnabled = false
            }
            diagnostics = DiagnosticsRecorder(
                directory: directory.appending(path: "diagnostics"),
                nativeSink: { _, _ in },
                buildID: "test-build",
                sessionID: UUID(uuidString: "f60082cb-e01d-4a6a-90c5-881e8aba36d4")!,
                now: { [clock] in clock.read() }
            )
        }

        func event(_ id: String, start: TimeInterval) -> CalendarEventOccurrence {
            var event = CalendarEventOccurrence.sample(
                eventID: id,
                title: "Synthetic private \(id)",
                startDate: clock.read().addingTimeInterval(start),
                calendarID: "synthetic-account::calendar",
                location: "https://meet.google.com/private-\(id)"
            )
            event.accountID = "synthetic-account@example.invalid"
            return event
        }

        func controller(notifier: any MeetingNotifying = NoopNotificationService()) -> MeetingShieldController {
            MeetingShieldController(
                settingsStore: settings,
                provider: provider,
                reminderStateStore: ReminderStateStore(fileURL: directory.appending(path: "state.json")),
                cacheStore: EventCacheStore(fileURL: directory.appending(path: "cache.json")),
                notificationService: notifier,
                launcher: MeetingLauncher(
                    profileService: BrowserProfileService(homeDirectory: directory),
                    browserLauncher: browser
                ),
                soundPlayer: NoSound(),
                dismissalPresenter: NoDismissal(),
                now: { self.clock.read() },
                refreshMenuBar: {},
                systemEventMonitor: SystemEventMonitor(),
                alertPresenter: alert,
                fallbackPresenter: NoFallback(),
                diagnostics: diagnostics
            )
        }

        func records() throws -> [Record] {
            let file = directory.appending(path: "diagnostics/diagnostics.jsonl")
            guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            return try Data(contentsOf: file).split(separator: 0x0A).map {
                try JSONDecoder().decode(Record.self, from: Data($0))
            }
        }

        func expectPrivateValuesAbsent(_ values: [String]) {
            let output = (try? String(contentsOf: directory.appending(path: "diagnostics/diagnostics.jsonl"), encoding: .utf8)) ?? ""
            for value in values where !value.isEmpty {
                #expect(!output.contains(value))
            }
        }

        func cleanup() {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private struct Record: Decodable {
        var buildID: String
        var sessionID: String
        var event: String
        var metadata: [String: String]
    }

    private actor DiagnosticProvider: CalendarProvider {
        enum Mode { case success, heldFailure }

        nonisolated let providerID = "synthetic-diagnostics"
        let entered = DiagnosticGate()
        let release = DiagnosticGate()
        private var currentEvents: [CalendarEventOccurrence] = []
        private var mode = Mode.success

        var authState: CalendarProviderAuthState { get async { .connected(accountEmail: "Synthetic account") } }
        func accounts() async -> [ConnectedCalendarAccount] {
            [ConnectedCalendarAccount(id: "synthetic-account@example.invalid", displayName: "Synthetic account")]
        }
        func calendars() async throws -> [UserCalendar] {
            [UserCalendar(
                id: "synthetic-account::calendar",
                accountID: "synthetic-account@example.invalid",
                displayName: "Synthetic calendar",
                isPrimary: true,
                isSelected: true
            )]
        }
        func events(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] { currentEvents }
        func refresh(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] { currentEvents }
        func refresh(in window: CalendarFetchWindow, calendars: [UserCalendar]) async throws -> [CalendarEventOccurrence] {
            switch mode {
            case .success:
                return currentEvents
            case .heldFailure:
                await entered.open()
                _ = await release.wait()
                throw CalendarProviderError.requestFailed(503)
            }
        }
        func reconnect() async throws {}
        func removeAccount(id: String) async throws {}
        func setEvents(_ events: [CalendarEventOccurrence]) { currentEvents = events }
        func holdNextRefresh() { mode = .heldFailure }
    }

    private actor GatedFailingNotifier: MeetingNotifying {
        let entered = DiagnosticGate()
        let release = DiagnosticGate()

        func authorizationStatus() async -> UNAuthorizationStatus { .denied }
        func notificationSettings() async -> NotificationSettingsSnapshot {
            NotificationSettingsSnapshot(authorizationStatus: .denied)
        }
        func requestAuthorization() async throws -> Bool { false }
        func deliver(_ notification: MeetingNotification) async throws {
            await entered.open()
            _ = await release.wait()
            throw URLError(.cannotConnectToHost)
        }
    }

    private actor DiagnosticGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Bool, Never>] = []

        func wait() async -> Bool {
            if isOpen { return true }
            return await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let current = waiters
            waiters.removeAll()
            current.forEach { $0.resume(returning: true) }
        }
    }

    @MainActor
    private final class RecordingAlert: FullScreenAlertPresenting {
        private(set) var isShowing = false
        func show(
            reminders: [ScheduledReminder], selectedID: String?,
            availableSnoozeChoices: @escaping (ScheduledReminder, Date) -> [SnoozeChoice],
            onJoin: @escaping (ScheduledReminder) -> Void,
            onSnooze: @escaping (ScheduledReminder, SnoozeChoice?) -> Void,
            onDismiss: @escaping (ScheduledReminder) -> Void,
            onRequestDismissal: @escaping (ScheduledReminder) -> Void,
            onMute: @escaping (ScheduledReminder) -> Void,
            onSnoozeAll: @escaping () -> Void
        ) { isShowing = !reminders.isEmpty }
        func update(reminders: [ScheduledReminder]) { isShowing = !reminders.isEmpty }
        func hide() { isShowing = false }
    }

    private final class RecordingBrowser: BrowserLaunching, @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func open(_ url: URL, target: BrowserLaunchTarget) throws { lock.withLock { urls.append(url) } }
    }

    private struct NoSound: AlertSoundPlaying { func playAlertSound() {} }

    @MainActor
    private final class NoDismissal: DismissalConfirming {
        func present(
            requestID: UUID, reminder: ScheduledReminder, source: DismissalRequestSource,
            completion: @escaping @MainActor (Bool) -> Void
        ) { completion(false) }
        func cancel(requestID: UUID) {}
    }

    @MainActor
    private final class NoFallback: JoinFallbackPresenting {
        func show(
            fallback: JoinFallbackState, aboveAlerts: Bool,
            onOpenAgain: @escaping () -> Void,
            onDismiss: @escaping () -> Void,
            onClose: @escaping () -> Void
        ) {}
        func updateLevel(aboveAlerts: Bool) {}
        func hide() {}
    }
}
