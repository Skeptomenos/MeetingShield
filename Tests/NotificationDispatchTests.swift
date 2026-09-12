import Foundation
import Testing
import UserNotifications
@testable import MeetingShield

private final class RecordingNotifier: MeetingNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var deliveredIDs: [String] = []
    var deliveryError: Error?
    var status: UNAuthorizationStatus = .authorized

    var delivered: [String] {
        lock.withLock { deliveredIDs }
    }

    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async throws -> Bool { status == .authorized }

    func deliver(_ notification: MeetingNotification) async throws {
        if let deliveryError { throw deliveryError }
        lock.withLock { deliveredIDs.append(notification.id) }
    }
}

@Suite("Notification health and dispatch", .timeLimit(.minutes(1)))
@MainActor
struct NotificationDispatchTests {
    @Test("Denied authorization produces a visible warning when notifications carry the alerts")
    func deniedAuthorizationWarns() {
        let health = NotificationHealth()
        health.recordAuthorizationStatus(.denied)

        #expect(health.authorizationDenied)
        let warning = try? #require(health.warningMessage(notificationsCarryAlerts: true))
        #expect(warning?.localizedCaseInsensitiveContains("notification") == true)
    }

    @Test("Denied authorization stays quiet while full-screen alerts are active")
    func deniedAuthorizationQuietWhenFullScreenActive() {
        let health = NotificationHealth()
        health.recordAuthorizationStatus(.denied)

        #expect(health.warningMessage(notificationsCarryAlerts: false) == nil)
    }

    @Test("Authorized status produces no warning")
    func authorizedProducesNoWarning() {
        let health = NotificationHealth()
        health.recordAuthorizationStatus(.authorized)

        #expect(!health.authorizationDenied)
        #expect(health.warningMessage(notificationsCarryAlerts: true) == nil)
    }

    @Test("Delivery failure is recorded and surfaces a warning")
    func deliveryFailureSurfacesWarning() async {
        let notifier = RecordingNotifier()
        notifier.deliveryError = URLError(.unknown)
        let health = NotificationHealth()
        let dispatcher = NotificationDispatcher(notifier: notifier, health: health)

        await dispatcher.deliver([
            MeetingNotification(id: "a", title: "Meeting", body: "Starts soon", date: nil)
        ])

        #expect(health.lastDeliveryFailed)
        #expect(health.warningMessage(notificationsCarryAlerts: true) != nil)
    }

    @Test("Successful delivery clears prior failures and reaches the notifier")
    func successfulDeliveryClearsFailure() async {
        let notifier = RecordingNotifier()
        let health = NotificationHealth()
        let dispatcher = NotificationDispatcher(notifier: notifier, health: health)

        notifier.deliveryError = URLError(.unknown)
        await dispatcher.deliver([MeetingNotification(id: "fails", title: "T", body: "B", date: nil)])
        #expect(health.lastDeliveryFailed)

        notifier.deliveryError = nil
        await dispatcher.deliver([
            MeetingNotification(id: "a", title: "T", body: "B", date: nil),
            MeetingNotification(id: "b", title: "T", body: "B", date: nil)
        ])

        #expect(!health.lastDeliveryFailed)
        #expect(notifier.delivered == ["a", "b"])
    }

    @Test("Observed channel restrictions follow warning precedence", arguments: ChannelCondition.allCases)
    func observedChannelWarning(condition: ChannelCondition) {
        let health = NotificationHealth()
        health.recordNotificationSettings(condition.settings)
        health.recordDeliveryResult(success: !condition.deliveryFailed)

        #expect(health.authorizationDenied == (condition.settings.authorizationStatus == .denied))
        #expect(health.lastDeliveryFailed == condition.deliveryFailed)
        expectWarning(health, kind: condition.warning)
        #expect(health.warningMessage(notificationsCarryAlerts: false) == nil)
    }

