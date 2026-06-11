import Foundation
import Testing
@testable import MeetingShield

/// Lock-protected counter for observing @Sendable timer callbacks under Swift 6.
private final class FireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    var fired: Bool { count > 0 }

    func increment() {
        lock.withLock { value += 1 }
    }
}

@Suite("Wall clock timer")
@MainActor
struct WallClockTimerTests {
    /// Simulates AppKit tracking modes (menu open, stepper held): a non-default
    /// run-loop mode registered as "common". Timers scheduled only in `.default`
    /// do not fire here; timers registered for `.common` must.
    private static let trackingMode = RunLoop.Mode("MeetingShieldTestTracking")

    init() {
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(Self.trackingMode.rawValue as CFString))
    }

    @Test("Fires while the run loop is in a tracking (common) mode")
    func firesDuringTrackingMode() {
        let counter = FireCounter()
        let timer = WallClockTimer.scheduled(withTimeInterval: 0.05, repeats: false) { _ in
            counter.increment()
        }
        defer { timer.invalidate() }

        let deadline = Date().addingTimeInterval(1)
        while !counter.fired && Date() < deadline {
            RunLoop.main.run(mode: Self.trackingMode, before: Date().addingTimeInterval(0.02))
        }

        #expect(counter.fired, "WallClockTimer must fire during tracking modes — alarm timers may not stall")
    }

    @Test("Plain scheduledTimer stalls in tracking mode (documents why WallClockTimer exists)")
    func plainTimerStallsDuringTrackingMode() {
        let counter = FireCounter()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
            counter.increment()
        }
        defer { timer.invalidate() }

        let deadline = Date().addingTimeInterval(0.3)
        while !counter.fired && Date() < deadline {
            RunLoop.main.run(mode: Self.trackingMode, before: Date().addingTimeInterval(0.02))
        }

        #expect(!counter.fired, "If this fires, scheduledTimer semantics changed and WallClockTimer may be unnecessary")
    }

    @Test("Repeating timers keep firing")
    func repeatingTimerFires() {
        let counter = FireCounter()
        let timer = WallClockTimer.scheduled(withTimeInterval: 0.03, repeats: true) { _ in
            counter.increment()
        }
        defer { timer.invalidate() }

        let deadline = Date().addingTimeInterval(1)
        while counter.count < 2 && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        #expect(counter.count >= 2)
    }
}

