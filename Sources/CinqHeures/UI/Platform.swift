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
        toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
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
    /// A page's margins: 28 points on the Mac and the iPad, 16 on an iPhone.
    func pagePadding(_ edges: Edge.Set = .all) -> some View { modifier(PagePadding(edges: edges)) }
}

private struct PagePadding: ViewModifier {
    let edges: Edge.Set
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content.padding(edges, sizeClass == .compact ? 16 : 28)
    }
}

