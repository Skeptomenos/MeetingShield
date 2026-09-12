import SwiftUI

struct MeetingAlertView: View {
    @ObservedObject var keyTarget: AlertKeyTarget
    var availableSnoozeChoices: (ScheduledReminder, Date) -> [SnoozeChoice]
    var onJoin: (ScheduledReminder) -> Void
    var onSnooze: (ScheduledReminder, SnoozeChoice?) -> Void
    var onDismiss: (ScheduledReminder) -> Void
    var onRequestDismissal: (ScheduledReminder) -> Void
    var onMute: (ScheduledReminder) -> Void
    var onSnoozeAll: () -> Void
    @State private var expandedSnooze = false
    private var reminders: [ScheduledReminder] { keyTarget.reminders }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 26) {
                        Label("Meeting Shield", systemImage: "shield")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        if reminders.count > 1 { overlapSelector }
                        if let reminder = keyTarget.selectedReminder {
                            alertContent(reminder, now: context.date)
                        }
                    }
                    .padding(.vertical, 40).padding(.horizontal, 28)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }
        }
        .background(AlertBackdrop())
        .onChange(of: keyTarget.selectedID) { _, _ in expandedSnooze = false }
        .onExitCommand {}
    }

    private var overlapSelector: some View {
        VStack(spacing: 10) {
            Text("\(reminders.count) meetings need attention").font(.system(size: 12)).foregroundStyle(.secondary)
            if reminders.count <= 3 {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) { meetingOptions }
                    VStack(spacing: 4) { meetingOptions }
                }
            } else {
                Picker("Meeting needing attention", selection: $keyTarget.selectedID) {
                    ForEach(reminders) { reminder in
                        Text("\(reminder.event.title) · \(DateFormatter.shortTimeString(from: reminder.event.startDate))")
                            .tag(Optional(reminder.id))
                    }
                }.frame(maxWidth: 450)
            }
        }
    }

    private var meetingOptions: some View {
        ForEach(reminders) { reminder in
            let selected = keyTarget.selectedReminder?.id == reminder.id
            Button { keyTarget.selectedID = reminder.id } label: {
                Text("\(reminder.event.title) · \(DateFormatter.shortTimeString(from: reminder.event.startDate))")
                    .font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.center)
                    .padding(.vertical, 9)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .overlay(alignment: .bottom) { Rectangle().fill(selected ? ShieldTheme.accent : .clear).frame(height: 2) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show alert for \(reminder.event.title)")
            .accessibilityValue(selected ? "Selected" : "Not selected")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    private func alertContent(_ reminder: ScheduledReminder, now: Date) -> some View {
        let canSnooze = !availableSnoozeChoices(reminder, now).isEmpty
        return VStack(spacing: 0) {
            Text(reminder.event.startDate > now ? "Your meeting starts in" : "Your meeting has started")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 12)
            Text(Self.countdown(until: reminder.event.startDate, now: now))
                .font(.system(size: 64, weight: .regular).monospacedDigit())
                .foregroundStyle(.secondary).padding(.bottom, 18)
                .accessibilityLabel("Meeting countdown")
                .accessibilityValue(Self.countdown(until: reminder.event.startDate, now: now))
            Text(reminder.event.title)
                .font(.system(size: 38, weight: .medium)).multilineTextAlignment(.center)
                .lineLimit(4).minimumScaleFactor(0.65).padding(.bottom, 12)
                .accessibilityAddTraits(.isHeader)
            Text("\(DateFormatter.shortTimeString(from: reminder.event.startDate))–\(DateFormatter.shortTimeString(from: reminder.event.endDate)) · \(calendarLabel(reminder)) · \(linkLabel(reminder))")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if reminders.contains(where: { $0.event.meetingRoom?.isEmpty == false }) {
                Label(reminder.event.meetingRoom ?? "Meeting room", systemImage: "mappin.and.ellipse")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .lineLimit(2).frame(height: 36).padding(.top, 8)
                    .opacity(reminder.event.meetingRoom?.isEmpty == false ? 1 : 0)
                    .accessibilityHidden(reminder.event.meetingRoom?.isEmpty != false)
            }
            // Reserve optional metadata across the whole overlap set. Switching the
            // selected meeting must not move the countdown, title or action buttons.
            if reminders.contains(where: { $0.event.isFromCache }) {
                Label("Calendar data may be stale", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(ShieldTheme.warning).font(.system(size: 13)).padding(.top, 14)
                    .opacity(reminder.event.isFromCache ? 1 : 0)
                    .accessibilityHidden(!reminder.event.isFromCache)
            }
            if reminders.contains(where: { $0.detectedLinks.isEmpty }) {
                Text("No meeting link found. Open the calendar event instead.")
                    .font(.system(size: 13)).foregroundStyle(ShieldTheme.warning)
                    .multilineTextAlignment(.center).padding(.top, 14)
                    .opacity(reminder.detectedLinks.isEmpty ? 1 : 0)
                    .accessibilityHidden(!reminder.detectedLinks.isEmpty)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { primaryActions(reminder, canSnooze: canSnooze) }
                VStack(spacing: 12) { primaryActions(reminder, canSnooze: canSnooze) }
            }.padding(.top, 32)
            if canSnooze {
                DisclosureGroup("Other snooze options", isExpanded: $expandedSnooze) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { snoozeChoices(reminder, now: now) }
                        VStack(spacing: 8) { snoozeChoices(reminder, now: now) }
                    }.padding(.top, 10)
                }
                .disclosureGroupStyle(ReservedSnoozeDisclosureStyle())
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 390).padding(.top, 16)
            } else {
                Text("Snooze is unavailable this close to the start.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 16)
            }
            HStack(spacing: 20) {
                DismissHoldButton(hasOverlappingReminders: reminders.count > 1,
                                  action: { onDismiss(reminder) }, requestConfirmation: { onRequestDismissal(reminder) })
                Button("Stay here") { onMute(reminder) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                    .accessibilityHint("Mutes only this event occurrence until it ends")
            }.padding(.top, 24)
            if reminders.count > 1 {
                Button("Snooze all visible") { onSnoozeAll() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                    .disabled(reminders.allSatisfy { availableSnoozeChoices($0, now).isEmpty })
                    .accessibilityLabel("Snooze all visible meetings")
                    .accessibilityHint("Snoozes meetings that can return safely; imminent meetings stay visible")
                    .padding(.top, 18)
            }
        }
    }

    @ViewBuilder
    private func primaryActions(_ reminder: ScheduledReminder, canSnooze: Bool) -> some View {
        Button { onJoin(reminder) } label: {
            Label(reminder.detectedLinks.isEmpty ? "Open event" : "Join meeting", systemImage: reminder.detectedLinks.isEmpty ? "calendar" : "video")
                .font(.system(size: 16, weight: .medium)).frame(width: 172, height: 46)
        }
        .buttonStyle(ShieldButtonStyle(role: .primary))
        .keyboardShortcut(.defaultAction)
        .accessibilityLabel(reminder.detectedLinks.isEmpty ? "Open event" : "Join meeting")
        Button { onSnooze(reminder, nil) } label: {
            Text("Snooze").font(.system(size: 16, weight: .medium)).frame(width: 150, height: 46)
        }
        .buttonStyle(ShieldButtonStyle())
        .keyboardShortcut("s", modifiers: [])
        .disabled(!canSnooze)
        .accessibilityLabel("Snooze reminder").accessibilityHint("Uses the default snooze duration, clamped before the meeting starts")
    }

    private func snoozeChoices(_ reminder: ScheduledReminder, now: Date) -> some View {
        ForEach(availableSnoozeChoices(reminder, now), id: \.label) { choice in
            Button(choice.label) { onSnooze(reminder, choice) }
                .buttonStyle(ShieldButtonStyle())
                .accessibilityLabel("Snooze \(choice.label)")
        }
    }

    static func countdown(until start: Date, now: Date) -> String {
        let seconds = max(0, Int(ceil(start.timeIntervalSince(now))))
        if seconds == 0 { return "Now" }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func calendarLabel(_ reminder: ScheduledReminder) -> String {
        let name = reminder.event.calendarDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? reminder.event.accountDisplayName : name
    }

    private func linkLabel(_ reminder: ScheduledReminder) -> String {
        switch reminder.detectedLinks.first?.kind {
        case .googleMeet: "Google Meet"
        case .zoom: "Zoom"
        case .teams: "Teams"
        case .webex: "Webex"
        case .generic: "Meeting link"
        case nil: "Calendar event"
        }
    }
}

private struct ReservedSnoozeDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .frame(width: 10).accessibilityHidden(true)
                    configuration.label
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            // Keep the same measured height while collapsed, without exposing
            // invisible choices to pointer, keyboard or accessibility actions.
            configuration.content
                .frame(maxWidth: .infinity)
                .opacity(configuration.isExpanded ? 1 : 0)
                .disabled(!configuration.isExpanded)
                .allowsHitTesting(configuration.isExpanded)
                .accessibilityHidden(!configuration.isExpanded)
        }
    }
}

