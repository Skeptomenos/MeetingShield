import Foundation

@MainActor
protocol DismissalConfirming: AnyObject {
    func present(
        requestID: UUID,
        reminder: ScheduledReminder,
        source: DismissalRequestSource,
        completion: @escaping @MainActor (Bool) -> Void
    )

    func cancel(requestID: UUID)
}
