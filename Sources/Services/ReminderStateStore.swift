import Foundation

struct OccurrenceReminderState: Codable, Equatable, Sendable {
    var occurrenceKey: OccurrenceKey
    var snoozedUntil: Date?
    var dismissedFingerprint: MaterialChangeFingerprint?
    var mutedUntilEventEnd: Bool
    var updatedAt: Date
}

final class ReminderStateStore: @unchecked Sendable {
    private var states: [OccurrenceKey: OccurrenceReminderState]
    private let fileURL: URL?
    private let lock = NSLock()

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([OccurrenceReminderState].self, from: data) {
            // Duplicate keys (corruption, older writers) must not trap; keep the newest entry.
            states = Dictionary(
                decoded.map { ($0.occurrenceKey, $0) },
                uniquingKeysWith: { first, second in
                    second.updatedAt >= first.updatedAt ? second : first
                }
            )
        } else {
            states = [:]
        }
    }

    func state(for key: OccurrenceKey) -> OccurrenceReminderState? {
        lock.withLock { states[key] }
    }

    func snooze(_ key: OccurrenceKey, until date: Date, now: Date = Date()) {
        lock.withLock {
            var state = states[key] ?? OccurrenceReminderState(
                occurrenceKey: key,
                snoozedUntil: nil,
                dismissedFingerprint: nil,
                mutedUntilEventEnd: false,
                updatedAt: now
            )
            state.snoozedUntil = date
            state.updatedAt = now
            states[key] = state
            persistLocked()
        }
    }

    func dismiss(_ key: OccurrenceKey, fingerprint: MaterialChangeFingerprint, now: Date = Date()) {
        lock.withLock {
            var state = states[key] ?? OccurrenceReminderState(
                occurrenceKey: key,
                snoozedUntil: nil,
                dismissedFingerprint: nil,
                mutedUntilEventEnd: false,
                updatedAt: now
            )
            state.dismissedFingerprint = fingerprint
            state.snoozedUntil = nil
            state.updatedAt = now
            states[key] = state
            persistLocked()
        }
    }

    func muteUntilEventEnd(_ key: OccurrenceKey, now: Date = Date()) {
        lock.withLock {
            var state = states[key] ?? OccurrenceReminderState(
                occurrenceKey: key,
                snoozedUntil: nil,
                dismissedFingerprint: nil,
                mutedUntilEventEnd: false,
                updatedAt: now
            )
            state.mutedUntilEventEnd = true
            state.updatedAt = now
            states[key] = state
            persistLocked()
        }
    }

    func clearSnooze(_ key: OccurrenceKey) {
        lock.withLock {
            guard var state = states[key] else { return }
            state.snoozedUntil = nil
            state.updatedAt = Date()
            states[key] = state
            persistLocked()
        }
    }

    func isDismissed(_ key: OccurrenceKey, currentFingerprint: MaterialChangeFingerprint) -> Bool {
        lock.withLock {
            states[key]?.dismissedFingerprint == currentFingerprint
        }
    }

    func prune(endedBefore cutoff: Date, activeKeys: Set<OccurrenceKey> = []) {
        lock.withLock {
            states = states.filter { key, state in
                activeKeys.contains(key) || state.updatedAt >= cutoff
            }
            persistLocked()
        }
    }

    private func persistLocked() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Array(states.values))
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Reminder state loss must not crash the app, but it must be visible:
            // lost dismissals mean repeat alerts after restart.
            AppLog.lifecycle.error("reminderStatePersistFailed error=\(LogPrivacy.errorClass(error), privacy: .public)")
        }
    }
}
