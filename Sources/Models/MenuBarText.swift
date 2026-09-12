import Foundation

struct MenuBarText: Equatable, Sendable {
    static let maximumTitleCharacters = 24
    static let maximumWidth: CGFloat = 220

    var preferred: String
    var fallback: String

    static func make(
        event: CalendarEventOccurrence?,
        now: Date,
        showEventTitle: Bool
    ) -> MenuBarText {
        guard let event else {
            return MenuBarText(preferred: AppIdentity.menuBarTitle, fallback: AppIdentity.menuBarTitle)
        }
        let countdown = RelativeDateTimeFormatter.shortString(for: event.startDate, relativeTo: now)
        guard showEventTitle else {
            return MenuBarText(preferred: countdown, fallback: countdown)
        }
        let title = compactTitle(event.title)
        return MenuBarText(preferred: "\(countdown) \(title)", fallback: countdown)
    }

    func resolved(
        maximumWidth: CGFloat = Self.maximumWidth,
        measure: (String) -> CGFloat
    ) -> String {
        measure(preferred) <= maximumWidth ? preferred : fallback
    }

    private static func compactTitle(_ title: String) -> String {
        guard title.count > maximumTitleCharacters else { return title }
        return String(title.prefix(maximumTitleCharacters - 1)) + "…"
    }
}
