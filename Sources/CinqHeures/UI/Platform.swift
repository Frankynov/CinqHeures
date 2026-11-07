import AVKit
import SwiftUI
#if os(macOS)
import AppKit
/// A decoded picture: NSImage on the Mac, UIImage on iPhone and iPad.
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

extension PlatformImage {
    convenience init(thumbnail: CGImage) {
        #if os(macOS)
        self.init(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        #else
        self.init(cgImage: thumbnail)
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension Notification.Name {
    /// The app came back to the front (a window was activated, or the app returned from the background).
    static var appBecameActive: Notification.Name {
        #if os(macOS)
        NSApplication.didBecomeActiveNotification
        #else
        UIApplication.didBecomeActiveNotification
        #endif
    }
}

extension View {
    /// No toolbar background (Mac only, see MainWindow); iOS keeps its own.
    @ViewBuilder func hiddenWindowToolbarBackground() -> some View {
        #if os(macOS)
        if #available(macOS 15, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            toolbarBackground(.hidden, for: .windowToolbar)
        }
        #else
        self
        #endif
    }

    /// Checkboxes on the Mac; iOS's standard switches.
    @ViewBuilder func checkboxStyle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        self
        #endif
    }

    /// A plain text menu on the Mac (the speed menu); iOS's default menu button.
    @ViewBuilder func borderlessMenu() -> some View {
        #if os(macOS)
        menuStyle(.borderlessButton)
        #else
        self
        #endif
    }
}

extension View {
    /// A pointer tooltip that VoiceOver doesn't repeat. `help` is also read out as the hint, which,
    /// when it's the control's own name, said it twice ("Ajouter aux favoris… Ajouter aux favoris").
    func tooltip(_ text: String) -> some View { help(text).accessibilityHint(Text(verbatim: "")) }

    /// A page's margins: 28 points on the Mac and the iPad, 16 on an iPhone.
    func pagePadding(_ edges: Edge.Set = .all) -> some View { modifier(PagePadding(edges: edges)) }
}

/// A page's side margin: 28 points on the Mac and the iPad, 16 on an iPhone, none on a TV, whose safe
/// area already keeps everything clear of the screen's edges.
func sideMargin(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
    #if os(tvOS)
    0
    #else
    sizeClass == .compact ? 16 : 28
    #endif
}

/// How much bigger fixed sizes (posters, tiles, artwork) are drawn on a TV, seen from the sofa. The
/// system already makes its fonts bigger there.
#if os(tvOS)
let tvScale: CGFloat = 1.75
#else
let tvScale: CGFloat = 1
#endif

private struct PagePadding: ViewModifier {
    let edges: Edge.Set
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content.padding(edges, sideMargin(sizeClass))
    }
}

#if os(tvOS)
/// A page's title and the line under it, at the top of the page on the TV, with the page's buttons on
/// the right. The TV draws a navigation title over the page, fixed while the page scrolls under it.
struct TVPageHeader<Controls: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var controls: Controls

    var body: some View {
        HStack(alignment: .center, spacing: 30) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2.weight(.bold)).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 40)
            controls
        }
        .focusSection()
    }
}

extension TVPageHeader where Controls == EmptyView {
    init(title: String, subtitle: String) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}
#endif

/// What the Mac and the iPad have and the Apple TV doesn't: nothing happens there.
extension View {
    /// The page's title in the bar. Not on the TV, where it stays put over the page as it scrolls:
    /// the pages show their title themselves there (`TVPageHeader`, or the film's or episode's own).
    @ViewBuilder func pageTitle(_ text: String) -> some View {
        #if os(tvOS)
        self
        #else
        navigationTitle(text)
        #endif
    }

    /// The label of an orange button. Black on the TV: a focused button turns white there, and the
    /// orange label it then got hardly showed on it.
    @ViewBuilder func orangeButtonLabel() -> some View {
        #if os(tvOS)
        foregroundStyle(.black)
        #else
        self
        #endif
    }

    /// The line under a page's title.
    @ViewBuilder func pageSubtitle(_ text: String) -> some View {
        #if os(tvOS)
        self
        #else
        navigationSubtitle(text)
        #endif
    }

    /// Text that can be selected and copied.
    @ViewBuilder func selectableText() -> some View {
        #if os(tvOS)
        self
        #else
        textSelection(.enabled)
        #endif
    }

    /// The pointer coming over the view and leaving it (the TV has focus instead).
    @ViewBuilder func pointerHover(_ action: @escaping (Bool) -> Void) -> some View {
        #if os(tvOS)
        self
        #else
        onHover(perform: action)
        #endif
    }

    /// A card that opens something: clicked or tapped on the Mac and iPhone/iPad (where the pointer
    /// shows a play button over it); on the TV a button the focus can rest on, whose picture lifts.
    @ViewBuilder func cardAction(_ action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        Button(action: action) { self }.buttonStyle(.borderless)
        #else
        contentShape(Rectangle()).onTapGesture(perform: action)
        #endif
    }

    /// A row's main part that opens something: clicked or tapped elsewhere, a button the focus can rest
    /// on (the TV's own platter) on the TV.
    @ViewBuilder func rowAction(_ action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        Button(action: action) { self }
        #else
        contentShape(Rectangle()).onTapGesture(perform: action)
        #endif
    }

    /// A row the TV's focus enters from anywhere above or below it, not only from what's straight
    /// above: down from the hero's right-hand button reaches a shelf of two cards on the left.
    @ViewBuilder func tvFocusSection() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }

    /// The picture of a card, lifted and lit under the TV's focus (nothing elsewhere).
    @ViewBuilder func focusLift() -> some View {
        #if os(tvOS)
        hoverEffect(.highlight)
        #else
        self
        #endif
    }

    /// No line under a list row.
    @ViewBuilder func hiddenRowSeparator() -> some View {
        #if os(tvOS)
        self
        #else
        listRowSeparator(.hidden)
        #endif
    }
}


/// The system's AirPlay button: speakers, Apple TV, AirPods… On the Mac it lists the routes of the
/// app's own player; on iPhone and iPad it routes the app's audio.
struct AirPlayButton: View {
    let player: PlayerModel
    var size: CGFloat = 28
    /// The icon's colour when nothing is routed (orange once it plays elsewhere).
    var tint: Color = .primary

    var body: some View {
        picker
            .frame(width: size, height: size)
            .tooltip("AirPlay")
            .accessibilityLabel("AirPlay")
    }

    @ViewBuilder private var picker: some View {
        #if os(iOS)
        // The system's picker only once the app holds the audio (it takes it when asked to play):
        // before that, the picker kept handling its own route notifications in a loop, burning a
        // third of a core and more on an idle iPad. Until then, the icon dimmed like the other
        // controls of an empty player.
        if player.audioSessionActive {
            RoutePicker(player: player.routedPlayer, tint: tint)
        } else {
            Image(systemName: "airplayaudio")
                .font(.system(size: size * 0.62, weight: .regular))
                .foregroundStyle(tint)
                .opacity(0.35)
        }
        #else
        RoutePicker(player: player.routedPlayer, tint: tint)
        #endif
    }
}

#if os(macOS)
private struct RoutePicker: NSViewRepresentable {
    let player: AVPlayer
    let tint: Color

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(NSColor(tint), for: .normal)
        view.setRoutePickerButtonColor(NSColor(brandOrange), for: .active)
        view.player = player
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) { view.player = player }
}
#else
private struct RoutePicker: UIViewRepresentable {
    let player: AVPlayer
    let tint: Color

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor(tint)
        view.activeTintColor = UIColor(brandOrange)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif
