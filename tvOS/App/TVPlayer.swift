import CinqHeuresCore
import SwiftUI

/// The TV's player, a tab of its own: the film being discussed big on the left, what's playing and
/// the controls on the right, and the episode's programme underneath, to jump from film to film.
///
/// The remote: play/pause anywhere (TVRoot); on the progress bar, left and right go back or forward
/// 15 seconds and a click pauses; the buttons under it go from passage to passage.
struct TVPlayer: View {
    let model: AppModel
    private var player: PlayerModel { model.player }

    var body: some View {
        let episode = player.episode
        let segment = player.currentSegment ?? player.requestedSegment
        ScrollView {
            VStack(alignment: .leading, spacing: 60) {
                HStack(alignment: .center, spacing: 70) {
                    artwork(episode: episode, segment: segment)
                    VStack(alignment: .leading, spacing: 34) {
                        titles(episode: episode, segment: segment)
                        TVProgressBar(player: player)
                        controls
                        if player.serverIsSlow {
                            Label("Le serveur de 5heures.be prépare ce passage : cela peut prendre une minute la première fois.",
                                  systemImage: "hourglass")
                                .font(.callout).foregroundStyle(.orange)
                        }
                        if case .failed(let message) = player.phase {
                            HStack(spacing: 24) {
                                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(2)
                                Button("Réessayer") { player.retry() }
                            }
                            .font(.callout)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let episode, episode.subjects.count > 1 {
                    programme(episode)
                }
            }
            .padding(.vertical, 30)
        }
        .scrollClipDisabled()
        .background { backdrop(segment: segment) }
        .modifier(PlaybackAnnouncements(player: player))
    }

    // MARK: Parts

    @ViewBuilder private func artwork(episode: Episode?, segment: Segment?) -> some View {
        Group {
            if let url = segment?.posterURL {
                PosterImage(url: url, pixels: 1000, corner: 22).frame(width: 440)
            } else if let episode {
                EpisodeArt(episode: episode, side: 520)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
        .animation(.easeInOut(duration: 0.3), value: segment?.id)
    }

    @ViewBuilder private func titles(episode: Episode?, segment: Segment?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let episode {
                HStack(spacing: 14) {
                    SeriesBadge(series: episode.series)
                    Text(EpisodeDates.long.string(from: episode.date)).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            Text(segment?.displayTitle ?? episode?.title ?? "Rien en lecture")
                .font(.system(size: 64, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)
            if let segment {
                HStack(spacing: 16) {
                    if let year = segment.year { Text(String(year)) }
                    if let director = segment.director { Text("de \(director)").lineLimit(1) }
                    if let stars = segment.stars { Text(Segment.starString(stars)).foregroundStyle(brandOrange) }
                    if let verdict = segment.spokenVerdict { Text(verdict).lineLimit(1) }
                }
                .font(.headline.weight(.regular))
                .foregroundStyle(.secondary)
            }
            if let episode, segment != nil, let name = episode.name {
                Text(name).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        let ready = player.phase == .ready
        let hasMarks = !player.marks.isEmpty
        return HStack(spacing: 28) {
            if hasMarks {
                round("backward.end.fill", label: player.previousPassage.map { "Passage précédent : \($0.displayTitle)" } ?? "Début de l'épisode") {
                    player.previousPassageStart()
                }
            }
            round("gobackward.15", label: "Reculer de 15 secondes") { player.skip(by: -PlayerModel.jump) }
            round(player.isPlaying ? "pause.fill" : "play.fill", label: player.isPlaying ? "Pause" : "Lecture", big: true) {
                player.togglePlayPause()
            }
            round("goforward.15", label: "Avancer de 15 secondes") { player.skip(by: PlayerModel.jump) }
            if hasMarks {
                round("forward.end.fill", label: player.nextPassage.map { "Passage suivant : \($0.displayTitle)" } ?? "Passage suivant") {
                    player.nextPassageStart()
                }
                .disabled(player.nextPassage == nil)
            }
            Spacer(minLength: 20)
            if let episode = player.episode {
                let favorite = model.favorites.contains(episode)
                round(favorite ? "heart.fill" : "heart", label: favorite ? "Retirer des favoris" : "Ajouter aux favoris") {
                    model.favorites.toggle(episode)
                }
                .foregroundStyle(favorite ? .pink : .primary)
            }
            Menu {
                Picker("Vitesse", selection: Binding(get: { player.rate }, set: { player.rate = $0 })) {
                    ForEach(PlayerModel.speeds, id: \.self) { Text(speed($0)).tag($0) }
                }
            } label: {
                Text(speed(player.rate)).font(.callout.weight(.semibold).monospacedDigit()).frame(minWidth: 70)
            }
            .accessibilityLabel("Vitesse : \(Spoken.speed(player.rate))")
            Button { model.openCurrentEpisode() } label: {
                Label("L'épisode", systemImage: "list.bullet")
            }
        }
        .disabled(!ready && player.phase != .loading)
        .focusSection()
    }

    private func round(_ symbol: String, label: String, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: big ? 40 : 30, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: big ? 76 : 56, height: big ? 76 : 56)
        }
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }

    private func speed(_ rate: Float) -> String {
        rate == 1 ? "1×" : rate.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "fr_BE"))) + "×"
    }

    /// Every film, series and person of the episode, in order: the one playing in orange; a click
    /// plays from its start.
    private func programme(_ episode: Episode) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Au programme").font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(episode.subjects) { subject in
                        TVSegmentCard(segment: subject, isCurrent: subject.id == player.currentSegmentID,
                                      action: { model.play(episode, from: subject) }, hint: "Écouter à partir de ce passage")
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    /// The film's poster, blurred and dark, behind everything.
    private func backdrop(segment: Segment?) -> some View {
        RemoteImage(url: segment?.posterURL, pixels: 300) { image in
            if let image {
                Image(platformImage: image).resizable().scaledToFill().blur(radius: 60).scaleEffect(1.2)
                    // Dark enough for the grey text over a pale poster.
                    .overlay(Color.black.opacity(0.75))
            } else {
                Color.clear
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 0.5), value: segment?.id)
    }
}

/// The progress bar, with a mark at each film. With the focus on it, it thickens, and the remote's
/// left and right go back or forward 15 seconds; a click plays or pauses.
private struct TVProgressBar: View {
    let player: PlayerModel
    @FocusState private var focused: Bool

    var body: some View {
        let ready = player.phase == .ready && player.duration > 0
        let time = player.currentTime
        VStack(spacing: 12) {
            GeometryReader { geo in
                let width = geo.size.width
                let x = { (t: Double) in CGFloat(min(max(t / max(player.duration, 1), 0), 1)) * width }
                let bar: CGFloat = focused ? 16 : 8
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.18)).frame(height: bar)
                    Capsule().fill(brandOrange).frame(width: ready ? x(time) : 0, height: bar)
                    if ready {
                        ForEach(player.marks, id: \.self) { mark in
                            Capsule().fill(.primary.opacity(0.6))
                                .frame(width: 4, height: bar + 12)
                                .offset(x: x(mark) - 2)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .animation(.easeOut(duration: 0.15), value: focused)
            }
            .frame(height: 32)
            HStack {
                Text(clock(time))
                Spacer(minLength: 20)
                if let segment = player.currentSegment { Text(segment.displayTitle).lineLimit(1) }
                Spacer(minLength: 20)
                Text("-" + clock(max(0, player.duration - time)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(focused ? .primary : .secondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, focused ? 20 : 0)
        .background(.white.opacity(focused ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .focusable(ready)
        .focused($focused)
        .onMoveCommand { direction in
            switch direction {
            case .left: player.skip(by: -PlayerModel.jump)
            case .right: player.skip(by: PlayerModel.jump)
            default: break
            }
        }
        .onTapGesture { player.togglePlayPause() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position de lecture")
        .accessibilityValue(ready ? "\(Spoken.duration(time)) sur \(Spoken.duration(player.duration))" : "Chargement")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.skip(by: PlayerModel.jump)
            case .decrement: player.skip(by: -PlayerModel.jump)
            @unknown default: break
            }
        }
    }
}
