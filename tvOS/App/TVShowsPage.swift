import CinqHeuresCore
import SwiftUI

/// The Émissions tab: what the iPad's sidebar lists, as big tiles to move between with the remote.
/// The shows in their colours, then Favoris and Récents, then the films by score.
struct TVShowsPage: View {
    let model: AppModel

    /// Four shows a row, two full rows with Favoris and Récents; the six scores in one row. Full rows
    /// keep the focus moving: down from a column with nothing under it went nowhere.
    private let showColumns = Array(repeating: GridItem(.flexible(), spacing: 48, alignment: .top), count: 4)
    private let scoreColumns = Array(repeating: GridItem(.flexible(), spacing: 36, alignment: .top), count: 6)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 56) {
                section("Émissions", columns: showColumns) {
                    ForEach(Series.allCases) { series in
                        tile(Route.show(series), title: series.title, detail: count(model.count(of: series), "épisode"),
                             host: series.host, colors: [series.tint, series.tint.mix(with: .black, by: 0.35)]) {
                            Image(systemName: series.symbol)
                        }
                    }
                    tile(.favorites, title: "Favoris", detail: count(model.favorites.ids.count, "épisode"),
                         colors: [.pink, .pink.mix(with: .black, by: 0.35)]) {
                        Image(systemName: "heart.fill")
                    }
                    tile(.recent, title: "Récents", detail: count(model.count(of: nil), "épisode"),
                         colors: [.gray, .gray.mix(with: .black, by: 0.45)]) {
                        Image(systemName: "clock.fill")
                    }
                }
                section("Notes des films", columns: scoreColumns) {
                    ForEach([4, 3, 2, 1, 0], id: \.self) { stars in
                        let color = stars >= 3 ? brandOrange : .gray
                        tile(.listing(.stars(stars)), title: Segment.starString(stars), detail: count(model.count(ofStars: stars), "titre"),
                             colors: [color, color.mix(with: .black, by: 0.4)], height: 170) {
                            Text("\(stars)").fontWeight(.heavy)
                        }
                        .accessibilityLabel(Spoken.stars(stars))
                    }
                    tile(.listing(.unrated), title: "Sans note", detail: count(model.unratedCount, "titre"),
                         colors: [.gray, .gray.mix(with: .black, by: 0.45)], height: 170) {
                        Image(systemName: "minus")
                    }
                }
                HStack(alignment: .center, spacing: 40) {
                    ResetButton(model: model)
                    SyncStatus(model: model)
                    Spacer()
                }
                // As wide as the page: down from any score reaches "Réinitialiser…".
                .focusSection()
            }
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
    }

    private func count(_ number: Int, _ noun: String) -> String { "\(number) \(noun)\(number > 1 ? "s" : "")" }

    private func section<Content: View>(_ title: String, columns: [GridItem], @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(title).font(.title3.weight(.bold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: 48) { content() }
        }
        .focusSection()
    }

    /// A show's tile: its colour, its glyph big on the right, its name and what it holds.
    private func tile<Glyph: View>(_ route: Route, title: String, detail: String, host: String? = nil, colors: [Color],
                                   height: CGFloat = 220, @ViewBuilder glyph: () -> Glyph) -> some View {
        NavigationLink(value: route) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                glyph()
                    .font(.system(size: height * 0.42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.22))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(.white).lineLimit(2)
                    Text(host.map { "par \($0) · \(detail)" } ?? detail)
                        .font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                }
                .padding(24)
            }
            .frame(height: height)
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.card)
    }
}
