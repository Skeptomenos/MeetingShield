import SwiftUI

/// Uses the real alert view with sample data and no provider, launcher or reminder store.
struct AlertDesignPreview: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var target: AlertKeyTarget
    @State private var confirmDismiss = false

    init() {
        let start = Date().addingTimeInterval(134)
        let event = CalendarEventOccurrence.sample(eventID: "design-preview", title: "Design review", startDate: start)
        let links = URL(string: "https://meet.google.com/sample-preview").map {
            [MeetingLink(url: $0, kind: .googleMeet, source: .conferenceMetadata)]
        } ?? []
        let reminder = ScheduledReminder(event: event, detectedLinks: links, fireDate: .now,
                                         browserSelection: .systemDefault, isSnoozed: false)
        _target = StateObject(wrappedValue: AlertKeyTarget(reminders: [reminder]))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Alert preview · Sample meeting").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
            }.padding(16)
            MeetingAlertView(
                keyTarget: target,
                availableSnoozeChoices: { _, now in
                    guard let start = target.selectedReminder?.event.startDate, start.timeIntervalSince(now) > 10 else { return [] }
                    return [.untilDangerPoint]
                },
                onJoin: { _ in dismiss() }, onSnooze: { _, _ in dismiss() },
                onDismiss: { _ in dismiss() }, onRequestDismissal: { _ in confirmDismiss = true },
                onMute: { _ in dismiss() }, onSnoozeAll: { dismiss() }
            )
        }
        .frame(width: 700, height: 610).background(ShieldTheme.window)
        .alert("Dismiss this sample meeting?", isPresented: $confirmDismiss) {
            Button("Cancel", role: .cancel) {}
            Button("Dismiss") { dismiss() }
        }
    }
}
