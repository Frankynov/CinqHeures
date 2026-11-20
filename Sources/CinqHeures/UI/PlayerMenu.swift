import CinqHeuresCore
import SwiftUI

#if !os(tvOS)
/// The player's "…": the sleep timer, and closing the player (where the episode was left is kept).
/// One menu rather than two more buttons, which squeezed the title in the iPad's bar. With a timer
/// set it shows a moon, so the timer can be seen without opening it.
struct PlayerMenu: View {
    let player: PlayerModel
    var size: CGFloat = 17

    var body: some View {
        Menu {
            Section(sectionTitle) {
                timerButton("Désactivée", timer: nil, checked: player.sleepTimer == nil)
                ForEach(PlayerModel.sleepMinutes, id: \.self) { minutes in
                    Button(minutes == 60 ? "Dans 1 heure" : "Dans \(minutes) minutes") { player.setSleepTimer(minutes: minutes) }
                }
                if !player.marks.isEmpty {
                    timerButton("À la fin du passage", timer: .endOfPassage, checked: player.sleepTimer == .endOfPassage)
                }
            }
            Divider()
            Button { player.close() } label: {
                Label("Fermer le lecteur", systemImage: "xmark")
            }
        } label: {
            label
        }
        .borderlessMenu()
        .fixedSize()
        .tooltip(player.sleepTimer == nil ? "Minuterie, fermer le lecteur" : "Minuterie de veille")
        .accessibilityLabel("Autres options du lecteur")
        .accessibilityValue(spokenTimer)
    }

    /// The moon alone: with the minutes beside it, the title in the iPad's bar was cut to a few letters.
    /// The minutes left head the menu.
    private var label: some View {
        Image(systemName: player.sleepTimer == nil ? "ellipsis.circle" : "moon.fill")
            .font(.system(size: player.sleepTimer == nil ? size : size * 0.9, weight: .medium))
            .foregroundStyle(brandOrange)
            .contentTransition(.symbolEffect(.replace))
    }

    private func timerButton(_ title: String, timer: PlayerModel.SleepTimer?, checked: Bool) -> some View {
        Button { player.setSleepTimer(timer) } label: {
            Text(title)
            if checked { Image(systemName: "checkmark") }
        }
    }

    private var sectionTitle: String {
        switch player.sleepTimer {
        case nil: "Minuterie de veille"
        case .endOfPassage: "Pause à la fin du passage"
        case .at(let date): "Pause dans \(minutesLeft(until: date, now: .now)) min"
        }
    }

    private var spokenTimer: String {
        switch player.sleepTimer {
        case nil: ""
        case .endOfPassage: "Pause à la fin du passage"
        case .at(let date): "Pause dans \(minutesLeft(until: date, now: .now)) minutes"
        }
    }

    private func minutesLeft(until date: Date, now: Date) -> Int { max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up))) }
}
#endif
