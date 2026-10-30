import Foundation

/// The JSON as 5heures.be sends it, read into the app's own models. Only what the app uses is
/// decoded, and every field that has ever been missing is optional.
struct WirePage: Decodable {
    struct Pagination: Decodable {
        let total_pages: Int
    }
    /// Lossy: one malformed episode is skipped instead of failing the whole page (and the refresh).
    @Lossy var podcasts: [WireEpisode]
    let pagination: Pagination
}

struct WireEpisode: Decodable {
    struct Part: Decodable {
        let id: Int
        let display_name: String
        let kind: String
        let start_second: Double?
        let score_text: String?
        let score: LooseString?
        let poster_url: String?
    }
    let id: Int
    let kind: String
    let display_name: String
    let available_at: String?
    let description: String?
    let audio_file_url: String?
    @Lossy var parts: [Part]

    /// `nil` for an episode the app can't use: unknown show, no audio file, no readable date.
    var episode: Episode? {
        guard let series = Series(rawValue: kind),
              let audio = audio_file_url.flatMap(URL.init(string:)),
              let date = Self.recordingDate(displayName: display_name, availableAt: available_at)
        else { return nil }
        let segments = parts.compactMap { part -> Segment? in
            guard let kind = SegmentKind(rawValue: part.kind) else { return nil }
            let verdict = part.score_text.flatMap { $0.isEmpty ? nil : $0 }
            return Segment(id: part.id, title: part.display_name, kind: kind, start: part.start_second,
                           verdict: verdict, score: Segment.parseScore(part.score?.value),
                           posterURL: part.poster_url.flatMap(URL.init(string:)))
        }
        return Episode(id: id, series: series, date: date, summary: description ?? "", audioURL: audio,
                       segments: segments)
    }

    /// "Podcast du 27/06/2025" → that day. Falls back to the API's date, which is later than the
    /// recording by about a month but is the only date left.
    static func recordingDate(displayName: String, availableAt: String?) -> Date? {
        if let range = displayName.range(of: #"\d{2}/\d{2}/\d{4}"#, options: .regularExpression),
           let date = EpisodeDates.short.date(from: String(displayName[range])) {
            return date
        }
        guard let availableAt else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = EpisodeDates.calendar
        formatter.timeZone = EpisodeDates.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: availableAt)
    }
}

struct WireConfig: Decodable {
    struct Config: Decodable {
        let years_for_kinds: [String: [Int]]
    }
    let config: Config
}

/// An array decoded element by element, keeping the elements that decode and dropping the rest.
@propertyWrapper
struct Lossy<Element: Decodable>: Decodable {
    var wrappedValue: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try? container.decode(Skipped.self)      // step over the bad one
            }
        }
        wrappedValue = elements
    }

    /// Accepts any value, so the container always moves past the bad element (an object, a string, null…).
    private struct Skipped: Decodable {
        init(from decoder: Decoder) {}
    }
}

/// A field the API sends as a string, a number or null depending on the entry.
struct LooseString: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { value = text }
        else if let number = try? container.decode(Double.self) { value = String(number) }
        else { value = nil }
    }
}
