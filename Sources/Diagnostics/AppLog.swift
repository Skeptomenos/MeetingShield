import Foundation
import OSLog

enum AppLog {
    private static let fallbackSubsystem = "com.skeptomenos.meetingshield"

    static var subsystem: String {
        Bundle.main.bundleIdentifier ?? fallbackSubsystem
    }

    static let lifecycle = Logger(subsystem: subsystem, category: "Lifecycle")
    static let refresh = Logger(subsystem: subsystem, category: "Refresh")
    static let alert = Logger(subsystem: subsystem, category: "Alert")
    static let fallback = Logger(subsystem: subsystem, category: "Fallback")
    static let oauth = Logger(subsystem: subsystem, category: "OAuth")
    static let diagnostics = Logger(subsystem: subsystem, category: "Diagnostics")
}
