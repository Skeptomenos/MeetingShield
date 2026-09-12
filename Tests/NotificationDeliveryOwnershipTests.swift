import Combine
import Foundation
import Testing
import UserNotifications
@testable import MeetingShield

@Suite("Notification delivery ownership", .timeLimit(.minutes(1)))
@MainActor
struct NotificationDeliveryOwnershipTests {
    @Test("An invalidated permission await cannot submit its batch or publish stale health", arguments: Invalidation.allCases)
    func invalidatedAuthorization(reason: Invalidation) async throws {
        let gate = Gate()
        let notifier = GatedNotifier()
        notifier.authorizationGates[1] = gate
        notifier.authorizationResults[1] = .denied
        try await withFixture(notifier: notifier, wakeOnly: reason == .wakeExpired) { fixture in
            let owner = try await fixture.beginAttempt(waitingAt: gate)

            await fixture.invalidate(reason)
            if reason.hasExplicitInvalidation { #expect(owner.isCancelled) }
            let publications = fixture.health.events
            gate.release()
            await owner.value

            #expect(notifier.authorizationReturnCount == 1)
            #expect(notifier.delivered.isEmpty)
            #expect(fixture.replacementNotifiers.allSatisfy { $0.delivered.isEmpty })
            #expect(fixture.health.events == publications)
            fixture.expectHealthyNotificationState()
            #expect(fixture.controller.pendingNotificationTask == nil)
        }
    }

    @Test("Invalidation during the first submission stops the rest of its batch and stale health", arguments: Invalidation.allCases)
    func invalidatedFirstSubmission(reason: Invalidation) async throws {
        let gate = Gate()
        let notifier = GatedNotifier()
        notifier.deliveryGates[1] = gate
        notifier.failedDeliveries = [1]
        try await withFixture(notifier: notifier, wakeOnly: reason == .wakeExpired) { fixture in
            let owner = try await fixture.beginAttempt(waitingAt: gate)
            #expect(notifier.delivered.map(\.id) == [fixture.events[0].id])

            await fixture.invalidate(reason)
            if reason.hasExplicitInvalidation { #expect(owner.isCancelled) }
            let publications = fixture.health.events
            gate.release()
            await owner.value

            #expect(notifier.deliveryReturnCount == 1)
            #expect(notifier.delivered.map(\.id) == [fixture.events[0].id])
            #expect(fixture.replacementNotifiers.allSatisfy { $0.delivered.isEmpty })
            #expect(fixture.health.events == publications)
            fixture.expectHealthyNotificationState()
            #expect(fixture.controller.pendingNotificationTask == nil)
        }
    }

    @Test("A current attempt completes and releases its retained task", arguments: CurrentAttempt.allCases)
    func currentAttemptCompletes(control: CurrentAttempt) async throws {
        let gate = Gate()
        let notifier = GatedNotifier()
        notifier.authorizationGates[1] = gate
        try await withFixture(
            notifier: notifier, wakeOnly: control == .activeWakeGrace,
            wakeEnabled: control != .unchanged
        ) { fixture in
            let owner = try await fixture.beginAttempt(waitingAt: gate)
            switch control {
            case .unchanged:
                break
            case .activeWakeGrace:
                fixture.clock.now = fixture.clock.now.addingTimeInterval(59)
                #expect(fixture.monitor.isInWakeGrace(now: fixture.clock.now))
                #expect(!fixture.controller.isPresentationMode)
            case .manualPresentationAfterGrace:
                fixture.clock.now = fixture.clock.now.addingTimeInterval(61)
                #expect(!fixture.monitor.isInWakeGrace(now: fixture.clock.now))
                #expect(fixture.controller.isPresentationMode)
            }

            gate.release()
            await owner.value

            #expect(!owner.isCancelled)
            #expect(notifier.delivered.map(\.id) == fixture.events.map(\.id))
            #expect(notifier.deliveryReturnCount == 2)
            #expect(fixture.controller.pendingNotificationTask == nil)
            #expect(fixture.alert.showCount == 0)
            fixture.expectHealthyNotificationState()
        }
    }

    @Test("An older completion cannot clear the newer held task or replace its current authorization health")
    func newerPendingTaskSurvivesOldCompletion() async throws {
        let oldAuthorization = Gate()
        let newDelivery = Gate()
        let notifier = GatedNotifier()
        notifier.authorizationGates[1] = oldAuthorization
        notifier.authorizationResults[1] = .denied
        notifier.deliveryGates[1] = newDelivery
        try await withFixture(notifier: notifier) { fixture in
            let oldOwner = try await fixture.beginAttempt(waitingAt: oldAuthorization)
            let currentEvents = fixture.replaceEventContent()
            let newOwner = try await fixture.beginAttempt(waitingAt: newDelivery)
            #expect(oldOwner.isCancelled)
            #expect(!newOwner.isCancelled)
            #expect(notifier.delivered.map(\.title) == [currentEvents[0].title])
            let publications = fixture.health.events

            oldAuthorization.release()
            await oldOwner.value

            #expect(fixture.controller.pendingNotificationTask != nil)
            #expect(fixture.controller.pendingNotificationTask?.isCancelled == false)
            #expect(notifier.delivered.map(\.title) == [currentEvents[0].title])
            #expect(fixture.health.events == publications)
            fixture.expectHealthyNotificationState()
            newDelivery.release()
            await newOwner.value

            #expect(notifier.delivered.map(\.title) == currentEvents.map(\.title))
            #expect(notifier.deliveryReturnCount == 2)
            #expect(fixture.controller.pendingNotificationTask == nil)
            fixture.expectHealthyNotificationState()
        }
    }

    @Test("An older submitted result cannot overwrite newer delivery health", arguments: [false, true])
    func newerDeliveryHealthSurvivesOldCompletion(newerFails: Bool) async throws {
        let oldDelivery = Gate()
        let newAuthorization = Gate()
        let notifier = GatedNotifier()
        notifier.deliveryGates[1] = oldDelivery
        notifier.authorizationGates[2] = newAuthorization
        notifier.failedDeliveries = newerFails ? [2, 3] : [1]
        try await withFixture(notifier: notifier) { fixture in
            let oldOwner = try await fixture.beginAttempt(waitingAt: oldDelivery)
            let currentEvents = fixture.replaceEventContent()
            let newOwner = try await fixture.beginAttempt(waitingAt: newAuthorization)
            #expect(oldOwner.isCancelled)
            newAuthorization.release()
            await newOwner.value
            #expect(fixture.controller.notificationHealth.lastDeliveryFailed == newerFails)
            #expect((fixture.controller.notificationWarning != nil) == newerFails)
            #expect(fixture.controller.pendingNotificationTask == nil)
            let publications = fixture.health.events
            let expectedTitles = [fixture.events[0].title] + currentEvents.map(\.title)
            #expect(notifier.delivered.map(\.title) == expectedTitles)

            oldDelivery.release()
            await oldOwner.value

            #expect(notifier.delivered.map(\.title) == expectedTitles)
            #expect(notifier.deliveryReturnCount == 3)
            #expect(fixture.health.events == publications)
            #expect(!fixture.controller.notificationHealth.authorizationDenied)
            #expect(fixture.controller.notificationHealth.lastDeliveryFailed == newerFails)
            #expect((fixture.controller.notificationWarning != nil) == newerFails)
            #expect(fixture.controller.pendingNotificationTask == nil)
        }
    }

    @Test("Queued startup authorization cannot begin after Stop or backend replacement", arguments: StartupInvalidation.allCases)
    func queuedStartupAuthorizationIsInvalidated(reason: StartupInvalidation) async throws {
        let notifier = GatedNotifier()
        try await withFixture(notifier: notifier) { fixture in
            let owner = fixture.beginStartupAttempt()
            fixture.invalidateStartup(reason)
            #expect(owner.isCancelled)
            #expect(fixture.controller.pendingNotificationAuthorizationTask == nil)
            let publications = fixture.health.events

            await owner.value

            #expect(notifier.authorizationRequestCount == 0)
            #expect(notifier.authorizationReadCount == 0)
            #expect(fixture.replacementNotifiers.allSatisfy { $0.authorizationRequestCount == 0 })
            #expect(fixture.replacementNotifiers.allSatisfy { $0.authorizationReadCount == 0 })
            #expect(fixture.health.events == publications)
            #expect(fixture.controller.pendingNotificationAuthorizationTask == nil)
            fixture.expectHealthyNotificationState()
            fixture.expectNoStartupPresentation()
        }
    }

    @Test(
        "An invalidated startup request or status await cannot publish or continue on a replacement backend",
        arguments: StartupInvalidation.allCases, StartupBoundary.allCases
    )
    func heldStartupAuthorizationIsInvalidated(reason: StartupInvalidation, boundary: StartupBoundary) async throws {
        let gate = Gate()
        let notifier = GatedNotifier()
        notifier.authorizationResults[1] = .denied
        if boundary == .status {
            notifier.authorizationGates[1] = gate
        } else {
            notifier.requestGates[1] = gate
            if boundary == .failedRequest { notifier.failedRequests = [1] }
        }
        try await withFixture(notifier: notifier) { fixture in
            fixture.expectedAuthorizationRequests = 1
            let owner = try await fixture.beginStartupAttempt(waitingAt: gate)
            fixture.invalidateStartup(reason)
            #expect(owner.isCancelled)
            #expect(fixture.controller.pendingNotificationAuthorizationTask == nil)
            let publications = fixture.health.events

            gate.release()
            await owner.value

            #expect(notifier.authorizationRequestCount == 1)
            #expect(notifier.authorizationRequestReturnCount == 1)
            #expect(notifier.authorizationReadCount == (boundary == .status ? 1 : 0))
            #expect(notifier.authorizationReturnCount == (boundary == .status ? 1 : 0))
            #expect(fixture.replacementNotifiers.allSatisfy { $0.authorizationRequestCount == 0 })
            #expect(fixture.replacementNotifiers.allSatisfy { $0.authorizationReadCount == 0 })
            #expect(fixture.health.events == publications)
            #expect(fixture.controller.pendingNotificationAuthorizationTask == nil)
            fixture.expectHealthyNotificationState()
            fixture.expectNoStartupPresentation()
        }
    }

    @Test("Current startup uses authoritative status after a grant, denial, or request error", arguments: StartupOutcome.allCases)
    func currentStartupAuthorizationCompletes(outcome: StartupOutcome) async throws {
        let gate = Gate()
        let notifier = GatedNotifier()
        notifier.requestResults[1] = true
        notifier.authorizationGates[1] = gate
        notifier.authorizationResults[1] = outcome == .deniedAfterGrant ? .denied : .authorized
        if outcome == .requestError { notifier.failedRequests = [1] }
        try await withFixture(notifier: notifier) { fixture in
            fixture.expectedAuthorizationRequests = 1
            let owner = try await fixture.beginStartupAttempt(waitingAt: gate)
            fixture.expectHealthyNotificationState()

            gate.release()
            await owner.value

            #expect(!owner.isCancelled)
            #expect(notifier.authorizationRequestCount == 1)
            #expect(notifier.authorizationRequestReturnCount == 1)
            #expect(notifier.authorizationReadCount == 1)
            #expect(notifier.authorizationReturnCount == 1)
            #expect(fixture.controller.notificationHealth.authorizationDenied == (outcome == .deniedAfterGrant))
            #expect(!fixture.controller.notificationHealth.lastDeliveryFailed)
            #expect((fixture.controller.notificationWarning != nil) == (outcome == .deniedAfterGrant))
            #expect(fixture.controller.pendingNotificationAuthorizationTask == nil)
            fixture.expectNoStartupPresentation()
        }
    }

    @Test("Repeated startup authorization calls share one pending request")
    func duplicateStartupAuthorizationCoalesces() async throws {
        let gate = Gate()
        let notifier = GatedNotifier()
        notifier.requestGates[1] = gate
        notifier.requestResults[1] = true
        try await withFixture(notifier: notifier) { fixture in
            fixture.expectedAuthorizationRequests = 1
            let firstOwner = try await fixture.beginStartupAttempt(waitingAt: gate)
            let repeatedOwner = fixture.beginStartupAttempt()
            #expect(!firstOwner.isCancelled)
            #expect(!repeatedOwner.isCancelled)

            gate.release()
            await firstOwner.value
            await repeatedOwner.value

            #expect(!firstOwner.isCancelled)
            #expect(!repeatedOwner.isCancelled)
            #expect(notifier.authorizationRequestCount == 1)
            #expect(notifier.authorizationRequestReturnCount == 1)
            #expect(notifier.authorizationReadCount == 1)
            #expect(notifier.authorizationReturnCount == 1)
            #expect(fixture.controller.pendingNotificationAuthorizationTask == nil)
            fixture.expectHealthyNotificationState()
            fixture.expectNoStartupPresentation()
        }
    }

    @Test("An older startup completion preserves the newer backend task and health", arguments: [false, true])
    func newerStartupAuthorizationSurvivesOldCompletion(newerCompletesFirst: Bool) async throws {
        let oldStatus = Gate()
        let newRequest = Gate()
        let notifier = GatedNotifier()
        notifier.authorizationGates[1] = oldStatus
        notifier.authorizationResults[1] = .denied
        let replacement = GatedNotifier()
        replacement.requestGates[1] = newRequest
        replacement.requestResults[1] = true
        try await withFixture(notifier: notifier) { fixture in
            fixture.expectedAuthorizationRequests = 2
            let oldOwner = try await fixture.beginStartupAttempt(waitingAt: oldStatus)
            fixture.replaceNotifier(replacement)
            let newOwner = try await fixture.beginStartupAttempt(waitingAt: newRequest)
            #expect(oldOwner.isCancelled)
            #expect(!newOwner.isCancelled)
            if newerCompletesFirst {
                newRequest.release()
                await newOwner.value
                #expect(fixture.controller.pendingNotificationAuthorizationTask == nil)
                fixture.expectHealthyNotificationState()
            }
            let publications = fixture.health.events

            oldStatus.release()
            await oldOwner.value

            #expect(fixture.health.events == publications)
            fixture.expectHealthyNotificationState()
            if !newerCompletesFirst {
                #expect(fixture.controller.pendingNotificationAuthorizationTask != nil)
                #expect(fixture.controller.pendingNotificationAuthorizationTask?.isCancelled == false)
                #expect(!newOwner.isCancelled)
                #expect(replacement.authorizationReadCount == 0)
                newRequest.release()
                await newOwner.value
            }

            #expect(notifier.authorizationRequestCount == 1)
            #expect(notifier.authorizationReadCount == 1)
            #expect(notifier.authorizationReturnCount == 1)
            #expect(replacement.authorizationRequestCount == 1)
            #expect(replacement.authorizationReadCount == 1)
            #expect(replacement.authorizationReturnCount == 1)
            #expect(fixture.controller.pendingNotificationAuthorizationTask == nil)
            fixture.expectHealthyNotificationState()
            fixture.expectNoStartupPresentation()
        }
    }

    @Test("An ordinary refresh leaves a held startup authorization active")
    func ordinaryRefreshPreservesStartupAuthorization() async throws {
        let request = Gate()
        let deliveryAuthorization = Gate()
        let notifier = GatedNotifier()
        notifier.requestGates[1] = request
        notifier.requestResults[1] = true
        notifier.authorizationGates[1] = deliveryAuthorization
        try await withFixture(notifier: notifier) { fixture in
            fixture.expectedAuthorizationRequests = 1
            let startupOwner = try await fixture.beginStartupAttempt(waitingAt: request)
            let deliveryOwner = try await fixture.beginAttempt(waitingAt: deliveryAuthorization)
            #expect(!startupOwner.isCancelled)
            #expect(fixture.controller.pendingNotificationAuthorizationTask?.isCancelled == false)

            deliveryAuthorization.release()
            await deliveryOwner.value

            #expect(notifier.delivered.map(\.id) == fixture.events.map(\.id))
            #expect(notifier.deliveryReturnCount == 2)
            #expect(notifier.authorizationRequestReturnCount == 0)
            #expect(!startupOwner.isCancelled)
            #expect(fixture.controller.pendingNotificationAuthorizationTask?.isCancelled == false)
            #expect(fixture.controller.pendingNotificationTask == nil)
            request.release()
            await startupOwner.value

            #expect(!startupOwner.isCancelled)
            #expect(notifier.authorizationRequestCount == 1)
            #expect(notifier.authorizationRequestReturnCount == 1)
            #expect(notifier.authorizationReadCount == 2)
            #expect(notifier.authorizationReturnCount == 2)
            #expect(fixture.controller.pendingNotificationAuthorizationTask == nil)
            #expect(fixture.alert.showCount == 0)
            fixture.expectHealthyNotificationState()
        }
    }

    @Test("Wake immediately schedules grace expiry and sends cached due reminders while refresh is held")
    func heldWakeRefreshUsesCachedReminders() async throws {
        let notifier = GatedNotifier()
        try await withFixture(notifier: notifier, wakeOnly: true, fixedNow: Self.wakeReferenceDate) { fixture in
            try await fixture.seedDueReminders()
            fixture.clock.now = fixture.clock.now.addingTimeInterval(15)
            let refresh = fixture.provider.holdNextRefresh()
            let wakeOwner = fixture.beginWake()
            let quietOwner = fixture.retainCurrentNotificationTask()
            try await fixture.waitForProviderEntry(refresh, owner: wakeOwner)

            #expect(fixture.controller.nextActionTargetDate == fixture.clock.now.addingTimeInterval(60))
            #expect(fixture.provider.refreshInvocationCount == 2)
            #expect(fixture.provider.refreshCompletionCount == 1)
            #expect(fixture.controller.activeReminders.map(\.id) == fixture.events.map(\.id))
            #expect(fixture.alert.showCount == 0)
            let currentDelivery = try #require(quietOwner, "Wake must queue cached due notifications before the provider returns")
            await currentDelivery.value
            #expect(notifier.delivered.map(\.id) == fixture.events.map(\.id) + fixture.events.map(\.id))
            #expect(fixture.provider.refreshCompletionCount == 1)

            refresh.release()
            await wakeOwner.value
            await fixture.drainCurrentNotificationTask()
            #expect(fixture.provider.refreshCompletionCount == 2)
            #expect(fixture.alert.showCount == 0)
        }
    }

    @Test("The scheduled grace boundary uses cached data while refresh is held", arguments: [false, true])
    func wakeExpiryWhileRefreshIsHeld(manualPresentation: Bool) async throws {
        let notifier = GatedNotifier()
        notifier.defaultAuthorizationStatus = .denied
        try await withFixture(
            notifier: notifier, wakeOnly: !manualPresentation, wakeEnabled: true,
            fixedNow: Self.wakeReferenceDate
        ) { fixture in
            try await fixture.seedDueReminders()
            let refresh = fixture.provider.holdNextRefresh()
            let wakeOwner = fixture.beginWake()
            let quietOwner = fixture.retainCurrentNotificationTask()
            try await fixture.waitForProviderEntry(refresh, owner: wakeOwner)
            if let quietOwner { await quietOwner.value }
            let expiry = fixture.clock.now.addingTimeInterval(60)
            if !manualPresentation { #expect(fixture.controller.nextActionTargetDate == expiry) }
            #expect(fixture.controller.notificationWarning != nil)
            #expect(fixture.alert.showCount == 0)
            let readsBeforeExpiry = fixture.provider.readCount

            fixture.clock.now = expiry
            #expect(!fixture.monitor.isInWakeGrace(now: fixture.clock.now))
            let timerOwner = try #require(fixture.fireNextAction(), "Cached due reminders must retain an actual next-action timer")
            await timerOwner.value
            await fixture.drainCurrentNotificationTask()

            #expect(fixture.provider.readCount == readsBeforeExpiry)
            #expect(fixture.provider.refreshCompletionCount == 1)
            #expect(fixture.controller.activeReminders.map(\.id) == fixture.events.map(\.id))
            #expect(fixture.controller.isPresentationMode == manualPresentation)
            #expect(fixture.controller.notificationHealth.authorizationDenied)
            #expect((fixture.controller.notificationWarning != nil) == manualPresentation)
            #expect(fixture.alert.isShowing == !manualPresentation)
            #expect(fixture.alert.showCount == (manualPresentation ? 0 : 1))
            if !manualPresentation { #expect(fixture.alert.reminders.map(\.id) == fixture.events.map(\.id)) }
            #expect(fixture.controller.nextActionTargetDate == fixture.events[0].endDate)
            #expect(fixture.controller.pendingNextActionTask == nil)

            refresh.release()
            await wakeOwner.value
            await fixture.drainCurrentNotificationTask()
            #expect(fixture.provider.refreshCompletionCount == 2)
            #expect(fixture.alert.showCount == (manualPresentation ? 0 : 1))
        }
    }

    @Test("A later wake replaces the prior grace deadline")
    func repeatedWakeExtendsDeadline() async throws {
        let notifier = GatedNotifier()
        try await withFixture(notifier: notifier, wakeOnly: true, fixedNow: Self.wakeReferenceDate) { fixture in
            try await fixture.seedDueReminders()
            fixture.clock.now = Self.wakeReferenceDate.addingTimeInterval(10)
            let firstRefresh = fixture.provider.holdNextRefresh()
            let firstWake = fixture.beginWake()
            let firstDelivery = fixture.retainCurrentNotificationTask()
            try await fixture.waitForProviderEntry(firstRefresh, owner: firstWake)
            if let firstDelivery { await firstDelivery.value }
            let firstDeadline = Self.wakeReferenceDate.addingTimeInterval(70)
            #expect(fixture.controller.nextActionTargetDate == firstDeadline)
            firstRefresh.release()
            await firstWake.value
            await fixture.drainCurrentNotificationTask()

            fixture.clock.now = Self.wakeReferenceDate.addingTimeInterval(40)
            let secondRefresh = fixture.provider.holdNextRefresh()
            let secondWake = fixture.beginWake()
            let secondDelivery = fixture.retainCurrentNotificationTask()
            try await fixture.waitForProviderEntry(secondRefresh, owner: secondWake)
            if let secondDelivery { await secondDelivery.value }

            #expect(fixture.controller.nextActionTargetDate == Self.wakeReferenceDate.addingTimeInterval(100))
            #expect(fixture.controller.nextActionTargetDate != firstDeadline)
            #expect(fixture.provider.refreshInvocationCount == 3)
            #expect(fixture.provider.refreshCompletionCount == 2)
            #expect(fixture.alert.showCount == 0)
            secondRefresh.release()
            await secondWake.value
            await fixture.drainCurrentNotificationTask()
        }
    }

    @Test("Disabled wake grace preserves the normal reminder target")
    func disabledWakeGraceUsesReminderTarget() async throws {
        let notifier = GatedNotifier()
        try await withFixture(notifier: notifier, fixedNow: Self.wakeReferenceDate) { fixture in
            fixture.controller.isPresentationMode = false
            await fixture.controller.refresh(reason: "timer")
            #expect(fixture.alert.showCount == 1)
            #expect(fixture.controller.nextActionTargetDate == fixture.events[0].endDate)
            let refresh = fixture.provider.holdNextRefresh()
            let wakeOwner = fixture.beginWake()
            try await fixture.waitForProviderEntry(refresh, owner: wakeOwner)

            #expect(fixture.monitor.isInWakeGrace(now: fixture.clock.now))
            #expect(!fixture.settings.snapshot.wakeGraceEnabled)
            #expect(fixture.controller.nextActionTargetDate == fixture.events[0].endDate)
            #expect(fixture.controller.pendingNotificationTask == nil)
            #expect(notifier.delivered.isEmpty)
            #expect(fixture.alert.showCount == 1)
            refresh.release()
            await wakeOwner.value
            await fixture.drainCurrentNotificationTask()
            #expect(notifier.delivered.isEmpty)
            #expect(fixture.alert.showCount == 1)
        }
    }

    @Test("Stop invalidates a queued next-action callback before it can present")
    func queuedTimerCannotReviveAfterStop() async throws {
        let notifier = GatedNotifier()
        try await withFixture(notifier: notifier, wakeOnly: true, fixedNow: Self.wakeReferenceDate) { fixture in
            try await fixture.seedDueReminders()
            fixture.clock.now = fixture.clock.now.addingTimeInterval(60)
            let deliveryCount = notifier.delivered.count
            let reads = fixture.provider.readCount
            let owner = try #require(fixture.fireNextAction())

            fixture.controller.stop()
            #expect(owner.isCancelled)
            #expect(fixture.controller.nextActionTargetDate == nil)
            #expect(fixture.controller.pendingNextActionTask == nil)
            await owner.value
            await fixture.drainCurrentNotificationTask()

            #expect(fixture.controller.nextActionTargetDate == nil)
            #expect(fixture.controller.pendingNextActionTask == nil)
            #expect(fixture.alert.showCount == 0)
            #expect(notifier.delivered.count == deliveryCount)
            #expect(fixture.provider.readCount == reads)
            #expect(fixture.fireNextAction() == nil)
        }
    }

    @Test("Stop clears a timer installed by recomputation before controller start")
    func stopBeforeStartClearsScheduledTimer() async throws {
        let notifier = GatedNotifier()
        try await withFixture(notifier: notifier, wakeOnly: true, fixedNow: Self.wakeReferenceDate) { fixture in
            try await fixture.seedDueReminders()
            #expect(fixture.controller.nextActionTargetDate != nil)
            let reads = fixture.provider.readCount
            let deliveryCount = notifier.delivered.count

            fixture.controller.stop()
            #expect(fixture.controller.nextActionTargetDate == nil)
            let unexpectedCallback = fixture.fireNextAction()
            #expect(unexpectedCallback == nil)
            if let unexpectedCallback { await unexpectedCallback.value }
            await fixture.drainCurrentNotificationTask()

            #expect(fixture.controller.nextActionTargetDate == nil)
            #expect(fixture.controller.pendingNextActionTask == nil)
            #expect(fixture.alert.showCount == 0)
            #expect(notifier.delivered.count == deliveryCount)
            #expect(fixture.provider.readCount == reads)
        }
    }

    @Test("A queued wake callback cannot begin a new refresh after Stop")
    func queuedWakeCannotRefreshAfterStop() async throws {
        let notifier = GatedNotifier()
        try await withFixture(notifier: notifier, wakeOnly: true, fixedNow: Self.wakeReferenceDate) { fixture in
            let owner = fixture.beginWake()
            fixture.controller.stop()

            await owner.value
            await fixture.drainCurrentNotificationTask()

            #expect(fixture.provider.readCount == 0)
            #expect(fixture.provider.refreshInvocationCount == 0)
            #expect(fixture.provider.refreshCompletionCount == 0)
            #expect(fixture.controller.activeReminders.isEmpty)
            #expect(fixture.controller.nextActionTargetDate == nil)
            #expect(fixture.controller.pendingNextActionTask == nil)
            fixture.expectNoStartupPresentation()
        }
    }

    private static let wakeReferenceDate = Date(timeIntervalSince1970: 2_000_000_000)

    enum StartupInvalidation: CaseIterable, Sendable {
        case stop, backendReplacement
    }

    enum StartupBoundary: CaseIterable, Sendable {
        case request, failedRequest, status
    }

    enum StartupOutcome: CaseIterable, Sendable {
        case granted, deniedAfterGrant, requestError
    }

    enum Invalidation: CaseIterable, Sendable {
        case stop, backendReplacement, providerReplacement, calendarDeselected
        case calendarAlertsDisabled, presentationOff, wakeExpired, sourcesEnded

        var hasExplicitInvalidation: Bool {
            self != .wakeExpired && self != .sourcesEnded
        }
    }

    enum CurrentAttempt: CaseIterable, Sendable {
        case unchanged, activeWakeGrace, manualPresentationAfterGrace
    }

    private func withFixture(
        notifier: GatedNotifier, wakeOnly: Bool = false, wakeEnabled: Bool = false,
        fixedNow: Date? = nil,
        _ body: @MainActor (Fixture) async throws -> Void
    ) async throws {
        let fixture = try Fixture(notifier: notifier, wakeOnly: wakeOnly, wakeEnabled: wakeEnabled, fixedNow: fixedNow)
        do {
            try await body(fixture)
        } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let domain = "NotificationDeliveryOwnershipTests.\(UUID().uuidString)"
        let clock: Clock
        let monitor: SystemEventMonitor
        let notifier: GatedNotifier
        let provider: FixtureProvider
        let settings: AppSettingsStore
        let state: ReminderStateStore
        let controller: MeetingShieldController
        let health: HealthTrace
        let alert: RecordingAlert
        let browser: RecordingBrowser
        let routes: Routes
        let events: [CalendarEventOccurrence]
        var expectedAuthorizationRequests = 0
        private(set) var replacementNotifiers: [GatedNotifier] = []
        private var ownedTasks: [Task<Void, Never>] = []
        private var completionObservers: [Task<Void, Never>] = []

        init(notifier: GatedNotifier, wakeOnly: Bool, wakeEnabled: Bool, fixedNow: Date?) throws {
            directory = try TestTempDirectory.make()
            let clock = Clock(now: fixedNow ?? Date())
            self.clock = clock
            let monitor = SystemEventMonitor()
            self.monitor = monitor
            if wakeOnly || wakeEnabled { monitor.enterWakeGrace(now: clock.now) }
            self.notifier = notifier
            let calendarID = "synthetic-notification-calendar"
            events = [300.0, 360.0].enumerated().map { index, offset in
                var event = CalendarEventOccurrence.sample(
                    eventID: "synthetic-notification-\(index)", title: "Synthetic original \(index)",
                    startDate: clock.now.addingTimeInterval(offset),
                    endDate: clock.now.addingTimeInterval(900), calendarID: calendarID,
                    location: "https://meet.google.com/synthetic-\(index)"
                )
                event.updatedAt = clock.now
                return event
            }
            let provider = FixtureProvider(events: events, calendarID: calendarID)
            self.provider = provider
            let settings = AppSettingsStore(domainName: domain)
            self.settings = settings
            settings.update {
                $0.selectedCalendarIDs = [calendarID]
                $0.defaultLeadTime = 600
                $0.defaultBrowserSelection = .systemDefault
                $0.presentationModeDefault = !wakeOnly
                $0.wakeGraceEnabled = wakeOnly || wakeEnabled
                $0.soundEnabled = false
                $0.urgentRepeatSoundEnabled = false
            }
            let state = ReminderStateStore(
                fileURL: directory.appending(path: "state.json"),
                diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "diagnostics"), nativeSink: { _, _ in })
            )
            self.state = state
            let alert = RecordingAlert()
            self.alert = alert
            let browser = RecordingBrowser()
            self.browser = browser
            let routes = Routes()
            self.routes = routes
            let controller = MeetingShieldController(
                settingsStore: settings, provider: provider,
                credentialsResolver: GoogleOAuthCredentialsResolver(bundleInfoValue: { _ in nil }, environment: [:]),
                makeGoogleProvider: { _ in
                    routes.authorizationProviders += 1
                    return provider
                },
                reminderStateStore: state,
                cacheStore: EventCacheStore(fileURL: directory.appending(path: "cache.json")),
                notificationService: notifier,
                launcher: MeetingLauncher(
                    profileService: BrowserProfileService(homeDirectory: directory), browserLauncher: browser
                ),
                soundPlayer: NoSound(), dismissalPresenter: NoDismissal(), now: { clock.now },
                refreshMenuBar: {}, systemEventMonitor: monitor,
                alertPresenter: alert, fallbackPresenter: NoFallback(),
                openAgenda: { routes.agenda += 1 }, presentSettings: { routes.settings += 1 }
            )
            self.controller = controller
            health = HealthTrace(controller: controller)
        }

        func beginAttempt(waitingAt gate: Gate) async throws -> Task<Void, Never> {
            await controller.refresh(reason: "timer")
            let owner = try #require(controller.pendingNotificationTask)
            ownedTasks.append(owner)
            completionObservers.append(Task { @MainActor in
                await owner.value
                gate.ownerDidFinish()
            })
            let reachedBoundary = await gate.waitForEntry()
            try #require(reachedBoundary, "Notification task finished before reaching its expected held boundary")
            #expect(controller.activeReminders.count == 2)
            return owner
        }

        func seedDueReminders() async throws {
            let gate = Gate()
            notifier.authorizationGates[notifier.authorizationReadCount + 1] = gate
            let owner = try await beginAttempt(waitingAt: gate)
            gate.release()
            await owner.value
        }

        func beginWake() -> Task<Void, Never> {
            monitor.enterWakeGrace(now: clock.now)
            let owner = controller.handleWakeOrUnlock()
            ownedTasks.append(owner)
            return owner
        }

        func waitForProviderEntry(_ gate: Gate, owner: Task<Void, Never>) async throws {
            completionObservers.append(Task { @MainActor in
                await owner.value
                gate.ownerDidFinish()
            })
            let reachedBoundary = await gate.waitForEntry()
            try #require(reachedBoundary, "Wake refresh finished before reaching its expected provider boundary")
        }

        func retainCurrentNotificationTask() -> Task<Void, Never>? {
            let owner = controller.pendingNotificationTask
            if let owner { ownedTasks.append(owner) }
            return owner
        }

        func drainCurrentNotificationTask() async {
            if let owner = retainCurrentNotificationTask() { await owner.value }
        }

        func fireNextAction() -> Task<Void, Never>? {
            let owner = controller.fireNextAction()
            if let owner { ownedTasks.append(owner) }
            return owner
        }

        func beginStartupAttempt() -> Task<Void, Never> {
            let owner = controller.beginNotificationAuthorization()
            ownedTasks.append(owner)
            return owner
        }

        func beginStartupAttempt(waitingAt gate: Gate) async throws -> Task<Void, Never> {
            let owner = beginStartupAttempt()
            completionObservers.append(Task { @MainActor in
                await owner.value
                gate.ownerDidFinish()
            })
            let reachedBoundary = await gate.waitForEntry()
            try #require(reachedBoundary, "Startup authorization finished before reaching its expected held boundary")
            return owner
        }

        func invalidateStartup(_ reason: StartupInvalidation) {
            switch reason {
            case .stop:
                controller.stop()
            case .backendReplacement:
                replaceNotifier(GatedNotifier())
            }
        }

        func replaceNotifier(_ replacement: GatedNotifier) {
            replacementNotifiers.append(replacement)
            controller.replaceNotificationService(replacement)
        }

        func invalidate(_ reason: Invalidation) async {
            switch reason {
            case .stop:
                controller.stop()
            case .backendReplacement:
                replaceNotifier(GatedNotifier())
            case .providerReplacement:
                controller.provider = FixtureProvider(events: [], calendarID: "replacement-calendar")
            case .calendarDeselected:
                settings.update { $0.selectedCalendarIDs = [] }
                await controller.refresh(reason: "settings")
                #expect(controller.activeReminders.isEmpty)
            case .calendarAlertsDisabled:
                settings.update {
                    var calendar = $0.calendarSettings(for: provider.calendarID)
                    calendar.isAlertEnabled = false
                    $0.calendarSettings[provider.calendarID] = calendar
                }
                controller.handleSettingsChanged()
                #expect(controller.activeReminders.isEmpty)
            case .presentationOff:
                controller.isPresentationMode = false
                #expect(alert.isShowing)
            case .wakeExpired:
                clock.now = clock.now.addingTimeInterval(61)
                #expect(!controller.isPresentationMode)
                #expect(!monitor.isInWakeGrace(now: clock.now))
            case .sourcesEnded:
                clock.now = events[0].endDate.addingTimeInterval(1)
                #expect(events.allSatisfy { $0.endDate < clock.now })
            }
        }

        func replaceEventContent() -> [CalendarEventOccurrence] {
            let current = events.map { original in
                var event = original
                event.title = "Synthetic current \(original.eventID)"
                event.updatedAt = clock.now.addingTimeInterval(1)
                return event
            }
            provider.eventValues = current
            return current
        }

        func expectHealthyNotificationState() {
            #expect(!controller.notificationHealth.authorizationDenied)
            #expect(!controller.notificationHealth.lastDeliveryFailed)
            #expect(controller.notificationWarning == nil)
        }

        func expectNoStartupPresentation() {
            #expect(notifier.delivered.isEmpty)
            #expect(replacementNotifiers.allSatisfy { $0.delivered.isEmpty })
            #expect(alert.showCount == 0)
            #expect(controller.pendingNotificationTask == nil)
        }

        func cleanup() async {
            if let current = controller.pendingNotificationTask { ownedTasks.append(current) }
            if let current = controller.pendingNotificationAuthorizationTask { ownedTasks.append(current) }
            if let current = controller.pendingNextActionTask { ownedTasks.append(current) }
            let allNotifiers = [notifier] + replacementNotifiers
            for backend in allNotifiers { backend.releaseAllGates() }
            provider.releaseAllGates()
            for owner in ownedTasks { await owner.value }
            await drainCurrentNotificationTask()
            for observer in completionObservers { await observer.value }
            controller.clearFallback()
            controller.stop()
            #expect(allNotifiers.allSatisfy { !$0.hasPendingGate })
            #expect(!provider.hasPendingGate)
            #expect(allNotifiers.reduce(0) { $0 + $1.authorizationRequestCount } == expectedAuthorizationRequests)
            #expect(browser.openedURLs.isEmpty)
            #expect(routes.agenda == 0)
            #expect(routes.settings == 0)
            #expect(routes.authorizationProviders == 0)
            #expect(provider.reconnectCount == 0)
            for event in events { #expect(state.state(for: event.occurrenceKey)?.acknowledgement == nil) }
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
            #expect(SettingsPreferences(domainName: domain).read() == nil)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @MainActor
    private final class Gate {
        private var entered = false
        private var released = false
        private var ownerFinished = false
        private var entry: CheckedContinuation<Bool, Never>?
        private var result: CheckedContinuation<Void, Never>?

        var isPending: Bool { entry != nil || result != nil }

        func hold() async {
            entered = true
            entry?.resume(returning: true)
            entry = nil
            guard !released else { return }
            await withCheckedContinuation { result = $0 }
        }

        func waitForEntry() async -> Bool {
            if entered { return true }
            if ownerFinished { return false }
            return await withCheckedContinuation { entry = $0 }
        }

        func release() {
            released = true
            result?.resume()
            result = nil
        }

        func ownerDidFinish() {
            ownerFinished = true
            entry?.resume(returning: entered)
            entry = nil
        }
    }

    @MainActor
    private final class GatedNotifier: MeetingNotifying {
        var defaultAuthorizationStatus: UNAuthorizationStatus = .authorized
        var requestGates: [Int: Gate] = [:]
        var requestResults: [Int: Bool] = [:]
        var failedRequests: Set<Int> = []
        var authorizationGates: [Int: Gate] = [:]
        var authorizationResults: [Int: UNAuthorizationStatus] = [:]
        var deliveryGates: [Int: Gate] = [:]
        var failedDeliveries: Set<Int> = []
        private(set) var authorizationReadCount = 0
        private(set) var authorizationReturnCount = 0
        private(set) var authorizationRequestCount = 0
        private(set) var authorizationRequestReturnCount = 0
        private(set) var delivered: [MeetingNotification] = []
        private(set) var deliveryReturnCount = 0

        var hasPendingGate: Bool {
            requestGates.values.contains(where: \.isPending)
                || authorizationGates.values.contains(where: \.isPending)
                || deliveryGates.values.contains(where: \.isPending)
        }

        func authorizationStatus() async -> UNAuthorizationStatus {
            authorizationReadCount += 1
            let index = authorizationReadCount
            let status = authorizationResults[index] ?? defaultAuthorizationStatus
            if let gate = authorizationGates[index] { await gate.hold() }
            authorizationReturnCount += 1
            return status
        }

        func requestAuthorization() async throws -> Bool {
            authorizationRequestCount += 1
            let index = authorizationRequestCount
            let granted = requestResults[index] ?? false
            let shouldFail = failedRequests.contains(index)
            if let gate = requestGates[index] { await gate.hold() }
            authorizationRequestReturnCount += 1
            if shouldFail { throw URLError(.cannotConnectToHost) }
            return granted
        }

        func deliver(_ notification: MeetingNotification) async throws {
            delivered.append(notification)
            let index = delivered.count
            let shouldFail = failedDeliveries.contains(index)
            if let gate = deliveryGates[index] { await gate.hold() }
            deliveryReturnCount += 1
            if shouldFail { throw URLError(.cannotConnectToHost) }
        }

        func releaseAllGates() {
            for gate in requestGates.values { gate.release() }
            for gate in authorizationGates.values { gate.release() }
            for gate in deliveryGates.values { gate.release() }
        }
    }

    @MainActor
    private final class HealthTrace {
        enum Event: Equatable {
            case authorization(Bool)
            case delivery(Bool)
            case warning(String?)
        }

        private(set) var events: [Event] = []
        private var observations: Set<AnyCancellable> = []

        init(controller: MeetingShieldController) {
            controller.notificationHealth.$authorizationDenied.dropFirst().sink { [weak self] in
                self?.events.append(.authorization($0))
            }.store(in: &observations)
            controller.notificationHealth.$lastDeliveryFailed.dropFirst().sink { [weak self] in
                self?.events.append(.delivery($0))
            }.store(in: &observations)
            controller.$notificationWarning.dropFirst().sink { [weak self] in
                self?.events.append(.warning($0))
            }.store(in: &observations)
        }
    }

    @MainActor
    private final class Clock {
        var now: Date

        init(now: Date) { self.now = now }
    }

    @MainActor
    private final class Routes {
        var agenda = 0
        var settings = 0
        var authorizationProviders = 0
    }

    @MainActor
    private final class FixtureProvider: CalendarProvider {
        nonisolated let providerID = "mock"
        let calendarID: String
        var eventValues: [CalendarEventOccurrence]
        private(set) var reconnectCount = 0
        private(set) var readCount = 0
        private(set) var refreshInvocationCount = 0
        private(set) var refreshCompletionCount = 0
        private var refreshGates: [Int: Gate] = [:]

        init(events: [CalendarEventOccurrence], calendarID: String) {
            eventValues = events
            self.calendarID = calendarID
        }

        var authState: CalendarProviderAuthState {
            get async {
                readCount += 1
                return .connected(accountEmail: "synthetic@example.invalid")
            }
        }

        func accounts() async -> [ConnectedCalendarAccount] {
            readCount += 1
            return [ConnectedCalendarAccount(id: "mock-account", displayName: "Synthetic account")]
        }

        func calendars() async throws -> [UserCalendar] {
            readCount += 1
            return [UserCalendar(id: calendarID, accountID: "mock-account", displayName: "Synthetic calendar", isPrimary: true, isSelected: true)]
        }

        func events(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
            readCount += 1
            return eventValues.filter { $0.endDate >= window.start && $0.startDate <= window.end }
        }

        func refresh(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
            try await events(in: window)
        }

        func refresh(in window: CalendarFetchWindow, calendars: [UserCalendar]) async throws -> [CalendarEventOccurrence] {
            refreshInvocationCount += 1
            let index = refreshInvocationCount
            let selectedIDs = Set(calendars.map(\.id))
            let result = try await events(in: window).filter { selectedIDs.contains($0.calendarID) }
            if let gate = refreshGates[index] { await gate.hold() }
            refreshCompletionCount += 1
            return result
        }

        var hasPendingGate: Bool { refreshGates.values.contains(where: \.isPending) }

        func holdNextRefresh() -> Gate {
            let gate = Gate()
            refreshGates[refreshInvocationCount + 1] = gate
            return gate
        }

        func releaseAllGates() {
            for gate in refreshGates.values { gate.release() }
        }

        func reconnect() async throws { reconnectCount += 1 }
        func removeAccount(id: String) async throws {}
    }

    @MainActor
    private final class RecordingAlert: FullScreenAlertPresenting {
        private(set) var isShowing = false
        private(set) var showCount = 0
        private(set) var reminders: [ScheduledReminder] = []

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
            showCount += 1
            self.reminders = reminders
            isShowing = !reminders.isEmpty
        }

        func update(reminders: [ScheduledReminder]) {
            self.reminders = reminders
            if reminders.isEmpty { isShowing = false }
        }

        func hide() {
            reminders = []
            isShowing = false
        }
    }

    @MainActor
    private final class NoFallback: JoinFallbackPresenting {
        func show(
            fallback: JoinFallbackState, aboveAlerts: Bool,
            onOpenAgain: @escaping () -> Void,
            onDismiss: @escaping () -> Void,
            onClose: @escaping () -> Void
        ) {
            Issue.record("Ordinary notification delivery unexpectedly opened a Join fallback")
        }

        func updateLevel(aboveAlerts: Bool) {}
        func hide() {}
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
