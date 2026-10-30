import CinqHeuresCore
import SwiftUI

private let gridColumns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 22, alignment: .top)]

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

    var body: some View {
        ScrollView {
            if loaded && items.isEmpty {
                ContentUnavailableView("Rien ici", systemImage: "film")
                    .frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                LazyVGrid(columns: gridColumns, spacing: 26) {
                    ForEach(items) { item in ItemCard(item: item, model: model, width: nil) }
                }
                .pagePadding()
            }
        }
        .pageEdges()
        .navigationTitle(listing.title)
        .navigationSubtitle(loaded ? "\(items.count) titre\(items.count > 1 ? "s" : "")" : "")
        .task(id: listing) {
            loaded = false
            let discovery = model.discovery
            let wanted = listing
            items = await Task.detached(priority: .userInitiated) { discovery.items(wanted) }.value
            loaded = true
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
                        group("Personnes", kind: .person, in: results.works)
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
                LazyVGrid(columns: gridColumns, spacing: 26) {
                    ForEach(matching.prefix(Self.limit)) { work in
                        if let first = work.mentions.first {
                            FilmCard(mention: first, model: model, width: nil, passages: work.mentions.count)
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