    @Test("A current healthy snapshot clears prior channel restrictions", arguments: ChannelCondition.restrictedCases)
    func healthySettingsClearRestriction(condition: ChannelCondition) {
        let health = NotificationHealth()
        health.recordNotificationSettings(condition.settings)
        expectWarning(health, kind: condition.warning)

        health.recordNotificationSettings(ChannelCondition.healthyBanner.settings)

        #expect(!health.authorizationDenied)
        #expect(!health.lastDeliveryFailed)
        expectWarning(health, kind: .clear)
    }

    @Test("Accepted delivery does not clear an observed channel restriction", arguments: ChannelCondition.restrictedCases)
    func acceptedDeliveryPreservesRestriction(condition: ChannelCondition) {
        let health = NotificationHealth()
        health.recordNotificationSettings(condition.settings)
        health.recordDeliveryResult(success: false)

        health.recordDeliveryResult(success: true)

        #expect(!health.lastDeliveryFailed)
        expectWarning(health, kind: condition.warning)
    }

    @Test("Settings observations cannot clear a delivery failure", arguments: ChannelCondition.unrestrictedCases)
    func settingsDoNotProveDelivery(condition: ChannelCondition) {
        let health = NotificationHealth()
        health.recordDeliveryResult(success: false)

        health.recordNotificationSettings(condition.settings)

        #expect(health.lastDeliveryFailed)
        expectWarning(health, kind: .deliveryFailed)

        health.recordDeliveryResult(success: true)

        #expect(!health.lastDeliveryFailed)
        expectWarning(health, kind: .clear)
    }

    @Test("Legacy notifiers expose authorization without inventing channel details", arguments: [
        UNAuthorizationStatus.authorized, .denied, .notDetermined, .provisional
    ])
    func legacyNotifierHasUnknownChannelDetails(status: UNAuthorizationStatus) async {
        let notifier = LegacyStatusNotifier(status: status)

        let settings = await notifier.notificationSettings()

        #expect(settings == NotificationSettingsSnapshot(authorizationStatus: status))
        #expect(settings.alertSetting == nil)
        #expect(settings.alertStyle == nil)
        #expect(settings.scheduledDeliverySetting == nil)
        #expect(notifier.authorizationReadCount == 1)
        #expect(notifier.authorizationRequestCount == 0)
        #expect(notifier.deliveryCount == 0)
    }

    @Test("Dispatcher reads one complete snapshot without requesting permission", arguments: ChannelCondition.restrictedCases)
    func dispatcherReadsDetailedSnapshot(condition: ChannelCondition) async {
        let notifier = DetailedSettingsNotifier(settings: condition.settings)
        let health = NotificationHealth()
        let dispatcher = NotificationDispatcher(notifier: notifier, health: health)

        await dispatcher.refreshAuthorizationStatus()

        #expect(notifier.settingsReadCount == 1)
        #expect(notifier.settingsReturnCount == 1)
        #expect(notifier.authorizationReadCount == 0)
        #expect(notifier.authorizationRequestCount == 0)
        #expect(notifier.deliveryCount == 0)
        expectWarning(health, kind: condition.warning)

        notifier.settings = ChannelCondition.healthyAlert.settings
        await dispatcher.refreshAuthorizationStatus()

        #expect(notifier.settingsReadCount == 2)
        #expect(notifier.settingsReturnCount == 2)
        #expect(notifier.authorizationReadCount == 0)
        #expect(notifier.authorizationRequestCount == 0)
        expectWarning(health, kind: .clear)
    }

    @Test("An obsolete caller cannot begin a settings read")
    func obsoleteCallerDoesNotReadSettings() async {
        let notifier = DetailedSettingsNotifier(settings: ChannelCondition.healthyBanner.settings)
        let health = NotificationHealth()
        health.recordNotificationSettings(ChannelCondition.scheduledDelivery.settings)
        let warning = health.warningMessage(notificationsCarryAlerts: true)
        let dispatcher = NotificationDispatcher(notifier: notifier, health: health)

        await dispatcher.refreshAuthorizationStatus(isCurrent: { false })

        #expect(notifier.settingsReadCount == 0)
        #expect(notifier.authorizationReadCount == 0)
        #expect(notifier.authorizationRequestCount == 0)
        #expect(notifier.deliveryCount == 0)
        #expect(health.warningMessage(notificationsCarryAlerts: true) == warning)
        expectWarning(health, kind: .scheduledDelivery)
    }

