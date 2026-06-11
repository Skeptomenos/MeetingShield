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
        // Broad TLD match; the classifier decides what counts as a meeting link.
        let pattern = #"(?i)\b((?:https?://)?(?:[\w-]+\.)+[a-z]{2,24}(?:/[^\s<>"']*)?)"#
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

    /// Host labels that mark a domain as conferencing infrastructure
    /// (e.g. meet.company.de, video.example.org).
    private static let conferenceHostLabels: Set<String> = [
        "meet", "meeting", "meetings", "video", "vc", "conference", "webinar"
    ]

    /// Exact path segments that mark a link as joinable on unknown hosts.
    private static let conferencePathSegments: Set<String> = ["join", "meet", "meeting", "meetings"]

    private static func classify(url: URL) -> MeetingLinkKind? {
        guard let host = url.host?.lowercased() else { return nil }
        if host == "meet.google.com" { return .googleMeet }
        if hostMatches(host, domain: "zoom.us") || hostMatches(host, domain: "zoom.com") || hostMatches(host, domain: "zoomgov.com") {
            return .zoom
        }
        if host == "teams.microsoft.com" || host == "teams.live.com" { return .teams }
        if host.contains("webex.com") { return .webex }
        if genericConferenceHosts.contains(where: { hostMatches(host, domain: $0) }) {
            return .generic
        }
        // Self-hosted conferencing: meet.company.de, video.corp.example.
        if let firstLabel = host.split(separator: ".").first,
           conferenceHostLabels.contains(String(firstLabel)) {
            return .generic
        }
        // Unknown host: only exact join/meeting path segments count, and the
        // segment must start with the marker word to avoid editorial URLs
        // ("/posts/why-meetings-suck", "/join-our-newsletter").
        let segments = url.path.lowercased().split(separator: "/").map(String.init)
        if segments.contains(where: { segment in
            conferencePathSegments.contains(segment) || segment.hasPrefix("meeting-")
        }) {
            return .generic
        }
        return nil
    }

    private static func hostMatches(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }
}
