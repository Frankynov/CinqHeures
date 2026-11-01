import AVFoundation
import SwiftUI

/// The iPhone and iPad app: the same screens as the Mac (Sources/CinqHeures), in one scene.
@main
struct CinqHeuresiOSApp: App {
    @ViewState private var model = AppModel()

    init() {
        // Audio keeps playing with the screen locked or another app in front, like any podcast app.
        // The session is only activated when playback starts (PlayerModel): activating it here
        // stopped whatever another app was playing as soon as 5heures was opened.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        // Segments as wide as their words: split evenly, "Personnalités" in the search scopes was cut off.
        UISegmentedControl.appearance().apportionsSegmentWidthsByContent = true
    }

    var body: some Scene {
        WindowGroup {
            MainWindow(model: model)
                .task { await model.start() }
        }
    }
}
