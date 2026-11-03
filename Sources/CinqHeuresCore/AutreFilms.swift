import Foundation

/// A film an "Autre" episode's description names: "La Main au collet (Alfred Hitchcock)".
public struct NamedFilm: Hashable, Sendable {
    public let title: String
    /// From the brackets; "Luc et Jean-Pierre Dardenne" gives both.
    public let directors: [String]
    /// The ways the title can be read, best first: a first title can carry what came before it
    /// ("Simenon au cinéma, Mon père ce héros"), so the part after its last comma is tried too.
    public let alternatives: [String]

    public init(title: String, directors: [String], alternatives: [String] = []) {
        self.title = title
        self.directors = directors
        self.alternatives = alternatives
    }
}

/// The "Autre" episodes (themed specials, summer shows) have no timecodes and no segments on
/// 5heures.be, only a description: "Thème : Monaco Cinéma : La Main au collet (Alfred Hitchcock), Le
/// roman d'un tricheur (Sacha Guitry) et La fille de Monaco (Anne Fontaine) Musique : …". Its films are
/// read from there. Songs are left out.
public enum AutreProgramme {
    /// Where a film list starts.
    private static let filmLabel = #"(?i)\b(cinéma|cinema|films?)\s*:"#
    /// Where it stops at the latest: the next section.
    private static let nextLabel = #"(?i)\b(musiques?|th[èe]me|thématique|bd|livres?|littérature|séries?(\s+télé)?|présentation|cinéma|cinema|films?)\s*:"#

    public static func films(in description: String) -> [NamedFilm] {
        let text = cleaned(description)
        var films: [NamedFilm] = []
        var searchFrom = text.startIndex
        while let label = text.range(of: filmLabel, options: .regularExpression, range: searchFrom..<text.endIndex) {
            let rest = text[label.upperBound...]
            let end = rest.range(of: nextLabel, options: .regularExpression)?.lowerBound ?? text.endIndex
            films += list(String(text[label.upperBound..<end]))
            searchFrom = end
        }
        // The same film twice in one description is one film.
        var seen = Set<String>()
        return films.filter { seen.insert(Search.fold($0.title)).inserted }
    }

