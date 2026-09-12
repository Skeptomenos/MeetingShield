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

    @Test("A pending urgent deadline survives refresh before, at, and after its due time", arguments: [109.0, 110.0, 111.0, 130.0])
    func matchingPendingDeadlineSurvivesRefresh(nowOffset: TimeInterval) {
        let current = reminder("current", startOffset: 120)
        let pending = TestDates.now.addingTimeInterval(110)

        #expect(AlertSoundPolicy.urgentRepeatDate(
            reminders: [current],
            settings: settings(sound: true, urgentRepeat: true),
            now: TestDates.now.addingTimeInterval(nowOffset),
            pendingDate: pending
        ) == pending)
    }

    @Test("An earlier upcoming meeting replaces a later pending urgent deadline")
    func earlierFutureDeadlineReplacesLaterPendingDeadline() {
        let later = reminder("later", startOffset: 600)
        let arriving = reminder("arriving", startOffset: 120)

        #expect(AlertSoundPolicy.urgentRepeatDate(
            reminders: [later, arriving],
            settings: settings(sound: true, urgentRepeat: true),
            now: TestDates.now,
            pendingDate: TestDates.now.addingTimeInterval(590)
        ) == TestDates.now.addingTimeInterval(110))
    }

    @Test("Title and meeting link edits preserve the pending urgent deadline")
    func metadataEditPreservesPendingDeadline() throws {
        let original = reminder("edited", startOffset: 120)
        var edited = original
        edited.event.title = "Synthetic revised meeting"
        edited.detectedLinks = [MeetingLink(
            url: try #require(URL(string: "https://example.com/synthetic-revised-meeting")),
            kind: .generic,
            source: .conferenceMetadata
        )]
        let pending = TestDates.now.addingTimeInterval(110)

        #expect(edited.id == original.id)
        #expect(edited.event.startDate == original.event.startDate)
        #expect(AlertSoundPolicy.urgentRepeatDate(
            reminders: [edited],
            settings: settings(sound: true, urgentRepeat: true),
            now: TestDates.now.addingTimeInterval(111),
            pendingDate: pending
        ) == pending)
    }

    @Test("Removing the pending meeting selects another deadline or cancels the alarm", arguments: [100.0, 111.0])
    func removedSourceDoesNotPreservePendingDeadline(nowOffset: TimeInterval) {
        let remaining = reminder("remaining", startOffset: 600)
        let pending = TestDates.now.addingTimeInterval(110)
        let now = TestDates.now.addingTimeInterval(nowOffset)

        #expect(AlertSoundPolicy.urgentRepeatDate(
            reminders: [remaining],
            settings: settings(sound: true, urgentRepeat: true),
            now: now,
            pendingDate: pending
        ) == TestDates.now.addingTimeInterval(590))
        #expect(AlertSoundPolicy.urgentRepeatDate(
            reminders: [],
            settings: settings(sound: true, urgentRepeat: true),
            now: now,
            pendingDate: pending
        ) == nil)
    }

    @Test("Postponing the same occurrence replaces its pending deadline", arguments: [100.0, 111.0])
    func postponedSourceDoesNotPreservePendingDeadline(nowOffset: TimeInterval) {
        let original = reminder("postponed", startOffset: 120)
        var postponed = original
        postponed.event.startDate = TestDates.now.addingTimeInterval(600)

        #expect(postponed.id == original.id)
        #expect(AlertSoundPolicy.urgentRepeatDate(
            reminders: [postponed],
            settings: settings(sound: true, urgentRepeat: true),
            now: TestDates.now.addingTimeInterval(nowOffset),
            pendingDate: TestDates.now.addingTimeInterval(110)
        ) == TestDates.now.addingTimeInterval(590))
    }

    @Test("An ended occurrence cannot retain its pending urgent deadline", arguments: [0.0, -1.0])
    func endedSourceDoesNotPreservePendingDeadline(endOffset: TimeInterval) {
        var ended = reminder("ended", startOffset: -120)
        ended.event.endDate = TestDates.now.addingTimeInterval(endOffset)
        let remaining = reminder("remaining", startOffset: 120)
        let pending = TestDates.now.addingTimeInterval(-130)

        #expect(AlertSoundPolicy.urgentRepeatDate(
            reminders: [ended],
            settings: settings(sound: true, urgentRepeat: true),
            now: TestDates.now,
            pendingDate: pending
        ) == nil)
        #expect(AlertSoundPolicy.urgentRepeatDate(
            reminders: [ended, remaining],
            settings: settings(sound: true, urgentRepeat: true),
            now: TestDates.now,
            pendingDate: pending
        ) == TestDates.now.addingTimeInterval(110))
    }

    @Test("Disabling sound or urgent repeat cancels a pending deadline", arguments: [109.0, 111.0])
    func disabledSoundCancelsPendingDeadline(nowOffset: TimeInterval) {
        let reminders = [reminder("current", startOffset: 120)]
        let pending = TestDates.now.addingTimeInterval(110)
        let now = TestDates.now.addingTimeInterval(nowOffset)

        #expect(AlertSoundPolicy.urgentRepeatDate(
            reminders: reminders,
            settings: settings(sound: false, urgentRepeat: true),
            now: now,
            pendingDate: pending
        ) == nil)
        #expect(AlertSoundPolicy.urgentRepeatDate(
            reminders: reminders,
            settings: settings(sound: true, urgentRepeat: false),
            now: now,
            pendingDate: pending
        ) == nil)
    }
}
