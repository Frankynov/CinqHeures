import CinqHeuresCore
import SwiftUI

/// An episode on the TV. The iPad's page, a column of rows as wide as the screen, left most of the
/// width empty; here the artwork is big beside the title, buttons and summary, and the programme is a
/// row of posters to move along, as in the player.
///
/// A poster opens its film, series or person, as posters do everywhere in the app, and a long press
/// plays from it. An introduction or an aside plays from a click.
struct TVEpisodeContent: View {
    let episode: Episode
    let model: AppModel
    let highlighted: Int?
    @State private var showsSummary = false

    /// Longer than this, the summary is cut and a click on it shows all of it.
    private static let summaryLength = 420

    var body: some View {
        let player = model.player
        let isCurrent = player.episode?.id == episode.id
        ScrollView {
            VStack(alignment: .leading, spacing: 56) {
                header(isCurrent: isCurrent)
                if !episode.segments.isEmpty { programme(isCurrent: isCurrent) }
            }
            .padding(.vertical, 30)
        }
        .scrollClipDisabled()
        .sheet(isPresented: $showsSummary) { summarySheet }
    }

    private func header(isCurrent: Bool) -> some View {
        HStack(alignment: .top, spacing: 60) {
            EpisodeArt(episode: episode, side: 400)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    SeriesBadge(series: episode.series)
                    Text(EpisodeDates.long.string(from: episode.date))
                    if let duration = episode.duration {
                        Text("· " + clock(duration)).monospacedDigit().accessibilityLabel(Spoken.duration(duration))
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text(episode.title)
                        .font(.system(size: 52, weight: .bold))
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let host = episode.series.host {
                        Text("\(episode.series.fullTitle), par \(host)").font(.headline.weight(.regular)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 30) {
                    Button { model.play(episode) } label: {
                        Label(isCurrent ? "Reprendre" : model.player.hasProgress(episode) ? "Reprendre l'épisode" : "Écouter l'épisode",
                              systemImage: "play.fill")
                            .orangeButtonLabel()
                    }
                    .buttonStyle(.borderedProminent).tint(brandOrange)
                    // Not tinted: a pink button turned bright pink under the focus, its pale heart hard to
                    // see. The heart alone is pink, on grey, or on white when focused.
                    FavoriteButton(episode: episode, favorites: model.favorites)
                        .buttonStyle(.bordered)
                        .foregroundStyle(.pink)
                }
                .focusSection()
                summary
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The summary, cut after a few lines when it's long: a click on it then shows all of it.
    @ViewBuilder private var summary: some View {
        if !episode.summary.isEmpty {
            let text = Text(episode.summary).font(.callout).foregroundStyle(.secondary)
            if episode.summary.count > Self.summaryLength {
                Button { showsSummary = true } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        text.lineLimit(6).multilineTextAlignment(.leading)
                        Text("Lire la suite").font(.caption.weight(.semibold)).foregroundStyle(brandOrange)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.card)
                .accessibilityHint("Affiche tout le résumé")
            } else {
                text.fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var summarySheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(episode.title).font(.title2.weight(.bold))
                Text(episode.summary).font(.body)
            }
            .frame(width: 1100, alignment: .leading)
            .padding(40)
            // A sheet's text scrolls only with something to focus.
            .focusable()
        }
    }

    private func programme(isCurrent: Bool) -> some View {
        // The "Autre" specials have no timecodes: their asides play nothing, the episode's button does.
        let timed = episode.segments.contains { $0.start != nil }
        return VStack(alignment: .leading, spacing: 24) {
            Text("Au programme · \(episode.subjects.count)").font(.title3.weight(.bold))
                .accessibilityLabel("Au programme, \(episode.subjects.count) titre\(episode.subjects.count > 1 ? "s" : "")")
                .accessibilityAddTraits(.isHeader)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        ForEach(episode.segments) { segment in
                            card(segment, timed: timed, isCurrent: isCurrent).id(segment.id)
                        }
                    }
                    .padding(.vertical, 20)
                }
                .scrollClipDisabled()
                // Opened for a passage (from a film's page): that one in view.
                .onAppear {
                    guard let highlighted else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { proxy.scrollTo(highlighted, anchor: .center) }
                }
            }
        }
        .focusSection()
    }

    private func card(_ segment: Segment, timed: Bool, isCurrent: Bool) -> some View {
        let play = timed ? { model.play(episode, from: segment) } : nil
        let isPlaying = isCurrent && model.player.currentSegmentID == segment.id
        return Group {
            if segment.kind.isSubject {
                TVSegmentCard(segment: segment, isCurrent: isPlaying, isHighlighted: segment.id == highlighted,
                              action: { model.open(.work(segment.kind, segment.title)) }, play: play,
                              hint: "Ouvre la page de ce titre")
            } else {
                TVSegmentCard(segment: segment, isCurrent: isPlaying, isHighlighted: segment.id == highlighted,
                              action: play, hint: "Écouter à partir d'ici")
            }
        }
    }
}
