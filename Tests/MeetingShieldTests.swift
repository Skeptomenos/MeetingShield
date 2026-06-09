import Foundation
import Testing
@testable import MeetingShield

@Suite("Meeting Shield smoke tests")
struct MeetingShieldTests {
    @Test("App identity is stable")
    func appIdentityIsStable() {
        #expect(AppIdentity.displayName == "Meeting Shield")
        #expect(AppIdentity.googleScopes.allSatisfy { $0.contains("readonly") })
    }

    @Test("Disconnected provider is quiet by default")
    func disconnectedProviderIsQuiet() async throws {
        let provider = DisconnectedCalendarProvider()
        let now = TestDates.now
        let events = try await provider.events(in: CalendarFetchWindow(
            start: now.addingTimeInterval(-2 * 60 * 60),
            end: now.addingTimeInterval(24 * 60 * 60)
        ))

        #expect(await provider.authState == .disconnected)
        #expect(events.isEmpty)
    }

    @Test("Demo calendar mode requires explicit selection")
    func demoCalendarModeRequiresExplicitSelection() {
        #expect(MockCalendarFixtureMode.selected(arguments: ["MeetingShield"], environment: [:]) == nil)
        #expect(MockCalendarFixtureMode.selected(arguments: ["MeetingShield", "--demo-calendar"], environment: [:]) == .overlap)
        #expect(MockCalendarFixtureMode.selected(arguments: ["MeetingShield", "--demo-calendar", "single"], environment: [:]) == .single)
        #expect(MockCalendarFixtureMode.selected(arguments: ["MeetingShield"], environment: ["MEETING_SHIELD_DEMO_CALENDAR": "fallback"]) == .fallback)
    }

    @Test("Mock provider fixtures have stable timing")
    func mockProviderFixturesHaveStableTiming() async throws {
        let now = TestDates.now
        let provider = MockCalendarProvider(fixtureMode: .overlap, now: { now })
        let events = try await provider.events(in: CalendarFetchWindow(
            start: now.addingTimeInterval(-2 * 60 * 60),
            end: now.addingTimeInterval(24 * 60 * 60)
        ))

        #expect(events.map(\.title) == ["Design standup", "Customer escalation"])
        #expect(events[0].startDate == now.addingTimeInterval(95))
        #expect(events[1].startDate == now.addingTimeInterval(120))
    }
}
