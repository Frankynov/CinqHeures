import CinqHeuresCore
import SwiftUI

/// One film, series or person: its poster, and every time the hosts talked about it.
struct WorkPage: View {
    let kind: SegmentKind
    let title: String
    let model: AppModel

    var body: some View {
        if let work = model.work(kind: kind, title: title), let latest = work.mentions.first {
            let segment = latest.segment
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    HStack(alignment: .top, spacing: 28) {
                        PosterImage(url: work.posterURL, corner: 12)
                            .frame(width: 210)
                            .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(segment.displayTitle).font(.largeTitle.weight(.bold))
                            HStack(spacing: 10) {
                                Label(kind.label, systemImage: kind.symbol)
                                if let year = segment.year { Text(String(year)) }
                                Text("\(work.mentions.count) passage\(work.mentions.count > 1 ? "s" : "")")
                            }
                            .foregroundStyle(.secondary)
                            if let best = work.mentions.compactMap(\.segment.stars).max() {
                                Text(Segment.starString(best)).font(.title3).foregroundStyle(brandOrange)
                            }
                            Button {
                                model.play(latest.episode, from: segment)
                            } label: {
                                Label("Écouter la critique", systemImage: "play.fill").padding(.horizontal, 6)
                            }
                            .buttonStyle(.borderedProminent).tint(brandOrange).controlSize(.large)
                            .padding(.top, 8)
                        }
                        Spacer(minLength: 0)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text(work.mentions.count > 1 ? "Les passages" : "Le passage").font(.title2.weight(.bold))
                        ForEach(work.mentions) { mention in PassageRow(mention: mention, model: model) }
                    }
                }
                .padding(28)
            }
            .pageEdges()
            .navigationTitle(segment.displayTitle)
            .navigationSubtitle(kind.label)
        } else {
            ContentUnavailableView("Introuvable", systemImage: "questionmark.folder")
        }
    }
}

private struct PassageRow: View {
    let mention: Work.Mention
    let model: AppModel

    var body: some View {
        let segment = mention.segment
        HStack(spacing: 14) {
            EpisodeArt(episode: mention.episode, side: 52)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(EpisodeDates.long.string(from: mention.episode.date)).font(.headline)
                    SeriesBadge(series: mention.episode.series)
                }
                HStack(spacing: 8) {
                    Text(clock(segment.start ?? 0)).monospacedDigit()
                    if let stars = segment.stars { Text(Segment.starString(stars)).foregroundStyle(brandOrange) }
                    if let verdict = segment.spokenVerdict { Text(verdict) }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.open(.episode(mention.episode.id, highlight: segment.id)) } label: {
                Label("Épisode", systemImage: "list.bullet")
            }
            .buttonStyle(.bordered)
            Button { model.play(mention.episode, from: segment) } label: {
                Label("Écouter", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent).tint(brandOrange)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
