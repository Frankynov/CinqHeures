import Foundation

/// Every episode and everything discussed in it, kept in memory for instant search and saved to
/// disk so the next launch starts with it.
public struct Catalogue: Codable, Sendable {
    /// Bumped when the app starts keeping something new from each episode; a saved catalogue with
    /// an older number is downloaded again once (and stays usable until then).
    public static let currentSchema = 2

    public private(set) var episodes: [Episode]
    public private(set) var updatedAt: Date?
    public private(set) var schema: Int

    public init(episodes: [Episode] = [], updatedAt: Date? = nil) {
        self.episodes = episodes.sorted(by: Self.newestFirst)
        self.updatedAt = updatedAt
        self.schema = Self.currentSchema
    }

    /// Newest first, and episodes recorded the same day always in the same order (by id). Without that,
    /// each refresh listed same-day episodes in a new order, which was enough to change the home page's
    /// shelves (drawn from the catalogue in order) a few seconds after launch, with nothing new.
    static func newestFirst(_ a: Episode, _ b: Episode) -> Bool {
        a.date != b.date ? a.date > b.date : a.id > b.id
    }

    private enum CodingKeys: String, CodingKey { case episodes, updatedAt, schema }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        episodes = try container.decode([Episode].self, forKey: .episodes)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? 1
    }

    public var needsFullDownload: Bool { schema < Self.currentSchema }

    /// Records that every episode was downloaded with the current fields.
    public mutating func markDownloadedInFull() { schema = Self.currentSchema }

    public var isEmpty: Bool { episodes.isEmpty }

    /// Adds new episodes and replaces the ones already known, newest first.
    public mutating func merge(_ fresh: [Episode], at date: Date = Date()) {
        var byID = Dictionary(episodes.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        for episode in fresh { byID[episode.id] = episode }
        episodes = byID.values.sorted(by: Self.newestFirst)
        updatedAt = date
    }

    /// Puts a feed show's current episodes in place of the ones known before: an episode removed from
    /// the feed goes, and an id scheme that changed can't leave copies behind.
    public mutating func replaceEpisodes(of series: Series, with fresh: [Episode], at date: Date = Date()) {
        episodes.removeAll { $0.series == series }
        merge(fresh, at: date)
    }

    public func episode(id: Int) -> Episode? { episodes.first { $0.id == id } }

    // MARK: Saving

    public static func load(from url: URL) -> Catalogue? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Catalogue.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    public static var defaultLocation: URL {
        URL.applicationSupportDirectory.appendingPathComponent("CinqHeures/catalogue.json")
    }
}
