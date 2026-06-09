import SwiftUI

struct MeetingAlertView: View {
    var reminders: [ScheduledReminder]
    var availableSnoozeChoices: (ScheduledReminder) -> [SnoozeChoice]
    var onJoin: (ScheduledReminder) -> Void
    var onSnooze: (ScheduledReminder, SnoozeChoice?) -> Void
    var onDismiss: (ScheduledReminder) -> Void
    var onMute: (ScheduledReminder) -> Void
    var onSnoozeAll: () -> Void

    @State private var selectedID: ScheduledReminder.ID?

    private var selectedReminder: ScheduledReminder {
        reminders.first { $0.id == selectedID } ?? reminders[0]
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.48)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                if reminders.count > 1 {
                    overlapSelector
                }

                alertCard(for: selectedReminder)
                    .frame(maxWidth: 780)
            }
            .padding(44)
        }
        .onAppear {
            selectedID = reminders.first?.id
        }
        .onExitCommand {}
    }

    private var overlapSelector: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(reminders) { reminder in
                    Button {
                        selectedID = reminder.id
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: selectedID == reminder.id ? "circle.fill" : "circle")
                                .font(.system(size: 8, weight: .bold))
                            Text(reminder.event.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                    }
                    .buttonStyle(OverlapChipButtonStyle(isSelected: selectedID == reminder.id))
                    .accessibilityLabel("Show alert for \(reminder.event.title)")
                    .accessibilityValue("Show alert for \(reminder.event.title)")
                    .accessibilityHint(selectedID == reminder.id ? "Currently selected meeting" : "Switches the alert to this meeting")
                }
            }
            .padding(5)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.11), lineWidth: 1)
            }

            Button {
                onSnoozeAll()
            } label: {
                Label("Snooze All", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(height: 30)
            }
            .buttonStyle(LiquidAlertButtonStyle(kind: .secondary, minWidth: 118))
            .accessibilityLabel("Snooze all visible meetings")
            .accessibilityValue("Snooze all visible meetings")
            .accessibilityHint("Hides every visible meeting alert until its next safe reminder time")
        }
    }

    private func alertCard(for reminder: ScheduledReminder) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: reminder.detectedLinks.isEmpty ? "calendar.badge.exclamationmark" : "shield.lefthalf.filled")
                        .font(.system(size: 13, weight: .semibold))
                    Text(reminder.detectedLinks.isEmpty ? "No Meeting Link Found" : "Meeting Shield")
                        .font(.system(size: 12, weight: .bold))
                        .textCase(.uppercase)
                        .tracking(0.8)
                    Spacer()
                    Text(linkStatus(for: reminder))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(reminder.detectedLinks.isEmpty ? .orange : .secondary)
                }
                .foregroundStyle(reminder.detectedLinks.isEmpty ? .orange : .secondary)

                Text(reminder.event.title)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.45)
                    .lineLimit(3)
                    .foregroundStyle(.white.opacity(0.96))
                    .frame(maxWidth: .infinity)

                metadataRow(for: reminder)

                if reminder.event.isFromCache {
                    Label("Calendar data may be stale", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.horizontal, 34)
            .padding(.top, 30)
            .padding(.bottom, 24)

            Divider()
                .overlay(.white.opacity(0.08))

            VStack(spacing: 14) {
                if reminder.detectedLinks.isEmpty {
                    linklessWarning
                }

                HStack(spacing: 12) {
                    Button {
                        onJoin(reminder)
                    } label: {
                        Label(reminder.detectedLinks.isEmpty ? "Open Event" : "Join", systemImage: reminder.detectedLinks.isEmpty ? "calendar" : "video.fill")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 62)
                    }
                    .buttonStyle(LiquidAlertButtonStyle(kind: .primary, minWidth: 210))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(reminder.detectedLinks.isEmpty ? "Open event" : "Join meeting")
                    .accessibilityValue(reminder.detectedLinks.isEmpty ? "Open event" : "Join meeting")
                    .accessibilityHint(reminder.detectedLinks.isEmpty ? "Opens the calendar event" : "Opens the meeting link")

                    Button {
                        onSnooze(reminder, nil)
                    } label: {
                        Label("Snooze", systemImage: "clock")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 62)
                    }
                    .buttonStyle(LiquidAlertButtonStyle(kind: .secondary, minWidth: 180))
                    .keyboardShortcut("s", modifiers: [])
                    .disabled(availableSnoozeChoices(reminder).isEmpty)
                    .accessibilityLabel("Snooze reminder")
                    .accessibilityValue("Snooze reminder")
                    .accessibilityHint("Uses the default snooze duration")
                }

                snoozeChoices(for: reminder)
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 22)

            HStack(spacing: 14) {
                DismissHoldButton(hasOverlappingReminders: reminders.count > 1) {
                    onDismiss(reminder)
                }
                Button {
                    onMute(reminder)
                } label: {
                    Label("Stay Here", systemImage: "speaker.slash")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.54))
                .accessibilityLabel("Stay here")
                .accessibilityValue("Stay here")
                .accessibilityHint("Mutes this event occurrence until it ends")

                Spacer()
                Text(reminder.detectedLinks.isEmpty ? "Opens the calendar event page" : linkSourceLabel(for: reminder))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 16)
            .background(Color.black.opacity(0.14))
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.22), .white.opacity(0.06), .black.opacity(0.22)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(0.55), radius: 36, x: 0, y: 22)
        .shadow(color: .white.opacity(0.05), radius: 1, x: 0, y: 1)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func snoozeChoices(for reminder: ScheduledReminder) -> some View {
        let choices = availableSnoozeChoices(reminder)
        if !choices.isEmpty {
            HStack(spacing: 8) {
                ForEach(choices, id: \.label) { choice in
                    Button {
                        onSnooze(reminder, choice)
                    } label: {
                        Text(choice.label)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(minWidth: 54, minHeight: 28)
                    }
                    .buttonStyle(SnoozeChipButtonStyle())
                    .accessibilityLabel("Snooze \(choice.label)")
                    .accessibilityValue("Snooze \(choice.label)")
                    .accessibilityHint("The reminder will return before the meeting starts")
                }
            }
        }
    }

    private var linklessWarning: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
            Text("No meeting link was found. Opening the Google Calendar event instead.")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.orange.opacity(0.22), lineWidth: 1)
        }
    }

    private func timeLine(for reminder: ScheduledReminder) -> String {
        let time = DateFormatter.shortTimeString(from: reminder.event.startDate)
        let countdown = RelativeDateTimeFormatter.shortString(for: reminder.event.startDate, relativeTo: Date())
        return "\(time) · \(countdown)"
    }

    private func metadataRow(for reminder: ScheduledReminder) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 12) {
                Label(timeLine(for: reminder), systemImage: "clock")
                    .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                    .fixedSize(horizontal: true, vertical: false)
                if let meetingRoom = meetingRoomLabel(for: reminder) {
                    metadataDivider
                    Label(meetingRoom, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                }
            }
            .foregroundStyle(.white.opacity(0.68))
            .minimumScaleFactor(0.72)

            HStack(spacing: 7) {
                Image(systemName: "calendar")
                    .font(.system(size: 13, weight: .semibold))
                Text(calendarLabel(for: reminder))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.54))
        }
        .frame(maxWidth: .infinity)
    }

    private var metadataDivider: some View {
        Divider()
            .frame(height: 16)
    }

    private func calendarLabel(for reminder: ScheduledReminder) -> String {
        let calendar = reminder.event.calendarDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !calendar.isEmpty {
            return calendar
        }
        return reminder.event.accountDisplayName
    }

    private func meetingRoomLabel(for reminder: ScheduledReminder) -> String? {
        let room = reminder.event.meetingRoom?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let room, !room.isEmpty else { return nil }
        return room
    }

    private func linkStatus(for reminder: ScheduledReminder) -> String {
        guard let link = reminder.detectedLinks.first else {
            return "Open event fallback"
        }
        switch link.kind {
        case .googleMeet:
            return "Google Meet ready"
        case .zoom:
            return "Zoom link ready"
        case .teams:
            return "Teams link ready"
        case .webex:
            return "Webex link ready"
        case .generic:
            return "Meeting link ready"
        }
    }

    private func linkSourceLabel(for reminder: ScheduledReminder) -> String {
        guard let link = reminder.detectedLinks.first else {
            return "No meeting link"
        }
        switch link.source {
        case .conferenceMetadata:
            return "Link from calendar conference data"
        case .location:
            return "Link from event location"
        case .description:
            return "Link from event notes"
        }
    }
}

