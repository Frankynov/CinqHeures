import Foundation

/// A film, series or person, with every time it has been discussed (some films come back).
public struct Work: Identifiable, Sendable {
    public struct Mention: Identifiable, Sendable {
        public let episode: Episode
        public let segment: Segment
        public var id: Int { segment.id }

        public init(episode: Episode, segment: Segment) {
            self.episode = episode
            self.segment = segment
        }
    }

    public let title: String
    public let kind: SegmentKind
    /// Newest first.
    public let mentions: [Mention]
    public var id: String { "\(kind.rawValue)|\(title)" }
    public var posterURL: URL? { mentions.lazy.compactMap(\.segment.posterURL).first }
}

public enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case all, movies, shows, people
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "Tout"
        case .movies: "Films"
        case .shows: "Séries"
        case .people: "Personnalités"
        }
    }

    func includes(_ kind: SegmentKind) -> Bool {
        switch self {
        case .all: kind.isSubject
        case .movies: kind == .movie
        case .shows: kind == .tvShow
        case .people: kind == .person
        }
    }
}

public enum Search {
    /// Lower case, no accents, punctuation as spaces: "Amélie Poulain" and "amelie-poulain" match.
    public static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        var out = ""
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Everything that matches, best title first, optionally limited to some of the shows.
    /// Builds an index each time: for repeated searches keep a `SearchIndex` instead.
    public static func works(matching query: String, in catalogue: Catalogue, scope: SearchScope = .all,
                             series: Set<Series> = Set(Series.allCases), stars: Int? = nil) -> [Work] {
        SearchIndex(catalogue).works(matching: query, scope: scope, series: series, stars: stars)
    }

    /// Episodes whose title or description (which names directors, actors and artists) mentions every word.
    public static func episodes(describedBy query: String, in catalogue: Catalogue,
                                series: Set<Series> = Set(Series.allCases)) -> [Episode] {
        SearchIndex(catalogue).episodes(describedBy: query, series: series)
    }

    /// 0 the whole title, 1 starts with it, 2 a word starts with it, 3 anywhere inside.
    static func rank(of title: String, phrase: String, tokens: [String]) -> Int {
        // Titles end with their year, "the substance 2024": ignore it when it isn't being searched.
        let bare = title.replacingOccurrences(of: #" \d{4}$"#, with: "", options: .regularExpression)
        if bare == phrase || title == phrase { return 0 }
        if title.hasPrefix(phrase) { return 1 }
        let words = Set(title.split(separator: " ").map(String.init))
        let wordStarts = tokens.allSatisfy { token in words.contains { $0.hasPrefix(token) } }
        return wordStarts ? 2 : 3
    }
}

/// A catalogue prepared for searching: every title and summary is folded once, here, instead of
/// on every keystroke (folding all ~5,000 titles and 1,400 long summaries takes ~150 ms).
public struct SearchIndex: Sendable {
    private struct Entry: Sendable {
        let episode: Int
        let segment: Int
        let folded: String
    }

    private let episodes: [Episode]
    private let entries: [Entry]
    private let summaries: [String]

    public init(_ catalogue: Catalogue) {
        episodes = catalogue.episodes
        summaries = episodes.map { Search.fold(($0.name ?? "") + " " + $0.summary) }
        entries = episodes.enumerated().flatMap { e, episode in
            episode.segments.enumerated().compactMap { s, segment in
                segment.kind.isSubject ? Entry(episode: e, segment: s, folded: Search.fold(segment.title)) : nil
            }
        }
    }

    /// Works matching every word of `query`. With `stars`, only the passages given that score, and
    /// then an empty query lists them all, newest first.
    public func works(matching query: String, scope: SearchScope = .all,
                      series: Set<Series> = Set(Series.allCases), stars: Int? = nil) -> [Work] {
        let tokens = Search.fold(query).split(separator: " ").map(String.init)
        guard !tokens.isEmpty || stars != nil else { return [] }
        let phrase = tokens.joined(separator: " ")

        struct Hit { var title: String; var kind: SegmentKind; var mentions: [Work.Mention] = []; var rank = Int.max }
        var hits: [String: Hit] = [:]
        for entry in entries {
            let episode = episodes[entry.episode]
            let segment = episode.segments[entry.segment]
            guard scope.includes(segment.kind), series.contains(episode.series),
                  stars == nil || segment.stars == stars,
                  tokens.allSatisfy({ entry.folded.contains($0) }) else { continue }
            let key = "\(segment.kind.rawValue)|\(segment.title)"
            var hit = hits[key] ?? Hit(title: segment.title, kind: segment.kind)
            hit.mentions.append(.init(episode: episode, segment: segment))
            hit.rank = min(hit.rank, Search.rank(of: entry.folded, phrase: phrase, tokens: tokens))
            hits[key] = hit
        }
        let byDate = tokens.isEmpty
        return hits.values
            .sorted { lhs, rhs in
                if byDate {
                    let (a, b) = (lhs.mentions.map(\.episode.date).max() ?? .distantPast, rhs.mentions.map(\.episode.date).max() ?? .distantPast)
                    return a > b
                }
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .map { Work(title: $0.title, kind: $0.kind, mentions: $0.mentions.sorted { $0.episode.date > $1.episode.date }) }
    }

    /// One film, series or person with every passage about it.
    public func work(kind: SegmentKind, title: String) -> Work? {
        let mentions = entries.compactMap { entry -> Work.Mention? in
            let episode = episodes[entry.episode]
            let segment = episode.segments[entry.segment]
            return segment.kind == kind && segment.title == title ? .init(episode: episode, segment: segment) : nil
        }
        guard !mentions.isEmpty else { return nil }
        return Work(title: title, kind: kind, mentions: mentions.sorted { $0.episode.date > $1.episode.date })
    }

    public func episodes(describedBy query: String, series: Set<Series> = Set(Series.allCases)) -> [Episode] {
        let tokens = Search.fold(query).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        return zip(episodes, summaries).compactMap { episode, text in
            series.contains(episode.series) && tokens.allSatisfy({ text.contains($0) }) ? episode : nil
        }
    }
}
