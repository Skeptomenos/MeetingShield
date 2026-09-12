import Foundation

final class DiagnosticsRecorder: @unchecked Sendable {
    enum Level: String, Sendable {
        case info
        case error
    }

    private enum StorageError: String, Error {
        case unsafeEntry = "diagnostic_unsafe_entry"
        case recordTooLarge = "diagnostic_record_too_large"
    }

    static let shared = DiagnosticsRecorder(directory: diagnosticsDirectory())
    static let disabled = DiagnosticsRecorder(directory: diagnosticsDirectory(), isEnabled: false)
    static var applicationDefault: DiagnosticsRecorder {
        recorder(for: Bundle.main.bundleURL)
    }
    static func recorder(for bundleURL: URL) -> DiagnosticsRecorder {
        bundleURL.pathExtension == "app" ? shared : disabled
    }
    static let maxRecordBytes = 2048
    static let maxFileBytes = 256 * 1024

    private let directory: URL
    private let nativeSink: @Sendable (Level, String) -> Void
    private let maxBytes: Int
    private let buildID: String
    private let sessionID: String
    private let now: @Sendable () -> Date
    private let isEnabled: Bool
    private let lock = NSLock()

    init(
        directory: URL,
        maxFileBytes: Int = DiagnosticsRecorder.maxFileBytes,
        nativeSink: @escaping @Sendable (Level, String) -> Void = AppLog.recordDiagnostic,
        buildID: String = DiagnosticsRecorder.currentBuildID,
        sessionID: UUID = UUID(),
        now: @escaping @Sendable () -> Date = { Date() },
        isEnabled: Bool = true
    ) {
        self.directory = directory
        self.maxBytes = max(1, min(maxFileBytes, Self.maxFileBytes))
        self.nativeSink = nativeSink
        self.buildID = Self.safeBuildID(buildID)
        self.sessionID = sessionID.uuidString.lowercased()
        self.now = now
        self.isEnabled = isEnabled
    }

    static func record(_ event: String, metadata: [String: String] = [:]) {
        applicationDefault.recordEvent(event, metadata: metadata)
    }

    func recordEvent(_ event: String, metadata: [String: String] = [:]) {
        guard isEnabled else { return }
        let safe = DiagnosticsSchema.sanitize(event, metadata: metadata)
        let level: Level = safe.event.hasSuffix("_failed") || safe.event == "diagnostic_rejected" ? .error : .info
        lock.lock()
        defer { lock.unlock() }
        do {
            let data = try encodedEntry(event: safe.event, metadata: safe.metadata, level: level)
            guard data.count <= Self.maxRecordBytes else { throw StorageError.recordTooLarge }
            nativeSink(level, String(decoding: data.dropLast(), as: UTF8.self))
            try write(data)
        } catch {
            if let data = try? encodedEntry(
                event: "diagnostic_write_failed",
                metadata: ["error": (error as? StorageError)?.rawValue ?? LogPrivacy.errorClass(error)],
                level: .error
            ) {
                nativeSink(.error, String(decoding: data.dropLast(), as: UTF8.self))
            }
        }
    }

    private func encodedEntry(event: String, metadata: [String: String], level: Level) throws -> Data {
        let entry = DiagnosticEntry(
            timestamp: ISO8601DateFormatter.stableString(from: now()),
            processID: Int(ProcessInfo.processInfo.processIdentifier),
            buildID: buildID,
            sessionID: sessionID,
            level: level.rawValue,
            event: event,
            metadata: metadata
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(entry) + Data([0x0A])
    }

    private func write(_ data: Data) throws {
        guard data.count <= maxBytes else { throw StorageError.recordTooLarge }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw StorageError.unsafeEntry }
        let current = directory.appending(path: "diagnostics.jsonl")
        let previous = directory.appending(path: "diagnostics.previous.jsonl")
        let currentSize = try regularFileSize(current)
        let previousSize = try regularFileSize(previous)

        if let previousSize, previousSize > maxBytes {
            try manager.removeItem(at: previous)
        }
        if let currentSize, currentSize > maxBytes {
            try data.write(to: current, options: .atomic)
            return
        }
        if let currentSize, currentSize + data.count > maxBytes {
            if manager.fileExists(atPath: previous.path) {
                try manager.removeItem(at: previous)
            }
            try manager.moveItem(at: current, to: previous)
            try data.write(to: current, options: .atomic)
            return
        }
        guard currentSize != nil else {
            try data.write(to: current, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: current)
        defer { try? handle.close() }
        let offset = try handle.seekToEnd()
        guard offset <= UInt64(maxBytes - data.count) else { throw StorageError.recordTooLarge }
        try handle.write(contentsOf: data)
    }

    private func regularFileSize(_ url: URL) throws -> Int? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
              let size = attributes[.size] as? NSNumber else { throw StorageError.unsafeEntry }
        return size.intValue
    }

    private static func diagnosticsDirectory() -> URL {
        URL.applicationSupportDirectory.appending(path: "MeetingShield")
    }

    private static var currentBuildID: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return version ?? "development"
    }

    private static func safeBuildID(_ value: String) -> String {
        let safe = value.prefix(64)
        guard !safe.isEmpty, safe.allSatisfy({ $0.isLetter || $0.isNumber || ".-_".contains($0) }) else {
            return "unknown"
        }
        return String(safe)
    }
}

private struct DiagnosticEntry: Encodable {
    var timestamp: String
    var processID: Int
    var buildID: String
    var sessionID: String
    var level: String
    var event: String
    var metadata: [String: String]
}
