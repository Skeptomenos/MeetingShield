import SwiftUI

struct PersistenceRecoverySection: View {
    @ObservedObject var controller: MeetingShieldController

    var body: some View {
        if !controller.persistenceWarnings.isEmpty || controller.isRetryingPersistence {
            SettingsSection(title: "Storage needs attention") {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        let warnings = controller.persistenceWarnings
                        ForEach(warnings.indices, id: \.self) { index in
                            Label(warnings[index], systemImage: "exclamationmark.triangle")
                                .font(.body)
                                .foregroundStyle(ShieldTheme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if controller.settingsPersistenceFailure != nil || controller.reminderPersistenceFailure != nil {
                            Text("Current choices still apply in this session. Unsaved changes may be lost when the app quits.")
                                .font(.callout)
                                .foregroundStyle(ShieldTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 10) {
                            Button("Retry storage") {
                                Task { await controller.retryPersistence() }
                            }
                            .disabled(controller.isRetryingPersistence)
                            .accessibilityIdentifier("retry-persistence")
                            if controller.isRetryingPersistence {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Checking storage…")
                                    .font(.callout)
                            }
                        }
                        Text("Retry keeps recoverable data. It does not reset settings, remove accounts or start sign-in.")
                            .font(.caption)
                            .foregroundStyle(ShieldTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
