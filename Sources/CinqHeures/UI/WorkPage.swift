import CinqHeuresCore
import SwiftUI

/// One film, series or person: its poster, and every time the hosts talked about it.
struct WorkPage: View {
    let kind: SegmentKind
    let title: String
    let model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ViewState private var width: CGFloat = 0
    /// iPhone, or any narrow column (a half-open iPhone Duo, iPad split view): a smaller poster beside
    /// the title, everything else below at full width. The size class alone left a regular-width but
    /// narrow column with the title squeezed beside the big poster, a word per line.
    private var compact: Bool { sizeClass == .compact || (width > 0 && width < 560) }

    var body: some View {
        if let work = model.work(kind: kind, title: title), let latest = work.mentions.first {
            let segment = latest.segment
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 22 : 30) {
                    if compact {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top, spacing: 16) {
                                PosterImage(url: work.posterURL, corner: 10)
                                    .frame(width: 112)
                                    .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
                                titleBlock(work: work, segment: segment)
                            }
                            details(work: work, latest: latest)
                        }
                    } else {
                        HStack(alignment: .top, spacing: 28) {
                            PosterImage(url: work.posterURL, corner: 12)
                                .frame(width: 210)
                                .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
                            VStack(alignment: .leading, spacing: 10) {
                                titleBlock(work: work, segment: segment)
                                details(work: work, latest: latest)
                            }
                            Spacer(minLength: 0)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text(work.mentions.count > 1 ? "Les passages" : "Le passage").font(.title2.weight(.bold))
                        ForEach(work.mentions) { mention in PassageRow(mention: mention, model: model, compact: compact) }
                    }
                }
                .padding(compact ? 16 : 28)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .pageEdges()
            .task(id: latest.segment.id) { model.warm(latest.episode, at: latest.segment) }
            .navigationTitle(segment.displayTitle)
            .navigationSubtitle(kind.label)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } else {
            ContentUnavailableView("Introuvable", systemImage: "questionmark.folder")
        }
    }

    /// Title, French title, and the line of facts.
    private func titleBlock(work: Work, segment: Segment) -> some View {
        // From TMDB, for films that don't come from 5heures.be (Dayez's): the French title, the director.
        let local = work.mentions.lazy.compactMap(\.segment.localTitle).first
        let director = work.mentions.lazy.compactMap(\.segment.director).first
        return VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            Text(segment.displayTitle)
                .font(compact ? .title.weight(.bold) : .largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            if let local, local != segment.displayTitle {
                Text(local).font(compact ? .callout : .title3).foregroundStyle(.secondary)
            }
            // Wraps as a line of facts on a phone, rather than one fact per column.
            let facts = [kind.label, segment.year.map(String.init), director.map { "de \($0)" },
                         "\(work.mentions.count) passage\(work.mentions.count > 1 ? "s" : "")"].compactMap { $0 }
            Text(facts.joined(separator: " · "))
                .font(compact ? .callout : .body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let best = work.mentions.compactMap(\.segment.stars).max() {
                Text(Segment.starString(best)).font(.title3).foregroundStyle(brandOrange)
            }
        }
    }

    /// The synopsis and the play button.
    private func details(work: Work, latest: Work.Mention) -> some View {
        let overview = work.mentions.lazy.compactMap(\.segment.overview).first
        return VStack(alignment: .leading, spacing: 10) {
            if let overview {
                Text(overview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 8 : 6)
                    .frame(maxWidth: 620, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("Synopsis et affiche : TMDB").font(.caption2).foregroundStyle(.tertiary)
            }
            Button {
                model.play(latest.episode, from: latest.segment)
            } label: {
                Label("Écouter la critique", systemImage: "play.fill")
                    .padding(.horizontal, 6)
                    .frame(maxWidth: compact ? .infinity : nil)
            }
            .buttonStyle(.borderedProminent).tint(brandOrange).controlSize(.large)
            .padding(.top, 8)
        }
    }
}

private struct PassageRow: View {
    let mention: Work.Mention
    let model: AppModel
    var compact = false

    var body: some View {
        let segment = mention.segment
        HStack(spacing: compact ? 10 : 14) {
            EpisodeArt(episode: mention.episode, side: compact ? 44 : 52)
            VStack(alignment: .leading, spacing: 4) {
                if compact {
                    Text(EpisodeDates.short.string(from: mention.episode.date)).font(.headline)
                    SeriesBadge(series: mention.episode.series)
                } else {
                    HStack(spacing: 8) {
                        Text(EpisodeDates.long.string(from: mention.episode.date)).font(.headline)
                        SeriesBadge(series: mention.episode.series)
                    }
                }
                HStack(spacing: 8) {
                    if let start = segment.start {
                        Text(clock(start)).monospacedDigit()
                    } else {
                        // Dayez's episodes have no per-film timecode: the whole (short) episode plays.
                        Text("Épisode entier" + (mention.episode.duration.map { " · \(Int($0 / 60)) min" } ?? ""))
                    }
                    if let stars = segment.stars { Text(Segment.starString(stars)).foregroundStyle(brandOrange) }
                    if let verdict = segment.spokenVerdict, !compact { Text(verdict) }
                }
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            // On a phone, icons only: the row stays one line.
            Button { model.open(.episode(mention.episode.id, highlight: segment.id)) } label: {
                Label("Épisode", systemImage: "list.bullet")
                    .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
            }
            .buttonStyle(.bordered)
            Button { model.play(mention.episode, from: segment) } label: {
                Label("Écouter", systemImage: "play.fill")
                    .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
            }
            .buttonStyle(.borderedProminent).tint(brandOrange)
        }
        .padding(compact ? 10 : 12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
