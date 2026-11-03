import Foundation

/// What a film or series page shows beyond its reviews, for titles 5heures.be discusses: a synopsis,
/// the French title, the director. Dayez's films get theirs from TMDB along with their posters (`FilmInfo`).
public struct WorkDetails: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// The film's page on 5heures.be.
        case site
        /// A TMDB search, for series: the site has no page for them.
        case tmdb
    }

    public let overview: String
    /// The French title, when it isn't the one 5heures.be uses.
    public let localTitle: String?
    public let director: String?
    public let source: Source

    public init(overview: String, localTitle: String? = nil, director: String? = nil, source: Source) {
        self.overview = overview
        self.localTitle = localTitle
        self.director = director
        self.source = source
    }

    /// Which details a work has, if any can be looked up: a film by its page on the site, a series by name.
    public static func key(for work: Work) -> String? {
        switch work.kind {
        case .movie: work.mentions.lazy.compactMap(\.segment.slug).first.map { "movie:" + $0 }
        case .tvShow: "tv:" + Search.fold(work.mentions.first?.segment.displayTitle ?? work.title)
        default: nil
        }
    }
}

extension SiteClient {
    struct MoviePage: Decodable {
        struct Movie: Decodable {
            struct Person: Decodable {
                struct Job: Decodable { let name: String? }
                let name: String?
                let job: Job?
            }
            let name: String?
            let name_fr: String?
            let overview: String?
            let people: [Person]?
        }
        let movie: Movie
    }

    /// A film's synopsis, French title and director, from its page on the site. `nil` when the page has no synopsis.
    public func movieDetails(slug: String) async throws -> WorkDetails? {
        let path = "api/movies/" + (slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug)
        return Self.details(fromMoviePage: try await get(path, query: []))
    }

    static func details(fromMoviePage data: Data) -> WorkDetails? {
        guard let movie = try? JSONDecoder().decode(MoviePage.self, from: data).movie,
              let overview = movie.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty
        else { return nil }
        let directors = (movie.people ?? []).filter { $0.job?.name == "Director" }.compactMap(\.name)
        let local = movie.name_fr.flatMap { $0.isEmpty || $0 == movie.name ? nil : $0 }
        return WorkDetails(overview: overview, localTitle: local,
                           director: directors.isEmpty ? nil : directors.prefix(2).joined(separator: " et "), source: .site)
    }
}

extension TMDBClient {
    struct SeriesPage: Decodable {
        struct Result: Decodable {
            let name: String
            let original_name: String
            let first_air_date: String?
            let overview: String?
            let popularity: Double?
        }
        let results: [Result]
    }

    /// The series 5heures.be calls `title`, discussed on `date`: one of the same name that had started by
    /// then (a series is reviewed at any season). `nil` when none fits or it has no French synopsis.
    public func seriesDetails(titled title: String, discussedOn date: Date) async throws -> WorkDetails? {
        let page: SeriesPage = try await get("search/tv", ["query": title, "language": "fr-FR", "include_adult": "false"])
        return Self.series(in: page, titled: title, discussedOn: date)
    }

    static func series(in page: SeriesPage, titled title: String, discussedOn date: Date) -> WorkDetails? {
        let fitting = page.results.filter { result in
            guard similarity(of: title, to: [result.name, result.original_name]) == 10,
                  let started = releaseDate(result.first_air_date) else { return false }
            return started < date.addingTimeInterval(60 * 86_400)
        }
        guard let chosen = fitting.max(by: { ($0.popularity ?? 0) < ($1.popularity ?? 0) }),
              let overview = chosen.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty
        else { return nil }
        let local = chosen.name == chosen.original_name || Search.fold(chosen.name) == Search.fold(title) ? nil : chosen.name
        return WorkDetails(overview: overview, localTitle: local, source: .tmdb)
    }
}

/// The details found so far, by `WorkDetails.key(for:)`, kept between launches. A title is looked up
/// when its page is opened; one with nothing to show is asked about again after a week.
public struct WorkDetailsLibrary: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let details: WorkDetails?
        public let checked: Date
    }

    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    public func details(for key: String) -> WorkDetails? { entries[key]?.details }

    public func needsLookup(_ key: String, now: Date = Date()) -> Bool {
        guard let entry = entries[key] else { return true }
        return entry.details == nil && now.timeIntervalSince(entry.checked) > 7 * 86_400
    }

    public mutating func record(_ details: WorkDetails?, for key: String, at now: Date = Date()) {
        entries[key] = Entry(details: details, checked: now)
    }

    public static var defaultLocation: URL {
        URL.applicationSupportDirectory.appendingPathComponent("CinqHeures/details.json")
    }

    public static func load(from url: URL = defaultLocation) -> WorkDetailsLibrary {
        guard let data = try? Data(contentsOf: url), let library = try? JSONDecoder().decode(WorkDetailsLibrary.self, from: data)
        else { return WorkDetailsLibrary() }
        return library
    }

    public func save(to url: URL = defaultLocation) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
