import Foundation

@MainActor
protocol JoinFallbackPresenting: AnyObject {
    func show(
        fallback: JoinFallbackState,
        aboveAlerts: Bool,
        onOpenAgain: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onClose: @escaping () -> Void
    )
    func updateLevel(aboveAlerts: Bool)
    func hide()
}
