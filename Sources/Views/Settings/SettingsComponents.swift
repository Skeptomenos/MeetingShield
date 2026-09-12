import SwiftUI

struct SettingsSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity)
            .shieldPanel()
    }
}

struct SettingsRow<Control: View>: View {
    var title: String?
    var subtitle: String?
    var value: String?
    @ViewBuilder var control: () -> Control
    init(title: String? = nil, subtitle: String? = nil, value: String? = nil, @ViewBuilder control: @escaping () -> Control = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.control = control
    }
    var body: some View {
        HStack(spacing: 18) {
            if let title {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
            }
            if let value { Text(value).foregroundStyle(.secondary) }
            control()
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsDivider: View {
    var body: some View { Divider().padding(.horizontal, 15) }
}
