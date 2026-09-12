import Foundation

struct OccurrenceReminderState: Codable, Equatable, Sendable {
    struct Acknowledgement: Codable, Equatable, Sendable {
        var fingerprint: MaterialChangeFingerprint
        var eventEnd: Date
    }

    var occurrenceKey: OccurrenceKey
    var snoozedUntil: Date?
    var dismissedFingerprint: MaterialChangeFingerprint?
    var mutedUntilEventEnd: Bool
    var updatedAt: Date
    var legacyRecoveryDeadline: Date? = nil
    var legacyMigrationBlocked: Bool? = nil
    var legacyObservedSource: OccurrenceKey? = nil
    var acknowledgement: Acknowledgement? = nil
}

final class ReminderStateStore: @unchecked Sendable {
    typealias StateReader = @Sendable (URL) -> Result<[OccurrenceKey: OccurrenceReminderState], PersistenceFailure>
    struct MigrationResult: Equatable, Sendable {
        var resolvedCount: Int
        var unresolvedCount: Int
        var expiredCount: Int
    }

    private var states: [OccurrenceKey: OccurrenceReminderState]
    private let fileURL: URL?
    private let diagnostics: DiagnosticsRecorder
    private let lock = NSLock()
    private let recoveryLock = NSLock()
    private let recoveryReader: StateReader
    private var hasPendingPersistence = false
    private var failure: PersistenceFailure?
    private var needsRecovery = false
    private var locallyChangedKeys: Set<OccurrenceKey> = []

    init(
        fileURL: URL? = nil,
        diagnostics: DiagnosticsRecorder = .shared,
        recoveryReader: StateReader? = nil
    ) {
        self.fileURL = fileURL
        self.diagnostics = diagnostics
        self.recoveryReader = recoveryReader ?? Self.readStates
        states = [:]
        guard let fileURL else { return }
        switch Self.readStates(fileURL) {
        case .success(let saved):
            states = saved
        case .failure(let failure):
            needsRecovery = true
            hasPendingPersistence = true
            setFailureLocked(failure)
        }
    }

    func state(for key: OccurrenceKey) -> OccurrenceReminderState? {
        lock.withLock { states[key] }
    }

    var unresolvedLegacyCount: Int {
        lock.withLock { states.keys.filter { !$0.isScoped }.count }
    }

    var isPersistencePending: Bool {
        lock.withLock { hasPendingPersistence }
    }

    var persistenceFailure: PersistenceFailure? {
        lock.withLock { failure }
    }

    @discardableResult
    nonisolated func retryPersistence() async -> Bool {
        // Nonisolated async work runs on the generic executor. Serialize recovery attempts,
        // but release the state lock during reads so UI actions can record newer intent.
        recoveryLock.withLock {
            let recoveryURL = lock.withLock { needsRecovery ? fileURL : nil }
            let recovered = recoveryURL.map(recoveryReader)
            return lock.withLock {
                if needsRecovery, let recovered {
                    switch recovered {
                    case .success(var recovered):
                        for key in locallyChangedKeys {
                            recovered[key] = states[key]
                        }
                        states = recovered
                        needsRecovery = false
                    case .failure(let failure):
                        setFailureLocked(failure)
                        return false
                    }
                }
                persistLocked()
                return !hasPendingPersistence
            }
        }
    }

    func reconcileLegacyStates(
        events: [CalendarEventOccurrence],
        cachedEvents: [CalendarEventOccurrence] = [],
        now: Date = Date()
    ) -> MigrationResult {
        lock.withLock {
            let legacyKeys = states.keys.filter { !$0.isScoped }
            var result = MigrationResult(resolvedCount: 0, unresolvedCount: 0, expiredCount: 0)
            guard !legacyKeys.isEmpty else {
                if hasPendingPersistence { persistLocked() }
                return result
            }
            let candidates = Dictionary(grouping: events + cachedEvents) { $0.occurrenceKey.legacyKey }
            let extractor = MeetingLinkExtractor()
            var changed = false
            for key in legacyKeys {
                guard var state = states[key] else { continue }
                let previous = state
                let deadline = state.legacyRecoveryDeadline ?? now.addingTimeInterval(8 * 24 * 60 * 60)
                state.legacyRecoveryDeadline = deadline
                if deadline <= now {
                    states.removeValue(forKey: key)
                    result.expiredCount += 1
                    changed = true
                    continue
                }
                if !key.isLegacy || state.snoozedUntil != nil || state.mutedUntilEventEnd || state.acknowledgement != nil {
                    state.legacyMigrationBlocked = true
                }
                if state.legacyMigrationBlocked != true, let fingerprint = state.dismissedFingerprint {
                    let sourceEvents = candidates[key] ?? []
                    var sourceKeys = Set(sourceEvents.map(\.occurrenceKey))
                    if let observedSource = state.legacyObservedSource {
                        sourceKeys.insert(observedSource)
                    }
                    if sourceKeys.count == 1 {
                        state.legacyObservedSource = sourceKeys.first
                    }
                    let matchingKeys = Set(sourceEvents.compactMap { event -> OccurrenceKey? in
                        let links = extractor.extractLinks(from: event)
                        return event.materialFingerprint(detectedLinks: links) == fingerprint ? event.occurrenceKey : nil
                    })
                    if sourceKeys.count == 1, let target = matchingKeys.first {
                        if states[target] == nil {
                            state.occurrenceKey = target
                            state.legacyRecoveryDeadline = nil
                            state.legacyMigrationBlocked = nil
                            state.legacyObservedSource = nil
                            states[target] = state
                        }
                        states.removeValue(forKey: key)
                        result.resolvedCount += 1
                        changed = true
                        continue
                    }
                    if sourceKeys.count > 1 {
                        state.legacyMigrationBlocked = true
                    }
                }
                states[key] = state
                result.unresolvedCount += 1
                changed = changed || state != previous
            }
            if changed || hasPendingPersistence {
                persistLocked()
            }
            if changed {
                diagnostics.recordEvent("legacy_state_migration", metadata: [
                    "resolved": "\(result.resolvedCount)",
                    "unresolved": "\(result.unresolvedCount)",
                    "expired": "\(result.expiredCount)"
                ])
            }
            return result
        }
    }