    @Test("An invalidated detailed response cannot publish its channel restriction")
    func invalidatedSettingsResponseDoesNotPublish() async {
        let gate = SettingsReadGate()
        let notifier = DetailedSettingsNotifier(settings: ChannelCondition.alertsDisabled.settings, firstReadGate: gate)
        let health = NotificationHealth()
        health.recordNotificationSettings(ChannelCondition.healthyBanner.settings)
        let dispatcher = NotificationDispatcher(notifier: notifier, health: health)
        var current = true
        let owner = Task { @MainActor in
            await dispatcher.refreshAuthorizationStatus(isCurrent: { current })
            gate.operationDidFinish()
        }
        defer {
            owner.cancel()
            gate.release()
        }

        let entered = await gate.waitForEntry()
        #expect(entered)
        guard entered else {
            gate.release()
            owner.cancel()
            await owner.value
            return
        }
        current = false
        gate.release()
        await owner.value

        #expect(notifier.settingsReadCount == 1)
        #expect(notifier.settingsReturnCount == 1)
        #expect(notifier.authorizationReadCount == 0)
        #expect(notifier.authorizationRequestCount == 0)
        #expect(notifier.deliveryCount == 0)
        #expect(!health.authorizationDenied)
        #expect(!health.lastDeliveryFailed)
        expectWarning(health, kind: .clear)
    }

    @Test("An older detailed response cannot replace newer channel health", arguments: [false, true])
    func newerSettingsSurviveOldResponse(newerRestricted: Bool) async {
        let gate = SettingsReadGate()
        let older: ChannelCondition = newerRestricted ? .healthyBanner : .alertsDisabled
        let newer: ChannelCondition = newerRestricted ? .scheduledDelivery : .healthyAlert
        let notifier = DetailedSettingsNotifier(settings: older.settings, firstReadGate: gate)
        let health = NotificationHealth()
        let dispatcher = NotificationDispatcher(notifier: notifier, health: health)
        var generation = 0
        let owner = Task { @MainActor in
            await dispatcher.refreshAuthorizationStatus(isCurrent: { generation == 0 })
            gate.operationDidFinish()
        }
        defer {
            owner.cancel()
            gate.release()
        }

        let entered = await gate.waitForEntry()
        #expect(entered)
        guard entered else {
            gate.release()
            owner.cancel()
            await owner.value
            return
        }
        generation = 1
        notifier.settings = newer.settings
        await dispatcher.refreshAuthorizationStatus(isCurrent: { generation == 1 })
        expectWarning(health, kind: newer.warning)
        let currentWarning = health.warningMessage(notificationsCarryAlerts: true)
        #expect(notifier.settingsReadCount == 2)
        #expect(notifier.settingsReturnCount == 1)

        gate.release()
        await owner.value

        #expect(notifier.settingsReadCount == 2)
        #expect(notifier.settingsReturnCount == 2)
        #expect(notifier.authorizationReadCount == 0)
        #expect(notifier.authorizationRequestCount == 0)
        #expect(notifier.deliveryCount == 0)
        #expect(health.warningMessage(notificationsCarryAlerts: true) == currentWarning)
        expectWarning(health, kind: newer.warning)
    }

    private func expectWarning(_ health: NotificationHealth, kind: WarningKind) {
        let warning = health.warningMessage(notificationsCarryAlerts: true)?.lowercased()
        if kind == .clear {
            #expect(warning == nil)
        } else {
            #expect(warning != nil)
            for fragment in kind.fragments {
                #expect(warning?.contains(fragment) == true)
            }
        }
    }

