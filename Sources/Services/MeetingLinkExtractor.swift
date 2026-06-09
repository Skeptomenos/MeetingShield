import Foundation

struct MeetingLinkExtractor: Sendable {
    private static let genericConferenceHosts = [
        "meet.google.com",
        "zoom.us",
        "teams.microsoft.com",
        "webex.com",
        "whereby.com",
        "gotomeeting.com",
        "bluejeans.com",
        "chime.aws"
    ]

    func extractLinks(from event: CalendarEventOccurrence) -> [MeetingLink] {
        var links: [MeetingLink] = []
        links.append(contentsOf: event.conferenceLinks)
        if let location = event.location {
            links.append(contentsOf: Self.extractURLs(from: location, source: .location))
        }
        if let description = event.eventDescription {
            links.append(contentsOf: Self.extractURLs(from: description, source: .description))
        }
        return dedupe(links).sorted { lhs, rhs in
            sourceRank(lhs.source) == sourceRank(rhs.source)
                ? lhs.normalizedURLString < rhs.normalizedURLString
                : sourceRank(lhs.source) < sourceRank(rhs.source)
        }
    }

    static func textContainsURL(_ text: String) -> Bool {
        !extractURLs(from: text, source: .description).isEmpty
    }

    static func extractURLs(from text: String, source: MeetingLinkSource) -> [MeetingLink] {
        let candidates = urlCandidates(in: text)
        return candidates.compactMap { candidate in
            guard let url = normalizedURL(from: candidate),
                  let kind = classify(url: url) else {
                return nil
            }
            return MeetingLink(url: url, kind: kind, source: source)
        }
    }

    private func dedupe(_ links: [MeetingLink]) -> [MeetingLink] {
        var seen: Set<String> = []
        var result: [MeetingLink] = []
        for link in links {
            guard !seen.contains(link.normalizedURLString) else { continue }
            seen.insert(link.normalizedURLString)
            result.append(link)
        }
        return result
    }

    private func sourceRank(_ source: MeetingLinkSource) -> Int {
        switch source {
        case .conferenceMetadata: 0
        case .location: 1
        case .description: 2
        }
    }

    private static func urlCandidates(in text: String) -> [String] {
        let pattern = #"(?i)\b((?:https?://)?(?:[\w-]+\.)+(?:com|us|net|org|io|co|app|dev|ai)(?:/[^\s<>"']*)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,);]"))
        }
    }

    private static func normalizedURL(from candidate: String) -> URL? {
        var string = candidate
        if !string.lowercased().hasPrefix("http://") && !string.lowercased().hasPrefix("https://") {
            string = "https://\(string)"
        }
        guard var components = URLComponents(string: string),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        components.scheme = components.scheme?.lowercased() ?? "https"
        components.host = host.lowercased()
        return components.url
    }

    private static func classify(url: URL) -> MeetingLinkKind? {
        guard let host = url.host?.lowercased() else { return nil }
        if host == "meet.google.com" { return .googleMeet }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") { return .zoom }
        if host == "teams.microsoft.com" { return .teams }
        if host.contains("webex.com") { return .webex }
        if genericConferenceHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
            return .generic
        }
        if url.path.lowercased().contains("meeting") || url.path.lowercased().contains("join") {
            return .generic
        }
        return nil
    }
}
