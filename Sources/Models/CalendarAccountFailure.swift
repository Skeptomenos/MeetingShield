import Foundation

struct CalendarAccountFailure: Error, Sendable {
    let errorClass: String
    let authorizationExpired: Bool

    init(_ error: Error) {
        errorClass = LogPrivacy.errorClass(error)
        if case CalendarProviderError.authExpired = error {
            authorizationExpired = true
        } else {
            authorizationExpired = false
        }
    }
}
