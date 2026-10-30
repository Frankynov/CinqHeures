import CinqHeuresCore

/// Where a tap leads. The window is one navigation stack: pages push onto it and the back button undoes them.
enum Route: Hashable {
    /// A film, series or person with every passage about it.
    case work(SegmentKind, String)
    /// An episode and its programme, optionally with one segment highlighted.
    case episode(Int, highlight: Int?)
    /// A shelf's "Tout voir".
    case listing(Listing)
    /// A show's episodes.
    case show(Series)
}
