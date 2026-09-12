import CoreFoundation
import Foundation
import Testing
@testable import MeetingShield

@Suite("Controller reconnect ownership at a synthetic authorization boundary")
@MainActor
struct CredentialReconnectLifecycleTests {
    @Test("A replaced provider's reconnect completion cannot change current health", arguments: ReconnectOutcome.allCases)
    func replacedProviderCompletionIsIgnored(outcome: ReconnectOutcome) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = AuthorizationProvider(accountID: "synthetic-original@example.invalid", outcome: outcome)
        let replacement = AuthorizationProvider(accountID: "synthetic-replacement@example.invalid")
        await replacement.setFailures([.save(accountID: replacement.accountID)])
        let factory = ProviderFactory(original)
        let controller = fixture.controller(provider: original, factory: factory)
        defer { controller.stop() }
        let operation = try #require(controller.reconnectGoogle())
        defer { operation.cancel() }
        let entered = await original.entered.wait()
        if !entered {
            await original.release.open()
            await operation.value
        }
        try #require(entered, "The original authorization must be suspended before replacing its provider.")

        controller.provider = replacement
        await controller.refresh(reason: "settings")
        #expect(controller.authState == .connected(accountEmail: replacement.accountID))
        #expect(controller.accounts.map(\.id) == [replacement.accountID])
        #expect(controller.calendars.map(\.id) == [replacement.calendarID])
        #expect(controller.statusMessage == nil)
        #expect(controller.credentialPersistenceFailures == [.save(accountID: replacement.accountID)])
        let currentSettings = fixture.settings.snapshot
        let currentWarnings = controller.persistenceWarnings
        let currentRefreshCount = await replacement.refreshCount

        await original.release.open()
        await operation.value