    func acknowledge(
        _ key: OccurrenceKey,
        fingerprint: MaterialChangeFingerprint,
        eventEnd: Date,
        now: Date = Date()
    ) {
        guard key.isScoped, eventEnd > now else { return }
        lock.withLock {
            var state = states[key] ?? OccurrenceReminderState(
                occurrenceKey: key,
                snoozedUntil: nil,
                dismissedFingerprint: nil,
                mutedUntilEventEnd: false,
                updatedAt: now
            )
            state.acknowledgement = .init(fingerprint: fingerprint, eventEnd: eventEnd)
            state.updatedAt = now
            states[key] = state
            persistLocked()
        }
    }

    func isAcknowledged(
        _ key: OccurrenceKey,
        currentFingerprint: MaterialChangeFingerprint,
        now: Date
    ) -> Bool {
        lock.withLock {
            guard key.isScoped, let acknowledgement = states[key]?.acknowledgement else { return false }
            return acknowledgement.eventEnd > now && acknowledgement.fingerprint == currentFingerprint
        }
    }

    func clearAcknowledgement(_ key: OccurrenceKey, now: Date = Date()) {
        guard key.isScoped else { return }
        lock.withLock {
            guard var state = states[key], state.acknowledgement != nil else {
                if hasPendingPersistence { persistLocked() }
                return
            }
            state.acknowledgement = nil
            state.updatedAt = now
            states[key] = state
            persistLocked()
        }
    }

    func reconcileAcknowledgements(events: [CalendarEventOccurrence], now: Date) {
        lock.withLock {
            let eventsByKey = Dictionary(grouping: events, by: \.occurrenceKey)
            let acknowledgedKeys = states.compactMap { key, state in
                key.isScoped && state.acknowledgement != nil ? key : nil
            }
            let extractor = MeetingLinkExtractor()
            var changed = false
            for key in acknowledgedKeys {
                guard var state = states[key], let acknowledgement = state.acknowledgement else { continue }
                let materialChanged = (eventsByKey[key] ?? []).contains { event in
                    event.materialFingerprint(detectedLinks: extractor.extractLinks(from: event)) != acknowledgement.fingerprint
                }
                guard acknowledgement.eventEnd <= now || materialChanged else { continue }
                state.acknowledgement = nil
                state.updatedAt = now
                states[key] = state
                changed = true
            }
            if changed || hasPendingPersistence {
                persistLocked()
            }
        }
    }

    func nextAcknowledgementExpiry(after now: Date) -> Date? {
        lock.withLock {
            states.compactMap { key, state -> Date? in
                guard key.isScoped, let end = state.acknowledgement?.eventEnd, end > now else { return nil }
                return end
            }.min()
        }
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

    func reconcileSnoozes(events: [CalendarEventOccurrence], now: Date) {
        lock.withLock {
            var changed = false
            for event in events where event.endDate > now && event.occurrenceKey.isScoped {
                let key = event.occurrenceKey
                guard var state = states[key], let snoozedUntil = state.snoozedUntil else { continue }
                let deadline = event.startDate.addingTimeInterval(-ReminderScheduler.dangerPointOffset)
                guard snoozedUntil > deadline else { continue }
                state.snoozedUntil = deadline
                state.updatedAt = now
                states[key] = state
                changed = true
            }
            if changed || hasPendingPersistence {
                persistLocked()
            }
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

    func prune(endedBefore cutoff: Date, activeKeys: Set<OccurrenceKey> = [], now: Date = Date()) {
        lock.withLock {
            let retained = states.filter { key, state in
                if key.isScoped, let acknowledgement = state.acknowledgement, acknowledgement.eventEnd > now {
                    return true
                }
                if !key.isScoped, let deadline = state.legacyRecoveryDeadline {
                    return deadline > now
                }
                return activeKeys.contains(key) || state.updatedAt >= cutoff
            }
            if retained != states {
                states = retained
                persistLocked()
            } else if hasPendingPersistence {
                persistLocked()
            }
        }
    }

    private func persistLocked() {
        guard let fileURL else { return }
        hasPendingPersistence = true
        if needsRecovery {
            locallyChangedKeys.formUnion(states.keys)
            return
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Array(states.values))
            try data.write(to: fileURL, options: [.atomic])
            hasPendingPersistence = false
            locallyChangedKeys.removeAll()
            setFailureLocked(nil)
        } catch {
            setFailureLocked(.writeFailed)
        }
    }

    private func setFailureLocked(_ failure: PersistenceFailure?) {
        guard self.failure != failure else { return }
        self.failure = failure
        if let failure {
            AppLog.lifecycle.error("reminderStateStorageFailed reason=\(failure.rawValue, privacy: .public)")
        }
    }

    private static func readStates(_ fileURL: URL) -> Result<[OccurrenceKey: OccurrenceReminderState], PersistenceFailure> {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .success([:])
        } catch {
            return .failure(.readFailed)
        }
        do {
            let decoded = try JSONDecoder().decode([OccurrenceReminderState].self, from: data)
            return .success(Dictionary(
                decoded.map { ($0.occurrenceKey, $0) },
                uniquingKeysWith: { first, second in
                    second.updatedAt >= first.updatedAt ? second : first
                }
            ))
        } catch {
            return .failure(.invalidData)
        }
    }
}
