import Foundation

/// Where a film or series can be watched in a country: the streaming services that include it, else
/// the free ones, else where to rent it. TMDB's data, from JustWatch (who must be credited).
public struct Streaming: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Part of a subscription (Netflix, Prime Video…).
        case subscription
        /// Free, with or without ads (Auvio…).
        case free
        /// To rent.
        case rent
    }

    public struct Service: Codable, Hashable, Sendable {
        public let name: String
        public let logoPath: String?
        public var logoURL: URL? { logoPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w92" + $0) } }

        public init(name: String, logoPath: String?) {
            self.name = name
            self.logoPath = logoPath
        }
    }

    public let kind: Kind
    /// Best known first, a few at most.
    public let services: [Service]
    /// TMDB's "where to watch" page for the title, which links to each service.
    public let link: URL?

    public init(kind: Kind, services: [Service], link: URL?) {
        self.kind = kind
        self.services = services
        self.link = link
    }
}

extension TMDBClient {
    struct ProvidersPage: Decodable {
        struct Country: Decodable {
            let link: String?
            let flatrate: [Provider]?
            let free: [Provider]?
            let ads: [Provider]?
            let rent: [Provider]?
        }
        struct Provider: Decodable {
            let provider_name: String
            let logo_path: String?
            let display_priority: Int?
        }
        let results: [String: Country]
    }

    /// The TMDB id of a film 5heures.be calls `title` (its original title, as a rule), released around `year`.
    public func movieID(titled title: String, year: Int?) async throws -> Int? {
        let page: SearchPage = try await get("search/movie", ["query": title, "language": "fr-FR", "include_adult": "false"])
        return Self.movieID(in: page, titled: title, year: year)
    }

    static func movieID(in page: SearchPage, titled title: String, year: Int?) -> Int? {
        page.results
            .filter { result in
                guard similarity(of: title, to: [result.title, result.original_title]) == 10 else { return false }
                guard let year else { return true }
                let released = releaseDate(result.release_date).map { EpisodeDates.calendar.component(.year, from: $0) }
                return released.map { abs($0 - year) <= 1 } ?? false
            }
            .max { ($0.popularity ?? 0) < ($1.popularity ?? 0) }?.id
    }

    /// The TMDB id of a series of that exact name that had started by the time it was discussed.
    public func seriesID(titled title: String, discussedOn date: Date) async throws -> Int? {
        let page: SeriesPage = try await get("search/tv", ["query": title, "language": "fr-FR", "include_adult": "false"])
        return page.results
            .filter { Self.similarity(of: title, to: [$0.name, $0.original_name]) == 10
                && (Self.releaseDate($0.first_air_date).map { $0 < date.addingTimeInterval(60 * 86_400) } ?? false) }
            .max { ($0.popularity ?? 0) < ($1.popularity ?? 0) }?.id
    }

    /// Where the film (`series` false) or series with that TMDB id can be watched in `region` ("BE").
    public func streaming(id: Int, series: Bool, region: String) async throws -> Streaming? {
        let page: ProvidersPage = try await get("\(series ? "tv" : "movie")/\(id)/watch/providers", [:])
        return Self.streaming(in: page, region: region)
    }

    static func streaming(in page: ProvidersPage, region: String) -> Streaming? {
        guard let country = page.results[region] else { return nil }
        let choices: [(Streaming.Kind, [ProvidersPage.Provider])] = [
            (.subscription, country.flatrate ?? []), (.free, (country.free ?? []) + (country.ads ?? [])), (.rent, country.rent ?? []),
        ]
        guard let (kind, providers) = choices.first(where: { !$0.1.isEmpty }) else { return nil }
        // One line each: "Netflix", not also "Netflix Standard with Ads"; "Prime Video", not its channels too.
        var seen = Set<String>()
        let services = providers
            .sorted { ($0.display_priority ?? .max) < ($1.display_priority ?? .max) }
            .filter { !$0.provider_name.localizedCaseInsensitiveContains("with ads") && !$0.provider_name.hasSuffix("Amazon Channel") }
            .filter { seen.insert(Search.fold($0.provider_name)).inserted }
            .prefix(3)
            .map { Streaming.Service(name: $0.provider_name, logoPath: $0.logo_path) }
        guard !services.isEmpty else { return nil }
        return Streaming(kind: kind, services: Array(services), link: country.link.flatMap(URL.init(string:)))
    }
}
