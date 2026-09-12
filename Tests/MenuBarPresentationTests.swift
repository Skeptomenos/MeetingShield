import Foundation
import Testing
@testable import MeetingShield

@Suite("Menu bar presentation")
struct MenuBarPresentationTests {
    @Test("Long event titles are truncated before entering the menu bar")
    func longTitlesAreTruncated() {
        let longTitle = String(repeating: "Privacy safe title ", count: 8)
        let event = CalendarEventOccurrence.sample(
            eventID: "long-title",
            title: longTitle,
            startDate: TestDates.now.addingTimeInterval(600)
        )

        let presentation = MenuBarText.make(
            event: event,
            now: TestDates.now,
            showEventTitle: true
        )

        let expectedTitle = String(longTitle.prefix(MenuBarText.maximumTitleCharacters - 1)) + "…"
        #expect(presentation.preferred == "\(presentation.fallback) \(expectedTitle)")
        #expect(expectedTitle.count == MenuBarText.maximumTitleCharacters)
        #expect(!presentation.preferred.contains(longTitle))
    }

    @Test("Privacy mode exposes only the countdown")
    func privacyModeUsesCountdownOnly() {
        let title = "Private acquisition review"
        let event = CalendarEventOccurrence.sample(
            eventID: "private-title",
            title: title,
            startDate: TestDates.now.addingTimeInterval(600)
        )

        let presentation = MenuBarText.make(
            event: event,
            now: TestDates.now,
            showEventTitle: false
        )

        #expect(presentation.preferred == presentation.fallback)
        #expect(!presentation.preferred.contains(title))
    }

    @Test("A tight menu bar falls back to the countdown")
    func tightSpaceUsesCountdownFallback() {
        let event = CalendarEventOccurrence.sample(
            eventID: "width",
            title: "Design review",
            startDate: TestDates.now.addingTimeInterval(600)
        )
        let presentation = MenuBarText.make(
            event: event,
            now: TestDates.now,
            showEventTitle: true
        )

        #expect(presentation.resolved(maximumWidth: 100, measure: { _ in 101 }) == presentation.fallback)
        #expect(presentation.resolved(maximumWidth: 100, measure: { _ in 99 }) == presentation.preferred)
    }

    @MainActor
    @Test("Disconnected state uses the disconnected icon")
    func disconnectedStateUsesDisconnectedIcon() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let domain = "MenuBarPresentationTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let controller = MeetingShieldController(
            settingsStore: AppSettingsStore(domainName: domain),
            provider: DisconnectedCalendarProvider(),
            reminderStateStore: ReminderStateStore(fileURL: directory.appending(path: "state.json")),
            cacheStore: EventCacheStore(fileURL: directory.appending(path: "cache.json")),
            refreshMenuBar: {}
        )

        #expect(controller.authState == .disconnected)
        #expect(controller.menuBarSystemImage == "exclamationmark.triangle.fill")
    }
}
