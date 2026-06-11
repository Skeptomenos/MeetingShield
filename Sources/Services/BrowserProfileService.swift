import AppKit
import Foundation

struct BrowserLaunchTarget: Equatable, Sendable {
    var browser: BrowserKind
    var profileID: String?
    var bundleIdentifier: String?

    var displayName: String {
        if let profileID, browser.supportsProfileSelection {
            "\(browser.displayName) (\(profileID))"
        } else {
            browser.displayName
        }
    }
}

struct BrowserProfileService: @unchecked Sendable {
    var fileManager: FileManager
    var homeDirectory: URL

    init(fileManager: FileManager = .default, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    func resolve(selection: BrowserSelection) -> BrowserLaunchTarget {
        let browser = selection.browser
        return BrowserLaunchTarget(
            browser: browser,
            profileID: browser.supportsProfileSelection ? selection.profileID : nil,
            bundleIdentifier: browser.bundleIdentifier
        )
    }

    func profiles(for browser: BrowserKind) -> [BrowserProfile] {
        guard browser.supportsProfileSelection else { return [] }
        let root: URL
        switch browser {
        case .chrome:
            root = homeDirectory.appending(path: "Library/Application Support/Google/Chrome", directoryHint: .isDirectory)
        case .arc:
            root = homeDirectory.appending(path: "Library/Application Support/Arc/User Data", directoryHint: .isDirectory)
        case .chromium:
            root = homeDirectory.appending(path: "Library/Application Support/Chromium", directoryHint: .isDirectory)
        case .systemDefault, .safari:
            return []
        }

        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        return names
            .filter { name in
                name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("Person ")
            }
            .sorted()
            .map { name in
                BrowserProfile(
                    id: name,
                    displayName: profileDisplayName(for: name, root: root),
                    browser: browser,
                    localPath: root.appending(path: name, directoryHint: .isDirectory).path
                )
            }
    }

    func hasProfile(_ profileID: String, for browser: BrowserKind) -> Bool {
        profiles(for: browser).contains { $0.id == profileID }
    }

    /// Chromium-family profiles keep their human name in
    /// `<profile>/Preferences` under `profile.name`; the directory name
    /// ("Profile 2") is meaningless to users.
    private func profileDisplayName(for id: String, root: URL) -> String {
        let preferencesURL = root
            .appending(path: id, directoryHint: .isDirectory)
            .appending(path: "Preferences")
        guard
            let data = try? Data(contentsOf: preferencesURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let profile = json["profile"] as? [String: Any],
            let name = (profile["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        else {
            return id
        }
        return name
    }
}
