import Foundation

enum AppIdentity {
    static let displayName = "Meeting Shield"
    static let menuBarTitle = "Meeting Shield"
    static let bundleIdentifier = "com.skeptomenos.meetingshield"
    static let settingsWindowTitle = "Meeting Shield Settings"
    static let keychainServiceName = "com.skeptomenos.meetingshield.keychain"
    static let googleOAuthClientIDInfoKey = "MSGoogleOAuthClientID"
    static let googleOAuthClientSecretInfoKey = "MSGoogleOAuthClientSecret"
    static let googleCalendarBaseURL = URL(string: "https://www.googleapis.com/calendar/v3")!
    static let googleOAuthAuthorizeURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let googleOAuthTokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    static let googleScopes = [
        "https://www.googleapis.com/auth/calendar.events.readonly",
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    ]
}
