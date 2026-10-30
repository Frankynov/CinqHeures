import CinqHeuresCore
import SwiftUI

struct HomeView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                if let hero = model.hero {
                    HeroView(mention: hero, model: model)
                        .id(hero.segment.id)
                        .transition(.opacity)
                }
                let resuming = model.continueListening.prefix(12).map { ShelfItem.episode($0.episode, resume: $0.seconds) }
                if !resuming.isEmpty {
                    ShelfRow(title: "Continuer l'écoute", items: Array(resuming), seeAll: nil, model: model)
                }
                ForEach(model.homeSections) { section in
                    switch section {
                    case .shelf(let shelf):
                        ShelfRow(title: shelf.title, items: shelf.items, seeAll: route(for: shelf), model: model)
                    case .decades(let tiles):
                        DecadeRow(tiles: tiles, model: model)
                    }
                }
            }
            .padding(.vertical, 24)
        }
        .pageEdges()
        .navigationTitle("Accueil")
        .navigationSubtitle("\(model.catalogue.episodes.count) épisodes")
        .toolbar { ShuffleToolbarItem(model: model) }
    }

    private func route(for shelf: Shelf) -> Route? {
        if let listing = shelf.listing { return .listing(listing) }
        if let show = shelf.show { return .show(show) }
        return nil
    }
}

/// "Surprenez-moi" next to the search field: an orange capsule, drawn here rather than left to the
/// toolbar. On macOS 26 the toolbar puts every item in a shared glass capsule and draws buttons in its
/// own grey style whatever their tint, so the item opts out of that background and draws its own.
private struct ShuffleToolbarItem: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .primaryAction) { button }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { button }
        }
    }

    private var button: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) { model.shuffle() }
        } label: {
            HStack(spacing: 6) {
                // A goat (a joke from the show) that hops on each click.
                GoatIcon(size: 15)
                    .phaseAnimator([0.0, -5, 0], trigger: model.shuffleSeed) { goat, lift in
                        goat.offset(y: lift)
                    } animation: { _ in .easeOut(duration: 0.12) }
                Text("Surprenez-moi")
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                LinearGradient(colors: [Color(red: 0.98, green: 0.62, blue: 0.12), brandOrange],
                               startPoint: .top, endPoint: .bottom),
                in: Capsule()
            )
            .shadow(color: brandOrange.opacity(0.35), radius: 4, y: 2)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Room between the capsule and the search field, which otherwise sits right against it.
        .padding(.trailing, 14)
        .help("D'autres films au hasard, partout sur cette page")
        .accessibilityLabel("Surprenez-moi")
    }
}

/// A well-rated review, big, with its poster blurred behind it: play it or open the film.
struct HeroView: View {
    let mention: Work.Mention
    let model: AppModel

    var body: some View {
        let segment = mention.segment
        ZStack(alignment: .leading) {
            RemoteImage(url: segment.posterURL, pixels: 300) { image in
                if let image {
                    Image(nsImage: image).resizable().scaledToFill().blur(radius: 38).scaleEffect(1.3)
                } else {
                    Rectangle().fill(Color(red: 0.05, green: 0.2, blue: 0.43))
                }
            }
            .overlay(LinearGradient(colors: [.black.opacity(0.72), .black.opacity(0.35)], startPoint: .leading, endPoint: .trailing))

            HStack(spacing: 26) {
                PosterImage(url: segment.posterURL, corner: 10)
                    .frame(width: 138)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                VStack(alignment: .leading, spacing: 9) {
                    Text("À LA UNE · UNE CRITIQUE AU HASARD")
                        .font(.caption.weight(.semibold)).tracking(1.4)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(segment.displayTitle)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        if let year = segment.year { Text(String(year)) }
                        if let stars = segment.stars { Text(Segment.starString(stars)).foregroundStyle(brandOrange) }
                        if let verdict = segment.spokenVerdict { Text("· \(verdict)") }
                    }
                    .font(.callout).foregroundStyle(.white.opacity(0.85))
                    Text("\(EpisodeDates.long.string(from: mention.episode.date)) · \(mention.episode.series.title)")
                        .font(.callout).foregroundStyle(.white.opacity(0.65))
                    HStack(spacing: 10) {
                        Button { model.play(mention.episode, from: segment) } label: {
                            Label("Écouter la critique", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent).tint(brandOrange).controlSize(.large)
                        Button { model.open(.work(segment.kind, segment.title)) } label: {
                            Label("Voir le film", systemImage: "info.circle")
                        }
                        .buttonStyle(.bordered).controlSize(.large).tint(.white)
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { model.anotherHero() }
                        } label: {
                            Label("Une autre", systemImage: "dice.fill")
                        }
                        .buttonStyle(.bordered).controlSize(.large).tint(.white)
                        .help("Une autre critique au hasard")
                    }
                    .padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28).padding(.vertical, 26)
        }
        .frame(height: 250)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 28)
    }
}

