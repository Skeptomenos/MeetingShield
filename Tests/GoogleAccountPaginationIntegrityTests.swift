import Foundation
import Testing
@testable import MeetingShield

@Suite("Google account page integrity")
struct GoogleAccountPaginationIntegrityTests {
    @Test("Account snapshots require complete consistent event pages", arguments: Scenario.allCases)
    func completeConsistentPages(scenario: Scenario) async throws {
        let marker = "p14-pages-\(UUID().uuidString)"
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Meeting-Shield-Test": marker]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = GoogleOAuthClient(
            configuration: GoogleOAuthConfiguration(clientID: "\(marker)-client"),
            keychain: InMemoryKeychain(), session: session,
            diagnostics: DiagnosticsRecorder(directory: directory, nativeSink: { _, _ in })
        )
        var calendars: [UserCalendar] = []
        for suffix in ["a", "b"] {
            let accountID = "\(marker)-\(suffix)@example.invalid"
            let sourceID = "\(marker)-\(suffix)-calendar"
            try client.saveToken(GoogleOAuthToken(
                accessToken: "access-\(marker)-\(suffix)", refreshToken: nil,
                expiresAt: .distantFuture, scope: "calendar.readonly", tokenType: "Bearer",
                accountID: accountID, accountDisplayName: "Synthetic \(suffix)"
            ))
            calendars.append(UserCalendar(
                id: "\(accountID)::\(sourceID)", sourceCalendarID: sourceID,
                accountID: accountID, accountDisplayName: "Synthetic \(suffix)",
                displayName: "Synthetic calendar", isPrimary: true, isSelected: true
            ))
        }
        let first = try #require(calendars.first)
        let second = try #require(calendars.last)
        register(marker: marker, calendar: first, pageToken: nil, items: [event(id: "a-event")], next: nil)
        switch scenario {
        case .completeAtCap, .remainingAtCap:
            for index in 0..<40 {
                let current = index == 0 ? nil : "page-\(index)"
                let next = index == 39 && scenario == .completeAtCap ? nil : "page-\(index + 1)"
                register(marker: marker, calendar: second, pageToken: current, items: [event(id: "b-\(index)")], next: next)
            }
        case .repeatedToken:
            register(marker: marker, calendar: second, pageToken: nil, items: [event(id: "b-first")], next: "repeat")
            register(marker: marker, calendar: second, pageToken: "repeat", items: [event(id: "b-second")], next: "repeat")
        case .emptyToken:
            register(marker: marker, calendar: second, pageToken: nil, items: [event(id: "b-first")], next: "")
            register(marker: marker, calendar: second, pageToken: "", items: [event(id: "b-second")], next: nil)
        case .identicalRepeat, .conflictingRepeat, .cancelledRepeat:
            register(marker: marker, calendar: second, pageToken: nil, items: [event(id: "b-repeat")], next: "second")
            let secondItem: [String: Any]
            switch scenario {
            case .cancelledRepeat:
                secondItem = ["id": "b-repeat", "status": "cancelled"]
            case .conflictingRepeat:
                secondItem = event(id: "b-repeat", title: "Changed synthetic meeting")
            default:
                secondItem = event(id: "b-repeat")
            }
            register(marker: marker, calendar: second, pageToken: "second", items: [secondItem], next: nil)
        case .missingStart, .missingEnd, .invalidTimestamp:
            var item = event(id: "b-malformed")
            switch scenario {
            case .missingStart:
                item.removeValue(forKey: "start")
            case .missingEnd:
                item.removeValue(forKey: "end")
            default:
                item["start"] = ["dateTime": "not-a-timestamp"]
            }
            register(marker: marker, calendar: second, pageToken: nil, items: [item], next: nil)
        case .cancelledOnly:
            register(
                marker: marker, calendar: second, pageToken: nil,
                items: [["id": "b-cancelled", "status": "cancelled"]], next: nil
            )
        }
        let provider = GoogleCalendarProvider(oauthClient: client)
        let window = CalendarFetchWindow(start: TestDates.now, end: TestDates.now.addingTimeInterval(86_400))

        let refreshed = try await provider.refreshResult(in: window, calendars: calendars, accountIDs: Set(calendars.map(\.accountID)))

        guard case .accounts(let results) = refreshed else {
            Issue.record("Google did not return account-specific outcomes")
            return
        }
        #expect(results.count == 2)
        let healthy = try #require(results.first { $0.accountID == first.accountID })
        let value = try healthy.result.get()
        #expect(value.events.map(\.eventID) == ["a-event"])
        #expect(value.fetchedCalendarIDs == [first.id])
        #expect(value.window == window)
        let tested = try #require(results.first { $0.accountID == second.accountID })
        if scenario.isComplete {
            let snapshot = try tested.result.get()
            #expect(snapshot.events.count == scenario.expectedEventCount)
            #expect(Set(snapshot.events.map(\.eventID)).count == snapshot.events.count)
            #expect(snapshot.fetchedCalendarIDs == [second.id])
            #expect(snapshot.window == window)
        } else {
            guard case .failure = tested.result else {
                Issue.record("Incomplete, conflicting, or malformed pages were accepted as a complete account snapshot")
                return
            }
        }
        #expect(StubURLProtocol.unmatched.filter {
            $0.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker
        }.isEmpty)
    }

    enum Scenario: CaseIterable, Sendable {
        case completeAtCap
        case remainingAtCap
        case repeatedToken
        case emptyToken
        case identicalRepeat
        case conflictingRepeat
        case cancelledRepeat
        case missingStart
        case missingEnd
        case invalidTimestamp
        case cancelledOnly

        var isComplete: Bool {
            self == .completeAtCap || self == .identicalRepeat || self == .cancelledOnly
        }

        var expectedEventCount: Int {
            switch self {
            case .completeAtCap: 40
            case .cancelledOnly: 0
            default: 1
            }
        }
    }

    private func event(id: String, title: String = "Synthetic meeting") -> [String: Any] {
        [
            "id": id, "summary": title, "status": "confirmed",
            "start": ["dateTime": ISO8601DateFormatter.stableString(from: TestDates.start)],
            "end": ["dateTime": ISO8601DateFormatter.stableString(from: TestDates.start.addingTimeInterval(1800))]
        ]
    }

    private func register(
        marker: String, calendar: UserCalendar, pageToken: String?, items: [[String: Any]], next: String?
    ) {
        var page: [String: Any] = ["items": items]
        if let next { page["nextPageToken"] = next }
        do {
            let data = try JSONSerialization.data(withJSONObject: page, options: [.sortedKeys])
            StubURLProtocol.register(
                matcher: { request in
                    request.value(forHTTPHeaderField: "X-Meeting-Shield-Test") == marker
                        && request.url?.path.hasSuffix("/calendars/\(calendar.apiCalendarID)/events") == true
                        && request.queryValues["pageToken"] == pageToken
                },
                response: .init(statusCode: 200, body: data)
            )
        } catch {
            Issue.record("Synthetic JSON page could not be encoded")
        }
    }
}
