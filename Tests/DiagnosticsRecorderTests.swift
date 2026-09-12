import Foundation
import Testing
@testable import MeetingShield

@Suite("Diagnostic recorder boundaries")
struct DiagnosticsRecorderTests {
    private let canaries = [
        "private-title-canary-秘密",
        "privacy-canary@example.invalid",
        "https://example.invalid/private-link-canary",
        "Bearer private-token-canary",
        "private-response-body-canary"
    ]

    @Test("Actual file and native payload reject untrusted names, keys and values")
    func untrustedInputCannotReachEitherSink() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = DiagnosticTestCapture()
        let recorder = DiagnosticsRecorder(directory: directory, nativeSink: { capture.record($0, $1) })
        for canary in canaries {
            recorder.recordEvent(canary, metadata: [canary: canary])
            recorder.recordEvent("refresh_failed", metadata: ["reason": canary, "error": canary, canary: canary])
            recorder.recordEvent("join_requested", metadata: ["hasLinks": canary])
            recorder.recordEvent("recompute_finished", metadata: ["candidates": canary, "due": "-1", "scheduled": "1e99"])
        }
        recorder.recordEvent("refresh_failed", metadata: Dictionary(uniqueKeysWithValues: (0..<200).map {
            ("unknown_\($0)", String(repeating: "秘密-private-large-canary", count: 300))
        }))
        let data = try Data(contentsOf: directory.appending(path: "diagnostics.jsonl"))
        let fileLines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(fileLines == capture.payloads)
        let output = capture.payloads.joined(separator: "\n")
        let decoded = try capture.decodedStrings()
        for canary in canaries {
            #expect(!output.contains(canary))
            #expect(!decoded.contains { $0.contains(canary) })
        }
        #expect(!output.contains("private-large-canary"))
        for line in fileLines {
            #expect(line.utf8.count + 1 <= 2048)
            let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect((object["metadata"] as? [String: String])?.count ?? 0 <= 8)
            #expect((object["metadata"] as? [String: String])?.keys.contains { $0.hasPrefix("unknown_") } == false)
        }
    }

    @Test("Useful finite operational values survive both sinks")
    func usefulFieldsRemain() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = DiagnosticTestCapture()
        let recorder = DiagnosticsRecorder(directory: directory, nativeSink: { capture.record($0, $1) })
        recorder.recordEvent("refresh_failed", metadata: ["reason": "timer", "error": "NSURLErrorDomain.-1001", "failedCount": "2"])
        recorder.recordEvent("present_active_reminders", metadata: ["count": "3", "presentationMode": "false", "wakeGrace": "true"])
        recorder.recordEvent("scheduled_next_action", metadata: ["interval": "1.25"])
        let records = try readRecords(in: directory)
        #expect(records.count == 3)
        #expect(records[0].metadata == ["reason": "timer", "error": "NSURLErrorDomain.-1001", "failedCount": "2"])
        #expect(records[1].metadata == ["count": "3", "presentationMode": "false", "wakeGrace": "true"])
        #expect(records[2].metadata == ["interval": "1.25"])
        #expect(capture.levels == [.error, .info, .info])
    }

    @Test("Rotation accounts for encoded bytes including the line delimiter")
    func exactByteLimit() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DiagnosticsRecorder(directory: directory, nativeSink: { _, _ in })
        first.recordEvent("app_initialized")
        let current = directory.appending(path: "diagnostics.jsonl")
        let oneLine = try Data(contentsOf: current).count
        let recorder = DiagnosticsRecorder(directory: directory, maxFileBytes: oneLine * 2, nativeSink: { _, _ in })
        recorder.recordEvent("app_initialized")
        #expect(try Data(contentsOf: current).count == oneLine * 2)
        recorder.recordEvent("app_initialized")
        #expect(try Data(contentsOf: current).count == oneLine)
        #expect(try Data(contentsOf: directory.appending(path: "diagnostics.previous.jsonl")).count == oneLine * 2)
        #expect(try readRecords(in: directory).count == 3)
    }

    @Test("Repeated concurrent writes retain two bounded decodable files")
    func concurrentWritesStayBounded() async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = DiagnosticsRecorder(directory: directory, maxFileBytes: 1024, nativeSink: { _, _ in })
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { recorder.recordEvent("refresh_succeeded", metadata: ["reason": "timer", "calendars": "2", "events": "100"]) }
            }
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 2)
        for file in files {
            #expect(try Data(contentsOf: file).count <= 1024)
        }
        #expect(try readRecords(in: directory).count > 0)
    }

    @Test("Write failure reports a fixed code without private paths or recursion")
    func writeFailureIsSafe() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let obstruction = directory.appending(path: canaries[0])
        try Data("keep".utf8).write(to: obstruction)
        let capture = DiagnosticTestCapture()
        let recorder = DiagnosticsRecorder(directory: obstruction, nativeSink: { capture.record($0, $1) })
        recorder.recordEvent("app_initialized")
        #expect(capture.payloads.count == 2)
        #expect(capture.levels == [.info, .error])
        #expect(!capture.payloads.joined().contains(canaries[0]))
        #expect(try !capture.decodedStrings().contains { $0.contains(canaries[0]) })
        #expect(capture.payloads.last?.contains("diagnostic_write_failed") == true)
        #expect(try String(contentsOf: obstruction, encoding: .utf8) == "keep")
    }

    @Test("Obstructed rotation preserves unknown entries and refuses to grow")
    func rotationFailureDoesNotDestroyOrAppend() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DiagnosticsRecorder(directory: directory, nativeSink: { _, _ in })
        first.recordEvent("app_initialized")
        let current = directory.appending(path: "diagnostics.jsonl")
        let before = try Data(contentsOf: current)
        let previous = directory.appending(path: "diagnostics.previous.jsonl")
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: false)
        let marker = previous.appending(path: "keep")
        try Data("keep".utf8).write(to: marker)
        let capture = DiagnosticTestCapture()
        let recorder = DiagnosticsRecorder(directory: directory, maxFileBytes: before.count, nativeSink: { capture.record($0, $1) })
        recorder.recordEvent("app_initialized")
        #expect(try Data(contentsOf: current) == before)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(capture.payloads.last?.contains("diagnostic_write_failed") == true)
    }

    @Test("Existing symlink targets are never used for diagnostics")
    func symlinkDoesNotRedirectWrite() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "keep")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appending(path: "diagnostics.jsonl"), withDestinationURL: target)
        let capture = DiagnosticTestCapture()
        DiagnosticsRecorder(directory: directory, nativeSink: { capture.record($0, $1) }).recordEvent("app_initialized")
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        #expect(capture.payloads.last?.contains("diagnostic_write_failed") == true)
        #expect(capture.payloads.last?.contains("diagnostic_unsafe_entry") == true)
    }

    @Test("A record that cannot fit reports a specific safe refusal code")
    func recordTooLargeHasSafeCode() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = DiagnosticTestCapture()
        DiagnosticsRecorder(directory: directory, maxFileBytes: 1, nativeSink: { capture.record($0, $1) })
            .recordEvent("app_initialized")
        #expect(capture.payloads.last?.contains("diagnostic_record_too_large") == true)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "diagnostics.jsonl").path))
    }

    @Test("An oversized legacy log is replaced without retaining unbounded content")
    func oversizedLegacyLogIsBounded() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 0x41, count: 8192).write(to: directory.appending(path: "diagnostics.jsonl"))
        let recorder = DiagnosticsRecorder(directory: directory, maxFileBytes: 1024, nativeSink: { _, _ in })
        recorder.recordEvent("app_initialized")
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            #expect(try Data(contentsOf: file).count <= 1024)
        }
        #expect(try readRecords(in: directory).count == 1)
    }

    private func readRecords(in directory: URL) throws -> [Record] {
        try ["diagnostics.previous.jsonl", "diagnostics.jsonl"].flatMap { name in
            let url = directory.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else { return [Record]() }
            let data = try Data(contentsOf: url)
            return try data.split(separator: 0x0A).map { try JSONDecoder().decode(Record.self, from: Data($0)) }
        }
    }

    private struct Record: Decodable {
        let event: String
        let metadata: [String: String]
    }
}
