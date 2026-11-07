import CinqHeuresCore
import Foundation
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A row of the sidebar. Not an optional `Series` with `nil` for "all": a List selection can't be nil.
enum SidebarItem: Hashable {
    case home
    /// The episodes marked as favourites.
    case favorites
    /// Every episode of every show.
    case all
    case show(Series)
    /// Every film given this score, 0 to 4, whichever show it was in.
    case score(Int)
    /// Every film reviewed without a score.
    case unrated
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
    /// The episodes played lately, kept on disk (AudioCache).
    var episodes = 0
    /// Anything else in the app's caches folder (answers older versions let the system cache).
    var other = 0

    var total: Int { catalogue + posters + episodes + other }

    /// Measured from the files themselves: URLCache's own counter lags well behind deletions.
    static func measure() -> CacheUsage {
        let caches = URL.cachesDirectory
        let systemCache = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "be.cinqheures.player")
        return CacheUsage(catalogue: size(of: Catalogue.defaultLocation), posters: size(of: PosterCache.folder),
                          episodes: size(of: AudioCache.folder), other: size(of: systemCache))
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

    /// The sidebar's row. `nil` only on iPhone, when the list itself is showing (back from a page):
    /// the rest of the app reads `sidebar`, which is then the last row picked.
    var sidebarSelection: SidebarItem? = .home {
        didSet { if let sidebarSelection { lastSidebar = sidebarSelection } }
    }
    private var lastSidebar: SidebarItem = .home
    var sidebar: SidebarItem {
        get { sidebarSelection ?? lastSidebar }
        set { sidebarSelection = newValue }
    }
    /// The pages pushed on top of the sidebar's page.
    var path: [Route] = []
    /// iPhone and Apple TV: the tab showing, and the pages pushed in the other tabs (`path` is Accueil's,
    /// and the only one on the Mac and the iPad). `playing` is the TV's player, which pushes nothing.
    enum PhoneTab: Hashable { case home, shows, search, playing }
    var phoneTab: PhoneTab = .home
    var showsPath: [Route] = []
    var searchPath: [Route] = []
    var searchText = ""
    /// What the last finished search found. Computed off the main thread, a moment after typing stops.
    private(set) var results = SearchOutcome()
    var scope: SearchScope = .all

