import AppKit
import Foundation

/// Pure policy for alert sounds (spec: product-spec.md "Sound" — optional
/// one-shot alert sound, optional urgent repeat near start).
enum AlertSoundPolicy {
    static func shouldPlayOnPresent(settings: AppSettingsSnapshot) -> Bool {
        settings.soundEnabled
    }

    /// The earliest upcoming danger point (start − 10s) among visible
    /// reminders, when the urgent repeat sound is enabled. Nil when disabled
    /// or all danger points have passed.
    static func urgentRepeatDate(
        reminders: [ScheduledReminder],
        settings: AppSettingsSnapshot,
        now: Date
    ) -> Date? {
        guard settings.soundEnabled, settings.urgentRepeatSoundEnabled else { return nil }
        return reminders
            .map { $0.event.startDate.addingTimeInterval(-ReminderScheduler.dangerPointOffset) }
            .filter { $0 > now }
            .min()
    }
}

protocol AlertSoundPlaying: Sendable {
    func playAlertSound()
}

struct SystemAlertSoundPlayer: AlertSoundPlaying {
    func playAlertSound() {
        // Distinct, non-jarring system sound; NSSound handles playback off-main.
        NSSound(named: "Glass")?.play()
    }
}
