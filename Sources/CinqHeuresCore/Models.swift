import Foundation

/// The four shows 5heures.be publishes, named the way the site's API names them, and the two that
/// come as podcast feeds: Rudy Léonet's "Il est toujours 5 heures quelque part" (on Ausha) and
/// Hugues Dayez's weekly reviews.
///
/// The order of the cases is the sidebar's order.
public enum Series: String, Codable, CaseIterable, Sendable, Identifiable {
    case podcast = "cinq_heures"
    case quelquePart = "ausha_quelque_part"
    /// Hugues Dayez's weekly reviews of three new films, from Franky's own Audiobookshelf feed.
    case dayez = "feed_dayez"
    case codLive = "cod_live"
    case soir = "cinq_heures_du_soir"
    case autre = "other"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .podcast: "Podcast"
        case .soir: "5 heures du soir"
        case .codLive: "COD Live"
        case .autre: "Autre"
        case .quelquePart: "Il est toujours 5 heures quelque part"
        case .dayez: "Hugues Dayez"
        }
    }

    /// Who makes it, for the shows that aren't 5heures.be's own.
    public var host: String? {
        switch self {
        case .quelquePart: "Rudy Léonet"
        case .dayez: "Hugues Dayez"
        default: nil
        }
    }

    /// Short label for the badge in a list row.
    public var badge: String {
        switch self {
        case .podcast: "Podcast"
        case .soir: "5H du soir"
        case .codLive: "COD Live"
        case .autre: "Autre"
        case .quelquePart: "Quelque part"
        case .dayez: "Dayez"
        }
    }

    /// The full name, for a window title.
    public var fullTitle: String {
        switch self {
        case .quelquePart: "Il est toujours 5 heures quelque part"
        case .dayez: "Les critiques d'Hugues Dayez"
        default: title
        }
    }

    /// Whether the audio comes from 5heures.be's own (slow when cold) server.
    public var isOnSite: Bool { self != .quelquePart && self != .dayez }

    /// The shows read from a podcast feed rather than from 5heures.be.
    public static let fromFeeds: [Series] = [.quelquePart, .dayez]
}

public enum SegmentKind: String, Codable, Sendable {
    case introduction, movie, conclusion, other, person
    case tvShow = "tv_show"

    /// Films, series and people are what you look up; the rest is the show's own chatter.
    public var isSubject: Bool { self == .movie || self == .tvShow || self == .person }

    public var label: String {
        switch self {
        case .movie: "Film"
        case .tvShow: "Série"
        case .person: "Personnalité"
        case .introduction: "Introduction"
        case .conclusion: "Conclusion"
        case .other: "Divers"
        }
    }
}

/// One thing discussed in an episode: a film, a series, a person, the intro…
public struct Segment: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let kind: SegmentKind
    /// Where it starts in the episode's audio. Missing for a few old entries.
    public let start: Double?
    /// The hosts' verdict in their own words ("4 bonnes doses", "2 brigadiers"): the unit is a
    /// running joke, only the number means anything.
    public let verdict: String?
    /// That number, 0 to 4 (a few old entries have halves). Missing before 2011 and when they
    /// didn't give one.
    public let score: Double?
    public let posterURL: URL?
    /// From TMDB, for films that don't come from 5heures.be: a synopsis, the director, and the
    /// French title when it differs from `title` (which is the original, as 5heures.be has it).
    public let overview: String?
    public let director: String?
    public let localTitle: String?

    public init(id: Int, title: String, kind: SegmentKind, start: Double?, verdict: String?,
                score: Double? = nil, posterURL: URL?, overview: String? = nil, director: String? = nil,
                localTitle: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.start = start
        self.verdict = verdict
        self.score = score
        self.posterURL = posterURL
        self.overview = overview
        self.director = director
        self.localTitle = localTitle
    }

    /// The release year at the end of a film's title: "Oblivion (2013)" is 2013.
    public var year: Int? {
        guard let range = title.range(of: #"\((\d{4})\)\s*$"#, options: .regularExpression) else { return nil }
        return Int(title[range].filter(\.isNumber))
    }

    /// The title without that year.
    public var displayTitle: String {
        year == nil ? title : title.replacingOccurrences(of: #"\s*\(\d{4}\)\s*$"#, with: "", options: .regularExpression)
    }

    /// The score as whole stars, 0 to 4.
    public var stars: Int? { score.map { Int(min(max($0, 0), 4).rounded(.down)) } }

    /// The verdict without the "Pas de cotation" placeholder.
    public var spokenVerdict: String? { verdict.flatMap { $0 == "Pas de cotation" ? nil : $0 } }

    /// "4", "1,5" and "3 porte-avions" are all scores; "Pas de cotation" and "" aren't.
    public static func parseScore(_ text: String?) -> Double? {
        guard let text, let range = text.range(of: #"^\s*\d+(?:[.,]\d+)?"#, options: .regularExpression) else { return nil }
        return Double(text[range].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// "★★★☆" for 3.
    public static func starString(_ stars: Int) -> String {
        String(repeating: "★", count: stars) + String(repeating: "☆", count: max(0, 4 - stars))
    }
}

public struct Episode: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let series: Series
    /// The day it was recorded, which is what the site's title says ("Podcast du 27/06/2025").
    /// The API's own `available_at` runs about a month later.
    public let date: Date
    public let summary: String
    public let audioURL: URL
    public let segments: [Segment]
    /// The episode's own title, for shows whose episodes have one ("Episode #44 - 20 octobre 2026").
    public let name: String?
    /// A square cover, for shows that have one instead of film posters.
    public let artwork: URL?
    /// Length in seconds, when the source says.
    public let duration: Double?

    public init(id: Int, series: Series, date: Date, summary: String, audioURL: URL, segments: [Segment],
                name: String? = nil, artwork: URL? = nil, duration: Double? = nil) {
        self.id = id
        self.series = series
        self.date = date
        self.summary = summary
        self.audioURL = audioURL
        self.segments = segments
        self.name = name
        self.artwork = artwork
        self.duration = duration
    }

    public var title: String { name ?? "\(series.title) du \(EpisodeDates.short.string(from: date))" }

    /// For a Dayez episode, the films as its title names them ("Coward · Wicker · Karma"), whatever
    /// its segments have since been renamed to: what TMDB lookups are keyed by.
    public var spokenFilms: [String] {
        guard series == .dayez, !segments.isEmpty, let name else { return [] }
        return name.components(separatedBy: " · ")
    }

    /// The films, series and people, in the order they're discussed.
    public var subjects: [Segment] { segments.filter { $0.kind.isSubject } }
    public var year: Int { EpisodeDates.calendar.component(.year, from: date) }
}

public enum EpisodeDates {
    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Brussels")!
        return calendar
    }()

    /// "27/06/2025".
    public static let short: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "fr_BE")
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter
    }()

    /// "vendredi 27 juin 2025".
    public static let long: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "fr_BE")
        formatter.dateFormat = "EEEE d MMMM yyyy"
        return formatter
    }()
}