    let player = PlayerModel()
    let favorites = Favorites()
    private let client = SiteClient()
    private let feeds = FeedClient.all
    /// Posters, synopses and directors for Dayez's films, from TMDB through Franky's proxy.
    private var films = FilmLibrary.load()
    private let tmdb = TMDBClient()
    private var filmLookup: Task<Void, Never>?
    /// Where each of Dayez's films starts, from the chapters in Franky's own MP3 files.
    private var chapters = ChapterLibrary.load()
    private let chapterReader = ChapterReader()
    private var chapterLookup: Task<Void, Never>?
    /// Synopses, French titles and directors of the films and series 5heures.be discusses, looked up as
    /// their pages are opened. Observed: a page shows its synopsis when it arrives.
    private(set) var workDetails = WorkDetailsLibrary.load()
    private var detailLookups: Set<String> = []
    @ObservationIgnored private var autreFilms: [Int: (summary: String, films: [NamedFilm])] = [:]
    @ObservationIgnored private var catalogueSave: Task<Void, Never>?
    /// The files `lookUpChapters(of:)` is reading.
    private var chapterChecks: Set<URL> = []
    private var lastFeedRefresh = Date.distantPast
    private var index = SearchIndex(Catalogue())
    private(set) var discovery = Discovery(Catalogue()) {
        didSet { listings = [:] }
    }
    /// Each listing's titles in each order, worked out once per catalogue (the sidebar's along with
    /// the index). A page that has its titles on its first frame builds its list in one go: filled a
    /// moment later, the Mac's table took 0.3 s to take in the 2,422 films without a score.
    @ObservationIgnored private var listings: [ListingKey: [ShelfItem]] = [:]
    private struct ListingKey: Hashable {
        let listing: Listing
        let order: ListingOrder
    }
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
        // What this device saved; else (a first launch, or a catalogue kept with fewer fields) the one
        // shipped with the app, which only needs its newest episodes.
        let saved = Catalogue.load(from: Catalogue.defaultLocation)
        catalogue = saved.flatMap { $0.needsFullDownload ? nil : $0 } ?? Self.shippedCatalogue() ?? saved ?? Catalogue()
        if films.adopt(Self.shippedFilms()) { try? films.save() }
        rebuildIndex()
        updateCacheUsage()
        EpisodeAlerts.shared.setUp { [weak self] id in self?.openFromOutside(.episode(id, highlight: nil)) }
        QuickAction.model = self
        // Posters pile up while browsing: measure again now and then, so the menu's figure is current.
        // Only while the app is in front: a walk through thousands of files every 20 seconds, with
        // the app in the background (playing on a locked iPhone, say), was work for nobody.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                if Self.isInFront { self?.updateCacheUsage() }
            }
        }
    }

    /// The app is the active one on the Mac, or on screen on iPhone and iPad.
    private static var isInFront: Bool {
        #if os(macOS)
        NSApplication.shared.isActive
        #else
        UIApplication.shared.applicationState == .active
        #endif
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
        await catalogueSave?.value         // a save still running would write it back
        try? FileManager.default.removeItem(at: Catalogue.defaultLocation)
        catalogue = Self.shippedCatalogue() ?? Catalogue()
        // The caches delete their own files (in the background). Deleting their folders instead
        // pulls the database out from under them, and nothing gets cached again until a relaunch.
        PosterCache.shared.clear()
        AudioCache.shared.clear()
        SpotlightIndex.reset()
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

    /// How many films each score's page lists: one per title, like the page.
    func count(ofStars stars: Int) -> Int { starCounts[stars, default: 0] }

    /// A listing's titles, in this order (newest first, or A to Z).
    func items(in listing: Listing, by order: ListingOrder) -> [ShelfItem] {
        let key = ListingKey(listing: listing, order: order)
        // Read before the cache, so a page showing the result follows a new catalogue.
        let discovery = discovery
        if let known = listings[key] { return known }
        let items = order.sorted(listings[ListingKey(listing: listing, order: .date)] ?? discovery.items(listing))
        listings[key] = items
        return items
    }

    /// Films reviewed without a score (their count is kept with the scores', under this key).
    private static let unratedKey = -1
    var unratedCount: Int { starCounts[Self.unratedKey, default: 0] }

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
        lookUpChapters(of: episode)
        playRequests += 1
    }

    /// Bumped each time something is asked to play: the TV then shows its player.
    private(set) var playRequests = 0

    /// The review someone is looking at, likely to be played next: warm its file on 5heures.be's server,
    /// or read a Dayez file's chapters again.
    func warm(_ episode: Episode, at segment: Segment? = nil) {
        player.warm(episode, at: segment)
        lookUpChapters(of: episode)
    }

    /// Pushes a page in the current tab (iPhone) or the content column (Mac, iPad).
    func open(_ route: Route) {
        switch phoneTab {
        case .home: path.append(route)
        case .shows: showsPath.append(route)
        case .search: searchPath.append(route)
        case .playing:
            // From the TV's player: the page opens in Accueil, over what was there.
            phoneTab = .home
            path.append(route)
        }
    }

    /// Back to the first page of the current tab (a new search, a new sidebar row).
    func popToRoot() {
        switch phoneTab {
        case .home: path = []
        case .shows: showsPath = []
        case .search: searchPath = []
        case .playing: break
        }
    }

    /// Bumped by Aller › Rechercher (⌘F): the window puts the cursor in the search field.
    private(set) var searchFocusRequests = 0
    func focusSearch() { searchFocusRequests += 1 }

    /// A page asked for from outside the app (a Spotlight result): out of any search, on top of the
    /// sidebar's page (Accueil's tab on iPhone). The sidebar row stays: changing it empties the pages.
    func openFromOutside(_ route: Route) {
        searchText = ""
        phoneTab = .home
        path = [route]
    }

    /// The episode being played, as a page.
    func openCurrentEpisode() {
        guard let episode = player.episode else { return }
        open(.episode(episode.id, highlight: player.currentSegmentID))
    }

    func work(kind: SegmentKind, title: String) -> Work? { index.work(kind: kind, title: title) }

    func episode(id: Int) -> Episode? { catalogue.episode(id: id) }

    /// Episodes started and left unfinished, most recent first.
    /// The favourite episodes the catalogue has, the last one added first.
    var favoriteEpisodes: [Episode] {
        let wanted = Set(favorites.ids)
        guard !wanted.isEmpty else { return [] }
        let found = Dictionary(catalogue.episodes.lazy.filter { wanted.contains($0.id) }.map { ($0.id, $0) },
                               uniquingKeysWith: { first, _ in first })
        return favorites.ids.compactMap { found[$0] }
    }

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
    /// Whether the index has been built once: what the icon's shortcuts need (`QuickAction`).
    private(set) var isBrowsable = false

    /// A well-rated review at random, as the home page's banner picks them.
    func surprise() -> Work.Mention? { discovery.hero(seed: UInt64.random(in: 0..<UInt64.max)) }

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
        let unrated = Self.unratedKey
        Task {
            let (fresh, browse, scored) = await Task.detached(priority: .utility) {
                let browse = Discovery(snapshot)
                // The sidebar's lists, ready before they're opened. Their badges count these titles.
                var scored: [Int: [ShelfItem]] = [:]
                for stars in 0...4 { scored[stars] = ListingOrder.date.sorted(browse.items(.stars(stars))) }
                scored[unrated] = ListingOrder.date.sorted(browse.items(.unrated))
                return (SearchIndex(snapshot), browse, scored)
            }.value
            guard generation == indexGeneration else { return }   // a newer catalogue is being indexed
            index = fresh
            discovery = browse
            for (stars, items) in scored {
                listings[ListingKey(listing: stars == unrated ? .unrated : .stars(stars), order: .date)] = items
            }
            var episodes: [Series: Int] = [:]
            for episode in snapshot.episodes { episodes[episode.series, default: 0] += 1 }
            episodeCounts = episodes
            starCounts = scored.mapValues(\.count)
            rebuildHome()
            searchChanged()
            SpotlightIndex.update(snapshot)
            isBrowsable = true
            performPendingQuickAction()
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
        applyDetails()
        lookUpFilms()
        lookUpChapters()
        // New episodes while the app stays open (the Mac above all): the feeds again every hour.
        if hourlyFeeds == nil {
            hourlyFeeds = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3600))
                    await self?.refreshFeed()
                }
            }
        }
    }

    private var hourlyFeeds: Task<Void, Never>?

    /// iPhone and iPad, in the background: the feeds, for the "nouvel épisode" notifications.
    func backgroundRefresh() async {
        lastFeedRefresh = .distantPast
        await refreshFeed()
    }

    // MARK: Film details from TMDB

    /// Dayez's episodes with what TMDB knows about their films (title, poster, synopsis, director),
    /// and where each film starts in the file. The one playing takes them too. Returns whether any changed.
    @discardableResult
    private func applyDetails() -> Bool {
        var changed = false
        // Dayez's episodes, and the "Autre" specials, whose films come from their descriptions.
        for series in [Series.dayez, .autre] {
            let episodes = catalogue.episodes.filter { $0.series == series }
            guard !episodes.isEmpty else { continue }
            let enriched = episodes.map(details)
            guard enriched.map(\.segments) != episodes.map(\.segments) else { continue }
            catalogue.replaceEpisodes(of: series, with: enriched, at: catalogue.updatedAt ?? Date())
            if let playing = player.episode, let updated = enriched.first(where: { $0.id == playing.id }) {
                player.update(updated)
            }
            changed = true
        }
        return changed
    }

    /// Looks up, in the background, the films not asked about yet. Every request is paced under the proxy's
    /// limit (`TMDBClient.Pacer`); a film that fails is skipped, three failures in a row stop the round, and
    /// what wasn't reached is asked about at the next launch.
    func lookUpFilms() {
        guard filmLookup == nil else { return }
        let dayez = catalogue.episodes.filter { $0.series == .dayez }.flatMap { episode in
            episode.spokenFilms.filter { films.needsLookup(title: $0, date: episode.date) }
                .map { (title: $0, date: episode.date, hints: episode.summary, named: NamedFilm?.none) }
        }
        // The "Autre" specials' films, named with their director: about 270, looked up once.
        let autre = catalogue.episodes.filter { $0.series == .autre }.flatMap { episode in
            AutreProgramme.films(in: episode.summary).filter { films.needsLookup(title: $0.title, date: episode.date) }
                .map { (title: $0.title, date: episode.date, hints: "", named: Optional($0)) }
        }
        let pending = dayez + autre
        guard !pending.isEmpty else { return }
        filmLookup = Task { [tmdb] in
            var done = 0
            var failures = 0
            var shown = ContinuousClock.now
            lookups: for film in pending {
                for attempt in 0..<3 {
                    do {
                        let info = if let named = film.named { try await tmdb.film(named: named) }
                                   else { try await tmdb.film(titled: film.title, discussedOn: film.date, hints: film.hints) }
                        films.record(info, title: film.title, date: film.date)
                        failures = 0
                        break
                    } catch SiteError.http(429) where attempt < 2 {
                        try? await Task.sleep(for: .seconds(65))       // the proxy's minute is over
                    } catch {
                        // A film that can't be asked about now (a timeout, the server busy) is left for the
                        // next launch; three in a row and the server is down, so the rest waits too.
                        failures += 1
                        if failures == 3 { break lookups }
                        break
                    }
                }
                done += 1
                // Posters appear as they come, but at most every 20 seconds: each time redraws the pages,
                // and a first launch looks up some 270 films.
                if done % 6 == 0, ContinuousClock.now - shown > .seconds(20) {
                    finishFilmBatch()
                    shown = ContinuousClock.now
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            finishFilmBatch()
            filmLookup = nil
        }
    }

    /// An episode with its films' TMDB details and, for Dayez's, their chapter starts.
    private func details(_ episode: Episode) -> Episode {
        let enriched = films.enrich(chapters.apply(to: episode))
        guard episode.series == .autre else { return enriched }
        return enriched.withNamedFilms(namedFilms(in: episode), from: films)
    }

    /// An "Autre" episode's films, read from its description once: reading all 167 again at every
    /// batch of lookups took 18 ms of the main thread.
    private func namedFilms(in episode: Episode) -> [NamedFilm] {
        if let known = autreFilms[episode.id], known.summary == episode.summary { return known.films }
        let films = AutreProgramme.films(in: episode.summary)
        autreFilms[episode.id] = (episode.summary, films)
        return films
    }

    /// The catalogue as it was when this version was built (`Tools/snapshot.sh`), in the app's resources:
    /// a first launch starts from it instead of downloading some 35 pages from 5heures.be, whose
    /// shows have stopped. Its newest year and the two feeds are then checked as on any launch.
    static func shippedCatalogue() -> Catalogue? {
        Bundle.main.url(forResource: "snapshot-catalogue", withExtension: "json").flatMap(Catalogue.load(from:))
            .flatMap { $0.needsFullDownload || $0.isEmpty ? nil : $0 }
    }

    /// The films matched on TMDB when the snapshot was made, so a first launch doesn't look them up again.
    static func shippedFilms() -> FilmLibrary {
        Bundle.main.url(forResource: "snapshot-films", withExtension: "json").map { FilmLibrary.load(from: $0) } ?? FilmLibrary()
    }

    /// Saves the catalogue (4 MB of JSON, some 30 ms) off the main thread, each save after the last.
    private func saveCatalogue() {
        let snapshot = catalogue
        let previous = catalogueSave
        catalogueSave = Task.detached(priority: .utility) {
            await previous?.value
            try? snapshot.save(to: Catalogue.defaultLocation)
        }
    }

    private func finishFilmBatch() {
        try? films.save()
        applyDetails()
        saveCatalogue()
        rebuildIndex()
    }

    /// The feed shows are weekly: one small request when the app starts and whenever it comes
    /// back to the front after an hour or more. Failing is fine; the saved episodes stay.
    func refreshFeed() async {
        guard Date().timeIntervalSince(lastFeedRefresh) > 3600 else { return }
        lastFeedRefresh = Date()
        var changed = false
        for feed in feeds {
            // One feed being down (Franky's server, say) doesn't keep the other from updating, and an
            // empty answer never wipes what's known.
            guard let episodes = try? await feed.episodes(), !episodes.isEmpty else { continue }
            let fresh = episodes.map(details)
            // Most times nothing is new: then nothing is saved or indexed again, and the home page
            // isn't rebuilt under the listener's eyes.
            guard Set(fresh) != Set(catalogue.episodes.filter { $0.series == feed.series }) else { continue }
            catalogue.replaceEpisodes(of: feed.series, with: fresh, at: catalogue.updatedAt ?? Date())
            changed = true
        }
        if changed {
            saveCatalogue()
            rebuildIndex()
        }
        EpisodeAlerts.shared.announce(newIn: catalogue)
        lookUpFilms()          // this week's three films, and any not found last time
        lookUpChapters()
    }

    // MARK: Chapters in Dayez's files

    /// Reads, in the background, the chapters of the Dayez files not read lately (a request for the
    /// first few kilobytes of each). A film with a chapter then starts there everywhere: its marks on
    /// the bar, the episode's programme, "Écouter la critique", the film playing on the lock screen.
    func lookUpChapters() {
        guard chapterLookup == nil else { return }
        let pending = catalogue.episodes.filter { $0.series == .dayez && chapters.needsLookup($0) }
        guard !pending.isEmpty else { return }
        chapterLookup = Task { [chapterReader] in
            var failures = 0
            for episode in pending {
                do {
                    chapters.record(try await chapterReader.chapters(of: episode.audioURL), for: episode)
                    failures = 0
                } catch {
                    // A file that can't be read is tried again next time; three in a row, the server is down.
                    failures += 1
                    if failures == 3 { break }
                }
            }
            chaptersRead()
            chapterLookup = nil
        }
    }

    /// Reads one Dayez file again as soon as its episode, or a film in it, is opened or played, unless
    /// that was done in the last minute: Franky adds chapters to a file after uploading it, which the
    /// reads above would only notice hours later.
    func lookUpChapters(of episode: Episode) {
        guard episode.series == .dayez, !chapterChecks.contains(episode.audioURL),
              Date().timeIntervalSince(chapters.lastRead(episode) ?? .distantPast) > 60 else { return }
        chapterChecks.insert(episode.audioURL)
        Task { [chapterReader] in
            defer { chapterChecks.remove(episode.audioURL) }
            guard let found = try? await chapterReader.chapters(of: episode.audioURL) else { return }
            if chapters.record(found, for: episode) { chaptersRead() }
        }
    }

    // MARK: Synopses

    func details(of work: Work) -> WorkDetails? {
        WorkDetails.key(for: work).flatMap(workDetails.details(for:))
    }

    /// Looks up a film's synopsis on its 5heures.be page, or a series' on TMDB (through the proxy), the
    /// first time its page is opened. Dayez's films already have theirs.
    func lookUpDetails(of work: Work) {
        guard work.mentions.allSatisfy({ $0.segment.overview == nil }), let key = WorkDetails.key(for: work),
              workDetails.needsLookup(key), !detailLookups.contains(key), let latest = work.mentions.first else { return }
        detailLookups.insert(key)
        let slug = work.mentions.lazy.compactMap(\.segment.slug).first
        Task { [client, tmdb] in
            defer { detailLookups.remove(key) }
            let found: WorkDetails?
            do {
                if let slug { found = try await client.movieDetails(slug: slug) }
                else { found = try await tmdb.seriesDetails(titled: latest.segment.displayTitle, discussedOn: latest.episode.date) }
            } catch {
                return                  // offline, or the proxy not allowing series yet: asked again next time
            }
            workDetails.record(found, for: key)
            try? workDetails.save()
        }
    }

    // MARK: Where to watch

    /// Where each film or series streams in this country, by `Work.id`: looked up when its page is
    /// first opened, kept until the app quits (the proxy keeps TMDB's answers a week).
    private(set) var streaming: [String: Streaming] = [:]
    private var streamingAsked: Set<String> = []

    func lookUpStreaming(of work: Work) {
        guard work.kind == .movie || work.kind == .tvShow, let latest = work.mentions.first,
              streamingAsked.insert(work.id).inserted else { return }
        let region = Locale.current.region?.identifier ?? "BE"
        Task { [tmdb] in
            do {
                let segment = latest.segment
                let id = work.kind == .movie
                    ? try await tmdb.movieID(titled: segment.displayTitle, year: segment.year)
                    : try await tmdb.seriesID(titled: segment.displayTitle, discussedOn: latest.episode.date)
                guard let id, let found = try await tmdb.streaming(id: id, series: work.kind == .tvShow, region: region) else { return }
                streaming[work.id] = found
            } catch {
                // Offline, or a proxy that doesn't pass these requests yet: asked again next launch.
                streamingAsked.remove(work.id)
            }
        }
    }

    /// What was found is kept, and the films start at their chapters everywhere.
    private func chaptersRead() {
        try? chapters.save()
        guard applyDetails() else { return }
        saveCatalogue()
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
            applyDetails()          // the "Autre" specials come without their films
            saveCatalogue()
            rebuildIndex()
            sync = .idle
            updateCacheUsage()
        } catch {
            // Keep whatever was fetched so far: it's still searchable.
            if !catalogue.isEmpty { saveCatalogue(); rebuildIndex() }
            sync = .failed(error.localizedDescription)
        }
    }
}
