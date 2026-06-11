import Foundation
import Testing
@testable import MeetingShield

@Suite("Alert sound policy")
struct AlertSoundPolicyTests {
    private func reminder(_ id: String, startOffset: TimeInterval) -> ScheduledReminder {
        ScheduledReminder(
            event: .sample(eventID: id, title: id, startDate: TestDates.now.addingTimeInterval(startOffset)),
            detectedLinks: [],
            fireDate: TestDates.now,
            browserSelection: .systemDefault,
            isSnoozed: false
        )
    }

    private func settings(sound: Bool, urgentRepeat: Bool) -> AppSettingsSnapshot {
        var snapshot = AppSettingsSnapshot.defaults
        snapshot.soundEnabled = sound
        snapshot.urgentRepeatSoundEnabled = urgentRepeat
        return snapshot
    }

    @Test("Present sound follows the sound setting")
    func presentSoundFollowsSetting() {
        #expect(AlertSoundPolicy.shouldPlayOnPresent(settings: settings(sound: true, urgentRepeat: false)))
        #expect(!AlertSoundPolicy.shouldPlayOnPresent(settings: settings(sound: false, urgentRepeat: true)))
    }

    @Test("Urgent repeat fires at the earliest upcoming danger point")
    func urgentRepeatAtEarliestDangerPoint() {
        let reminders = [reminder("later", startOffset: 600), reminder("sooner", startOffset: 120)]

        let date = AlertSoundPolicy.urgentRepeatDate(
            reminders: reminders,
            settings: settings(sound: true, urgentRepeat: true),
            now: TestDates.now
        )

        // Danger point = start - 10s of the soonest meeting.
        #expect(date == TestDates.now.addingTimeInterval(120 - 10))
    }

    @Test("No urgent repeat when disabled, sound off, or danger point passed")
    func urgentRepeatGuards() {
        let upcoming = [reminder("a", startOffset: 120)]
        let started = [reminder("b", startOffset: 5)]

        #expect(AlertSoundPolicy.urgentRepeatDate(reminders: upcoming, settings: settings(sound: true, urgentRepeat: false), now: TestDates.now) == nil)
        #expect(AlertSoundPolicy.urgentRepeatDate(reminders: upcoming, settings: settings(sound: false, urgentRepeat: true), now: TestDates.now) == nil)
        #expect(AlertSoundPolicy.urgentRepeatDate(reminders: started, settings: settings(sound: true, urgentRepeat: true), now: TestDates.now) == nil)
    }
}
