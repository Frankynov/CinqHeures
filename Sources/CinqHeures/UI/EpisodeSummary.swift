import CinqHeuresCore
import SwiftUI

/// An episode's description as headings, paragraphs and lists (`SummaryBlock`), rather than one grey
/// block: the films of a Dayez episode each get their title, the podcast's songs a list.
struct SummaryText: View {
    let text: String
    var font: Font = .callout

    var body: some View {
        let blocks = SummaryBlock.blocks(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let title):
                    Text(title)
                        .font(font.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.top, index > 0 ? 8 : 0)
                        .accessibilityAddTraits(.isHeader)
                case .paragraph(let paragraph):
                    Text(paragraph).font(font).foregroundStyle(.secondary)
                case .item(let item):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").accessibilityHidden(true)
                        Text(item)
                    }
                    .font(font)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .selectableText()
    }
}

/// The description on an episode's page. A long one shows its beginning and "Lire la suite", so the
/// programme stays in sight: three Dayez critiques ran over a whole iPad screen.
struct EpisodeSummary: View {
    let text: String
    @ScaledMetric(relativeTo: .callout) private var collapsedHeight: CGFloat = 170
    @ViewState private var expanded = false
    @ViewState private var fullHeight: CGFloat = 0

    var body: some View {
        // Cutting off two lines isn't worth a button.
        let long = fullHeight > collapsedHeight + 50
        let cut = long && !expanded
        VStack(alignment: .leading, spacing: 4) {
            SummaryText(text: text)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                .frame(maxHeight: cut ? collapsedHeight : nil, alignment: .top)
                .clipped()
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: cut ? 0.7 : 1),
                                           .init(color: cut ? .clear : .black, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
            if long {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Label(expanded ? "Réduire" : "Lire la suite", systemImage: expanded ? "chevron.up" : "chevron.down")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .font(.callout.weight(.semibold))
                .tint(brandOrange)
                .foregroundStyle(brandOrange)
            }
        }
    }
}
