import CinqHeuresCore
import AppKit
import SwiftUI

extension Series {
    /// One colour per show, so a row says which it is before the label is read.
    var tint: Color {
        switch self {
        case .podcast: Color(red: 0.93, green: 0.55, blue: 0.05)
        case .soir: Color(red: 0.36, green: 0.40, blue: 0.85)
        case .codLive: Color(red: 0.80, green: 0.22, blue: 0.25)
        case .autre: Color(red: 0.45, green: 0.50, blue: 0.55)
        case .quelquePart: Color(red: 0.05, green: 0.55, blue: 0.58)
        case .dayez: Color(red: 0.78, green: 0.25, blue: 0.48)
        }
    }

    var symbol: String {
        switch self {
        case .podcast: "mic.fill"
        case .soir: "moon.fill"
        case .codLive: "theatermasks.fill"
        case .autre: "sparkles"
        case .quelquePart: "music.note"
        case .dayez: "popcorn.fill"
        }
    }
}

extension SegmentKind {
    var symbol: String {
        switch self {
        case .movie: "film"
        case .tvShow: "tv"
        case .person: "person.fill"
        case .introduction: "text.bubble"
        case .conclusion: "text.bubble"
        case .other: "ellipsis.bubble"
        }
    }
}

/// A goat in silhouette, in the current foreground colour: a running joke on the show. SF Symbols has
/// no goat, so this keeps only the shape of the 🐐 emoji (its alpha) and fills it like a symbol.
struct GoatIcon: View {
    var size: CGFloat = 15

    var body: some View {
        Rectangle()
            .fill(.foreground)
            .frame(width: size * 1.25, height: size * 1.1)
            .mask(Text("🐐").font(.system(size: size)))
            .accessibilityHidden(true)
    }
}

/// A sidebar icon: a white glyph on a small rounded tile in the row's colour, like System Settings.
/// Every glyph is fitted to the same tile, so a wide one (the COD Live masks) takes no more room.
struct SidebarIcon: View {
    let symbol: String
    let color: Color
    /// Wide glyphs (the masks) fill the tile's width first, so they get a little less margin.
    var inset: CGFloat = 4

    var body: some View {
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(inset)
            .frame(width: 20, height: 20)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// The same tile with a number, for the rating rows.
struct SidebarNumber: View {
    let number: Int
    let color: Color

    var body: some View {
        Text("\(number)")
            .font(.system(size: 12, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

struct SeriesBadge: View {
    let series: Series

    var body: some View {
        Text(series.badge)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.white)
            .background(series.tint, in: Capsule())
            .fixedSize()
    }
}

struct Poster: View {
    let url: URL?
    var width: CGFloat = 30
    @ViewState private var image: NSImage?

    init(url: URL?, width: CGFloat = 30) {
        self.url = url
        self.width = width
        _image = ViewState(initialValue: PosterCache.shared.cached(url, pixels: Self.pixels(width)))
    }

    private static func pixels(_ width: CGFloat) -> Int { max(90, Int(width * 3)) }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "film").foregroundStyle(.tertiary))
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .task(id: url) {
            guard let url else { image = nil; return }
            let pixels = Self.pixels(width)
            if let cached = PosterCache.shared.cached(url, pixels: pixels) { image = cached; return }
            image = await PosterCache.shared.image(for: url, pixels: pixels)
        }
    }
}

/// A square cover, for the feed shows' episodes (they have no film posters).
struct Artwork: View {
    let url: URL?
    var side: CGFloat = 40
    @ViewState private var image: NSImage?

    init(url: URL?, side: CGFloat = 40) {
        self.url = url
        self.side = side
        _image = ViewState(initialValue: PosterCache.shared.cached(url, pixels: Self.pixels(side)))
    }

    private static func pixels(_ side: CGFloat) -> Int { Int(side * 2) }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "music.note").foregroundStyle(.tertiary))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.12))
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await PosterCache.shared.image(for: url, pixels: Self.pixels(side))
        }
    }
}

func clock(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
