import CinqHeuresCore
import SwiftUI

/// An episode and everything discussed in it, pushed from a card, a row or the player bar.
struct EpisodePage: View {
    let id: Int
    let highlight: Int?
    let model: AppModel

    var body: some View {
        if let episode = model.episode(id: id) {
            Group {
                #if os(tvOS)
                // tvOS/App: the artwork beside the title, and the programme as a row of posters.
                TVEpisodeContent(episode: episode, model: model, highlighted: highlight)
                #else
                EpisodeContent(episode: episode, model: model, highlighted: highlight)
                #endif
            }
                .task(id: episode.id) {
                    model.warm(episode, at: episode.segments.first { $0.id == highlight } ?? episode.subjects.first)
                }
                .pageTitle(episode.title)
                .pageSubtitle(EpisodeDates.long.string(from: episode.date))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        } else {
            ContentUnavailableView("Introuvable", systemImage: "questionmark.folder")
        }
    }
}

private struct EpisodeContent: View {
    let episode: Episode
    let model: AppModel
    let highlighted: Int?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let player = model.player
        let isCurrent = player.episode?.id == episode.id
        // A plain scroll view, not a List: a List is an AppKit table, and when it scrolls itself to the
        // highlighted passage its top rows draw outside the clip, over the (transparent) toolbar.
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        // Always on the TV, where the title isn't in a bar above the page.
                        if episode.artwork != nil || tvScale > 1 {
                            HStack(alignment: .top, spacing: 14) {
                                if episode.artwork != nil { Artwork(url: episode.artwork, side: 110 * tvScale) }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(episode.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                                    if let host = episode.series.host {
                                        Text("\(episode.series.fullTitle), par \(host)")
                                            .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                                    }
                                    Text(EpisodeDates.long.string(from: episode.date))
                                        .foregroundStyle(.secondary)
                                    if let duration = episode.duration {
                                        Text(clock(duration)).foregroundStyle(.secondary).monospacedDigit()
                                            .accessibilityLabel(Spoken.duration(duration))
                                    }
                                }
                            }
                        }
                        // With the largest text sizes the buttons go under the badge, the play button across
                        // the page: beside it, its words broke over four lines in a circle.
                        if typeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    SeriesBadge(series: episode.series)
                                    Spacer()
                                    favoriteButton
                                }
                                playButton(isCurrent: isCurrent, fullWidth: true)
                            }
                        } else {
                            HStack {
                                SeriesBadge(series: episode.series)
                                Spacer()
                                favoriteButton
                                playButton(isCurrent: isCurrent, fullWidth: false)
                            }
                        }
                        if !episode.summary.isEmpty {
                            Text(episode.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .selectableText()
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !episode.segments.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Au programme · \(episode.subjects.count)")
                                .font(.title3.weight(.bold))
                                .accessibilityLabel("Au programme, \(episode.subjects.count) titre\(episode.subjects.count > 1 ? "s" : "")")
                                .accessibilityAddTraits(.isHeader)
                                .padding(.bottom, 10)
                            ForEach(Array(episode.segments.enumerated()), id: \.element.id) { index, segment in
                                if index > 0 { Divider().padding(.leading, (episode.segments.contains { $0.start != nil } ? 98 : 46) * tvScale) }
                                SegmentRow(segment: segment, episode: episode, model: model,
                                           isHighlighted: segment.id == highlighted,
                                           isPlaying: isCurrent && player.currentSegmentID == segment.id)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(segment.id == highlighted ? Color.accentColor.opacity(0.15) : .clear,
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .id(segment.id)
                            }
                        }
                    }
                }
                .pagePadding()
            }
            .pageEdges()
            .onAppear { scroll(proxy) }
            .onChange(of: highlighted) { scroll(proxy) }
            .onChange(of: episode.id) { scroll(proxy) }
        }
    }

    private var favoriteButton: some View {
        FavoriteButton(episode: episode, favorites: model.favorites)
            .buttonStyle(.bordered)
            .tint(.pink)
    }

    private func playButton(isCurrent: Bool, fullWidth: Bool) -> some View {
        let player = model.player
        return Button {
            model.play(episode)
        } label: {
            Label(isCurrent ? "Reprendre" : player.hasProgress(episode) ? "Reprendre l'épisode" : "Écouter l'épisode",
                  systemImage: "play.fill")
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .orangeButtonLabel()
        }
        .buttonStyle(.borderedProminent).tint(brandOrange)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let highlighted else { return }
        // Once the page has its size; centring before that lands short.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(highlighted, anchor: .center) }
        }
    }
}

