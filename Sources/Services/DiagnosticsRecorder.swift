import Foundation
import OSLog

enum DiagnosticsRecorder {
    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "diagnostics")
    private static let lock = NSLock()
    private static let maxBytes = 256 * 1024
    private static let fileName = "diagnostics.jsonl"
    private static let rotatedFileName = "diagnostics.previous.jsonl"

    static func record(_ event: String, metadata: [String: String] = [:]) {
        let sanitized = metadata
            .filter { !$0.key.isEmpty && !$0.value.isEmpty }
            .reduce(into: [String: String]()) { result, pair in
                result[pair.key] = String(pair.value.prefix(120))
            }

        logger.info("\(event, privacy: .public) \(sanitized.description, privacy: .public)")
        let entry = DiagnosticEntry(
            timestamp: ISO8601DateFormatter.stableString(from: Date()),
            processID: Int(ProcessInfo.processInfo.processIdentifier),
            event: event,
            metadata: sanitized
        )

        lock.lock()
        defer { lock.unlock() }
        write(entry)
    }

    private static func write(_ entry: DiagnosticEntry) {
        do {
            let directory = diagnosticsDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: fileName)
            rotateIfNeeded(url)
            let data = try JSONEncoder().encode(entry) + Data([0x0A])
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            handle.closeFile()
        } catch {
            logger.error("diagnostic write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func diagnosticsDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MeetingShield")
    }

    private static func rotateIfNeeded(_ url: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              size.intValue > maxBytes else {
            return
        }
        let rotatedURL = url.deletingLastPathComponent().appending(path: rotatedFileName)
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: url, to: rotatedURL)
    }
}

private struct DiagnosticEntry: Encodable {
    var timestamp: String
    var processID: Int
    var event: String
    var metadata: [String: String]
}
