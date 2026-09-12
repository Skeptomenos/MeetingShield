import Foundation
@testable import MeetingShield

final class DiagnosticTestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(DiagnosticsRecorder.Level, String)] = []

    func record(_ level: DiagnosticsRecorder.Level, _ payload: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((level, payload))
    }

    var payloads: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map(\.1)
    }

    var levels: [DiagnosticsRecorder.Level] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map(\.0)
    }

    func decodedStrings() throws -> [String] {
        try payloads.flatMap { payload in
            strings(in: try JSONSerialization.jsonObject(with: Data(payload.utf8)))
        }
    }

    private func strings(in value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { [$0.key] + strings(in: $0.value) }
        }
        if let array = value as? [Any] { return array.flatMap { strings(in: $0) } }
        return []
    }
}