        #expect((controller.provider as? AuthorizationProvider) === replacement)
        #expect(controller.authState == .connected(accountEmail: replacement.accountID))
        #expect(controller.accounts.map(\.id) == [replacement.accountID])
        #expect(controller.calendars.map(\.id) == [replacement.calendarID])
        #expect(controller.statusMessage == nil)
        #expect(controller.credentialPersistenceFailures == [.save(accountID: replacement.accountID)])
        #expect(controller.persistenceWarnings == currentWarnings)
        #expect(fixture.settings.snapshot == currentSettings)
        #expect(controller.events.isEmpty)
        #expect(controller.activeReminders.isEmpty)
        #expect(controller.scheduledReminders.isEmpty)
        #expect(await original.reconnectCount == 1)
        #expect(await original.refreshCount == 0)
        #expect(await replacement.reconnectCount == 0)
        #expect(await replacement.refreshCount == currentRefreshCount)
        #expect(factory.clientIDs == [Fixture.clientID])
    }

    @Test("The current provider's reconnect still publishes its own result", arguments: ReconnectOutcome.allCases)
    func currentProviderCompletionIsAccepted(outcome: ReconnectOutcome) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let provider = AuthorizationProvider(accountID: "synthetic-current@example.invalid", outcome: outcome)
        let factory = ProviderFactory(provider)
        let controller = fixture.controller(provider: provider, factory: factory)
        defer { controller.stop() }
        let operation = try #require(controller.reconnectGoogle())
        defer { operation.cancel() }
        let entered = await provider.entered.wait()
        if !entered {
            await provider.release.open()
            await operation.value
        }
        try #require(entered)
        #expect(controller.authState == .authenticating)

        await provider.release.open()
        await operation.value

        #expect((controller.provider as? AuthorizationProvider) === provider)
        #expect(await provider.reconnectCount == 1)
        #expect(factory.clientIDs == [Fixture.clientID])
        #expect(controller.events.isEmpty)
        #expect(controller.activeReminders.isEmpty)
        #expect(controller.scheduledReminders.isEmpty)
        switch outcome {
        case .success:
            #expect(controller.authState == .connected(accountEmail: provider.accountID))
            #expect(controller.accounts.map(\.id) == [provider.accountID])
            #expect(controller.calendars.map(\.id) == [provider.calendarID])
            #expect(controller.statusMessage == nil)
            #expect(controller.credentialPersistenceFailures == [.legacyCleanup])
            #expect(await provider.refreshCount == 1)
        case .failure:
            #expect(controller.authState == .expired(reason: AuthorizationProvider.failureReason))
            #expect(controller.statusMessage == "Google Calendar connection failed: Calendar authorization expired: synthetic-reconnect-failure")
            #expect(controller.credentialPersistenceFailures == [.save(accountID: provider.accountID)])
            #expect(await provider.refreshCount == 0)
        }
    }

    @Test("Replacing a provider before the reconnect task starts authorizes neither provider")
    func replacementBeforeTaskStartsDoesNotRedirectAuthorization() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = AuthorizationProvider(accountID: "synthetic-queued-original@example.invalid", outcome: .failure)
        let replacement = AuthorizationProvider(accountID: "synthetic-queued-replacement@example.invalid")
        let factory = ProviderFactory(original)
        let controller = fixture.controller(provider: original, factory: factory)
        defer { controller.stop() }

        let operation = try #require(controller.reconnectGoogle())
        controller.provider = replacement
        await operation.value

        #expect((controller.provider as? AuthorizationProvider) === replacement)
        #expect(await original.reconnectCount == 0)
        #expect(await replacement.reconnectCount == 0)
        #expect(await original.refreshCount == 0)
        #expect(await replacement.refreshCount == 0)
        #expect(factory.clientIDs == [Fixture.clientID])
        #expect(controller.events.isEmpty)
        #expect(controller.activeReminders.isEmpty)
    }

    enum ReconnectOutcome: CaseIterable, Sendable {
        case success, failure
    }

    private actor AuthorizationProvider: CalendarProvider {
        nonisolated let providerID = "synthetic-reconnect-controller"
        nonisolated let accountID: String
        nonisolated let calendarID: String
        nonisolated let entered = ReconnectGate()
        nonisolated let release = ReconnectGate()
        static let failureReason = "synthetic-reconnect-failure"
        private let outcome: ReconnectOutcome?
        private var failed = false
        private var failures: Set<GoogleOAuthPersistenceFailure> = []
        private(set) var reconnectCount = 0
        private(set) var refreshCount = 0

        init(accountID: String, outcome: ReconnectOutcome? = nil) {
            self.accountID = accountID
            self.calendarID = "\(accountID)::synthetic-calendar"
            self.outcome = outcome
        }

        var authState: CalendarProviderAuthState {
            failed ? .expired(reason: Self.failureReason) : .connected(accountEmail: accountID)
        }

        var credentialPersistenceFailures: Set<GoogleOAuthPersistenceFailure> { failures }

        func setFailures(_ failures: Set<GoogleOAuthPersistenceFailure>) {
            self.failures = failures
        }

        func accounts() async -> [ConnectedCalendarAccount] {
            [ConnectedCalendarAccount(id: accountID, displayName: "Synthetic controller account")]
        }

        func calendars() async throws -> [UserCalendar] {
            [UserCalendar(id: calendarID, accountID: accountID, displayName: "Synthetic controller calendar", isPrimary: true, isSelected: true)]
        }

        func events(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
            try await refresh(in: window)
        }

        func refresh(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] {
            refreshCount += 1
            return []
        }

        func refresh(in window: CalendarFetchWindow, calendars: [UserCalendar]) async throws -> [CalendarEventOccurrence] {
            try await refresh(in: window)
        }

        func reconnect() async throws {
            reconnectCount += 1
            guard let outcome else { return }
            await entered.open()
            guard await release.wait() else { throw CancellationError() }
            switch outcome {
            case .success:
                failures = [.legacyCleanup]
            case .failure:
                failed = true
                failures = [.save(accountID: accountID)]
                throw CalendarProviderError.authExpired(Self.failureReason)
            }
        }

        func removeAccount(id: String) async throws {
            Issue.record("A controller reconnect must not remove an account.")
        }

        func retryCredentialPersistence() async {
            Issue.record("A controller reconnect must not start a storage retry.")
        }
    }

    @MainActor
    private final class ProviderFactory {
        let provider: AuthorizationProvider
        private(set) var clientIDs: [String] = []

        init(_ provider: AuthorizationProvider) {
            self.provider = provider
        }

        func make(_ configuration: GoogleOAuthConfiguration) -> any CalendarProvider {
            clientIDs.append(configuration.clientID)
            return provider
        }
    }

    @MainActor
    private struct Fixture {
        static let clientID = "synthetic-controller-reconnect-client"
        let domain: String
        let directory: URL
        let settings: AppSettingsStore

        init() throws {
            let domain = "CredentialReconnectLifecycleTests.\(UUID().uuidString)"
            self.domain = domain
            directory = try TestTempDirectory.make()
            settings = AppSettingsStore(domainName: domain)
            settings.update {
                $0.googleOAuthClientID = Self.clientID
                $0.presentationModeDefault = true
                $0.soundEnabled = false
                $0.urgentRepeatSoundEnabled = false
                $0.wakeGraceEnabled = false
            }
        }

        func controller(provider: AuthorizationProvider, factory: ProviderFactory) -> MeetingShieldController {
            MeetingShieldController(
                settingsStore: settings, provider: provider,
                credentialsResolver: GoogleOAuthCredentialsResolver(bundleInfoValue: { _ in nil }, environment: [:]),
                makeGoogleProvider: { factory.make($0) },
                reminderStateStore: ReminderStateStore(
                    fileURL: directory.appending(path: "reminder-state.json"),
                    diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "diagnostics"), nativeSink: { _, _ in })
                ),
                cacheStore: EventCacheStore(fileURL: directory.appending(path: "event-cache.json")),
                notificationService: NoopNotificationService(), soundPlayer: UnexpectedSound(),
                dismissalPresenter: UnexpectedDismissal(), refreshMenuBar: {}
            )
        }

        func cleanup() {
            for user in [kCFPreferencesCurrentUser, kCFPreferencesAnyUser] {
                CFPreferencesSetValue("meetingShield.settings.v1" as CFString, nil, domain as CFString, user, kCFPreferencesAnyHost)
                _ = CFPreferencesSynchronize(domain as CFString, user, kCFPreferencesAnyHost)
                #expect(CFPreferencesCopyValue("meetingShield.settings.v1" as CFString, domain as CFString, user, kCFPreferencesAnyHost) == nil)
            }
            UserDefaults.standard.removePersistentDomain(forName: domain)
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("The owned reconnect fixture directory could not be removed.") }
        }
    }

    private struct UnexpectedSound: AlertSoundPlaying {
        func playAlertSound() {
            Issue.record("An empty reconnect fixture must not play sound.")
        }
    }

    @MainActor
    private final class UnexpectedDismissal: DismissalConfirming {
        func present(requestID: UUID, reminder: ScheduledReminder, source: DismissalRequestSource, completion: @escaping @MainActor (Bool) -> Void) {
            Issue.record("An empty reconnect fixture must not present a dismissal confirmation.")
            completion(false)
        }

        func cancel(requestID: UUID) {}
    }

    private actor ReconnectGate {
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
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
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
}
