import Foundation

/// A repeatable shuffle: the same seed gives the same "random" shelves, which keeps tests stable
/// and lets the app reshuffle on demand.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A way of browsing the archive: what a shelf's "Tout voir" opens.
public enum Listing: Hashable, Sendable {
    case latest, rediscover, series, people, repeats, codLive
    case stars(Int)
    /// A decade by its first year; 0 is everything before 1960.
    case decade(Int)

    public var title: String {
        switch self {
        case .latest: "Derniers passages"
        case .rediscover: "À redécouvrir"
        case .series: "Séries"
        case .people: "Rencontres"
        case .repeats: "Revenus plusieurs fois"
        case .codLive: "Critic On Demand Live"
        case .stars(let n): "Films notés \(n)/4"
        case .decade(let d): Decade.title(d)
        }
    }
}

public enum Decade {
    public static let all = [0, 1960, 1970, 1980, 1990, 2000, 2010, 2020]

    public static func of(year: Int) -> Int { year < 1960 ? 0 : year / 10 * 10 }

    public static func title(_ decade: Int) -> String {
        switch decade {
        case 0: "Avant 1960"
        case 2000: "Années 2000"
        case 2010: "Années 2010"
        case 2020: "Années 2020"
        default: "Années \(decade % 100)"
        }
    }
}

public struct DecadeTile: Identifiable, Sendable {
    public let decade: Int
    public let count: Int
    /// A few posters to build the tile's collage from.
    public let posters: [URL]
    public var id: Int { decade }
    public var title: String { Decade.title(decade) }
}

public enum ShelfItem: Identifiable, Sendable {
    case passage(Work.Mention)
    case episode(Episode, resume: Double?)

    public var id: String {
        switch self {
        case .passage(let mention): "p|\(mention.segment.kind.rawValue)|\(mention.segment.title)"
        case .episode(let episode, _): "e|\(episode.id)"
        }
    }
}

public struct Shelf: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let items: [ShelfItem]
    /// Where "Tout voir" goes.
    public let listing: Listing?
    public let show: Series?
}

/// What the home page and the browse pages show, drawn from the catalogue.
public struct Discovery: Sendable {
    /// Every film, series and person passage, newest first.
    private let passages: [Work.Mention]
    private let episodes: [Episode]

    public init(_ catalogue: Catalogue) {
        episodes = catalogue.episodes
        passages = catalogue.episodes.flatMap { episode in
            episode.segments.filter { $0.kind.isSubject }.map { Work.Mention(episode: episode, segment: $0) }
        }
    }

    private func films() -> [Work.Mention] { passages.filter { $0.segment.kind == .movie } }

    /// One passage per work: the newest.
    private func unique(_ list: [Work.Mention]) -> [Work.Mention] {
        var seen = Set<String>()
        return list.filter { seen.insert("\($0.segment.kind.rawValue)|\($0.segment.title)").inserted }
    }

    private func hasPoster(_ mention: Work.Mention) -> Bool { mention.segment.posterURL != nil }

    // MARK: Whole listings

    /// Everything in a listing, in the order its page shows it.
    public func items(_ listing: Listing, now: Date = Date()) -> [ShelfItem] {
        let films = films()
        let thisYear = EpisodeDates.calendar.component(.year, from: now)
        let chosen: [Work.Mention]
        switch listing {
        case .latest:
            chosen = unique(films)
        case .stars(let n):
            chosen = unique(films.filter { $0.segment.stars == n })
        case .rediscover:
            chosen = unique(films.filter { ($0.segment.year ?? thisYear) <= thisYear - 10 && ($0.segment.stars ?? 0) >= 3 })
        case .series:
            chosen = unique(passages.filter { $0.segment.kind == .tvShow })
        case .people:
            chosen = unique(passages.filter { $0.segment.kind == .person })
        case .codLive:
            chosen = unique(films.filter { $0.episode.series == .codLive })
        case .repeats:
            var counts: [String: Int] = [:]
            for film in films { counts["\(film.segment.title)", default: 0] += 1 }
            chosen = unique(films.filter { counts[$0.segment.title, default: 0] >= 2 })
                .sorted { counts[$0.segment.title, default: 0] > counts[$1.segment.title, default: 0] }
        case .decade(let decade):
            chosen = unique(films.filter { $0.segment.year.map(Decade.of(year:)) == decade })
                .sorted { ($0.segment.stars ?? -1) > ($1.segment.stars ?? -1) }
        }
        return chosen.map(ShelfItem.passage)
    }

    // MARK: Home

    /// The home page's poster shelves. `seed` picks the random ones; the same seed gives the same shelves.
    public func shelves(seed: UInt64, size: Int = 20) -> [Shelf] {
        var rng = SeededGenerator(seed: seed)
        func sample(_ listing: Listing, title: String, id: String) -> Shelf {
            let withPoster = items(listing).filter { if case .passage(let m) = $0 { hasPoster(m) } else { false } }
            return Shelf(id: id, title: title, items: Array(withPoster.shuffled(using: &rng).prefix(size)),
                         listing: listing, show: nil)
        }
        // No "latest" shelf: the 5heures.be archive no longer grows, so it would never change.
        // The music podcast, which does, comes right after the first shelf. "À redécouvrir" leads:
        // it draws on far more films than the 4-star shelf, so a shuffle changes it more.
        var shelves = [
            sample(.rediscover, title: "À redécouvrir", id: "rediscover"),
            sample(.stars(4), title: "Coups de cœur ★★★★", id: "stars4"),
            sample(.series, title: "Séries", id: "series"),
            sample(.repeats, title: "Revenus plusieurs fois", id: "repeats"),
            sample(.people, title: "Rencontres", id: "people"),
            sample(.codLive, title: "Critic On Demand Live", id: "cod"),
        ]
        // The shows that still get new episodes, right after the first shelf.
        for (offset, show) in Series.fromFeeds.enumerated() {
            let latest = episodes.filter { $0.series == show }.prefix(12)
            guard !latest.isEmpty else { continue }
            shelves.insert(Shelf(id: "feed-\(show.rawValue)", title: show.fullTitle,
                                 items: latest.map { .episode($0, resume: nil) }, listing: nil, show: show),
                           at: min(1 + offset, shelves.count))
        }
        return shelves.filter { !$0.items.isEmpty }
    }

    /// Whether a passage is still in the catalogue this was built from.
    public func contains(_ mention: Work.Mention) -> Bool {
        passages.contains { $0.segment.id == mention.segment.id }
    }

    /// A well-rated review to feature at the top of the home page.
    public func hero(seed: UInt64) -> Work.Mention? {
        var rng = SeededGenerator(seed: seed &+ 7)
        return unique(films().filter { ($0.segment.stars ?? 0) >= 3 && hasPoster($0) }).randomElement(using: &rng)
    }

    /// The decades that have films, each with some posters for its tile.
    public func decadeTiles(seed: UInt64) -> [DecadeTile] {
        var rng = SeededGenerator(seed: seed &+ 13)
        let all = unique(films())
        return Decade.all.compactMap { decade in
            let inDecade = all.filter { $0.segment.year.map(Decade.of(year:)) == decade }
            guard !inDecade.isEmpty else { return nil }
            let posters = inDecade.compactMap(\.segment.posterURL)
            return DecadeTile(decade: decade, count: inDecade.count, posters: Array(posters.shuffled(using: &rng).prefix(3)))
        }
    }
}
