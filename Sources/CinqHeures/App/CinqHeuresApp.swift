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
            CommandMenu("Lecture") {
                Button("Lecture / Pause") { model.player.togglePlayPause() }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Reculer de 15 secondes") { model.player.skip(by: -PlayerModel.jump) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Avancer de 15 secondes") { model.player.skip(by: PlayerModel.jump) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
            }
        }
    }
}