struct DismissHoldButton: View {
    var hasOverlappingReminders: Bool
    var action: () -> Void
    @State private var isPressing = false

    private var title: String {
        isPressing ? "Keep holding..." : "Hold to dismiss"
    }

    private var accessibilityHint: String {
        if hasOverlappingReminders {
            return "Long press for one second to dismiss this event occurrence. Other overlapping meetings will remain visible."
        }
        return "Long press for one second to dismiss this event occurrence and close the alert."
    }

    var body: some View {
        Label(title, systemImage: isPressing ? "checkmark.circle.fill" : "hand.tap")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isPressing ? .red : .white.opacity(0.58))
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(isPressing ? .red.opacity(0.15) : .white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isPressing ? .red.opacity(0.36) : .white.opacity(0.08), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onLongPressGesture(minimumDuration: 1.0, maximumDistance: 80) {
                action()
            } onPressingChanged: { pressing in
                isPressing = pressing
            }
            .accessibilityLabel("Hold to dismiss this event")
            .accessibilityValue("Hold to dismiss this event")
            .accessibilityHint(accessibilityHint)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                action()
            }
            .accessibilityRepresentation {
                Button("Hold to dismiss this event", action: action)
                    .accessibilityLabel("Hold to dismiss this event")
                    .accessibilityValue("Hold to dismiss this event")
                    .accessibilityHint(accessibilityHint)
            }
    }
}

