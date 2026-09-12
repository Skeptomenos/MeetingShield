import AppKit
import SwiftUI

enum ShieldTheme {
    static let accent = Color.accentColor
    static let window = adaptive(light: 0xfaf9f7, dark: 0x1b1d21)
    static let sidebar = adaptive(light: 0xefefed, dark: 0x23262b)
    static let panel = adaptive(light: 0xffffff, dark: 0x25292f)
    static let popoverFill = window
    static let separator = Color(nsColor: .separatorColor)
    static let border = adaptive(light: 0xdedfe1, dark: 0x393e46)
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let tertiaryText = Color.secondary
    static let warning = Color(nsColor: .systemOrange)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255,
                           green: Double((rgb >> 8) & 255) / 255,
                           blue: Double(rgb & 255) / 255, alpha: 1)
        })
    }
}

struct AlertBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                ShieldTheme.window
            } else {
                FrostedWindowBackground()
                ShieldTheme.window.opacity(0.66)
            }
        }.ignoresSafeArea()
    }
}

private struct FrostedWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct CompactSwitch: View {
    @Binding var isOn: Bool
    var accessibilityLabel: String

    var body: some View {
        Toggle(accessibilityLabel, isOn: $isOn)
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .accessibilityLabel(accessibilityLabel)
    }
}

struct ShieldButtonStyle: ButtonStyle {
    enum Role { case neutral, primary, destructive }
    var role: Role = .neutral
    var minWidth: CGFloat = 0
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 11)
            .frame(minWidth: minWidth, minHeight: 28)
            .foregroundStyle(role == .primary ? Color.white : role == .destructive ? Color.red : Color.primary)
            .background(role == .primary ? ShieldTheme.accent : ShieldTheme.panel, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).stroke(role == .primary ? Color.clear : ShieldTheme.border, lineWidth: 1) }
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
    }
}

extension View {
    func shieldTextField() -> some View {
        textFieldStyle(.roundedBorder).font(.system(size: 13)).controlSize(.regular)
    }

    func shieldPanel(cornerRadius: CGFloat = 10) -> some View {
        background(ShieldTheme.panel, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay { RoundedRectangle(cornerRadius: cornerRadius).stroke(ShieldTheme.border, lineWidth: 1) }
    }
}
