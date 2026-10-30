import AVFoundation
import SwiftUI

/// The iPhone and iPad app: the same screens as the Mac (Sources/CinqHeures), in one scene.
@main
struct CinqHeuresiOSApp: App {
    @ViewState private var model = AppModel()

    init() {
        // Audio keeps playing with the screen locked or another app in front, like any podcast app.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            MainWindow(model: model)
                .task { await model.start() }
        }
    }
}
