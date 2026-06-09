import AppKit
import Foundation

@MainActor
final class SystemEventMonitor: ObservableObject {
    static let shared = SystemEventMonitor()

    @Published private(set) var wakeGraceUntil: Date?

    var onWakeOrUnlock: (@MainActor () -> Void)?

    private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.enterWakeGrace() }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.enterWakeGrace() }
        })
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    func enterWakeGrace(now: Date = Date()) {
        wakeGraceUntil = now.addingTimeInterval(60)
        DiagnosticsRecorder.record("wake_grace_started")
        onWakeOrUnlock?()
    }

    func isInWakeGrace(now: Date = Date()) -> Bool {
        guard let wakeGraceUntil else { return false }
        return wakeGraceUntil > now
    }
}
