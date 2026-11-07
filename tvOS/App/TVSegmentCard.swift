import CinqHeuresCore
import SwiftUI

/// One passage of an episode as a poster, in a row the remote moves along: the player's programme and
/// the episode page's. Its poster lifts under the focus; the one playing has a waveform and an orange
/// title. A film, series or person has its poster; an introduction or an aside, a tile with its symbol.
struct TVSegmentCard: View {
    let segment: Segment
    var isCurrent = false
    /// The passage the page was opened for: outlined in orange.
    var isHighlighted = false
    /// What a click does: nil leaves the card out of the focus (an untimed aside does nothing).
    let action: (() -> Void)?
    /// Offered by a long press: "Écouter à partir de 7:17", on a card whose click opens the film.
    var play: (() -> Void)? = nil
    /// What VoiceOver says a click does.
    var hint = ""

    static let width: CGFloat = 190

    var body: some View {
        if let action {
            Button(action: action) { card }
                .buttonStyle(.borderless)
                .contextMenu {
                    if let play {
                        Button(segment.start.map { "Écouter à partir de \(clock($0))" } ?? "Écouter", systemImage: "play.fill", action: play)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityHint(hint)
        } else {
            card
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            cover
                .frame(width: Self.width)
                .overlay {
                    if isHighlighted {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(brandOrange, lineWidth: 5)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isCurrent {
                        Image(systemName: "waveform")
                            .font(.title3.weight(.bold)).foregroundStyle(.white)
                            .padding(10).background(brandOrange, in: Circle()).padding(10)
                    }
                }
                .hoverEffect(.highlight)
            Text(segment.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isCurrent ? brandOrange : segment.kind.isSubject ? .primary : .secondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                if let start = segment.start { Text(clock(start)).monospacedDigit() }
                if let stars = segment.stars { Text(Segment.starString(stars)).foregroundStyle(brandOrange) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(width: Self.width, alignment: .leading)
    }

    @ViewBuilder private var cover: some View {
        if segment.kind.isSubject {
            PosterImage(url: segment.posterURL, pixels: 400, corner: 12)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    Image(systemName: segment.kind.symbol)
                        .font(.system(size: 56, weight: .medium))
                        .foregroundStyle(.secondary)
                }
        }
    }

    private var spoken: String {
        let kind = segment.kind.isSubject && segment.kind != .movie ? segment.kind.label : nil
        return Spoken.join([segment.title, kind, isCurrent ? "en cours" : nil,
                            segment.start.map { "à \(Spoken.duration($0))" }, segment.stars.map(Spoken.stars),
                            segment.spokenVerdict])
    }
}
