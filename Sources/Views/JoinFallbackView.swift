import SwiftUI
import AppKit

@MainActor
final class JoinFallbackWindowController {
    static let shared = JoinFallbackWindowController()

    private var window: NSWindow?

    private init() {}

    func show(
        fallback: JoinFallbackState,
        onOpenAgain: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        hide()
        DiagnosticsRecorder.record("join_fallback_window_show", metadata: [
            "hasWarning": "\(fallback.warning != nil)"
        ])
        let view = JoinFallbackView(
            fallback: fallback,
            onOpenAgain: onOpenAgain,
            onDismiss: onDismiss,
            onClose: onClose
        )
        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 548, height: 86),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = false
        window.contentView = hostingView
        position(window)
        window.orderFrontRegardless()
        self.window = window
    }

    func hide() {
        if window != nil {
            DiagnosticsRecorder.record("join_fallback_window_hide")
        }
        window?.close()
        window = nil
    }

    private func position(_ window: NSWindow) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 24
        ))
    }
}

struct JoinFallbackView: View {
    var fallback: JoinFallbackState
    var onOpenAgain: () -> Void
    var onDismiss: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: fallback.warning == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(fallback.warning == nil ? Color(nsColor: .systemGreen) : LiquidGlassTheme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Opened in \(fallback.openedIn)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LiquidGlassTheme.primaryText)
                if let warning = fallback.warning {
                    Text(warning)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LiquidGlassTheme.secondaryText)
                }
            }
            Spacer(minLength: 12)
            Button {
                onOpenAgain()
            } label: {
                Label("Open Again", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(SmallGlassButtonStyle(role: .neutral, minWidth: 98))
            .accessibilityLabel("Open again")
            .accessibilityHint("Opens the meeting link again")
            Button {
                onDismiss()
            } label: {
                Label("Dismiss", systemImage: "checkmark")
            }
            .buttonStyle(SmallGlassButtonStyle(role: .primary, minWidth: 82))
            .accessibilityLabel("Dismiss this event")
            .accessibilityHint("Dismisses this event occurrence")
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(LiquidGlassTheme.secondaryText)
            .frame(width: 24, height: 24)
            .accessibilityLabel("Close fallback alert")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(minWidth: 520)
        .glassPanel(cornerRadius: 10)
        .shadow(color: .black.opacity(0.42), radius: 28, x: 0, y: 16)
    }
}
