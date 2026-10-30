import CinqHeuresCore
import SwiftUI

/// The player: one compact row of Liquid Glass floating over the bottom of the content. Artwork and
/// title, the transport, the scrubber (with a mark at each film of the episode), volume and speed.
struct PlayerBar: View {
    let player: PlayerModel
    /// Called when the now-playing block is clicked: opens the episode's page.
    let open: () -> Void

    /// What each page keeps free at its bottom (see `pageEdges`): the bar, its margin and a little air.
    static let reservedHeight: CGFloat = 86

    var body: some View {
        HStack(spacing: 16) {
            nowPlaying
                .frame(minWidth: 170, idealWidth: 270, maxWidth: 300, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if player.episode != nil { open() } }
                .help(player.episode == nil ? "" : "Ouvrir l'épisode")

            transport
                .disabled(player.phase != .ready)

            // The scrubber gets the room first: on a narrow window the volume slider goes instead.
            ChapterScrubber(player: player)
                .frame(minWidth: 280)
                .layoutPriority(1)

            // On a narrow window the volume slider goes; the speed stays.
            ViewThatFits(in: .horizontal) {
                trailing(withVolume: true)
                trailing(withVolume: false)
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .modifier(GlassPanel(cornerRadius: 22))
        .frame(maxWidth: 1240)
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button { player.skip(by: -PlayerModel.jump) } label: {
                Image(systemName: "gobackward.15").font(.system(size: 17, weight: .medium))
            }
            .help("Reculer de 15 secondes")
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
                    .background(
                        LinearGradient(colors: [Color(red: 0.98, green: 0.62, blue: 0.12), brandOrange],
                                       startPoint: .top, endPoint: .bottom),
                        in: Circle()
                    )
                    .shadow(color: brandOrange.opacity(0.35), radius: 4, y: 2)
                    .opacity(player.phase == .ready ? 1 : 0.45)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(player.isPlaying ? "Pause" : "Lecture")
            Button { player.skip(by: PlayerModel.jump) } label: {
                Image(systemName: "goforward.15").font(.system(size: 17, weight: .medium))
            }
            .help("Avancer de 15 secondes")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func trailing(withVolume: Bool) -> some View {
        HStack(spacing: 12) {
            if withVolume {
                HStack(spacing: 5) {
                    Image(systemName: volumeSymbol)
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1)
                        .controlSize(.mini)
                        .frame(width: 80)
                        .help("Volume")
                }
            }
            Menu {
                ForEach(PlayerModel.speeds, id: \.self) { speed in
                    Button {
                        player.rate = speed
                    } label: {
                        Text(speedLabel(speed))
                        if speed == player.rate { Image(systemName: "checkmark") }
                    }
                }
            } label: {
                Text(speedLabel(player.rate)).monospacedDigit().font(.callout.weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Vitesse de lecture")
        }
    }

    private var volumeSymbol: String {
        switch player.volume {
        case 0: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    private func speedLabel(_ speed: Float) -> String {
        (speed == speed.rounded() ? String(format: "%.0f", speed) : String(format: "%g", speed)) + "×"
    }

    @ViewBuilder private var nowPlaying: some View {
        if let episode = player.episode {
            let segment = player.currentSegment ?? player.requestedSegment
            HStack(spacing: 10) {
                if segment?.posterURL == nil, episode.artwork != nil {
                    Artwork(url: episode.artwork, side: 42)
                } else {
                    Poster(url: segment?.posterURL, width: 28)
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    switch player.phase {
                    case .loading:
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Chargement…") }
                            .font(.callout.weight(.semibold))
                    case .failed:
                        Text("Lecture impossible")
                            .font(.callout.weight(.semibold)).foregroundStyle(.red).lineLimit(1)
                    default:
                        MarqueeText(text: segment?.displayTitle ?? episode.title)
                    }
                    if case .failed(let message) = player.phase {
                        Button { player.retry() } label: {
                            Label("Réessayer", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .help(message)
                    } else if player.serverIsSlow {
                        // While the file opens as well as during playback: the wait is the server's.
                        SlowServerNote(player: player)
                    } else if player.phase != .loading {
                        HStack(spacing: 5) {
                            SeriesBadge(series: episode.series)
                            Text(EpisodeDates.short.string(from: episode.date))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "headphones").foregroundStyle(.secondary)
                Text("Rien en lecture").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// A one-line title that scrolls when it doesn't fit: a pause, a slow glide to its end, back again.
/// With "Reduce motion" on it stays put, and the whole title shows on hover.
private struct MarqueeText: View {
    let text: String
    var font: Font = .callout.weight(.semibold)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var textWidth: CGFloat = 0
    @ViewState private var boxWidth: CGFloat = 0
    @ViewState private var offset: CGFloat = 0

    private var overflow: CGFloat { max(0, textWidth - boxWidth) }

    var body: some View {
        // The box is sized by a one-letter stand-in, so the long title never widens it; the title
        // itself is laid over the box at its natural width and clipped.
        Text("X").font(font).hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .overlay(alignment: .leading) {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                    .offset(x: offset)
            }
            .clipped()
            .mask {
                // Soft edges only while the title is too long, on the side it runs off.
                HStack(spacing: 0) {
                    LinearGradient(colors: [offset < 0 ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: overflow > 1 ? 10 : 0)
                    Color.black
                    LinearGradient(colors: [.black, offset > -overflow + 1 ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: overflow > 1 ? 10 : 0)
                }
            }
            .help(overflow > 1 ? text : "")
            .task(id: "\(text)|\(Int(overflow))|\(reduceMotion)") {
                offset = 0
                guard overflow > 1, !reduceMotion else { return }
                let glide = Double(overflow) / 28          // about 28 points a second
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2.5))
                    if Task.isCancelled { return }
                    withAnimation(.linear(duration: glide)) { offset = -overflow }
                    try? await Task.sleep(for: .seconds(glide + 1.8))
                    if Task.isCancelled { return }
                    withAnimation(.easeInOut(duration: 0.5)) { offset = 0 }
                    try? await Task.sleep(for: .seconds(0.5))
                }
            }
    }
}

/// The progress line, with a small mark where each film, series or person of the episode starts.
/// Hovering shows the time and the passage under the pointer; clicking or dragging seeks there.
private struct ChapterScrubber: View {
    let player: PlayerModel
    @ViewState private var hoverX: CGFloat?
    @ViewState private var dragTime: Double?

    var body: some View {
        HStack(spacing: 8) {
            Text(clock(dragTime ?? player.currentTime))
                .frame(minWidth: 44, alignment: .trailing)
            GeometryReader { geo in track(width: geo.size.width) }
                .frame(height: 18)
            Text("-" + clock(max(0, player.duration - (dragTime ?? player.currentTime))))
                .frame(minWidth: 50, alignment: .leading)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var ready: Bool { player.phase == .ready && player.duration > 0 }

    /// Every segment that has a start, for the marks and for naming what's under the pointer.
    private var chapters: [Segment] {
        (player.episode?.segments ?? []).filter { ($0.start ?? 0) > 0 }
    }

    private func track(width: CGFloat) -> some View {
        let duration = max(player.duration, 1)
        let time = dragTime ?? player.currentTime
        let x = { (t: Double) in CGFloat(min(max(t / duration, 0), 1)) * width }
        let active = hoverX != nil || dragTime != nil
        return ZStack(alignment: .leading) {
            Capsule().fill(.primary.opacity(0.14)).frame(height: active ? 6 : 4)
            Capsule().fill(brandOrange).frame(width: ready ? x(time) : 0, height: active ? 6 : 4)
            if ready {
                ForEach(chapters) { chapter in
                    Capsule()
                        .fill(.primary.opacity(0.5))
                        .frame(width: 2, height: active ? 14 : 10)
                        .offset(x: x(chapter.start ?? 0) - 1)
                }
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .frame(width: 12, height: 12)
                    .offset(x: x(time) - 6)
                    .opacity(active ? 1 : 0)
            }
        }
        .frame(width: width, height: 18)
        .animation(.easeOut(duration: 0.12), value: active)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hoverX = ready ? location.x : nil
            case .ended: hoverX = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard ready else { return }
                    dragTime = Double(min(max(value.location.x / width, 0), 1)) * duration
                    hoverX = value.location.x
                }
                .onEnded { _ in
                    if let dragTime { player.seek(to: dragTime) }
                    dragTime = nil
                }
        )
        .overlay(alignment: .topLeading) {
            if let hoverX, ready {
                // Centred on the pointer in a wide box, lifted above the track.
                bubble(at: Double(min(max(hoverX / width, 0), 1)) * duration)
                    .frame(width: 320)
                    .offset(x: min(max(hoverX, 0), width) - 160, y: -30)
                    .allowsHitTesting(false)
            }
        }
    }

    /// "Contagion · 16:36" above the pointer: the passage being discussed at that time.
    private func bubble(at time: Double) -> some View {
        let chapter = chapters.last { ($0.start ?? 0) <= time }
        return HStack(spacing: 6) {
            if let chapter {
                Text(chapter.displayTitle).fontWeight(.semibold).lineLimit(1)
            }
            Text(clock(time)).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.caption)
        .foregroundStyle(.primary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}

/// Liquid Glass on macOS 26, a material panel before it.
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
        }
    }
}

/// Shown while 5heures.be's server is slow to hand over a passage: short enough to always fit, with
/// the time waited so far, and the explanation one click away.
private struct SlowServerNote: View {
    let player: PlayerModel
    @ViewState private var showsExplanation = false

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Préparation du passage… \(clock(context.date.timeIntervalSince(player.slowSince ?? context.date)))")
                    .monospacedDigit()
            }
            Button { showsExplanation.toggle() } label: {
                Label("Pourquoi ?", systemImage: "info.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .popover(isPresented: $showsExplanation, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Le serveur de 5heures.be est lent").font(.headline)
                    Text("""
                         Ce fichier audio n'a pas été demandé récemment : le serveur du site met parfois \
                         une à deux minutes à atteindre ce passage la première fois. Ensuite tout est \
                         instantané, y compris les sauts de 15 secondes.

                         Ce n'est pas un défaut de l'app : le même délai se voit dans le navigateur, où le \
                         lecteur du site finit par repartir du début. Ici la lecture démarre dès que le \
                         serveur répond.
                         """)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Réessayer") { player.retry(); showsExplanation = false }
                }
                .padding(16)
                .frame(width: 340)
            }
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .lineLimit(1)
    }
}
