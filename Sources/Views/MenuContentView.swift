import AppKit
import SwiftUI

@MainActor
final class MenuPresentationState: ObservableObject {
    @Published var showsMonth = false
    @Published var showsHealth = false
}

struct MenuContentView: View {
    static let preferredWidth: CGFloat = 348
    @ObservedObject var controller: MeetingShieldController
    var popoverHeight: CGFloat
    var closeMenu: @MainActor () -> Void = { MenuBarController.shared.closePopover() }
    @ObservedObject var presentation = MenuPresentationState()
    var onExpansionChange: () -> Void = {}
    @State private var selectedMonth = Date()

    static func preferredHeight(eventCount: Int, hasPersistenceWarning: Bool = false, hasNotificationWarning: Bool = false,
                                showsMonth: Bool = false, showsHealth: Bool = false) -> CGFloat {
        232 + CGFloat(min(eventCount, 5)) * 46
            + (hasPersistenceWarning ? 35 : 0) + (hasNotificationWarning ? 55 : 0)
            + (showsMonth ? 245 : 0) + (showsHealth ? 92 : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { presentation.showsHealth.toggle() } label: {
                    Label(controller.protectionHealthSummary.level == .healthy ? "Protected" : "Needs attention",
                          systemImage: healthSystemImage(controller.protectionHealthSummary.level))
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(healthColor(controller.protectionHealthSummary.level))
                .accessibilityLabel("Protection details")
                .accessibilityValue(controller.protectionHealthSummary.title)
            }.padding(.horizontal, 18).padding(.vertical, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if presentation.showsHealth || controller.protectionHealthSummary.level != .healthy { healthDetails }
                    warnings
                    nextSection
                    if !controller.menuEvents.isEmpty { agendaSection }
                }.padding(.horizontal, 18).padding(.bottom, 16)
            }
            VStack(alignment: .leading, spacing: 18) {
                Divider()
                DisclosureGroup(isExpanded: $presentation.showsMonth) {
                    MiniMonthCalendarView(selectedDate: $selectedMonth).padding(.top, 12)
                } label: {
                    Text("Month calendar").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.bottom, 16)
            .fixedSize(horizontal: false, vertical: true)
            bottomBar
        }
        .frame(width: Self.preferredWidth, height: popoverHeight, alignment: .topLeading)
        .background(ShieldTheme.popoverFill)
        .onChange(of: presentation.showsMonth) { _, _ in onExpansionChange() }
        .onChange(of: presentation.showsHealth) { _, _ in onExpansionChange() }
    }