private struct SegmentRow: View {
    let segment: Segment
    let episode: Episode
    let model: AppModel
    let isHighlighted: Bool
    let isPlaying: Bool

    var body: some View {
        let isSubject = segment.kind.isSubject
        // The "Autre" specials have no timecodes at all: no column of dashes, no buttons all playing
        // from the start (the episode's own button does that).
        let timed = episode.segments.contains { $0.start != nil }
        HStack(spacing: 10) {
            if timed {
                Text(segment.start.map(clock) ?? "–")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 52 * tvScale, alignment: .trailing)
            }
            if isSubject {
                Poster(url: segment.posterURL, width: 26 * tvScale)
            } else {
                Image(systemName: segment.kind.symbol)
                    .foregroundStyle(.tertiary)
                    .frame(width: 26 * tvScale)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(segment.title)
                    .font(isSubject ? .body.weight(.medium) : .body)
                    .foregroundStyle(isSubject ? .primary : .secondary)
                HStack(spacing: 6) {
                    if segment.kind != .movie && isSubject {
                        Label(segment.kind.label, systemImage: segment.kind.symbol).labelStyle(.titleAndIcon)
                    }
                    if let stars = segment.stars {
                        Text(Segment.starString(stars)).foregroundStyle(.orange)
                            .accessibilityLabel("\(stars) étoiles sur 4")
                    }
                    if let verdict = segment.spokenVerdict { Text(verdict) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            // The whole block, up to the buttons, opens the film, series or person, as a row does
            // everywhere else: the title's own words were a small target, with a finger above all.
            .frame(maxWidth: .infinity, alignment: .leading)
            // On the TV an aside's row plays it: a row the focus lands on should do something.
            .rowAction { if isSubject { model.open(.work(segment.kind, segment.title)) } else if tvScale > 1 { model.play(episode, from: segment) } }
            .help(isSubject ? "Voir la page de ce titre" : "")
            .accessibilityAddTraits(isSubject ? .isButton : [])
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor)
            }
            if timed {
                Button {
                    model.play(episode, from: segment)
                } label: {
                    Label("Écouter", systemImage: "play.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Écouter à partir de \(clock(segment.start ?? 0))")
            }
        }
        .padding(.vertical, 2)
        // One element a row: "4 minutes et 12 secondes, Pfau, 3 étoiles sur 4, 3 bonnes doses". It opens
        // the title's page (an aside plays instead); playing from its time is an action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(timed: timed))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isSubject ? "" : "Écoute à partir d'ici")
        .accessibilityAction {
            if isSubject { model.open(.work(segment.kind, segment.title)) } else { model.play(episode, from: segment) }
        }
        .accessibilityActions {
            if timed, isSubject {
                Button("Écouter à partir de \(Spoken.duration(segment.start ?? 0))") { model.play(episode, from: segment) }
            }
        }
    }

    private func spoken(timed: Bool) -> String {
        let kind = segment.kind.isSubject && segment.kind != .movie ? segment.kind.label : nil
        return Spoken.join([timed ? segment.start.map(Spoken.duration) : nil, segment.title, kind,
                            segment.stars.map(Spoken.stars), segment.spokenVerdict, isPlaying ? "en cours" : nil])
    }
}
