import CinqHeuresCore
import SwiftUI

/// The accent used for "Tout voir", the chevrons and the stars: the Podcast orange.
let brandOrange = Color(red: 0.93, green: 0.55, blue: 0.05)

extension View {
    /// What every page needs at its edges, applied on each page (a page pushed onto the navigation
    /// stack is hosted on its own, so modifiers on the stack miss it):
    /// - a clip at the top: the toolbar has no background (see MainWindow), and without it rows
    ///   scroll up behind the title and the search field;
    /// - room at the bottom for the floating player, so the last row can scroll above it.
    ///
    /// On iPad the clip also keeps the shelves from sliding under the floating sidebar.
    func pageEdges() -> some View { modifier(PageEdges()) }
}

/// Loads a thumbnail and hands it to `content` (nil while it loads).
struct RemoteImage<Content: View>: View {
    let url: URL?
    let pixels: Int
    @ViewBuilder let content: (PlatformImage?) -> Content
    @ViewState private var image: PlatformImage?

    init(url: URL?, pixels: Int, @ViewBuilder content: @escaping (PlatformImage?) -> Content) {
        self.url = url
        self.pixels = pixels
        self.content = content
        _image = ViewState(initialValue: PosterCache.shared.cached(url, pixels: pixels))
    }

    var body: some View {
        content(image)
            .task(id: url) {
                guard let url else { image = nil; return }
                if let cached = PosterCache.shared.cached(url, pixels: pixels) { image = cached; return }
                image = await PosterCache.shared.image(for: url, pixels: pixels)
            }
    }
}

