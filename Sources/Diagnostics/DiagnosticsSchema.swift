import Foundation

enum DiagnosticsSchema {
    private enum Field {
        case count
        case duration
        case boolean
        case reason
        case error
        case oauth
        case status
        case choice
        case identifier
        case timestamp
        case decision
        case outcome
        case refreshOutcome

        func sanitize(_ value: String) -> String? {
            guard value.utf8.count <= 120 else { return nil }
            switch self {
            case .count:
                guard let number = Int(value), (0...1_000_000_000).contains(number), String(number) == value else { return nil }
                return value
            case .duration:
                guard let number = Double(value), number.isFinite, (0...604_800).contains(number) else { return nil }
                return String(number)
            case .boolean:
                return ["true", "false"].contains(value) ? value : nil
            case .reason:
                return LogPrivacy.refreshReason(value)
            case .error:
                return LogPrivacy.safeErrorCode(value)
            case .oauth:
                return LogPrivacy.oauthErrorCode(value)
            case .status:
                guard let number = Int(value), (100...599).contains(number), String(number) == value else { return "unknown" }
                return value
            case .choice:
                return ["seconds", "until_danger_point"].contains(value) ? value : "unknown"
            case .identifier:
                if let identifier = UUID(uuidString: value), identifier.uuidString.lowercased() == value.lowercased() {
                    return value.lowercased()
                }
                let parts = value.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 2,
                      ["id", "set"].contains(String(parts[0])),
                      parts[1].count == 12,
                      parts[1].allSatisfy({ $0.isHexDigit }) else { return nil }
                return value.lowercased()
            case .timestamp:
                guard ISO8601DateFormatter.stableDate(from: value) != nil else { return nil }
                return value
            case .decision:
                return reminderDecisions.contains(value) ? value : nil
            case .outcome:
                return reminderOutcomes.contains(value) ? value : nil
            case .refreshOutcome:
                return ["cancelled", "obsolete"].contains(value) ? value : nil
            }
        }

        private var reminderDecisions: Set<String> {
            [
                "cancelled", "unselected_calendar", "calendar_disabled", "invalid_time", "all_day",
                "event_type_excluded", "rsvp_excluded", "free_excluded", "rule_suppressed", "dismissed",
                "ended", "muted", "acknowledged", "scheduled", "snoozed", "due", "grouped_duplicate",
                "removed", "unknown"
            ]
        }

        private var reminderOutcomes: Set<String> {
            [
                "notification_submitted", "notification_failed", "channel_unavailable", "response_received",
                "window_constructed", "window_updated", "window_closed", "window_unavailable",
                "launch_accepted", "launch_failed", "snooze_accepted", "dismiss_accepted", "mute_accepted"
            ]
        }
    }

    static func sanitize(_ event: String, metadata: [String: String]) -> (event: String, metadata: [String: String]) {
        guard let fields = fields(for: event) else {
            return ("diagnostic_rejected", ["reason": "unknown_event"])
        }
        var safe: [String: String] = [:]
        for (key, field) in fields {
            if let value = metadata[key], let sanitized = field.sanitize(value) {
                safe[key] = sanitized
            }
        }
        return (event, safe)
    }

    private static func fields(for event: String) -> [String: Field]? {
        switch event {
        case "app_initialized", "launch_complete", "termination_requested", "application_will_terminate",
             "controller_start", "controller_stop", "wake_grace_started", "network_returned",
             "dismiss_requested", "mute_requested", "join_fallback_window_hide", "legacy_state_cache_deferred":
            [:]
        case "refresh_started":
            ["reason": .reason, "operation": .identifier, "evaluated": .timestamp]
        case "refresh_succeeded":
            ["reason": .reason, "calendars": .count, "events": .count, "operation": .identifier,
             "duration": .duration, "evaluated": .timestamp]
        case "refresh_failed":
            ["reason": .reason, "error": .error, "failedCount": .count, "operation": .identifier,
             "duration": .duration, "evaluated": .timestamp]
        case "refresh_abandoned":
            ["reason": .reason, "outcome": .refreshOutcome, "operation": .identifier,
             "duration": .duration, "evaluated": .timestamp]
        case "legacy_state_migration":
            ["resolved": .count, "unresolved": .count, "expired": .count]
        case "join_failed", "cache_save_failed", "cache_load_failed":
            ["error": .error]
        case "oauth_authorization_failed":
            ["code": .oauth]
        case "oauth_token_failed":
            ["code": .oauth, "status": .status]
        case "notification_delivery_failed":
            ["count": .count]
        case "join_requested":
            ["hasLinks": .boolean]
        case "snooze_requested":
            ["choice": .choice, "seconds": .duration]
        case "recompute_started":
            ["events": .count]
        case "recompute_finished":
            ["candidates": .count, "scheduled": .count, "due": .count]
        case "present_active_reminders":
            ["count": .count, "presentationMode": .boolean, "wakeGrace": .boolean]
        case "scheduled_next_action":
            ["interval": .duration]
        case "fallback_show", "join_fallback_window_show":
            ["hasWarning": .boolean]
        case "fullscreen_alert_show":
            ["reminders": .count, "screens": .count]
        case "fullscreen_alert_update":
            ["reminders": .count, "windows": .count]
        case "fullscreen_alert_hide":
            ["windows": .count]
        case "reminder_decision":
            ["operation": .identifier, "occurrence": .identifier, "account": .identifier,
             "reason": .decision, "target": .timestamp, "evaluated": .timestamp]
        case "reminder_timer_scheduled":
            ["operation": .identifier, "target": .timestamp, "evaluated": .timestamp]
        case "reminder_timer_fired":
            ["operation": .identifier, "target": .timestamp, "actual": .timestamp, "delay": .duration]
        case "reminder_presentation", "reminder_notification", "reminder_action":
            ["operation": .identifier, "occurrence": .identifier, "outcome": .outcome, "evaluated": .timestamp]
        default:
            nil
        }
    }
}
