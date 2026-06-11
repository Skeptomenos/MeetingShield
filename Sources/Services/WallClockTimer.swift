import Foundation

/// Timer factory for alarm-critical timers.
///
/// `Timer.scheduledTimer` registers in the run loop's `.default` mode only, so it
/// stalls while AppKit runs tracking sessions (status-item menus, steppers,
/// scroll tracking). Meeting Shield's refresh/next-action/fallback timers are
/// reliability mechanisms and must fire regardless, so they are added to the
/// main run loop in `.common` mode.
enum WallClockTimer {
    @discardableResult
    static func scheduled(
        withTimeInterval interval: TimeInterval,
        repeats: Bool,
        block: @escaping @Sendable (Timer) -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
