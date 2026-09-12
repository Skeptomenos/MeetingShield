import AppKit
import Foundation

enum AlertSoundPolicy {
    static func shouldPlayOnPresent(settings: AppSettingsSnapshot) -> Bool {
        settings.soundEnabled
    }

    static func urgentRepeatDate(
        reminders: [ScheduledReminder],
        settings: AppSettingsSnapshot,
        now: Date,
        pendingDate: Date? = nil
    ) -> Date? {
        guard settings.soundEnabled, settings.urgentRepeatSoundEnabled else { return nil }
        return reminders
            .filter { $0.event.endDate > now }
            .map { $0.event.startDate.addingTimeInterval(-ReminderScheduler.dangerPointOffset) }
            .filter { $0 > now || $0 == pendingDate }
            .min()
    }
}

protocol AlertSoundPlaying: Sendable {
    func playAlertSound()
}

struct SystemAlertSoundPlayer: AlertSoundPlaying {
    func playAlertSound() {
        NSSound(named: "Glass")?.play()
    }
}
