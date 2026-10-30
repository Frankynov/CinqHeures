import Foundation

/// What TMDB knows about a film, kept once looked up. TMDB is also where 5heures.be's posters come from.
public struct FilmInfo: Codable, Hashable, Sendable {
    public let tmdbID: Int
    /// The French title, as released here.
    public let title: String
    /// The title in its own language: what 5heures.be names films by, so the same film links up.
    public let originalTitle: String
    public let year: Int?
    public let overview: String
    public let posterPath: String?
    public let director: String?

    public var posterURL: URL? { posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w500" + $0) } }

    /// "Coward (2026)": the way 5heures.be titles its films. The original title, unless it's in
    /// another script (Chinese, Arabic…), where the French one reads better.
    public var archiveTitle: String {
        let latin = originalTitle.unicodeScalars.allSatisfy { !$0.properties.isAlphabetic || $0.value < 0x0250 || (0x1E00...0x1EFF).contains($0.value) }
        let name = latin ? originalTitle : title
        return year.map { "\(name) (\($0))" } ?? name
    }
}

/// Looks films up on TMDB, through Franky's proxy (which holds the token) or, in tests, directly.
public struct TMDBClient: Sendable {
    public enum Route: Sendable {
        /// The PHP proxy on Franky's hosting: the token never leaves the server.
        case proxy(URL)
        /// Straight to TMDB with a token: tests only.
        case direct(token: String)
    }

    public static let proxyURL = URL(string: "https://frankynov.ovh/cinqheures/tmdb.php")!

    private let route: Route
    private let session: URLSession

    public init(route: Route = .proxy(TMDBClient.proxyURL), session: URLSession = SiteClient.uncachedSession) {
        self.route = route
        self.session = session
    }

    // MARK: Requests

    struct SearchPage: Decodable {
        struct Result: Decodable {
            let id: Int
            let title: String
            let original_title: String
            let release_date: String?
            let overview: String?
            let poster_path: String?
            let popularity: Double?
        }
        let results: [Result]
    }

    struct Details: Decodable {
        struct Credits: Decodable {
            struct Person: Decodable { let name: String; let job: String? }
            let cast: [Person]
            let crew: [Person]
        }
        let id: Int
        let title: String
        let original_title: String
        let release_date: String?
        let overview: String?
        let poster_path: String?
        let credits: Credits?
    }