    enum ChannelCondition: String, CaseIterable, Sendable {
        case denied
        case notDetermined
        case alertsDisabled
        case alertStyleNone
        case provisional
        case scheduledDelivery
        case healthyBanner
        case healthyAlert
        case authorizationOnly
        case unknownAlertSetting
        case unknownAlertStyle
        case unsupportedDetails
        case disabledWithUnknownStyle
        case noneWithUnknownSetting
        case deniedWithOtherRestrictions
        case notDeterminedWithOtherRestrictions
        case disabledWithDeliveryFailure
        case noneWithDeliveryFailure
        case failureWithProvisional
        case failureWithScheduled
        case provisionalWithScheduled
        case failureWithUnknownDetails

        static var restrictedCases: [Self] {
            [.denied, .notDetermined, .alertsDisabled, .alertStyleNone, .provisional, .scheduledDelivery]
        }

        static var unrestrictedCases: [Self] {
            [.healthyBanner, .healthyAlert, .authorizationOnly, .unknownAlertSetting, .unknownAlertStyle, .unsupportedDetails]
        }

        var settings: NotificationSettingsSnapshot {
            var result = NotificationSettingsSnapshot(
                authorizationStatus: .authorized,
                alertSetting: .enabled,
                alertStyle: .banner,
                scheduledDeliverySetting: .disabled
            )
            switch self {
            case .denied:
                result.authorizationStatus = .denied
            case .notDetermined:
                result.authorizationStatus = .notDetermined
            case .alertsDisabled:
                result.alertSetting = .disabled
            case .alertStyleNone:
                result.alertStyle = UNAlertStyle.none
            case .provisional:
                result.authorizationStatus = .provisional
            case .scheduledDelivery:
                result.scheduledDeliverySetting = .enabled
            case .healthyBanner:
                break
            case .healthyAlert:
                result.alertStyle = .alert
            case .authorizationOnly, .failureWithUnknownDetails:
                return NotificationSettingsSnapshot(authorizationStatus: .authorized)
            case .unknownAlertSetting:
                result.alertSetting = nil
            case .unknownAlertStyle:
                result.alertStyle = nil
            case .unsupportedDetails:
                result.alertSetting = .notSupported
                result.alertStyle = nil
                result.scheduledDeliverySetting = .notSupported
            case .disabledWithUnknownStyle:
                result.alertSetting = .disabled
                result.alertStyle = nil
            case .noneWithUnknownSetting:
                result.alertSetting = nil
                result.alertStyle = UNAlertStyle.none
            case .deniedWithOtherRestrictions, .notDeterminedWithOtherRestrictions:
                result.authorizationStatus = self == .deniedWithOtherRestrictions ? .denied : .notDetermined
                result.alertSetting = .disabled
                result.alertStyle = UNAlertStyle.none
                result.scheduledDeliverySetting = .enabled
            case .disabledWithDeliveryFailure:
                result.alertSetting = .disabled
                result.scheduledDeliverySetting = .enabled
            case .noneWithDeliveryFailure:
                result.alertStyle = UNAlertStyle.none
                result.scheduledDeliverySetting = .enabled
            case .failureWithProvisional, .provisionalWithScheduled:
                result.authorizationStatus = .provisional
                result.alertSetting = .disabled
                result.alertStyle = UNAlertStyle.none
                result.scheduledDeliverySetting = .enabled
            case .failureWithScheduled:
                result.scheduledDeliverySetting = .enabled
            }
            return result
        }

        var deliveryFailed: Bool {
            switch self {
            case .deniedWithOtherRestrictions, .notDeterminedWithOtherRestrictions,
                 .disabledWithDeliveryFailure, .noneWithDeliveryFailure,
                 .failureWithProvisional, .failureWithScheduled, .failureWithUnknownDetails:
                return true
            default:
                return false
            }
        }

