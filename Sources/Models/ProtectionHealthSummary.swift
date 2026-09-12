import Foundation

struct ProtectionHealthSummary: Equatable, Sendable {
    static let maximumCopyBytes = 2048
    static let schedulerDelayThreshold: TimeInterval = 120
    static let maximumCopiedAccounts = 8

    enum Level: String, Sendable {
        case healthy = "Healthy"
        case partial = "Needs attention"
        case unavailable = "Unavailable"
    }

    enum Connection: String, Sendable {
        case connected
        case connecting
        case disconnected
        case needsConfiguration
        case expired
    }

    enum Notification: String, Sendable {
        case notRequired = "Not required for current full-screen mode"
        case available = "Available"
        case unknown = "Unknown"
        case blocked = "Blocked"
    }

    enum Action: String, CaseIterable, Sendable {
        case retry = "Retry"
        case reconnect = "Reconnect"
        case settings = "Settings"
    }

    struct Account: Equatable, Sendable {
        enum State: String, Sendable {
            case protected
            case stale
            case unavailable
        }

        var accountID: String
        var state: State
    }

    struct Input: Sendable {
        var connection: Connection
        var accounts: [Account]
        var hasCalendarSelection: Bool
        var lastSuccessfulRefresh: Date?
        var oldestCoverage: Date?
        var refreshIssue: Bool
        var schedulerLastEvaluation: Date?
        var nextReminder: Date?
        var notification: Notification
        var storageWarningCount: Int
        var reconnectAccountIDs: Set<String> = []
        var requiresGenericReconnect = false
        var now: Date
    }

    var level: Level
    var title: String
    var coverageText: String
    var scheduleText: String
    var actions: [Action]
    var copyText: String

    static func derive(from input: Input) -> ProtectionHealthSummary {
        let protectedCount = input.accounts.count { $0.state != .unavailable }
        let hasStaleAccount = input.accounts.contains { $0.state == .stale }
        let schedulerDelayed = input.schedulerLastEvaluation.map {
            input.now.timeIntervalSince($0) > schedulerDelayThreshold
        } ?? true
        let connectionAvailable = input.connection == .connected
        let notificationNeedsAttention = input.notification == .blocked || input.notification == .unknown
        let storageWarningCount = max(0, input.storageWarningCount)
        let connectionNeedsReconnect = input.connection == .disconnected
            || input.connection == .needsConfiguration || input.connection == .expired
        let authorizationNeedsReconnect = connectionNeedsReconnect
            || !input.reconnectAccountIDs.isEmpty || input.requiresGenericReconnect

        let level: Level
        if !connectionAvailable || !input.hasCalendarSelection || protectedCount == 0 {
            level = .unavailable
        } else if protectedCount < input.accounts.count || hasStaleAccount || input.refreshIssue
            || schedulerDelayed || notificationNeedsAttention || storageWarningCount > 0 || authorizationNeedsReconnect {
            level = .partial
        } else {
            level = .healthy
        }

        let coverageText: String
        if protectedCount == 0 {
            coverageText = "No protected calendar coverage"
        } else {
            let noun = input.accounts.count == 1 ? "account" : "accounts"
            let age = input.oldestCoverage.map { ageLabel(from: $0, to: input.now) } ?? "unknown"
            coverageText = "\(protectedCount) of \(input.accounts.count) \(noun) protected · checked \(age) ago"
        }

        let nextReminder = input.nextReminder.map {
            "Next alert \(relativeLabel(from: input.now, to: $0))"
        } ?? "No alert scheduled"
        let scheduleText = "\(nextReminder) · scheduler \(schedulerDelayed ? "delayed" : "current")"
        let actions = actions(
            level: level,
            needsReconnect: authorizationNeedsReconnect,
            hasCalendarSelection: input.hasCalendarSelection,
            coverageNeedsRetry: protectedCount < input.accounts.count || hasStaleAccount || input.refreshIssue || schedulerDelayed,
            notificationNeedsSettings: notificationNeedsAttention,
            storageNeedsSettings: storageWarningCount > 0
        )
        let copyText = makeCopyText(
            input: input,
            level: level,
            protectedCount: protectedCount,
            schedulerDelayed: schedulerDelayed,
            storageWarningCount: storageWarningCount
        )
        return ProtectionHealthSummary(
            level: level,
            title: level == .healthy ? "Protection healthy" : level == .partial ? "Protection needs attention" : "Protection unavailable",
            coverageText: coverageText,
            scheduleText: scheduleText,
            actions: actions,
            copyText: copyText
        )
    }