private struct LiquidAlertButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    var kind: Kind
    var minWidth: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 18)
            .frame(minWidth: minWidth)
            .foregroundStyle(foregroundColor)
            .background(backgroundStyle(isPressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(borderStyle, lineWidth: 1)
            }
            .shadow(color: shadowColor, radius: configuration.isPressed ? 6 : 14, x: 0, y: configuration.isPressed ? 3 : 9)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        switch kind {
        case .primary:
            .white
        case .secondary:
            .white.opacity(0.88)
        }
    }

    private var borderStyle: some ShapeStyle {
        switch kind {
        case .primary:
            LinearGradient(
                colors: [.white.opacity(0.34), .white.opacity(0.10)],
                startPoint: .top,
                endPoint: .bottom
            )
        case .secondary:
            LinearGradient(
                colors: [.white.opacity(0.18), .white.opacity(0.07)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var shadowColor: Color {
        switch kind {
        case .primary:
            Color.blue.opacity(0.28)
        case .secondary:
            Color.black.opacity(0.20)
        }
    }

    private func backgroundStyle(isPressed: Bool) -> some ShapeStyle {
        switch kind {
        case .primary:
            LinearGradient(
                colors: [
                    Color(nsColor: NSColor(calibratedRed: 0.18, green: 0.49, blue: 1.0, alpha: isPressed ? 0.82 : 1.0)),
                    Color(nsColor: NSColor(calibratedRed: 0.05, green: 0.32, blue: 0.86, alpha: isPressed ? 0.82 : 1.0))
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .secondary:
            LinearGradient(
                colors: [
                    Color.white.opacity(isPressed ? 0.13 : 0.18),
                    Color.white.opacity(isPressed ? 0.07 : 0.10)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

private struct SnoozeChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 9)
            .foregroundStyle(.white.opacity(0.78))
            .background(.white.opacity(configuration.isPressed ? 0.15 : 0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            }
    }
}

private struct OverlapChipButtonStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? .white : .white.opacity(0.62))
            .background(
                isSelected ? Color(nsColor: NSColor.controlAccentColor).opacity(configuration.isPressed ? 0.78 : 0.96) : Color.white.opacity(configuration.isPressed ? 0.10 : 0.04),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }
}
