import Foundation
import Testing
@testable import MeetingShield

@Suite("Google API pagination")
struct GoogleCalendarPaginationTests {
    private let calendarPrefix = "pagination-\(UUID().uuidString)"

    @Test("Event fetch follows nextPageToken across all pages")
    func eventFetchFollowsNextPageToken() async throws {
        let calendarID = "\(calendarPrefix)-events"
        let session = StubURLProtocol.makeSession()
        let client = makeAuthedClient(session: session)
        let provider = GoogleCalendarProvider(oauthClient: client)
        let calendar = UserCalendar(
            id: "acct::\(calendarID)",
            sourceCalendarID: calendarID,
            accountID: "acct@example.com",
            accountDisplayName: "Acct",
            displayName: "Paginated",
            isPrimary: true,
            isSelected: true,
            colorHex: nil
        )

        StubURLProtocol.registerJSON(
            matcher: { request in
                request.url?.path.contains("calendars/\(calendarID)/events") == true
                    && request.queryValues["pageToken"] == nil
            },
            json: eventsPage(ids: ["page1-a", "page1-b"], nextPageToken: "token-page-2")
        )
        StubURLProtocol.registerJSON(
            matcher: { request in
                request.url?.path.contains("calendars/\(calendarID)/events") == true
                    && request.queryValues["pageToken"] == "token-page-2"
            },
            json: eventsPage(ids: ["page2-a"], nextPageToken: nil)
        )

        let window = CalendarFetchWindow(start: TestDates.now, end: TestDates.now.addingTimeInterval(86_400))
        let events = try await provider.refresh(in: window, calendars: [calendar])

        #expect(events.map(\.eventID).sorted() == ["page1-a", "page1-b", "page2-a"])
    }

    @Test("Calendar list follows nextPageToken across all pages")
    func calendarListFollowsNextPageToken() async throws {
        let marker = "\(calendarPrefix)-list"
        let session = StubURLProtocol.makeSession()
        let client = makeAuthedClient(session: session, accountID: "\(marker)@example.com")
        let provider = GoogleCalendarProvider(oauthClient: client)

        StubURLProtocol.registerJSON(
            matcher: { request in
                request.url?.path.contains("users/me/calendarList") == true
                    && request.queryValues["pageToken"] == nil
                    && self.requestBelongsToAccount(request, marker: marker)
            },
            json: calendarListPage(ids: ["\(marker)@example.com", "\(marker)-team"], nextPageToken: "list-page-2")
        )
        StubURLProtocol.registerJSON(
            matcher: { request in
                request.url?.path.contains("users/me/calendarList") == true
                    && request.queryValues["pageToken"] == "list-page-2"
                    && self.requestBelongsToAccount(request, marker: marker)
            },
            json: calendarListPage(ids: ["\(marker)-shared"], nextPageToken: nil)
        )

        let calendars = try await provider.calendars()

        #expect(calendars.count == 3)
        #expect(Set(calendars.compactMap(\.sourceCalendarID)) == [
            "\(marker)@example.com", "\(marker)-team", "\(marker)-shared"
        ])
    }

    private func requestBelongsToAccount(_ request: URLRequest, marker: String) -> Bool {
        request.value(forHTTPHeaderField: "Authorization")?.contains("access-\(marker)") == true
    }

    private func makeAuthedClient(session: URLSession, accountID: String = "acct@example.com") -> GoogleOAuthClient {
        let keychain = InMemoryKeychain()
        let client = GoogleOAuthClient(
            configuration: GoogleOAuthConfiguration(clientID: "client-id"),
            keychain: keychain,
            session: session
        )
        let marker = accountID.split(separator: "@").first.map(String.init) ?? accountID
        let token = GoogleOAuthToken(
            accessToken: "access-\(marker)",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600),
            scope: AppIdentity.googleScopes.joined(separator: " "),
            tokenType: "Bearer"
        )
        try? client.saveToken(token, accountID: accountID, accountDisplayName: "Acct")
        return client
    }

    private func eventsPage(ids: [String], nextPageToken: String?) -> String {
        let items = ids.map { id in
            """
            {
              "id": "\(id)",
              "status": "confirmed",
              "summary": "Event \(id)",
              "start": { "dateTime": "2026-06-11T10:00:00Z" },
              "end": { "dateTime": "2026-06-11T10:30:00Z" }
            }
            """
        }.joined(separator: ",")
        let tokenLine = nextPageToken.map { "\"nextPageToken\": \"\($0)\"," } ?? ""
        return "{ \(tokenLine) \"items\": [\(items)] }"
    }

    private func calendarListPage(ids: [String], nextPageToken: String?) -> String {
        let items = ids.map { id in
            """
            {
              "id": "\(id)",
              "summary": "Calendar \(id)",
              "primary": \(id.contains("@") ? "true" : "false")
            }
            """
        }.joined(separator: ",")
        let tokenLine = nextPageToken.map { "\"nextPageToken\": \"\($0)\"," } ?? ""
        return "{ \(tokenLine) \"items\": [\(items)] }"
    }
}