    /// "A (X), B (Y) et C (Z)": items until the one after "et", which ends a French list (songs
    /// sometimes follow without a label of their own).
    static func list(_ section: String) -> [NamedFilm] {
        var films: [NamedFilm] = []
        var rest = Substring(section)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            var raw = rest[..<open].trimmingCharacters(in: .whitespaces)
            let inside = rest[rest.index(after: open)..<close]
            rest = rest[rest.index(after: close)...]
            var last = false
            if films.isEmpty {
                // The first title as it stands: the part after a comma is tried as well, below.
            } else if raw.hasPrefix(",") || raw.hasPrefix(";") {
                raw = raw.dropFirst().trimmingCharacters(in: .whitespaces)
            } else if raw.hasPrefix("et ") {
                raw = String(raw.dropFirst(3)); last = true
            } else if let and = raw.range(of: " et ", options: .backwards) {
                // A remark between two films: "Le Triporteur (…) d'après le roman de René Fallet et René La Canne (…)".
                raw = String(raw[and.upperBound...]); last = true
            } else if let comma = raw.range(of: ", ", options: .backwards) {
                raw = String(raw[comma.upperBound...])
            } else {
                break
            }
            let title = raw.trimmingCharacters(in: CharacterSet(charactersIn: " «»“”\"'’").union(.whitespaces))
            // A title can carry what came before it ("Simenon au cinéma, Mon père ce héros"): the part after
            // its last comma is tried too, after the whole ("Cousin, cousine").
            let alternatives = title.range(of: ", ", options: .backwards).map { [String(title[$0.upperBound...])] } ?? []
            let directors = inside
                .replacingOccurrences(of: " & ", with: ", ").replacingOccurrences(of: " et ", with: ", ")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !title.isEmpty, title.count <= 90, !directors.isEmpty {
                films.append(NamedFilm(title: title, directors: directors, alternatives: alternatives.filter { $0 != title }))
            }
            if last { break }
        }
        return films
    }

    /// The site's descriptions come with HTML entities, sometimes encoded twice ("&amp;amp;"), and line breaks.
    static func cleaned(_ text: String) -> String {
        var text = text
        for _ in 0..<2 { text = text.replacingOccurrences(of: "&amp;", with: "&") }
        for (entity, character) in [("&#39;", "'"), ("&quot;", "\""), ("&nbsp;", " "), ("&rsquo;", "’")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

extension Episode {
    /// An "Autre" episode with the films its description names as its programme: no start (these
    /// episodes have no timecodes), each with TMDB's poster, synopsis and archive title once found,
    /// so it links up with the other passages about the same film. Other episodes are unchanged.
    public func withNamedFilms(from library: FilmLibrary) -> Episode {
        withNamedFilms(AutreProgramme.films(in: summary), from: library)
    }

    /// The same, with the films already read from the description (reading all of them takes a while).
    public func withNamedFilms(_ named: [NamedFilm], from library: FilmLibrary) -> Episode {
        guard series == .autre, segments.allSatisfy({ $0.id < 0 }) else { return self }
        let programme = named.enumerated().compactMap { index, film -> Segment? in
            // Below zero, out of the way of the site's own ids; far from the feeds' (see FeedClient.stableID).
            let segmentID = -(3_000_000_000 + id * 100 + index)
            guard let info = library.info(title: film.title, date: date) else {
                // Not found on TMDB: most often not a film at all (a book's author in the brackets, a remark).
                if library.knows(title: film.title, date: date) { return nil }
                return Segment(id: segmentID, title: film.title, kind: .movie, start: nil, verdict: nil, posterURL: nil,
                               director: film.directors.joined(separator: " et "))
            }
            return Segment(id: segmentID, title: info.archiveTitle, kind: .movie, start: nil, verdict: nil, posterURL: info.posterURL,
                           overview: info.overview.isEmpty ? nil : info.overview, director: info.director,
                           localTitle: info.title == info.originalTitle ? nil : info.title)
        }
        guard programme != segments else { return self }
        return Episode(id: id, series: series, date: date, summary: summary, audioURL: audioURL, segments: programme,
                       name: name, artwork: artwork, duration: duration)
    }
}

extension TMDBClient {
    /// The film an "Autre" description names: one of that title made by the director in brackets
    /// (a misspelt surname still counts). These are classics as often as new films, so no date limit.
    public func film(named film: NamedFilm) async throws -> FilmInfo? {
        for language in ["fr-FR", "en-US"] {
            for title in [film.title] + film.alternatives {
                let page: SearchPage = try await get("search/movie", ["query": title, "language": language, "include_adult": "false"])
                let candidates = page.results
                    .map { ($0, Self.similarity(of: title, to: [$0.title, $0.original_title])) }
                    .filter { $0.1 >= 6 }
                    .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : ($0.0.popularity ?? 0) > ($1.0.popularity ?? 0) }
                    .prefix(4)
                for (candidate, _) in candidates {
                    let details: Details = try await get("movie/\(candidate.id)", ["language": "fr-FR", "append_to_response": "credits"])
                    let directors = details.credits?.crew.filter { $0.job == "Director" }.map(\.name) ?? []
                    if Self.sameDirector(film.directors, directors) { return Self.info(details) }
                }
            }
        }
        return nil
    }

    /// Whether any surname in brackets is a TMDB director's, give or take a typo or two.
    static func sameDirector(_ named: [String], _ found: [String]) -> Bool {
        let theirs = found.flatMap { Search.fold($0).split(separator: " ").map(String.init) }.filter { $0.count >= 3 }
        return named.contains { name in
            guard let surname = Search.fold(name).split(separator: " ").last.map(String.init), surname.count >= 3 else { return false }
            return theirs.contains { $0 == surname || (surname.count >= 5 && editDistance($0, surname) <= 2) }
        }
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }
}
