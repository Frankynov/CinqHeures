import CinqHeuresCore
import SwiftUI

private let gridColumns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 22, alignment: .top)]
/// For a narrow column, where 150 points left room for one poster a row.
private let narrowGridColumns = [GridItem(.adaptive(minimum: 120, maximum: 190), spacing: 16, alignment: .top)]

/// Shown instead of any page while the catalogue hasn't been downloaded yet.
struct FirstLaunchView: View {
    let model: AppModel

    var body: some View {
        switch model.sync {
        case .failed(let message):
            ContentUnavailableView {
                Label("Catalogue indisponible", systemImage: "wifi.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Réessayer") { Task { await model.refresh(everything: true) } }
            }
        case .running(let done, let total):
            ContentUnavailableView {
                Label("Première ouverture", systemImage: "arrow.down.circle")
            } description: {
                Text("Téléchargement des \u{00AB} 5heures \u{00BB} depuis 5heures.be. Cela ne se fait qu'une fois.")
            } actions: {
                VStack(spacing: 6) {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .frame(width: 260)
                    Text("\(done) sur \(total)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        case .idle:
            ContentUnavailableView {
                Label("Première ouverture", systemImage: "arrow.down.circle")
            } description: {
                Text("Téléchargement des \u{00AB} 5heures \u{00BB} depuis 5heures.be. Cela ne se fait qu'une fois.")
            }
        }
    }
}

/// A shelf's "Tout voir", a score, a decade: a grid of everything in it.
struct ListingPage: View {
    let listing: Listing
    let model: AppModel
    @ViewState private var items: [ShelfItem] = []
    @ViewState private var loaded = false
    @AppStorage("listingOrder") private var order = ListingOrder.date
    @AppStorage("listingReversed") private var reversed = false
    @AppStorage("listingLayout") private var layout = ListingLayout.grid
    /// Whether the page has room for full-size grid cells and for the show and date on the right of
    /// each row; `nil` until it's laid out. A yes or no rather than the width itself: the width
    /// changes at every step of a window resize, and each change redrew and re-sorted the page.
    @ViewState private var isWide: Bool? = nil
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let shown = order.sorted(items, reversed: reversed)
        Group {
            if loaded && items.isEmpty {
                ContentUnavailableView("Rien ici", systemImage: "film")
            } else if sizeClass == .compact || layout == .list {
                // Two posters a row fill an iPhone screen with four titles; rows show a dozen. On the
                // Mac and the iPad the rows are the dense alternative to the grid.
                List {
                    ForEach(shown) { ItemRow(item: $0) }
                    // A List ignores the bottom room kept for the floating player (see ShowPage).
                    Color.clear
                        .frame(height: sizeClass == .compact ? 0 : PlayerBar.reservedHeight)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .accessibilityHidden(true)
                }
                .listStyle(.plain)
            } else {
                ScrollView {
                    LazyVGrid(columns: isWide == false ? narrowGridColumns : gridColumns, spacing: 26) {
                        ForEach(shown) { item in ItemCard(item: item, model: model, width: nil) }
                    }
                    .pagePadding()
                }
            }
        }
        // A narrow regular-width column (half-open iPhone Duo, iPad split view) gets the phone's rows.
        .onGeometryChange(for: Bool?.self) { $0.size.width > 0 ? $0.size.width >= 560 : nil } action: { isWide = $0 }
        .environment(\.wideRows, isWide)
        .pageEdges()
        .navigationTitle(listing.title)
        // Never empty: a subtitle that appears once the titles have loaded made iOS drop the large
        // title into the bar a moment after the page opened.
        .navigationSubtitle(loaded ? "\(items.count) titre\(items.count > 1 ? "s" : "")" : "Chargement…")
        .toolbar {
            if sizeClass != .compact {
                ToolbarItem {
                    #if os(macOS)
                    Picker("Affichage", selection: $layout) {
                        Label("Grille", systemImage: "square.grid.2x2").tag(ListingLayout.grid)
                        Label("Liste", systemImage: "list.bullet").tag(ListingLayout.list)
                    }
                    .pickerStyle(.segmented)
                    .help("Afficher en grille d'affiches ou en liste")
                    #else
                    // One button showing the other view: a segmented picker drew its own capsule inside
                    // the toolbar's glass one.
                    Button {
                        layout = layout == .grid ? .list : .grid
                    } label: {
                        layout == .grid ? Label("Liste", systemImage: "list.bullet")
                                        : Label("Grille", systemImage: "square.grid.2x2")
                    }
                    #endif
                }
            }
            ToolbarItem {
                Menu {
                    // Choosing the current order again flips it, so each is a button rather than a picker.
                    ForEach(ListingOrder.allCases, id: \.self) { choice in
                        Button {
                            if order == choice { reversed.toggle() } else { order = choice; reversed = false }
                        } label: {
                            #if os(macOS)
                            // A Mac menu row has no subtitle line: the direction goes in its title.
                            Text(order == choice ? "\(choice.title) · \(choice.direction(reversed: reversed))" : choice.title)
                            #else
                            // Title, subtitle and icon as siblings: the form a menu row draws a subtitle from.
                            Text(choice.title)
                            if order == choice { Text(choice.direction(reversed: reversed)) }
                            #endif
                            Image(systemName: order == choice ? choice.arrow(reversed: reversed) : choice.symbol)
                        }
                    }
                } label: {
                    Label("Trier", systemImage: "arrow.up.arrow.down")
                }
                #if os(iOS)
                .menuActionDismissBehavior(.disabled)
                #endif
                .help("Trier par date ou par nom ; choisir à nouveau inverse l'ordre")
            }
        }
        .task(id: listing) {
            loaded = false
            let discovery = model.discovery
            let wanted = listing
            items = await Task.detached(priority: .userInitiated) { discovery.items(wanted) }.value
            loaded = true
        }
    }
}

/// Posters in a grid, or the denser rows (always rows on iPhone).
enum ListingLayout: String {
    case grid, list
}

/// How a listing's titles are ordered: newest passage first, or A to Z; reversed, the other way round.
enum ListingOrder: String, CaseIterable {
    case date, name

    var title: String { self == .date ? "Date" : "Nom" }
    var symbol: String { self == .date ? "calendar" : "textformat" }

    /// Points the way the list runs: down for newest or A first, up when reversed.
    func arrow(reversed: Bool) -> String { reversed ? "arrow.up" : "arrow.down" }

    func direction(reversed: Bool) -> String {
        switch self {
        case .date: reversed ? "Les plus anciens d'abord" : "Les plus récents d'abord"
        case .name: reversed ? "De Z à A" : "De A à Z"
        }
    }

    func sorted(_ items: [ShelfItem], reversed: Bool) -> [ShelfItem] {
        let sorted = switch self {
        case .date: items.sorted { date($0) > date($1) }
        // Each name worked out once, rather than twice per comparison.
        case .name: items.map { (name: name($0), item: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { $0.item }
        }
        return reversed ? sorted.reversed() : sorted
    }

    private func date(_ item: ShelfItem) -> Date {
        switch item {
        case .passage(let mention): mention.episode.date
        case .episode(let episode, _): episode.date
        }
    }

    private func name(_ item: ShelfItem) -> String {
        switch item {
        case .passage(let mention): mention.segment.displayTitle
        case .episode(let episode, _): episode.name ?? episode.title
        }
    }
}

/// A show's episodes, by year, each with a mosaic of its films.
struct ShowPage: View {
    let series: Series?
    let model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let episodes = model.catalogue.episodes.filter { series == nil || $0.series == series }
        let groups = Dictionary(grouping: episodes, by: \.year).sorted { $0.key > $1.key }
        // A List (an AppKit table) recycles its rows, which keeps a 1,160-episode list smooth on the
        // first scroll; a lazy stack dropped 10% of frames there. It ignores the bottom room kept for
        // the floating player, though, so a clear row as tall as the player ends the list.
        List {
            ForEach(groups, id: \.key) { year, episodes in
                Section(String(year)) {
                    ForEach(episodes) { episode in
                        NavigationLink(value: Route.episode(episode.id, highlight: nil)) {
                            EpisodeRow(episode: episode, showSeries: series == nil)
                        }
                    }
                }
            }
            Color.clear
                .frame(height: sizeClass == .compact ? 0 : PlayerBar.reservedHeight)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .accessibilityHidden(true)
        }
        .pageEdges()
        .navigationTitle(series?.fullTitle ?? "Récents")
        .navigationSubtitle((series?.host.map { "par \($0) · " } ?? "") + "\(episodes.count) épisodes")
    }
}

struct EpisodeRow: View {
    let episode: Episode
    var showSeries = true

    var body: some View {
        HStack(spacing: 12) {
            EpisodeArt(episode: episode, side: 56)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(episode.name ?? EpisodeDates.long.string(from: episode.date))
                        .font(.headline)
                        .lineLimit(2)
                    Spacer()
                    if showSeries { SeriesBadge(series: episode.series) }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    /// The films and series for a review show; date and length for a plain recording.
    private var detail: String {
        // A review show lists its films, unless they're already the episode's title (feed shows).
        if !episode.subjects.isEmpty, episode.name == nil { return episode.subjects.map(\.displayTitle).joined(separator: " · ") }
        var parts = [EpisodeDates.long.string(from: episode.date)]
        if let duration = episode.duration { parts.append(clock(duration)) }
        if !episode.summary.isEmpty, episode.subjects.isEmpty { parts.append(episode.summary) }
        return parts.joined(separator: " · ")
    }
}

/// What a search found: posters by kind, then the episodes whose title or summary matched.
struct SearchPage: View {
    @Bindable var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    private static let limit = 120

    var body: some View {
        let results = model.results
        VStack(spacing: 0) {
            Picker("Chercher dans", selection: $model.scope) {
                ForEach(SearchScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            .padding(14)

            if results.isEmpty {
                if model.searchIsSettled { ContentUnavailableView.search(text: model.searchText) }
                else { Spacer() }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        group("Films", kind: .movie, in: results.works)
                        group("Séries", kind: .tvShow, in: results.works)
                        group("Personnalités", kind: .person, in: results.works)
                        if !results.described.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Dans le titre ou le résumé d'un épisode").font(.title3.weight(.bold))
                                ForEach(results.described.prefix(40)) { episode in
                                    NavigationLink(value: Route.episode(episode.id, highlight: nil)) {
                                        EpisodeRow(episode: episode)
                                    }
                                    .buttonStyle(.plain)
                                    Divider()
                                }
                            }
                        }
                    }
                    .pagePadding([.horizontal, .bottom])
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .pageEdges()
        .navigationTitle("Recherche")
        .navigationSubtitle(model.searchText)
    }

    @ViewBuilder private func group(_ title: String, kind: SegmentKind, in works: [Work]) -> some View {
        let matching = works.filter { $0.kind == kind }
        if !matching.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(title) · \(matching.count)").font(.title3.weight(.bold))
                if sizeClass == .compact {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(matching.prefix(Self.limit)) { work in
                            if let first = work.mentions.first {
                                NavigationLink(value: Route.work(first.segment.kind, first.segment.title)) {
                                    FilmRow(mention: first, passages: work.mentions.count)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                } else {
                    LazyVGrid(columns: gridColumns, spacing: 26) {
                        ForEach(matching.prefix(Self.limit)) { work in
                            if let first = work.mentions.first {
                                FilmCard(mention: first, model: model, width: nil, passages: work.mentions.count)
                            }
                        }
                    }
                }
                if matching.count > Self.limit {
                    Text("… et \(matching.count - Self.limit) autres : précisez la recherche.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}
