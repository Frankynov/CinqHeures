import AVFoundation
import SwiftUI

/// The Apple TV app: the iPad's pages, with a tvOS root and player (TVRoot).
@main
struct CinqHeuresTVApp: App {
    @ViewState private var model = AppModel()

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
    }

    var body: some Scene {
        WindowGroup {
            TVRoot(model: model)
                .task { await model.start() }
        }
    }
}
