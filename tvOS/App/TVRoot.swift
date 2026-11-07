import CinqHeuresCore
import SwiftUI
import UIKit

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
                    // On the search's own page, not the stack: on the stack, the field and its keyboard
                    // stayed over the film or episode opened from a result.
                    .searchable(text: $model.searchText, prompt: "Film, série, réalisateur, acteur…")
                    .navigationDestination(for: Route.self) { RoutePage(route: $0, model: model) }
                }
            }
        }
        // The remote's play/pause button works wherever the focus is, as in the TV's own apps.
        .onPlayPauseCommand { if model.player.episode != nil { model.player.togglePlayPause() } }
        // With the focus up in the tab bar, Back left the app and kept the page: reopened, the app was
        // on that page again, with no way home. There, Back closes the tab's page first; on a tab's
        // first page (no action) it leaves the app as usual. In the page the stack closes it itself.
        .onExitCommand(perform: backAction.map { back in { if Self.focusIsInTabBar { back() } } })
        // Like the Podcasts app: what's asked to play comes up full screen. Back on the remote returns
        // to the tab bar, and the page it was started from is still in its tab.
        .onChange(of: model.playRequests) { model.phoneTab = .playing }
        // The player tab goes when nothing plays any more (a reset): back to Accueil rather than nowhere.
        .onChange(of: model.player.episode == nil) { _, empty in if empty, model.phoneTab == .playing { model.phoneTab = .home } }
        .modifier(AppBehaviors(model: model))
    }

    /// Whether the focus is up in the tab bar rather than in the page.
    private static var focusIsInTabBar: Bool {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        guard let view = scene?.focusSystem?.focusedItem as? UIView else { return false }
        return sequence(first: view, next: \.superview).contains { $0 is UITabBar }
    }

    /// Closes the current tab's top page; nil on a tab's first page.
    private var backAction: (() -> Void)? {
        switch model.phoneTab {
        case .home: model.path.isEmpty ? nil : { model.path.removeLast() }
        case .shows: model.showsPath.isEmpty ? nil : { model.showsPath.removeLast() }
        case .search: model.searchPath.isEmpty ? nil : { model.searchPath.removeLast() }
        case .playing: nil
        }
    }
}