/// A titled row of cards that scrolls sideways, with chevrons for a mouse.
struct ShelfRow: View {
    let title: String
    let items: [ShelfItem]
    let seeAll: Route?
    let model: AppModel
    @ViewState private var first = 0
    @ViewState private var hovering = false

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.title2.weight(.bold))
                    Spacer()
                    if let seeAll {
                        Button { model.open(seeAll) } label: {
                            Text("Tout voir").font(.callout.weight(.semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(brandOrange)
                    }
                }
                .padding(.horizontal, 28)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(items) { item in
                            ItemCard(item: item, model: model).id(item.id)
                        }
                    }
                    .padding(.horizontal, 28).padding(.vertical, 6)
                }
                .overlay(alignment: .leading) {
                    if hovering && first > 0 { chevron("chevron.left") { move(-5, proxy) } }
                }
                .overlay(alignment: .trailing) {
                    if hovering && first < items.count - 5 { chevron("chevron.right") { move(5, proxy) } }
                }
            }
        }
        .onHover { hovering = $0 }
    }

    private func move(_ delta: Int, _ proxy: ScrollViewProxy) {
        first = min(max(0, first + delta), max(0, items.count - 1))
        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(items[first].id, anchor: .leading) }
    }

    private func chevron(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.title3.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 38, height: 38).background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.bottom, 56)
    }
}

/// Decades as colourful tiles: the archive's way of "Genres".
struct DecadeRow: View {
    let tiles: [DecadeTile]
    let model: AppModel

    private static let palette: [[Color]] = [
        [Color(red: 0.35, green: 0.30, blue: 0.28), Color(red: 0.62, green: 0.50, blue: 0.36)],
        [Color(red: 0.75, green: 0.30, blue: 0.25), Color(red: 0.95, green: 0.62, blue: 0.20)],
        [Color(red: 0.55, green: 0.25, blue: 0.60), Color(red: 0.90, green: 0.40, blue: 0.55)],
        [Color(red: 0.15, green: 0.40, blue: 0.75), Color(red: 0.45, green: 0.30, blue: 0.80)],
        [Color(red: 0.10, green: 0.50, blue: 0.55), Color(red: 0.25, green: 0.70, blue: 0.45)],
        [Color(red: 0.20, green: 0.25, blue: 0.60), Color(red: 0.55, green: 0.30, blue: 0.70)],
        [Color(red: 0.80, green: 0.35, blue: 0.20), Color(red: 0.55, green: 0.15, blue: 0.40)],
        [Color(red: 0.05, green: 0.35, blue: 0.55), Color(red: 0.10, green: 0.60, blue: 0.70)],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Explorer par époque").font(.title2.weight(.bold)).padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 18) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                        DecadeTileView(tile: tile, colors: Self.palette[index % Self.palette.count])
                            .onTapGesture { model.open(.listing(.decade(tile.decade))) }
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 6)
            }
        }
    }
}

private struct DecadeTileView: View {
    let tile: DecadeTile
    let colors: [Color]
    @ViewState private var hovering = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            // A fan of posters from that decade on the right.
            HStack(spacing: -34) {
                ForEach(Array(tile.posters.enumerated()), id: \.offset) { index, url in
                    PosterImage(url: url, pixels: 220, corner: 5)
                        .frame(width: 62)
                        .rotationEffect(.degrees(Double(index - 1) * 7))
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.trailing, 22)
            .opacity(0.95)
            VStack(alignment: .leading, spacing: 2) {
                Text(tile.title).font(.title3.weight(.bold)).foregroundStyle(.white)
                Text("\(tile.count) films").font(.caption).foregroundStyle(.white.opacity(0.8))
            }
            .padding(16)
        }
        .frame(width: 250, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(hovering ? 0.3 : 0.12), radius: hovering ? 10 : 4, y: 3)
        .scaleEffect(hovering ? 1.03 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
    }
}
