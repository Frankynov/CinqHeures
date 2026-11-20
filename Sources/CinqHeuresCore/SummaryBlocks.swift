import Foundation

/// An episode description cut into what it's made of, so a page can show headings, paragraphs and lists
/// rather than one block of text. The descriptions are plain text with line breaks, written three ways:
///
/// - a title line, then its paragraph, for each film (Dayez: "Le drame du Heysel revisité dans
///   Heysel 85" / "Le film belge Heysel 85 revient sur…");
/// - "- Critique du film Marsupilami :" headings over "- " points (some Dayez episodes);
/// - questions as paragraphs, then "Les découvertes musicales :" and a song a line (the podcast).
public enum SummaryBlock: Equatable, Sendable {
    case heading(String)
    case paragraph(String)
    case item(String)

    public static func blocks(_ text: String) -> [SummaryBlock] {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return lines.map(SummaryBlock.paragraph) }
        if let paired = titlesAndParagraphs(lines) { return paired }

        var blocks: [SummaryBlock] = []
        // Under a "…:" heading or among "- " points, short unmarked lines are items too (the songs).
        var inList = false
        for line in lines {
            let (marked, text) = unmarked(line)
            if text.hasSuffix(":"), text.count < 70 {
                blocks.append(.heading(text.dropLast().trimmingCharacters(in: .whitespaces)))
                inList = true
            } else if marked {
                blocks.append(.item(text))
                inList = true
            } else if inList, text.count < 80, !text.hasSuffix("?") {
                blocks.append(.item(text))
            } else {
                blocks.append(.paragraph(text))
                inList = false
            }
        }
        return blocks
    }

    /// Title, paragraph, title, paragraph…: an even number of lines where every other one is a short
    /// title (no closing punctuation, shorter than what follows it), and no "- " points.
    private static func titlesAndParagraphs(_ lines: [String]) -> [SummaryBlock]? {
        guard lines.count.isMultiple(of: 2), !lines.contains(where: { unmarked($0).marked }) else { return nil }
        var blocks: [SummaryBlock] = []
        for index in stride(from: 0, to: lines.count, by: 2) {
            let (title, paragraph) = (lines[index], lines[index + 1])
            guard title.count < 110, title.count < paragraph.count,
                  !(title.hasSuffix("?") || title.hasSuffix(".") || title.hasSuffix(":")) else { return nil }
            blocks += [.heading(title), .paragraph(paragraph)]
        }
        return blocks
    }

    /// The line without its "- ", "– " or "• ", and whether it had one.
    private static func unmarked(_ line: String) -> (marked: Bool, text: String) {
        guard let first = line.first, "-–•".contains(first) else { return (false, line) }
        return (true, line.dropFirst().trimmingCharacters(in: .whitespaces))
    }
}
