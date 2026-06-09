import AppKit
import SwiftUI

struct MenuContentView: View {
    static let preferredWidth: CGFloat = 292
    static let fixedHeightExcludingAgendaRows: CGFloat = 450
    static let agendaRowHeight: CGFloat = 26

    @ObservedObject var controller: MeetingShieldController
    var popoverHeight: CGFloat
    @State private var selectedMonth = Date()

    static func preferredHeight(eventCount: Int) -> CGFloat {
        fixedHeightExcludingAgendaRows + CGFloat(eventCount) * agendaRowHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusSection
                .padding(.horizontal, 12)
                .padding(.top, 9)
                .padding(.bottom, 8)

            MenuDivider()

            nextSection
                .padding(.horizontal, 12)
                .padding(.vertical, 11)

            MenuDivider()

            agendaSection
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            MenuDivider()

            MiniMonthCalendarView(selectedDate: $selectedMonth)
                .padding(.horizontal, 12)
                .padding(.top, 11)
                .padding(.bottom, 21)

            bottomBar
        }
        .frame(width: Self.preferredWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .background(LiquidGlassTheme.popoverFill)
    }

    @ViewBuilder
    private var statusSection: some View {
        if let status = controller.statusMessage {
            Label(status, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LiquidGlassTheme.warning)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else if case .disconnected = controller.authState {
            Label("Connect Google Calendar", systemImage: "calendar.badge.plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LiquidGlassTheme.warning)
        } else if case .needsConfiguration = controller.authState {
            Label("Google Calendar needs setup", systemImage: "gearshape")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LiquidGlassTheme.warning)
        } else if case .authenticating = controller.authState {
            Label("Connecting Google Calendar", systemImage: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LiquidGlassTheme.secondaryText)
        } else if case .expired = controller.authState {
            Label("Reconnect Google Calendar", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LiquidGlassTheme.warning)
        } else if controller.isPresentationMode {
            Label("Presentation mode", systemImage: "bell.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LiquidGlassTheme.secondaryText)
        } else {
            Label("Protecting meetings", systemImage: "checkmark.shield")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LiquidGlassTheme.secondaryText)
        }
    }

    private var reconnectTitle: String {
        switch controller.authState {
        case .disconnected, .needsConfiguration:
            "Connect Google Calendar"
        case .authenticating:
            "Connecting Google Calendar"
        case .connected, .expired:
            "Reconnect Google Calendar"
        }
    }

    @ViewBuilder
    private var nextSection: some View {
        if let event = controller.nextEvent {
            VStack(alignment: .leading, spacing: 6) {
                Text("NEXT")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(LiquidGlassTheme.secondaryText)
                Text(event.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LiquidGlassTheme.primaryText)
                    .lineLimit(1)
                Text("\(DateFormatter.shortTimeString(from: event.startDate)) · \(controller.displayCalendarName(for: event))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LiquidGlassTheme.secondaryText)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("NEXT")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(LiquidGlassTheme.secondaryText)
                Text("No meetings in view")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LiquidGlassTheme.secondaryText)
            }
        }
    }

    private var agendaSection: some View {
        let menuEvents = controller.menuEvents
        return VStack(alignment: .leading, spacing: 8) {
            Text("AGENDA")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(LiquidGlassTheme.secondaryText)
            if !menuEvents.isEmpty {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(menuEvents) { event in
                            HStack(spacing: 8) {
                                Text(DateFormatter.shortTimeString(from: event.startDate))
                                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                                    .monospacedDigit()
                                    .foregroundStyle(LiquidGlassTheme.secondaryText)
                                    .frame(width: 48, alignment: .leading)
                                Text(event.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(LiquidGlassTheme.primaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .layoutPriority(1)
                                Spacer(minLength: 0)
                                Text(controller.displayCalendarName(for: event))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(LiquidGlassTheme.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(width: 86, alignment: .trailing)
                            }
                            .frame(height: Self.agendaRowHeight - 8)
                        }
                    }
                }
                .frame(height: agendaListHeight(eventCount: menuEvents.count))
            }
        }
    }

    private func agendaListHeight(eventCount: Int) -> CGFloat {
        let desiredHeight = CGFloat(eventCount) * Self.agendaRowHeight
        let availableHeight = max(Self.agendaRowHeight, popoverHeight - Self.fixedHeightExcludingAgendaRows)
        return min(desiredHeight, availableHeight)
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            MenuIconButton(systemImage: "plus", help: "New Event") {
                controller.openNewGoogleEvent()
            }
            if shouldShowReconnectAction {
                MenuIconButton(systemImage: "arrow.clockwise", help: reconnectTitle) {
                    controller.reconnectGoogle()
                }
            }
            MenuIconButton(systemImage: controller.isPresentationMode ? "bell.slash.fill" : "bell.slash", help: "Presentation Mode") {
                controller.isPresentationMode.toggle()
            }
            Spacer()
            MenuIconButton(systemImage: "gearshape", help: "Settings") {
                controller.openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.thinMaterial)
        .background(Color.white.opacity(0.045))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LiquidGlassTheme.separator)
                .frame(height: 1)
        }
    }

    private var shouldShowReconnectAction: Bool {
        switch controller.authState {
        case .connected, .authenticating:
            controller.statusMessage != nil
        case .disconnected, .needsConfiguration, .expired:
            true
        }
    }
}

private struct MenuIconButton: View {
    var systemImage: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(LiquidGlassTheme.secondaryText)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct MenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(LiquidGlassTheme.separator)
            .frame(height: 1)
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
                    .foregroundStyle(LiquidGlassTheme.secondaryText)
                Spacer()
                MonthNavigationButton(systemImage: "chevron.left", help: "Previous month") {
                    moveMonth(by: -1)
                }
                MonthNavigationButton(systemImage: "chevron.right", help: "Next month") {
                    moveMonth(by: 1)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 0), count: 7), spacing: 8) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, weekday in
                    Text(weekday)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(LiquidGlassTheme.secondaryText)
                        .frame(width: 28, height: 18)
                }
                ForEach(days.indices, id: \.self) { index in
                    if let date = days[index] {
                        Text("\(calendar.component(.day, from: date))")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(calendar.isDateInToday(date) ? Color.white : LiquidGlassTheme.primaryText)
                            .frame(width: 28, height: 22)
                            .background(calendar.isDateInToday(date) ? LiquidGlassTheme.accent.opacity(0.92) : Color.clear)
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
        .foregroundStyle(LiquidGlassTheme.secondaryText)
        .help(help)
        .accessibilityLabel(help)
    }
}
