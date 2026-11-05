#if os(iOS)
import CinqHeuresCore
import SwiftUI

/// The iPhone layout: three tabs (Accueil, Émissions, and search as the round button), with the mini
/// player above them. Scrolling down shrinks the tab bar to an icon and the mini player moves in beside
/// it, the way iOS's own apps do; scrolling back up brings both back.
struct PhoneTabs: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.phoneTab) {
            Tab("Accueil", systemImage: "house.fill", value: AppModel.PhoneTab.home) {
                NavigationStack(path: $model.path) {
                    Group {
                        if model.catalogue.isEmpty || (model.isSyncing && model.homeSections.isEmpty) {
                            FirstLaunchView(model: model)
                        } else {
                            HomeView(model: model)
                        }
                    }
                    .navigationDestination(for: Route.self) { RoutePage(route: $0, model: model) }
                }
            }
            Tab("Émissions", systemImage: "square.stack.fill", value: AppModel.PhoneTab.shows) {
                NavigationStack(path: $model.showsPath) {
                    PhoneShowsList(model: model)
                        .navigationDestination(for: Route.self) { RoutePage(route: $0, model: model) }
                }
            }
            Tab(value: AppModel.PhoneTab.search, role: .search) {
                NavigationStack(path: $model.searchPath) {
                    Group {
                        if model.isSearching {
                            SearchPage(model: model)
                        } else {
                            ContentUnavailableView("Rechercher", systemImage: "magnifyingglass",
                                                   description: Text("Un film, une série, un réalisateur, un acteur, un artiste…"))
                                .navigationTitle("Recherche")
                        }
                    }
                    .navigationDestination(for: Route.self) { RoutePage(route: $0, model: model) }
                }
                .searchable(text: $model.searchText, prompt: "Film, série, réalisateur, acteur…")
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            MiniPlayer(player: model.player, favorites: model.favorites, openEpisode: { model.openCurrentEpisode() })
        }
        .tint(brandOrange)
    }
}

/// The Émissions tab: what the sidebar holds on the iPad and the Mac, as rows that open each list.
private struct PhoneShowsList: View {
    let model: AppModel

    var body: some View {
        List {
            Section {
                NavigationLink(value: Route.favorites) {
                    Label { Text("Favoris") } icon: { SidebarIcon(symbol: "heart.fill", color: .pink) }
                        .badge(model.favorites.ids.count)
                }
            }
            Section {
                NavigationLink(value: Route.recent) {
                    Label { Text("Récents") } icon: { SidebarIcon(symbol: "clock.fill", color: .gray) }
                        .badge(model.count(of: nil))
                }
                ForEach(Series.allCases) { series in
                    NavigationLink(value: Route.show(series)) {
                        Label { Text(series.title).lineLimit(2) } icon: {
                            SidebarIcon(symbol: series.symbol, color: series.tint, inset: series == .codLive ? 2.5 : 4)
                        }
                        .badge(model.count(of: series))
                    }
                }
            }
            Section("Notes des films") {
                ForEach([4, 3, 2, 1, 0], id: \.self) { stars in
                    NavigationLink(value: Route.listing(.stars(stars))) {
                        Label {
                            Text(Segment.starString(stars)).foregroundStyle(stars >= 3 ? Color.orange : Color.secondary)
                        } icon: {
                            SidebarNumber(number: stars, color: stars >= 3 ? brandOrange : .gray)
                        }
                        .badge(model.count(ofStars: stars))
                        .accessibilityLabel(Spoken.stars(stars))
                    }
                }
                NavigationLink(value: Route.listing(.unrated)) {
                    Label { Text("Sans note").foregroundStyle(.secondary) } icon: { SidebarIcon(symbol: "minus", color: .gray) }
                        .badge(model.unratedCount)
                }
            }
            Section { ResetButton(model: model) }
            Section { SyncStatus(model: model) }
                .listRowBackground(Color.clear)
        }
        .navigationTitle("Émissions")
    }
}

/// The mini player in the tab bar's accessory: artwork, what's playing, play/pause and +15 s. Narrower
/// beside the shrunk tab bar (inline), where it keeps only play/pause. A tap opens the full player.
private struct MiniPlayer: View {
    let player: PlayerModel
    let favorites: Favorites
    let openEpisode: () -> Void
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @ViewState private var showsFullPlayer = false

    var body: some View {
        let episode = player.episode
        let segment = player.currentSegment ?? player.requestedSegment
        HStack(spacing: 12) {
            HStack(spacing: 12) {
            Group {
                if let url = segment?.posterURL {
                    Poster(url: url, width: 26)
                } else if let episode, episode.artwork != nil {
                    Artwork(url: episode.artwork, side: 34)
                } else {
                    Image(systemName: "headphones").font(.title3).foregroundStyle(.secondary).frame(width: 34)
                        .accessibilityHidden(true)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(segment?.displayTitle ?? episode?.title ?? "Rien en lecture")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(episode == nil ? .secondary : .primary)
                if let episode {
                    Text(status(episode))
                        .font(.caption)
                        .foregroundStyle(player.serverIsSlow ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
            }
            .lineLimit(1)
            }
            // What's playing as one button that opens the full player, as a tap on the bar does.
            .modifier(NowPlayingAccessibility(player: player, opensPlayer: true) { if episode != nil { showsFullPlayer = true } })
            Spacer(minLength: 4)
            if episode != nil {
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 36, height: 36)
                }
                .disabled(player.phase != .ready)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Lecture")
                if placement != .inline {
                    Button { player.skip(by: PlayerModel.jump) } label: {
                        Image(systemName: "goforward.15").font(.title3).frame(width: 36, height: 36)
                    }
                    .disabled(player.phase != .ready)
                    .accessibilityLabel("Avancer de 15 secondes")
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture { if episode != nil { showsFullPlayer = true } }
        .sheet(isPresented: $showsFullPlayer) {
            FullPlayer(player: player, favorites: favorites, openEpisode: { showsFullPlayer = false; openEpisode() })
                .presentationDragIndicator(.visible)
        }
        .modifier(PlaybackAnnouncements(player: player))
        // The accessory's height is the system's: past this size the title and show were cut off.
        // A tap opens the full player, which takes any size.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func status(_ episode: Episode) -> String {
        switch player.phase {
        case .loading: return "Chargement…"
        case .failed: return "Lecture impossible"
        default: return player.serverIsSlow ? "Préparation du passage…" : episode.series.title
        }
    }
}
#endif
