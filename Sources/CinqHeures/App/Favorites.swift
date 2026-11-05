import CinqHeuresCore
import Observation
import SwiftUI

/// The episodes marked as favourites, the last one added first. Kept in UserDefaults, like the
/// listening progress, by episode id: they survive a cache reset and come back with the catalogue.
@MainActor @Observable
final class Favorites {
    private(set) var ids: [Int]
    @ObservationIgnored private let defaults: UserDefaults
    static let key = "favoriteEpisodes"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = defaults.array(forKey: Self.key) as? [Int] ?? []
    }

    func contains(_ episode: Episode) -> Bool { ids.contains(episode.id) }

    func toggle(_ episode: Episode) {
        if let index = ids.firstIndex(of: episode.id) { ids.remove(at: index) } else { ids.insert(episode.id, at: 0) }
        defaults.set(ids, forKey: Self.key)
    }
}

/// A heart that adds the episode to the favourites, or takes it out.
struct FavoriteButton: View {
    let episode: Episode
    let favorites: Favorites
    var size: CGFloat? = nil

    var body: some View {
        let isFavorite = favorites.contains(episode)
        Button { favorites.toggle(episode) } label: {
            Label(isFavorite ? "Retirer des favoris" : "Ajouter aux favoris", systemImage: isFavorite ? "heart.fill" : "heart")
                .labelStyle(.iconOnly)
                .font(size.map { .system(size: $0, weight: .medium) })
                // Pink once chosen. Until then the tint on iPhone and iPad (pink on the episode page, orange in
                // the full player), and on the Mac the bar's own colour, like its other controls.
                .foregroundStyle(isFavorite ? AnyShapeStyle(Color.pink) : idle)
                .contentTransition(.symbolEffect(.replace))
        }
        .tooltip(isFavorite ? "Retirer des favoris" : "Ajouter aux favoris")
    }

    private var idle: AnyShapeStyle {
        #if os(macOS)
        AnyShapeStyle(.foreground)
        #else
        AnyShapeStyle(.tint)
        #endif
    }
}

/// "Ajouter aux favoris" in an episode row's context menu and, on iPhone and iPad, its swipe actions.
struct FavoriteActions: ViewModifier {
    let episode: Episode
    let favorites: Favorites

    func body(content: Content) -> some View {
        let isFavorite = favorites.contains(episode)
        let action = Button { favorites.toggle(episode) } label: {
            Label(isFavorite ? "Retirer des favoris" : "Ajouter aux favoris", systemImage: isFavorite ? "heart.slash" : "heart")
        }
        content
            .contextMenu { action }
            #if os(iOS)
            .swipeActions(edge: .leading) { action.tint(.pink) }
            #endif
    }
}