/// A poster at whatever width its container gives it, always 2:3.
struct PosterImage: View {
    let url: URL?
    var pixels = 520
    var corner: CGFloat = 10

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                RemoteImage(url: url, pixels: pixels) { image in
                    if let image {
                        Image(platformImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "film").font(.title).foregroundStyle(.tertiary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// A poster cropped to a rectangle: one cell of an episode's mosaic.
private struct Tile: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        RemoteImage(url: url, pixels: max(60, Int(max(width, height) * 2))) { image in
            ZStack {
                Rectangle().fill(.quaternary)
                if let image { Image(platformImage: image).resizable().scaledToFill() }
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }
}

/// A square picture for an episode: its cover when it has one, else the posters of its films.
struct EpisodeArt: View {
    let episode: Episode
    var side: CGFloat

    var body: some View {
        Group {
            if episode.artwork != nil {
                Artwork(url: episode.artwork, side: side)
            } else {
                mosaic.clipShape(RoundedRectangle(cornerRadius: side * 0.1, style: .continuous))
            }
        }
        .frame(width: side, height: side)
    }

    @ViewBuilder private var mosaic: some View {
        let urls = episode.subjects.compactMap(\.posterURL).prefix(4)
        let half = side / 2
        switch urls.count {
        case 0:
            Rectangle().fill(.quaternary)
                .overlay(Image(systemName: "headphones").font(.title).foregroundStyle(.tertiary))
        case 1:
            Tile(url: urls[0], width: side, height: side)
        case 2:
            HStack(spacing: 1) { ForEach(Array(urls), id: \.self) { Tile(url: $0, width: half - 0.5, height: side) } }
        default:
            VStack(spacing: 1) {
                HStack(spacing: 1) { Tile(url: urls[0], width: half - 0.5, height: half - 0.5); Tile(url: urls[1], width: half - 0.5, height: half - 0.5) }
                if urls.count > 3 {
                    HStack(spacing: 1) { Tile(url: urls[2], width: half - 0.5, height: half - 0.5); Tile(url: urls[3], width: half - 0.5, height: half - 0.5) }
                } else {
                    // Three posters: the last one takes the whole bottom row.
                    Tile(url: urls[2], width: side, height: half - 0.5)
                }
            }
        }
    }
}

/// One film, series or person as a poster with its title: tap to open its page, hover to play.
struct FilmCard: View {
    let mention: Work.Mention
    let model: AppModel
    /// Fixed in a shelf; `nil` fills the grid cell.
    var width: CGFloat? = 150
    var passages = 1
    @ViewState private var hovering = false

    var body: some View {
        let segment = mention.segment
        VStack(alignment: .leading, spacing: 8) {
            PosterImage(url: segment.posterURL)
                .overlay(alignment: .bottomLeading) {
                    if let stars = segment.stars {
                        Text(Segment.starString(stars))
                            .font(.caption2).foregroundStyle(brandOrange)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.62), in: Capsule())
                            .padding(7)
                    }
                }
                .overlay {
                    if hovering {
                        Button {
                            model.play(mention.episode, from: mention.segment)
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.title2).foregroundStyle(.white)
                                .frame(width: 54, height: 54)
                                .background(.black.opacity(0.55), in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .help("Écouter la critique à \(clock(segment.start ?? 0))")
                    }
                }
                .shadow(color: .black.opacity(hovering ? 0.35 : 0.18), radius: hovering ? 12 : 5, y: hovering ? 6 : 3)
            Text(segment.displayTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .scaleEffect(hovering ? 1.03 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture { model.open(.work(segment.kind, segment.title)) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var subtitle: String { filmSubtitle(mention.segment, passages: passages) }
}

/// "Série", "2019 · 3 passages", "2024 · À voir".
private func filmSubtitle(_ segment: Segment, passages: Int) -> String {
    var parts: [String] = []
    switch segment.kind {
    case .tvShow: parts.append("Série")
    case .person: parts.append("Personnalité")
    default: if let year = segment.year { parts.append(String(year)) }
    }
    if passages > 1 { parts.append("\(passages) passages") }
    else if segment.kind == .movie, let verdict = segment.spokenVerdict { parts.append(verdict) }
    return parts.joined(separator: " · ")
}

/// A film card as a list row: a small poster, the title and its stars, and the show and date it was
/// talked about. Tapping it opens the film, like the card. On the iPhone's narrow screen the show and
/// date take a third line; with room (Mac, iPad) they move to the right and the row gets tighter.
struct FilmRow: View {
    let mention: Work.Mention
    var passages = 1
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let segment = mention.segment
        let wide = sizeClass != .compact
        let source = "\(mention.episode.series.title) · \(EpisodeDates.short.string(from: mention.episode.date))"
        HStack(spacing: 12) {
            Poster(url: segment.posterURL, width: wide ? 28 : 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(segment.displayTitle).font(.headline).lineLimit(wide ? 1 : 2)
                HStack(spacing: 6) {
                    if let stars = segment.stars {
                        Text(Segment.starString(stars)).foregroundStyle(brandOrange)
                    }
                    Text(filmSubtitle(segment, passages: passages)).foregroundStyle(.secondary)
                }
                .font(.caption)
                .lineLimit(1)
                if !wide {
                    Text(source).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            if wide {
                Spacer(minLength: 12)
                Text(source).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, wide ? 0 : 2)
    }
}

/// A shelf item as a list row: a film row, or the episode row the show pages use.
struct ItemRow: View {
    let item: ShelfItem

    var body: some View {
        switch item {
        case .passage(let mention):
            NavigationLink(value: Route.work(mention.segment.kind, mention.segment.title)) { FilmRow(mention: mention) }
        case .episode(let episode, _):
            NavigationLink(value: Route.episode(episode.id, highlight: nil)) { EpisodeRow(episode: episode) }
        }
    }
}

/// An episode in a shelf: its cover or mosaic, its title, and how far you got.
struct EpisodeCard: View {
    let episode: Episode
    let resume: Double?
    let model: AppModel
    var width: CGFloat = 150
    @ViewState private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EpisodeArt(episode: episode, side: width)
                .overlay(alignment: .bottom) {
                    if let resume, let total = episode.duration ?? model.player.duration(of: episode), total > 0 {
                        ProgressView(value: min(resume, total), total: total)
                            .progressViewStyle(.linear).tint(brandOrange)
                            .padding(8)
                    }
                }
                .overlay {
                    if hovering {
                        Button {
                            model.play(episode)
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.title2).foregroundStyle(.white)
                                .frame(width: 54, height: 54)
                                .background(.black.opacity(0.55), in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .shadow(color: .black.opacity(hovering ? 0.35 : 0.18), radius: hovering ? 12 : 5, y: hovering ? 6 : 3)
            Text(episode.name ?? episode.title)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width)
        .scaleEffect(hovering ? 1.03 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture { model.open(.episode(episode.id, highlight: nil)) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var subtitle: String {
        if let resume {
            return "Reprendre à \(clock(resume))"
        }
        var parts = [EpisodeDates.short.string(from: episode.date)]
        if let duration = episode.duration { parts.append(clock(duration)) }
        return parts.joined(separator: " · ")
    }
}

/// Any shelf item as the right card.
struct ItemCard: View {
    let item: ShelfItem
    let model: AppModel
    var width: CGFloat? = 150

    var body: some View {
        switch item {
        case .passage(let mention): FilmCard(mention: mention, model: model, width: width)
        case .episode(let episode, let resume): EpisodeCard(episode: episode, resume: resume, model: model, width: width ?? 150)
        }
    }
}

private struct PageEdges: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        // On iPhone the tab bar and its mini player inset the pages themselves.
        let room: CGFloat = sizeClass == .compact ? 0 : PlayerBar.reservedHeight
        #if os(macOS)
        content.clipped().contentMargins(.bottom, room, for: .scrollContent)
        #else
        // No clip on iPhone and iPad: iOS draws each page's large title at the top of its scroll
        // content, and clipping cut it in half under the navigation bar.
        content.contentMargins(.bottom, room, for: .scrollContent)
        #endif
    }
}
