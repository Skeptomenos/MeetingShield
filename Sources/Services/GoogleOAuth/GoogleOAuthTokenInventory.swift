import Foundation

struct GoogleOAuthTokenInventory: Sendable {
    var tokens: [GoogleOAuthToken]
    var knownAccountIDs: Set<String>
    var failure: CalendarAccountFailure?

    var isComplete: Bool {
        failure == nil
    }
}