    private func get<T: Decodable>(_ path: String, _ params: [String: String]) async throws -> T {
        var components: URLComponents
        var request: URLRequest
        switch route {
        case .proxy(let url):
            components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "path", value: path)]
                + params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            request = URLRequest(url: components.url!)
        case .direct(let token):
            components = URLComponents(string: "https://api.themoviedb.org/3/" + path)!
            components.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            request = URLRequest(url: components.url!)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        request.setValue(SiteClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SiteError.http(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Matching

    /// The film Dayez means by `title` in an episode recorded on `date`. `hints` is the episode's
    /// description, which often names the director or an actor ("Wicker avec Olivia Colman"): when it
    /// does, the candidate whose credits contain that name wins. `nil` when nothing fits.
    public func film(titled title: String, discussedOn date: Date, hints: String) async throws -> FilmInfo? {
        // French titles first; then English ones, for a film known here by its English name ("The Blue Trail").
        for language in ["fr-FR", "en-US"] {
            if let info = try await film(titled: title, discussedOn: date, hints: hints, searchingIn: language) { return info }
        }
        return nil
    }

    private func film(titled title: String, discussedOn date: Date, hints: String, searchingIn language: String) async throws -> FilmInfo? {
        let page: SearchPage = try await get("search/movie", ["query": title, "language": language, "include_adult": "false"])
        let ranked = Self.rank(page.results, query: title, around: date)
        guard !ranked.isEmpty else { return nil }

        let foldedHints = Search.fold(hints)
        let chosen = ranked[0]
        if !foldedHints.isEmpty {
            for candidate in ranked.prefix(3) {
                let details: Details = try await get("movie/\(candidate.id)", ["language": "fr-FR", "append_to_response": "credits"])
                if Self.names(in: details).contains(where: { foldedHints.contains(Search.fold($0)) }) {
                    return Self.info(details)
                }
            }
        }
        // No name to go by (or none matched): the best-ranked one, if it's a clear fit.
        guard Self.isConfident(chosen, query: title, around: date) else { return nil }
        let details: Details = try await get("movie/\(chosen.id)", ["language": "fr-FR", "append_to_response": "credits"])
        return Self.info(details)
    }

    /// Candidates released close to the episode, best first: same title, then release nearest the episode.
    static func rank(_ results: [SearchPage.Result], query: String, around date: Date) -> [SearchPage.Result] {
        let wanted = Search.fold(query)
        return results
            .compactMap { result -> (SearchPage.Result, Double)? in
                guard let released = releaseDate(result.release_date) else { return nil }
                let days = date.timeIntervalSince(released) / 86_400
                // Reviewed in the weeks around the release in Belgium; festival dates can be a year or two earlier.
                guard days > -120, days < 900 else { return nil }
                // The same title outweighs everything else: "Chopin, Chopin!" isn't "Chopin", however near its date.
                let similarity = similarity(of: query, to: [result.title, result.original_title])
                var score = Double(similarity == 10 ? 20 : similarity)
                score += max(0, 6 - abs(days) / 60)                 // the nearer the release, the better
                score += min(2, (result.popularity ?? 0) / 20)
                return (result, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// 10 the same title, 6 every word of it starts a word of theirs ("Miroirs n°3" and "Miroirs No. 3",
    /// "Downton Abbey, le grand final" and "Downton Abbey III : Le Grand Final"), 3 one inside the other, 0 else.
    static func similarity(of query: String, to titles: [String]) -> Int {
        let wanted = Search.fold(query)
        let compact = wanted.replacingOccurrences(of: " ", with: "")
        var best = 0
        for title in titles.map(Search.fold) {
            if title == wanted || title.replacingOccurrences(of: " ", with: "") == compact { return 10 }
            let theirs = title.split(separator: " ")
            if wanted.split(separator: " ").allSatisfy({ word in theirs.contains { $0.hasPrefix(word) } }) { best = max(best, 6) }
            else if title.contains(wanted) || wanted.contains(title) { best = max(best, 3) }
        }
        return best
    }

    static func isConfident(_ result: SearchPage.Result, query: String, around date: Date) -> Bool {
        guard similarity(of: query, to: [result.title, result.original_title]) >= 6 else { return false }
        guard let released = releaseDate(result.release_date) else { return false }
        return abs(date.timeIntervalSince(released)) < 400 * 86_400
    }

    static func names(in details: Details) -> [String] {
        let crew = details.credits?.crew.filter { $0.job == "Director" }.map(\.name) ?? []
        let cast = details.credits?.cast.prefix(10).map(\.name) ?? []
        return crew + cast
    }

    static func info(_ details: Details) -> FilmInfo {
        FilmInfo(tmdbID: details.id, title: details.title, originalTitle: details.original_title,
                 year: releaseDate(details.release_date).map { EpisodeDates.calendar.component(.year, from: $0) },
                 overview: details.overview ?? "", posterPath: details.poster_path,
                 director: details.credits?.crew.first { $0.job == "Director" }?.name)
    }

    static func releaseDate(_ text: String?) -> Date? {
        guard let text, text.count >= 10 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = EpisodeDates.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(text.prefix(10)))
    }
}

/// Films already looked up, saved between launches so each is asked about once.
public struct FilmLibrary: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let info: FilmInfo?
        public let checked: Date
    }

    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    public static func key(title: String, date: Date) -> String {
        "\(Search.fold(title))|\(EpisodeDates.calendar.component(.year, from: date))"
    }

    public func info(title: String, date: Date) -> FilmInfo? { entries[Self.key(title: title, date: date)]?.info }

    /// Not looked up yet, or not found a week ago or more (TMDB fills in new releases quickly).
    public func needsLookup(title: String, date: Date, now: Date = Date()) -> Bool {
        guard let entry = entries[Self.key(title: title, date: date)] else { return true }
        return entry.info == nil && now.timeIntervalSince(entry.checked) > 7 * 86_400
    }

    public mutating func record(_ info: FilmInfo?, title: String, date: Date, at now: Date = Date()) {
        entries[Self.key(title: title, date: date)] = Entry(info: info, checked: now)
    }

    /// The episode with each film it names replaced by what TMDB knows: the archive's title format
    /// (so it links up with 5heures.be's own reviews of it), a poster, a synopsis and its director.
    public func enrich(_ episode: Episode) -> Episode {
        guard episode.series == .dayez else { return episode }
        let segments = episode.segments.enumerated().map { index, segment -> Segment in
            let spoken = episode.spokenFilms.indices.contains(index) ? episode.spokenFilms[index] : segment.title
            guard let info = info(title: spoken, date: episode.date) else { return segment }
            return Segment(id: segment.id, title: info.archiveTitle, kind: .movie, start: segment.start,
                           verdict: nil, posterURL: info.posterURL, overview: info.overview.isEmpty ? nil : info.overview,
                           director: info.director, localTitle: info.title == info.originalTitle ? nil : info.title)
        }
        return Episode(id: episode.id, series: episode.series, date: episode.date, summary: episode.summary,
                       audioURL: episode.audioURL, segments: segments, name: episode.name,
                       artwork: episode.artwork, duration: episode.duration)
    }

    // MARK: Saving

    public static var defaultLocation: URL {
        URL.applicationSupportDirectory.appendingPathComponent("CinqHeures/films.json")
    }

    public static func load(from url: URL = defaultLocation) -> FilmLibrary {
        guard let data = try? Data(contentsOf: url), let library = try? JSONDecoder().decode(FilmLibrary.self, from: data)
        else { return FilmLibrary() }
        return library
    }

    public func save(to url: URL = defaultLocation) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