    private var healthDetails: some View {
        let summary = controller.protectionHealthSummary
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(summary.title).font(.system(size: 12, weight: .medium))
                Spacer()
                Button { controller.copyProtectionSummary() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).accessibilityLabel("Copy protection summary").help("Copy protection summary")
            }
            Text(summary.coverageText).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(summary.scheduleText).font(.system(size: 11)).foregroundStyle(.secondary)
            if !summary.actions.isEmpty {
                HStack(spacing: 14) {
                    ForEach(summary.actions, id: \.rawValue) { action in
                        Button(action.rawValue) { controller.performProtectionHealthAction(action) }
                            .buttonStyle(.plain).foregroundStyle(ShieldTheme.accent).font(.system(size: 12))
                    }
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var warnings: some View {
        if !controller.persistenceWarnings.isEmpty {
            Button("Storage needs attention", systemImage: "exclamationmark.triangle") { controller.openSettings() }
                .font(.system(size: 12)).foregroundStyle(ShieldTheme.warning).buttonStyle(.plain)
                .accessibilityIdentifier("persistence-warning-settings")
        }
        if let warning = controller.notificationWarning { warningLabel(warning, systemImage: "bell.slash.circle") }
        if let status = controller.statusMessage { warningLabel(status, systemImage: "exclamationmark.triangle") }
        if case .authenticating = controller.authState {
            Label("Connecting Google Calendar…", systemImage: "arrow.clockwise").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func warningLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage).font(.system(size: 12)).foregroundStyle(ShieldTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func healthSystemImage(_ level: ProtectionHealthSummary.Level) -> String {
        switch level {
        case .healthy: "checkmark.shield"
        case .partial: "exclamationmark.shield"
        case .unavailable: "xmark.shield"
        }
    }
    private func healthColor(_ level: ProtectionHealthSummary.Level) -> Color {
        level == .healthy ? .secondary : ShieldTheme.warning
    }

    private var nextSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let event = controller.nextEvent {
                Text(RelativeDateTimeFormatter.shortString(for: event.startDate, relativeTo: .now))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(ShieldTheme.accent)
                Text(event.title).font(.system(size: 22, weight: .medium)).lineLimit(3)
                Text("\(DateFormatter.shortTimeString(from: event.startDate))–\(DateFormatter.shortTimeString(from: event.endDate)) · \(controller.displayCalendarName(for: event))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("No upcoming meetings").font(.system(size: 20, weight: .medium))
                Text("In your selected window").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var agendaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agenda").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            ForEach(controller.menuEvents) { event in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.isAllDay ? "All day" : DateFormatter.shortTimeString(from: event.startDate))
                            .font(.system(size: 12)).monospacedDigit()
                        if !Calendar.current.isDateInToday(event.startDate) {
                            Text(event.startDate.formatted(.dateTime.day().month(.abbreviated))).font(.system(size: 10))
                        }
                    }.foregroundStyle(.secondary).frame(width: 49, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        Text(controller.displayCalendarName(for: event)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if controller.canAlertAgain(event) {
                        Button("Alert again") { closeMenu(); controller.alertAgain(event) }
                            .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(ShieldTheme.accent)
                            .accessibilityLabel("Alert again for \(event.title)")
                    }
                }
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Toggle("Presentation mode", isOn: $controller.isPresentationMode)
                .toggleStyle(.checkbox).font(.system(size: 11))
            Spacer()
            MenuIconButton(systemImage: "plus", help: "New Event") { controller.openNewGoogleEvent() }
            MenuIconButton(systemImage: "gearshape", help: "Settings") { controller.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(ShieldTheme.sidebar)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct MenuIconButton: View {
    var systemImage: String
    var help: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: systemImage).frame(width: 22, height: 22) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(help).accessibilityLabel(help)
    }
}

struct MiniMonthCalendarView: View {
    @Binding var selectedDate: Date
    private let calendar = Calendar.current
    private let weekdays = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        let days = monthDays()
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(monthTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ShieldTheme.secondaryText)
                Spacer()
                MonthNavigationButton(systemImage: "chevron.left", help: "Previous month") {
                    moveMonth(by: -1)
                }
                MonthNavigationButton(systemImage: "chevron.right", help: "Next month") {
                    moveMonth(by: 1)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 8) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, weekday in
                    Text(weekday)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ShieldTheme.secondaryText)
                        .frame(width: 28, height: 18)
                }
                ForEach(days.indices, id: \.self) { index in
                    if let date = days[index] {
                        Text("\(calendar.component(.day, from: date))")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(calendar.isDateInToday(date) ? Color.white : ShieldTheme.primaryText)
                            .frame(width: 28, height: 22)
                            .background(calendar.isDateInToday(date) ? ShieldTheme.accent.opacity(0.92) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else {
                        Color.clear.frame(width: 28, height: 22)
                    }
                }
            }
        }
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: selectedDate)
    }

    private func moveMonth(by offset: Int) {
        guard let newDate = calendar.date(byAdding: .month, value: offset, to: selectedDate) else { return }
        selectedDate = newDate
    }

    private func monthDays() -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: selectedDate),
              let range = calendar.range(of: .day, in: .month, for: selectedDate) else {
            return []
        }
        let leading = mondayFirstWeekdayIndex(for: interval.start)
        let dates: [Date?] = range.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: interval.start)
        }
        return Array(repeating: nil, count: leading) + dates
    }

    private func mondayFirstWeekdayIndex(for date: Date) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }
}

private struct MonthNavigationButton: View {
    var systemImage: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(ShieldTheme.secondaryText)
        .help(help)
        .accessibilityLabel(help)
    }
}
