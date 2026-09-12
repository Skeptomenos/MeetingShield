import Foundation

final class RuntimeRecordingBrowserLauncher: BrowserLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var openedURLs: [URL] = []
    private var failLaunches = false
    private var failedLaunchCount = 0

    var requests: [URL] { lock.withLock { openedURLs } }
    var failureCount: Int { lock.withLock { failedLaunchCount } }
    var shouldFail: Bool {
        get { lock.withLock { failLaunches } }
        set { lock.withLock { failLaunches = newValue } }
    }

    func open(_ url: URL, target: BrowserLaunchTarget) throws {
        guard url.host == "example.com", url.path.hasPrefix("/meeting-shield-demo/"),
              target.browser == .systemDefault else {
            throw CalendarProviderError.invalidResponse
        }
        try lock.withLock {
            if failLaunches {
                failedLaunchCount += 1
                throw MeetingLauncherError.launchFailed("Synthetic browser launch failed.")
            }
            openedURLs.append(url)
        }
    }
}
