import Foundation

public enum SiteError: Error, LocalizedError {
    case http(Int)
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .http(let code): "5heures.be a répondu \(code)."
        case .unreadable: "La réponse de 5heures.be n'a pas pu être lue."
        }
    }
}

/// Reads the episode list from 5heures.be's own JSON API, the one the website itself uses.
public struct SiteClient: Sendable {
    public static let userAgent = "CinqHeures/1.0 (personal podcast player)"

    private let session: URLSession
    private let base: URL

    /// No URL cache: every answer is fetched fresh anyway, and caching them kept ~15 MB of JSON on disk.
    public static let uncachedSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    public init(base: URL = URL(string: "https://5heures.be")!, session: URLSession = SiteClient.uncachedSession) {
        self.base = base
        self.session = session
    }

    /// The years each show has episodes for.
    public func yearsPerSeries() async throws -> [Series: [Int]] {
        let config = try JSONDecoder().decode(WireConfig.self, from: await get("api/config", query: []))
        var years: [Series: [Int]] = [:]
        for (kind, list) in config.config.years_for_kinds {
            if let series = Series(rawValue: kind) { years[series] = list }
        }
        return years
    }

    /// Every episode of one show in one year, across however many pages that takes.
    public func episodes(of series: Series, year: Int) async throws -> [Episode] {
        var result: [Episode] = []
        var page = 1
        while true {
            let data = try await get("api/podcasts", query: [
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "year", value: String(year)),
                URLQueryItem(name: "kind", value: series.rawValue),
                URLQueryItem(name: "page", value: String(page)),
            ])
            let decoded = try JSONDecoder().decode(WirePage.self, from: data)
            result += decoded.podcasts.compactMap(\.episode)
            if page >= decoded.pagination.total_pages { return result }
            page += 1
        }
    }

    /// The site's CDN answers 503 now and then; asking again a moment later works.
    private func get(_ path: String, query: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        var lastError: Error = SiteError.unreadable
        for attempt in 0..<4 {
            if attempt > 0 { try await Task.sleep(for: .seconds(Double(attempt))) }
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { return data }
                lastError = SiteError.http(status)
                if status != 503 && status != 502 && status != 504 { throw lastError }
            } catch let error as SiteError {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
