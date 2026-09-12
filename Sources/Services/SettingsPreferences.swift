import CoreFoundation
import Foundation

@MainActor
struct SettingsPreferences {
    static let current = SettingsPreferences(applicationID: kCFPreferencesCurrentApplication)

    private let applicationID: CFString
    private let userName: CFString
    private let key = "meetingShield.settings.v1" as CFString

    init(domainName: String, userName: CFString = kCFPreferencesCurrentUser) {
        self.init(applicationID: domainName as CFString, userName: userName)
    }

    private init(applicationID: CFString, userName: CFString = kCFPreferencesCurrentUser) {
        self.applicationID = applicationID
        self.userName = userName
    }

    func read() -> Any? {
        CFPreferencesCopyValue(key, applicationID, userName, kCFPreferencesAnyHost)
    }

    func write(_ data: Data) -> Bool {
        CFPreferencesSetValue(key, data as CFData, applicationID, userName, kCFPreferencesAnyHost)
        return CFPreferencesSynchronize(applicationID, userName, kCFPreferencesAnyHost)
    }
}
