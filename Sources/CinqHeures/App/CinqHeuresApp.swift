#if os(macOS)
import CinqHeuresCore
import SwiftUI

/// "Réinitialiser… (cache : 12 Mo)" in the app menu: clears the cache, the listening progress, or both.
/// A view of its own, so its title follows the measured size (SwiftUI refreshes it when the menu opens):
/// a button written straight into `commands` keeps the title it had when the menu was first built.
private struct ClearCacheMenuItem: View {
    let model: AppModel

    var body: some View {
        Button("Réinitialiser… (cache : \(CacheUsage.text(model.cacheUsage.total)))") {
            model.updateCacheUsage()
            model.showsReset = true
        }
    }
}

@main
struct CinqHeuresApp: App {
    @ViewState private var model = AppModel()
    /// The Dock icon's menu (QuickActions).
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("5heures") {
            MainWindow(model: model)
                .frame(minWidth: 980, minHeight: 600)
                .task { await model.start() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Divider()
                ClearCacheMenuItem(model: model)
            }
            CommandGroup(after: .newItem) {
                Button("Actualiser le catalogue") { Task { await model.refresh(everything: true) } }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandMenu("Lecture") { PlaybackMenu(model: model) }
            CommandMenu("Aller") { GoMenu(model: model) }
        }
    }
}

/// The Lecture menu. A view of its own, so its items follow the player (the favourite's wording,
/// the speed's checkmark, what's available).
private struct PlaybackMenu: View {
    let model: AppModel

    var body: some View {
        let player = model.player
        let ready = player.phase == .ready
        Button(player.isPlaying ? "Pause" : "Lecture") { player.togglePlayPause() }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(!ready)
        Divider()
        Button("Reculer de 15 secondes") { player.skip(by: -PlayerModel.jump) }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(!ready)
        Button("Avancer de 15 secondes") { player.skip(by: PlayerModel.jump) }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(!ready)
        Button("Passage précédent") { player.previousPassageStart() }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            .disabled(!ready || player.marks.isEmpty)
        Button("Passage suivant") { player.nextPassageStart() }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            .disabled(!ready || player.nextPassage == nil)
        Divider()
        Picker("Vitesse", selection: Binding(get: { player.rate }, set: { player.rate = $0 })) {
            ForEach(PlayerModel.speeds, id: \.self) { speed in
                Text(speed == speed.rounded() ? String(format: "%.0f×", speed) : String(format: "%g×", speed)).tag(speed)
            }
        }
        Divider()
        if let episode = player.episode {
            let isFavorite = model.favorites.contains(episode)
            Button(isFavorite ? "Retirer des favoris" : "Ajouter aux favoris") { model.favorites.toggle(episode) }
                .keyboardShortcut("d", modifiers: .command)
        } else {
            Button("Ajouter aux favoris") {}.keyboardShortcut("d", modifiers: .command).disabled(true)
        }
        Button("Afficher l'épisode en cours") {
            model.searchText = ""
            model.openCurrentEpisode()
        }
        .keyboardShortcut("l", modifiers: .command)
        .disabled(player.episode == nil)
    }
}

/// The Aller menu: the sidebar's rows by number, as in Music or Finder, and back.
private struct GoMenu: View {
    let model: AppModel

    var body: some View {
        Button("Précédent") { _ = model.path.popLast() }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(model.path.isEmpty)
        Button("Rechercher") { model.focusSearch() }
            .keyboardShortcut("f", modifiers: .command)
        Divider()
        item("Accueil", .home, "1")
        item("Favoris", .favorites, "2")
        item("Récents", .all, "3")
        ForEach(Array(Series.allCases.enumerated()), id: \.element) { index, series in
            item(series.title, .show(series), KeyEquivalent(Character(String(index + 4))))
        }
    }

    private func item(_ title: String, _ destination: SidebarItem, _ key: KeyEquivalent) -> some View {
        Button(title) {
            model.searchText = ""
            if model.sidebar == destination { model.popToRoot() } else { model.sidebar = destination }
        }
        .keyboardShortcut(key, modifiers: .command)
    }
}
#endif
