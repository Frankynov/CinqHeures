import CinqHeuresCore
import SwiftUI

/// An episode and everything discussed in it, pushed from a card, a row or the player bar.
struct EpisodePage: View {
    let id: Int
    let highlight: Int?
    let model: AppModel

    var body: some View {
        if let episode = model.episode(id: id) {
            EpisodeContent(episode: episode, model: model, highlighted: highlight)
                .task(id: episode.id) {
                    model.warm(episode, at: episode.segments.first { $0.id == highlight } ?? episode.subjects.first)
                }
                .navigationTitle(episode.title)
                .navigationSubtitle(EpisodeDates.long.string(from: episode.date))
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

    var body: some View {
        let player = model.player
        let isCurrent = player.episode?.id == episode.id
        // A plain scroll view, not a List: a List is an AppKit table, and when it scrolls itself to the
        // highlighted passage its top rows draw outside the clip, over the (transparent) toolbar.
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        if episode.artwork != nil {
                            HStack(alignment: .top, spacing: 14) {
                                Artwork(url: episode.artwork, side: 110)
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
                                    }
                                }
                            }
                        }
                        HStack {
                            SeriesBadge(series: episode.series)
                            Spacer()
                            Button {
                                model.play(episode)
                            } label: {
                                Label(isCurrent ? "Reprendre" : player.hasProgress(episode) ? "Reprendre l'épisode" : "Écouter l'épisode",
                                      systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent).tint(brandOrange)
                        }
                        if !episode.summary.isEmpty {
                            Text(episode.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !episode.segments.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Au programme · \(episode.subjects.count)")
                                .font(.title3.weight(.bold))
                                .padding(.bottom, 10)
                            ForEach(Array(episode.segments.enumerated()), id: \.element.id) { index, segment in
                                if index > 0 { Divider().padding(.leading, 98) }
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
        HStack(spacing: 10) {
            Text(segment.start.map(clock) ?? "–")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            if isSubject {
                Poster(url: segment.posterURL, width: 26)
            } else {
                Image(systemName: segment.kind.symbol)
                    .foregroundStyle(.tertiary)
                    .frame(width: 26)
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
            .contentShape(Rectangle())
            .onTapGesture { if isSubject { model.open(.work(segment.kind, segment.title)) } }
            .help(isSubject ? "Voir la page de ce titre" : "")
            .accessibilityAddTraits(isSubject ? .isButton : [])
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor)
            }
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
        .padding(.vertical, 2)
    }
}
