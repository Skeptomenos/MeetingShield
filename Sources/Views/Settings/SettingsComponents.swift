import SwiftUI

struct SettingsSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(LiquidGlassTheme.secondaryText)
                .tracking(0.6)
                .padding(.leading, 2)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .glassPanel(cornerRadius: 10)
        .frame(maxWidth: .infinity)
    }
}

struct SettingsRow<Control: View>: View {
    var title: String?
    var value: String?
    @ViewBuilder var control: () -> Control

    init(title: String? = nil, value: String? = nil, @ViewBuilder control: @escaping () -> Control = { EmptyView() }) {
        self.title = title
        self.value = value
        self.control = control
    }

    var body: some View {
        HStack(spacing: 16) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LiquidGlassTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if let value {
                    Text(value)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LiquidGlassTheme.secondaryText)
                        .lineLimit(1)
                }
                control()
            } else {
                control()
                Spacer(minLength: 12)
                if let value {
                    Text(value)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LiquidGlassTheme.secondaryText)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(SettingsTheme.separator)
            .frame(height: 1)
    }
}

