import Foundation

enum TestDates {
    static let now = Date(timeIntervalSince1970: 1_779_443_200)
    static let start = now.addingTimeInterval(10 * 60)
}

enum TestTempDirectory {
    static func make() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "MeetingShieldTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
