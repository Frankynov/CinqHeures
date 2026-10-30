import CinqHeuresCore
import Foundation
import Observation

/// A row of the sidebar. Not an optional `Series` with `nil` for "all": a List selection can't be nil.
enum SidebarItem: Hashable {
    case home
    /// Every episode of every show.
    case all
    case show(Series)
    /// Every film given this score, 0 to 4, whichever show it was in.
    case score(Int)
}

/// The outcome of a search: the works that matched and the episodes whose title or summary did.
struct SearchOutcome: Sendable {
    /// The folded query these results answer, to tell a finished search from one still pending.
    let query: String
    let works: [Work]
    let described: [Episode]

    init(query: String = "", works: [Work] = [], described: [Episode] = []) {
        self.query = query
        self.works = works
        self.described = described
    }

    var isEmpty: Bool { works.isEmpty && described.isEmpty }
}

/// What the app keeps on disk, for the "Vider le cache" menu item.
struct CacheUsage: Equatable, Sendable {
    var catalogue = 0
    var posters = 0
    /// Anything else in the app's caches folder (answers older versions let the system cache).
    var other = 0

    var total: Int { catalogue + posters + other }

    /// Measured from the files themselves: URLCache's own counter lags well behind deletions.
    static func measure() -> CacheUsage {
        let caches = URL.cachesDirectory
        let systemCache = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "be.cinqheures.player")
        return CacheUsage(catalogue: size(of: Catalogue.defaultLocation), posters: size(of: PosterCache.folder),
                          other: size(of: systemCache))
    }

    /// Bytes on disk of a file, or of everything inside a folder.
    static func size(of url: URL) -> Int {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return values.totalFileAllocatedSize ?? 0
        }
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total = 0
        for case let file as URL in files {
            total += (try? file.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0
        }
        return total
    }

    static func text(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

/// One block of the home page, top to bottom.
enum HomeSection: Identifiable {
    case shelf(Shelf)
    case decades([DecadeTile])

    var id: String {
        switch self {
        case .shelf(let shelf): shelf.id
        case .decades: "decades"
        }
    }
}

@MainActor @Observable
final class AppModel {
    enum SyncState: Equatable {
        case idle
        case running(done: Int, of: Int)
        case failed(String)
    }

    private(set) var catalogue: Catalogue
    private(set) var sync: SyncState = .idle

    var sidebar: SidebarItem = .home
    /// The pages pushed on top of the sidebar's page.
    var path: [Route] = []
    var searchText = ""
    /// What the last finished search found. Computed off the main thread, a moment after typing stops.
    private(set) var results = SearchOutcome()
    var scope: SearchScope = .all

    let player = PlayerModel()
    private let client = SiteClient()
    private let feeds = FeedClient.all
    private var lastFeedRefresh = Date.distantPast
    private var index = SearchIndex(Catalogue())
    private(set) var discovery = Discovery(Catalogue())
    /// Picks the random shelves; a new one reshuffles the home page.
    private(set) var shuffleSeed = UInt64.random(in: 0..<UInt64.max)
    private(set) var homeSections: [HomeSection] = []
    private(set) var hero: Work.Mention?
    /// Titles featured lately, so "Une autre" doesn't bring one back.
    private var recentHeroes: [String] = []
    private var searchTask: Task<Void, Never>?
    /// Only the newest index build may replace the current one (builds can finish out of order).
    private var indexGeneration = 0
    /// Sidebar counts, worked out once per catalogue change rather than on every redraw.
    private(set) var episodeCounts: [Series: Int] = [:]
    private(set) var starCounts: [Int: Int] = [:]
    private(set) var cacheUsage = CacheUsage()
    /// Shows the "Réinitialiser" sheet.
    var showsReset = false

    init() {
        catalogue = Catalogue.load(from: Catalogue.defaultLocation) ?? Catalogue()
        rebuildIndex()
        updateCacheUsage()
        // Posters pile up while browsing: measure again now and then, so the menu's figure is current.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.updateCacheUsage()
            }
        }
    }

    var isSyncing: Bool { if case .running = sync { true } else { false } }

    // MARK: Cache

    /// Walks the cache folders in the background (a few thousand poster files) and updates the menu.
    func updateCacheUsage() {
        Task {
            cacheUsage = await Task.detached(priority: .utility) { CacheUsage.measure() }.value
        }
    }

    /// Forgets listening progress and/or the cache, as chosen in the "Réinitialiser" sheet.
    ///
    /// Progress: every resume position, so "Continuer l'écoute" empties. Cache: back to a first launch
    /// (no catalogue, no posters, nothing playing), then the download starts again as the very first time.
    func reset(cache: Bool, progress: Bool) async {
        if progress { player.forgetAllProgress() }
        guard cache, !isSyncing else { return }
        player.stop()
        path = []
        searchText = ""
        sidebar = .home
        try? FileManager.default.removeItem(at: Catalogue.defaultLocation)
        catalogue = Catalogue()
        // The caches delete their own files (in the background). Deleting their folders instead
        // pulls the database out from under them, and nothing gets cached again until a relaunch.
        PosterCache.shared.clear()
        URLCache.shared.removeAllCachedResponses()
        hero = nil
        recentHeroes = []
        homeSections = []
        results = SearchOutcome()
        lastFeedRefresh = .distantPast
        rebuildIndex()
        updateCacheUsage()
        await start()
        updateCacheUsage()
    }

    /// The show chosen in the sidebar; `nil` is all of them.
    var series: Series? {
        if case .show(let series) = sidebar { series } else { nil }
    }

    /// How many passages were given each score.
    func count(ofStars stars: Int) -> Int { starCounts[stars, default: 0] }

    /// False between a keystroke and its results, so the page doesn't flash "no results".
    var searchIsSettled: Bool { results.query == Search.fold(searchText) }

    var isSearching: Bool { !Search.fold(searchText).isEmpty }
    var activeSeries: Set<Series> { series.map { [$0] } ?? Set(Series.allCases) }

    var episodesShown: [Episode] {
        catalogue.episodes.filter { activeSeries.contains($0.series) }
    }

    /// From the same counts as each show's, so all of them appear together once the catalogue is indexed.
    func count(of series: Series?) -> Int {
        guard let series else { return episodeCounts.values.reduce(0, +) }
        return episodeCounts[series, default: 0]
    }

    func play(_ episode: Episode, from segment: Segment? = nil) {
        player.play(episode, from: segment)
    }

    func open(_ route: Route) { path.append(route) }

    /// Back to the sidebar's own page (a new search, a new sidebar row).
    func popToRoot() { path = [] }

    /// The episode being played, as a page.
    func openCurrentEpisode() {
        guard let episode = player.episode else { return }
        open(.episode(episode.id, highlight: player.currentSegmentID))
    }

    func work(kind: SegmentKind, title: String) -> Work? { index.work(kind: kind, title: title) }

    func episode(id: Int) -> Episode? { catalogue.episode(id: id) }

    /// Episodes started and left unfinished, most recent first.
    var continueListening: [(episode: Episode, seconds: Double)] {
        _ = player.progressRevision      // observed, so the shelf updates after a reset
        return player.unfinished().compactMap { entry in
            catalogue.episode(id: entry.id).map { ($0, entry.seconds) }
        }
    }

    // MARK: Home

    func shuffle() {
        shuffleSeed = UInt64.random(in: 0..<UInt64.max)
        rebuildHome()
        anotherHero()
    }

    /// Cheap enough to do on the main thread: a few milliseconds over the whole catalogue.
    private func rebuildHome() {
        var sections = discovery.shelves(seed: shuffleSeed).map(HomeSection.shelf)
        let tiles = discovery.decadeTiles(seed: shuffleSeed)
        if !tiles.isEmpty { sections.insert(.decades(tiles), at: min(3, sections.count)) }
        homeSections = sections
        if hero == nil || !(hero.map { discovery.contains($0) } ?? false) { showHero(discovery.hero(seed: shuffleSeed)) }
    }

    /// Another random review in the banner, not one featured in the last thirty.
    func anotherHero() {
        for _ in 0..<12 {
            let candidate = discovery.hero(seed: UInt64.random(in: 0..<UInt64.max))
            if let candidate, !recentHeroes.contains(candidate.segment.title) {
                showHero(candidate)
                return
            }
        }
        showHero(discovery.hero(seed: UInt64.random(in: 0..<UInt64.max)))
    }

    private func showHero(_ mention: Work.Mention?) {
        hero = mention
        guard let title = mention?.segment.title else { return }
        recentHeroes.append(title)
        if recentHeroes.count > 30 { recentHeroes.removeFirst() }
    }


    // MARK: Searching

    /// Call whenever the query, the scope or the chosen show changes. The text field stays instant:
    /// the search runs after a short pause in typing, off the main thread, and a newer keystroke
    /// cancels an older search.
    func searchChanged(typing: Bool = true) {
        searchTask?.cancel()
        guard isSearching else { results = SearchOutcome(); return }
        let (query, scope, series, index) = (searchText, scope, activeSeries, index)
        searchTask = Task {
            // Wait out a burst of typing; a click on the sidebar or the scope doesn't need to.
            if typing { try? await Task.sleep(for: .milliseconds(140)) }
            if Task.isCancelled { return }
            let outcome = await Task.detached(priority: .userInitiated) {
                SearchOutcome(query: Search.fold(query),
                              works: index.works(matching: query, scope: scope, series: series),
                              described: scope == .all ? index.episodes(describedBy: query, series: series) : [])
            }.value
            if !Task.isCancelled { results = outcome }
        }
    }

    /// Folding every title takes a moment, so it's done in the background; searches use the old
    /// index until the new one is ready.
    private func rebuildIndex() {
        let snapshot = catalogue
        indexGeneration += 1
        let generation = indexGeneration
        Task {
            let (fresh, browse) = await Task.detached(priority: .utility) { (SearchIndex(snapshot), Discovery(snapshot)) }.value
            guard generation == indexGeneration else { return }   // a newer catalogue is being indexed
            index = fresh
            discovery = browse
            var episodes: [Series: Int] = [:]
            var stars: [Int: Int] = [:]
            for episode in snapshot.episodes {
                episodes[episode.series, default: 0] += 1
                for segment in episode.segments { if let n = segment.stars { stars[n, default: 0] += 1 } }
            }
            episodeCounts = episodes
            starCounts = stars
            rebuildHome()
            searchChanged()
        }
    }

    // MARK: Keeping the catalogue

    /// First launch downloads everything; later launches only look at each show's newest year,
    /// and only when the last look was a while ago.
    func start() async {
        if catalogue.isEmpty || catalogue.needsFullDownload {
            await refresh(everything: true)
        } else if Date().timeIntervalSince(catalogue.updatedAt ?? .distantPast) > 12 * 3600 {
            await refresh(everything: false)
        }
        await refreshFeed()
    }

    /// The music podcast is weekly: one small request when the app starts and whenever it comes
    /// back to the front after an hour or more. Failing is fine; the saved episodes stay.
    func refreshFeed() async {
        guard Date().timeIntervalSince(lastFeedRefresh) > 3600 else { return }
        lastFeedRefresh = Date()
        var changed = false
        for feed in feeds {
            // One feed being down (Franky's server, say) doesn't keep the other from updating, and an
            // empty answer never wipes what's known.
            guard let episodes = try? await feed.episodes(), !episodes.isEmpty else { continue }
            catalogue.replaceEpisodes(of: feed.series, with: episodes, at: catalogue.updatedAt ?? Date())
            changed = true
        }
        guard changed else { return }
        try? catalogue.save(to: Catalogue.defaultLocation)
        rebuildIndex()
    }

    func refresh(everything: Bool) async {
        guard sync == .idle || { if case .failed = sync { true } else { false } }() else { return }
        sync = .running(done: 0, of: 1)
        lastFeedRefresh = .distantPast
        do {
            let years = try await client.yearsPerSeries()
            var jobs: [(Series, Int)] = []
            for (series, list) in years {
                let chosen = everything ? list : Array(list.sorted(by: >).prefix(1))
                jobs += chosen.map { (series, $0) }
            }
            jobs.sort { ($0.1, $0.0.rawValue) > ($1.1, $1.0.rawValue) }
            sync = .running(done: 0, of: jobs.count)
            for (index, job) in jobs.enumerated() {
                let episodes = try await client.episodes(of: job.0, year: job.1)
                // Merged into the live catalogue, not a copy taken at the start: the music feed can
                // be merged while this runs, and writing a stale copy back would drop its episodes.
                catalogue.merge(episodes)
                sync = .running(done: index + 1, of: jobs.count)
            }
            if everything { catalogue.markDownloadedInFull() }
            try? catalogue.save(to: Catalogue.defaultLocation)
            rebuildIndex()
            sync = .idle
            updateCacheUsage()
        } catch {
            // Keep whatever was fetched so far: it's still searchable.
            if !catalogue.isEmpty { try? catalogue.save(to: Catalogue.defaultLocation); rebuildIndex() }
            sync = .failed(error.localizedDescription)
        }
    }
}
