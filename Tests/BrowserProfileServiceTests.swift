import Foundation
import Testing
@testable import MeetingShield

@Suite("Browser profile discovery")
struct BrowserProfileServiceTests {
    @Test("Chrome Arc and Chromium profiles are discovered from local profile roots")
    func discoversChromiumFamilyProfiles() throws {
        let home = try TestTempDirectory.make()
        try createProfile(home: home, relativePath: "Library/Application Support/Google/Chrome/Default")
        try createProfile(home: home, relativePath: "Library/Application Support/Google/Chrome/Profile 2")
        try createProfile(home: home, relativePath: "Library/Application Support/Arc/User Data/Profile 1")
        try createProfile(home: home, relativePath: "Library/Application Support/Chromium/Person 3")
        try createProfile(home: home, relativePath: "Library/Application Support/Chromium/System Profile")

        let service = BrowserProfileService(homeDirectory: home)

        #expect(service.profiles(for: .chrome).map(\.id) == ["Default", "Profile 2"])
        #expect(service.profiles(for: .arc).map(\.id) == ["Profile 1"])
        #expect(service.profiles(for: .chromium).map(\.id) == ["Person 3"])
        #expect(service.profiles(for: .safari).isEmpty)
        #expect(service.profiles(for: .systemDefault).isEmpty)
    }

    @Test("Browser selection ignores profiles for non-profile browsers")
    func resolveDropsProfileForSafariAndSystemDefault() {
        let service = BrowserProfileService()

        #expect(service.resolve(selection: BrowserSelection(browser: .safari, profileID: "Profile 1")).profileID == nil)
        #expect(service.resolve(selection: BrowserSelection(browser: .systemDefault, profileID: "Profile 1")).profileID == nil)
        #expect(service.resolve(selection: BrowserSelection(browser: .chrome, profileID: "Profile 1")).profileID == "Profile 1")
    }

    @Test("Profile display names come from the profile's Preferences JSON")
    func displayNamesFromPreferences() throws {
        let home = try TestTempDirectory.make()
        try createProfile(home: home, relativePath: "Library/Application Support/Google/Chrome/Default")
        try createProfile(home: home, relativePath: "Library/Application Support/Google/Chrome/Profile 2")
        try createProfile(home: home, relativePath: "Library/Application Support/Google/Chrome/Profile 3")
        let preferences = """
        { "profile": { "name": "Work (Acme)" } }
        """
        try preferences.write(
            to: home.appending(path: "Library/Application Support/Google/Chrome/Profile 2/Preferences"),
            atomically: true,
            encoding: .utf8
        )

        let service = BrowserProfileService(homeDirectory: home)
        let names = Dictionary(
            service.profiles(for: .chrome).map { ($0.id, $0.displayName) },
            uniquingKeysWith: { _, new in new }
        )

        #expect(names["Profile 2"] == "Work (Acme)")
        // Directory-name fallback when Preferences is missing or unreadable.
        #expect(names["Profile 3"] == "Profile 3")
        #expect(names["Default"] == "Default")
    }

    private func createProfile(home: URL, relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: home.appending(path: relativePath, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
    }
}