struct DismissHoldButton: View {
    var hasOverlappingReminders: Bool
    var action: () -> Void
    var requestConfirmation: () -> Void
    @State private var isPressing = false

    private var title: String {
        isPressing ? "Keep holding..." : "Hold to dismiss"
    }

    private var accessibilityHint: String {
        if hasOverlappingReminders {
            return "Opens confirmation before dismissing this event occurrence. Other overlapping meetings will remain visible."
        }
        return "Opens confirmation before dismissing this event occurrence and closing the alert."
    }

    var body: some View {
        Label(title, systemImage: isPressing ? "checkmark.circle.fill" : "hand.tap")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isPressing ? .red : Color.secondary)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(isPressing ? .red.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isPressing ? .red.opacity(0.36) : Color.clear, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .focusable()
            .onKeyPress(.space) {
                requestConfirmation()
                return .handled
            }
            .onLongPressGesture(minimumDuration: 1.0, maximumDistance: 80) {
                action()
            } onPressingChanged: { pressing in
                isPressing = pressing
            }
            .accessibilityLabel("Dismiss this event")
            .accessibilityValue("Confirmation required")
            .accessibilityHint(accessibilityHint)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                requestConfirmation()
            }
            .accessibilityRepresentation {
                Button("Dismiss this event", action: requestConfirmation)
                    .accessibilityLabel("Dismiss this event")
                    .accessibilityValue("Confirmation required")
                    .accessibilityHint(accessibilityHint)
            }
    }
}
