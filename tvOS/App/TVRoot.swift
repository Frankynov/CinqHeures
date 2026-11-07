import CinqHeuresCore
import SwiftUI

/// The Apple TV layout: tabs along the top, as the TV's own apps have them. Accueil and the search are
/// the iPhone's; Émissions shows the shows as big tiles; En écoute, once something plays, is the player.
/// Each tab pushes its own pages (the pages are the iPad's, drawn bigger).
struct TVRoot: View {
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
                    TVShowsPage(model: model)
                        .navigationDestination(for: Route.self) { RoutePage(route: $0, model: model) }
                }
            }
            if model.player.episode != nil {
                Tab("En écoute", systemImage: "waveform", value: AppModel.PhoneTab.playing) {
                    TVPlayer(model: model)
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
                        }
                    }
                    .navigationDestination(for: Route.self) { RoutePage(route: $0, model: model) }
                }
                .searchable(text: $model.searchText, prompt: "Film, série, réalisateur, acteur…")
            }
        }
        // The remote's play/pause button works wherever the focus is, as in the TV's own apps.
        .onPlayPauseCommand { if model.player.episode != nil { model.player.togglePlayPause() } }
        // Like the Podcasts app: what's asked to play comes up full screen. Back on the remote returns
        // to the tab bar, and the page it was started from is still in its tab.
        .onChange(of: model.playRequests) { model.phoneTab = .playing }
        // The player tab goes when nothing plays any more (a reset): back to Accueil rather than nowhere.
        .onChange(of: model.player.episode == nil) { _, empty in if empty, model.phoneTab == .playing { model.phoneTab = .home } }
        .modifier(AppBehaviors(model: model))
    }
}