    private static func actions(
        level: Level,
        needsReconnect: Bool,
        hasCalendarSelection: Bool,
        coverageNeedsRetry: Bool,
        notificationNeedsSettings: Bool,
        storageNeedsSettings: Bool
    ) -> [Action] {
        var result: [Action] = []
        if needsReconnect { result.append(.reconnect) }
        if level != .healthy && coverageNeedsRetry { result.append(.retry) }
        if !hasCalendarSelection || notificationNeedsSettings || storageNeedsSettings { result.append(.settings) }
        return result
    }

    private static func makeCopyText(
        input: Input,
        level: Level,
        protectedCount: Int,
        schedulerDelayed: Bool,
        storageWarningCount: Int
    ) -> String {
        let noun = input.accounts.count == 1 ? "account" : "accounts"
        var lines = [
            "Meeting Shield protection summary",
            "Status: \(level.rawValue)",
            "Connection: \(input.connection.rawValue)",
            authorizationLabel(input),
            "Calendar coverage: \(protectedCount) of \(input.accounts.count) selected \(noun)",
            "Last successful refresh: \(dateLabel(input.lastSuccessfulRefresh))",
            "Oldest protected coverage: \(dateLabel(input.oldestCoverage))",
            "Next reminder: \(dateLabel(input.nextReminder, missing: "None scheduled"))",
            "Scheduler last evaluation: \(dateLabel(input.schedulerLastEvaluation, missing: "Not observed")) (\(schedulerDelayed ? "delayed" : "current"))",
            "Notifications: \(input.notification.rawValue)",
            "Storage: \(storageWarningCount == 0 ? "Healthy" : "\(storageWarningCount) warning\(storageWarningCount == 1 ? "" : "s")")"
        ]
        for account in input.accounts
            .sorted(by: { first, second in
                let firstNeedsReconnect = input.reconnectAccountIDs.contains(first.accountID)
                let secondNeedsReconnect = input.reconnectAccountIDs.contains(second.accountID)
                if firstNeedsReconnect != secondNeedsReconnect { return firstNeedsReconnect }
                return LogPrivacy.redactedID(first.accountID) < LogPrivacy.redactedID(second.accountID)
            })
            .prefix(maximumCopiedAccounts) {
            let reconnect = input.reconnectAccountIDs.contains(account.accountID) ? "; reconnect required" : ""
            lines.append("Account \(LogPrivacy.redactedID(account.accountID)): \(account.state.rawValue)\(reconnect)")
        }
        let omitted = input.accounts.count - min(input.accounts.count, maximumCopiedAccounts)
        if omitted > 0 { lines.append("\(omitted) more accounts omitted") }
        lines.append("Visible delivery, Focus behavior, user attention, browser launch, and attendance are not observable here.")
        let output = lines.joined(separator: "\n")
        guard output.utf8.count > maximumCopyBytes else { return output }
        return String(decoding: output.utf8.prefix(maximumCopyBytes - 3), as: UTF8.self) + "..."
    }

    private static func authorizationLabel(_ input: Input) -> String {
        if !input.reconnectAccountIDs.isEmpty {
            let noun = input.reconnectAccountIDs.count == 1 ? "account" : "accounts"
            return "Authorization: Reconnect required for \(input.reconnectAccountIDs.count) \(noun)"
        }
        if input.requiresGenericReconnect || input.connection == .disconnected
            || input.connection == .needsConfiguration || input.connection == .expired {
            return "Authorization: Reconnect required"
        }
        return "Authorization: Current"
    }

    private static func dateLabel(_ date: Date?, missing: String = "Unavailable") -> String {
        date.map(ISO8601DateFormatter.stableString) ?? missing
    }

    private static func ageLabel(from date: Date, to now: Date) -> String {
        durationLabel(max(0, now.timeIntervalSince(date)))
    }

    private static func relativeLabel(from now: Date, to date: Date) -> String {
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return "due" }
        return "in \(durationLabel(interval))"
    }

    private static func durationLabel(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded(.down))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 60 * 60 { return "\(seconds / 60)m" }
        if seconds < 24 * 60 * 60 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }
}
