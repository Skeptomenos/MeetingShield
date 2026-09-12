import Foundation

@MainActor
protocol FullScreenAlertPresenting: AnyObject {
    var isShowing: Bool { get }

    func show(
        reminders: [ScheduledReminder],
        selectedID: String?,
        availableSnoozeChoices: @escaping (ScheduledReminder, Date) -> [SnoozeChoice],
        onJoin: @escaping (ScheduledReminder) -> Void,
        onSnooze: @escaping (ScheduledReminder, SnoozeChoice?) -> Void,
        onDismiss: @escaping (ScheduledReminder) -> Void,
        onRequestDismissal: @escaping (ScheduledReminder) -> Void,
        onMute: @escaping (ScheduledReminder) -> Void,
        onSnoozeAll: @escaping () -> Void
    )
    func update(reminders: [ScheduledReminder])
    func hide()
}
