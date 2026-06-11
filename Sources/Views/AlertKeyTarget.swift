import Foundation

/// Shared selection state between the full-screen alert UI (overlap chips) and
/// the keyboard handlers. Key actions (Enter = join, S = snooze) must resolve
/// the reminder at keypress time — capturing `reminders[0]` at install time
/// made shortcuts act on the wrong meeting when the user selected another
/// overlapping reminder.
@MainActor
final class AlertKeyTarget: ObservableObject {
    @Published var selectedID: ScheduledReminder.ID?
    @Published private(set) var reminders: [ScheduledReminder]

    init(reminders: [ScheduledReminder]) {
        self.reminders = reminders
        self.selectedID = reminders.first?.id
    }

    var selectedReminder: ScheduledReminder? {
        reminders.first { $0.id == selectedID } ?? reminders.first
    }

    func update(reminders: [ScheduledReminder]) {
        self.reminders = reminders
        if !reminders.contains(where: { $0.id == selectedID }) {
            selectedID = reminders.first?.id
        }
    }
}
