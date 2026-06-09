import AppKit
import SwiftUI

enum LiquidGlassTheme {
    static let accent = Color(nsColor: .controlAccentColor)
    static let window = Color(nsColor: NSColor(calibratedWhite: 0.072, alpha: 0.90))
    static let sidebar = Color(nsColor: NSColor(calibratedWhite: 0.062, alpha: 0.74))
    static let popoverFill = Color(nsColor: NSColor(calibratedWhite: 0.080, alpha: 0.68))
    static let glassFill = Color.white.opacity(0.060)
    static let recessedFill = Color.black.opacity(0.24)
    static let separator = Color.white.opacity(0.070)
    static let border = Color.white.opacity(0.10)
    static let strongBorder = Color.white.opacity(0.16)
    static let primaryText = Color.white.opacity(0.88)
    static let secondaryText = Color.white.opacity(0.58)
    static let tertiaryText = Color.white.opacity(0.36)
    static let warning = Color(nsColor: .systemOrange)
}

struct CompactSwitch: View {
    @Binding var isOn: Bool
    var accessibilityLabel: String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 0) {
                if isOn {
                    Spacer(minLength: 0)
                }
                Circle()
                    .fill(Color.white.opacity(isEnabled ? 0.94 : 0.58))
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.20), radius: 1.5, x: 0, y: 1)
                if !isOn {
                    Spacer(minLength: 0)
                }
            }
            .padding(3)
            .frame(width: 34, height: 20)
            .background(
                Capsule()
                    .fill(isOn ? LiquidGlassTheme.accent : Color.white.opacity(0.14))
            )
            .overlay {
                Capsule()
                    .stroke(isOn ? Color.white.opacity(0.20) : LiquidGlassTheme.border, lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.46)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}

struct SmallGlassButtonStyle: ButtonStyle {
    enum Role {
        case neutral
        case primary
        case destructive
    }

    var role: Role = .neutral
    var minWidth: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .frame(minWidth: minWidth, minHeight: 24)
            .background(background(isPressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(border, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch role {
        case .neutral:
            Color.white.opacity(0.82)
        case .primary:
            .white
        case .destructive:
            Color(nsColor: .systemRed).opacity(0.92)
        }
    }

    private var border: Color {
        switch role {
        case .neutral:
            LiquidGlassTheme.border
        case .primary:
            Color.white.opacity(0.24)
        case .destructive:
            Color(nsColor: .systemRed).opacity(0.26)
        }
    }

    private func background(isPressed: Bool) -> Color {
        switch role {
        case .neutral:
            Color.white.opacity(isPressed ? 0.14 : 0.09)
        case .primary:
            LiquidGlassTheme.accent.opacity(isPressed ? 0.76 : 0.94)
        case .destructive:
            Color(nsColor: .systemRed).opacity(isPressed ? 0.15 : 0.10)
        }
    }
}

struct GlassTextFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 25)
            .background(LiquidGlassTheme.recessedFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(LiquidGlassTheme.border, lineWidth: 1)
            }
    }
}

extension View {
    func glassTextField() -> some View {
        modifier(GlassTextFieldModifier())
    }

    func glassPanel(cornerRadius: CGFloat = 10) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(LiquidGlassTheme.glassFill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.16),
                                Color.white.opacity(0.06),
                                Color.black.opacity(0.18)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
    }
}