        var warning: WarningKind {
            switch self {
            case .denied, .deniedWithOtherRestrictions:
                return .denied
            case .notDetermined, .notDeterminedWithOtherRestrictions:
                return .notDetermined
            case .alertsDisabled, .alertStyleNone, .disabledWithUnknownStyle,
                 .noneWithUnknownSetting, .disabledWithDeliveryFailure, .noneWithDeliveryFailure:
                return .disabledBanners
            case .provisional, .provisionalWithScheduled:
                return .quietDelivery
            case .scheduledDelivery:
                return .scheduledDelivery
            case .failureWithProvisional, .failureWithScheduled, .failureWithUnknownDetails:
                return .deliveryFailed
            case .healthyBanner, .healthyAlert, .authorizationOnly,
                 .unknownAlertSetting, .unknownAlertStyle, .unsupportedDetails:
                return .clear
            }
        }
    }

    enum WarningKind: Sendable {
        case clear
        case denied
        case notDetermined
        case disabledBanners
        case deliveryFailed
        case quietDelivery
        case scheduledDelivery

        var fragments: [String] {
            switch self {
            case .clear: []
            case .denied: ["disabled", "system settings"]
            case .notDetermined: ["permission", "not granted"]
            case .disabledBanners: ["banner", "disabled"]
            case .deliveryFailed: ["delivery failed"]
            case .quietDelivery: ["quiet"]
            case .scheduledDelivery: ["delay"]
            }
        }
    }

    @MainActor
    private final class LegacyStatusNotifier: MeetingNotifying {
        let status: UNAuthorizationStatus
        private(set) var authorizationReadCount = 0
        private(set) var authorizationRequestCount = 0
        private(set) var deliveryCount = 0

        init(status: UNAuthorizationStatus) { self.status = status }

        func authorizationStatus() async -> UNAuthorizationStatus {
            authorizationReadCount += 1
            return status
        }

        func requestAuthorization() async throws -> Bool {
            authorizationRequestCount += 1
            return status == .authorized
        }

        func deliver(_ notification: MeetingNotification) async throws {
            deliveryCount += 1
        }
    }

    @MainActor
    private final class DetailedSettingsNotifier: MeetingNotifying {
        var settings: NotificationSettingsSnapshot
        let firstReadGate: SettingsReadGate?
        private(set) var settingsReadCount = 0
        private(set) var settingsReturnCount = 0
        private(set) var authorizationReadCount = 0
        private(set) var authorizationRequestCount = 0
        private(set) var deliveryCount = 0

        init(settings: NotificationSettingsSnapshot, firstReadGate: SettingsReadGate? = nil) {
            self.settings = settings
            self.firstReadGate = firstReadGate
        }

        func authorizationStatus() async -> UNAuthorizationStatus {
            authorizationReadCount += 1
            return .authorized
        }

        func notificationSettings() async -> NotificationSettingsSnapshot {
            settingsReadCount += 1
            let result = settings
            if settingsReadCount == 1 { await firstReadGate?.hold() }
            settingsReturnCount += 1
            return result
        }

        func requestAuthorization() async throws -> Bool {
            authorizationRequestCount += 1
            return false
        }

        func deliver(_ notification: MeetingNotification) async throws {
            deliveryCount += 1
        }
    }

    @MainActor
    private final class SettingsReadGate {
        private var entry: CheckedContinuation<Bool, Never>?
        private var pendingResult: CheckedContinuation<Void, Never>?
        private var entered = false
        private var released = false
        private var operationFinished = false

        func waitForEntry() async -> Bool {
            if entered { return true }
            if operationFinished { return false }
            return await withCheckedContinuation { entry = $0 }
        }

        func hold() async {
            await withCheckedContinuation { continuation in
                entered = true
                pendingResult = continuation
                entry?.resume(returning: true)
                entry = nil
                if released { release() }
            }
        }

        func release() {
            released = true
            pendingResult?.resume()
            pendingResult = nil
        }

        func operationDidFinish() {
            operationFinished = true
            entry?.resume(returning: entered)
            entry = nil
        }
    }
}
