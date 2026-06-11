import AppKit
import Foundation
import Network

@MainActor
final class SystemEventMonitor: ObservableObject {
    static let shared = SystemEventMonitor()

    @Published private(set) var wakeGraceUntil: Date?

    var onWakeOrUnlock: (@MainActor () -> Void)?
    /// Fired when network connectivity returns after an offline period
    /// (TECH.md: refresh on network return).
    var onNetworkReturn: (@MainActor () -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?
    private var lastPathSatisfied: Bool?

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
        // Screen unlock without sleep (lock screen) — distributed notification,
        // not covered by didWake.
        distributedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                AppLog.lifecycle.info("screenUnlocked")
                self?.enterWakeGrace()
            }
        })
        startNetworkMonitor()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.forEach { distributed.removeObserver($0) }
        distributedObservers.removeAll()
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathSatisfied = nil
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

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                defer { self.lastPathSatisfied = satisfied }
                // Only offline → online transitions trigger a refresh.
                if satisfied, self.lastPathSatisfied == false {
                    AppLog.refresh.info("networkReturned")
                    DiagnosticsRecorder.record("network_returned")
                    self.onNetworkReturn?()
                }
            }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }
}
