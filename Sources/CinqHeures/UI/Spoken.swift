import CinqHeuresCore
import Foundation

/// What VoiceOver says for what the screen shows in symbols and short forms: "3 étoiles sur 4" for
/// "★★★☆", "4 minutes et 12 secondes" for "4:12", "mercredi 29 avril 2015" for "29/04/2015".
enum Spoken {
    static func stars(_ stars: Int) -> String { "\(stars) étoile\(stars > 1 ? "s" : "") sur 4" }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        return durationFormatter.string(from: seconds.rounded(.down)) ?? clock(seconds)
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "fr_BE")
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    /// A title with stars in it, "Coups de cœur ★★★★", as "Coups de cœur, 4 étoiles sur 4".
    static func text(_ text: String) -> String {
        guard let run = text.range(of: "[★☆]+", options: .regularExpression) else { return text }
        let filled = text[run].filter { $0 == "★" }.count
        return join([String(text[..<run.lowerBound]), stars(filled), String(text[run.upperBound...])])
    }

    static func date(_ date: Date) -> String { EpisodeDates.long.string(from: date) }

    /// "1,5 fois".
    static func speed(_ speed: Float) -> String {
        (speed == speed.rounded() ? String(format: "%.0f", speed) : String(format: "%g", speed))
            .replacingOccurrences(of: ".", with: ",") + " fois"
    }

    /// The parts that have something in them, read with a short pause between each. The screen's
    /// "·" separators become pauses too: VoiceOver says "point médian".
    static func join(_ parts: [String?]) -> String {
        parts.compactMap { $0?.replacingOccurrences(of: " · ", with: ", ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// An episode's name, or its show and date in words ("Podcast, vendredi 27 juin 2025" rather
    /// than "Podcast du 27/06/2025").
    static func title(_ episode: Episode) -> String {
        episode.name ?? "\(episode.series.title), \(date(episode.date))"
    }

    /// A film card or row: its title, score, kind or year, and passages or the hosts' verdict.
    static func film(_ segment: Segment, passages: Int = 1) -> String {
        var parts: [String?] = [segment.displayTitle, segment.stars.map(stars)]
        switch segment.kind {
        case .tvShow: parts.append("Série")
        case .person: parts.append("Personnalité")
        default: parts.append(segment.year.map(String.init))
        }
        if passages > 1 { parts.append("\(passages) passages") }
        else if segment.kind == .movie, let verdict = segment.spokenVerdict, verdict.contains(where: \.isLetter) { parts.append(verdict) }
        return join(parts)
    }

    /// An episode row or card: its name or date, its show, and what's in it.
    static func episode(_ episode: Episode, showSeries: Bool = true) -> String {
        var parts: [String?] = [episode.name ?? date(episode.date)]
        if showSeries { parts.append(episode.series.title) }
        if !episode.subjects.isEmpty, episode.name == nil {
            parts.append(episode.subjects.map(\.displayTitle).joined(separator: ", "))
        } else {
            if episode.name != nil { parts.append(date(episode.date)) }
            parts.append(episode.duration.map(duration))
        }
        return join(parts)
    }
}
