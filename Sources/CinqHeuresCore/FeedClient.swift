import Foundation

/// Reads the shows that come as plain podcast feeds:
/// - Rudy Léonet's weekly "Il est toujours 5 heures quelque part", from Ausha;
/// - Hugues Dayez's weekly reviews, from Franky's own Audiobookshelf (RTBF's Auvio needs a login).
/// Their episodes have no per-film timecodes. Dayez's titles name the three films, which become
/// segments without a start, so they're searchable and listed, and play from the episode's start.
public struct FeedClient: Sendable {
    public static let quelquePartFeed = URL(string: "https://feed.ausha.co/j0n2zsQR3XOG")!
    public static let dayezFeed = URL(string: "https://audio.frankynov.ovh/audiobookshelf/feed/9a2355b5-d416-42fa-929c-45bea81d29c5")!

    private let session: URLSession
    private let feed: URL
    public let series: Series

    public init(feed: URL = Self.quelquePartFeed, series: Series = .quelquePart,
                session: URLSession = SiteClient.uncachedSession) {
        self.feed = feed
        self.series = series
        self.session = session
    }

    public static let all = [FeedClient(feed: quelquePartFeed, series: .quelquePart),
                             FeedClient(feed: dayezFeed, series: .dayez)]

    public func episodes() async throws -> [Episode] {
        var request = URLRequest(url: feed)
        request.setValue(SiteClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SiteError.http(status) }
        return try Self.episodes(from: data, series: series)
    }

    /// The feed's episodes, newest first. Parsing is separate from fetching so it can be tested.
    public static func episodes(from data: Data, series: Series = .quelquePart) throws -> [Episode] {
        let parser = FeedParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { throw SiteError.unreadable }
        let items = parser.items.filter { $0.audio != nil && $0.date != nil }

        // Every episode carries the same generic tags (Concerts, pop culture…): the ones that are
        // only on some episodes name the artists discussed.
        var frequency: [String: Int] = [:]
        for item in items { for keyword in Set(item.keywords) { frequency[keyword.lowercased(), default: 0] += 1 } }
        let generic = Set(frequency.filter { Double($0.value) >= Double(max(items.count, 1)) * 0.4 }.keys)

        return items.map { item in
            // "Il est toujours 5 heures quelque part" keeps the ids it always had (its guid alone); others are prefixed by their show.
            let key = (series == .quelquePart ? "" : series.rawValue + "|") + (item.guid ?? item.title)
            let artwork = item.artwork ?? parser.channelArtwork
            if series == .dayez {
                let films = filmTitles(in: item.title)
                let segments = films.enumerated().map { index, film in
                    Segment(id: stableID(key + "#\(index)"), title: film, kind: .movie, start: nil, verdict: nil, posterURL: nil)
                }
                return Episode(id: stableID(key), series: series,
                               date: dateInTitle(item.title) ?? item.date!,
                               summary: readableDescription(item.description, title: item.title),
                               audioURL: item.audio!, segments: segments,
                               name: films.isEmpty ? item.title : films.joined(separator: " · "),
                               artwork: artwork, duration: item.duration)
            }
            let artists = item.keywords.filter { !generic.contains($0.lowercased()) }
            return Episode(id: stableID(key), series: series, date: item.date!,
                           summary: artists.isEmpty ? "" : "Au menu : " + artists.joined(separator: ", "),
                           audioURL: item.audio!, segments: [], name: item.title,
                           artwork: artwork, duration: item.duration)
        }
        .sorted { $0.date > $1.date }
    }

    /// The films named in a Dayez episode title, whichever way it was written:
    /// `Coward - Wicker - Karma`, `"Les Misérables", "Le Corset", "Franz"`, `Digger, Notre Salut et Verity`,
    /// `Cinéma, avec Hugues Dayez - "Un simple accident"-"Rembrandt" - 01/10/2025`.
    static func filmTitles(in raw: String) -> [String] {
        var title = raw
        title = title.replacingOccurrences(of: #"\s*-\s*\d{2}/\d{2}/\d{4}\s*$"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"^\s*Les chroniques de la Grande matin[ée]e,\s*avec Hugues Dayez\s*-\s*"#,
                                           with: "", options: [.regularExpression, .caseInsensitive])
        let rtbfStyle = title.range(of: #"^\s*Cin[ée]ma\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        title = title.replacingOccurrences(of: #"^\s*Cin[ée]ma\s*(,\s*avec Hugues Dayez)?\s*[:\-–]\s*"#, with: "",
                                           options: [.regularExpression, .caseInsensitive])

        func split(_ pattern: String) -> [String] {
            title.replacingOccurrences(of: pattern, with: "\u{1}", options: .regularExpression).components(separatedBy: "\u{1}")
        }
        // Quoted titles first ("…", “…”, «…», and the odd '…" mix); then clear separators; then, in
        // RTBF's "Cinéma : A-B-C" style, bare hyphens; commas and "et" last, as they also occur inside titles.
        let quoted = matches(of: #"(?:^|[\s,;:\-–(])["“«']\s*([^"”»]+?)\s*["”»]"#, in: title)
        let strong = split(#"\s+[-–—/]\s+|\s*;\s*"#)
        let hyphens = split(#"\s*-\s*"#)
        let pieces = quoted.count >= 2 ? quoted
            : strong.count >= 2 ? strong
            : rtbfStyle && hyphens.count >= 3 ? hyphens
            : split(#"\s*,\s*|\s+et\s+"#)

        return pieces
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"«»“”',.").union(.whitespacesAndNewlines)) }
            // Descriptors after the title: "The end avec Tilda Swinton", "Mary Anning, film d'animation".
            .map { $0.replacingOccurrences(of: #"(,\s*film d['’]animation|\s+avec\s+.+)$"#, with: "",
                                            options: [.regularExpression, .caseInsensitive]) }
            // A one-film title may end with its director, "The Death of Robin Hood de Michael Sarnoski".
            // Not in a list: "La voix de Hind Rajab" is a whole title.
            .map { pieces.count == 1 ? $0.replacingOccurrences(of: #"\s+de\s+\p{Lu}[\p{L}'’-]+(\s+\p{Lu}[\p{L}'’-]+)+$"#,
                                                                with: "", options: .regularExpression) : $0 }
            // Interviews and asides aren't films.
            .filter { piece in
                !piece.isEmpty && piece.count <= 80 && !piece.hasSuffix("?")
                    && piece.range(of: "interview", options: .caseInsensitive) == nil
            }
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            (1..<match.numberOfRanges).lazy.compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }.first
        }
    }

    /// "… - 01/10/2025" at the end of a title: some episodes have a wrong publication date but a right title.
    static func dateInTitle(_ title: String) -> Date? {
        guard let range = title.range(of: #"\d{2}/\d{2}/\d{4}\s*$"#, options: .regularExpression) else { return nil }
        return EpisodeDates.short.date(from: title[range].trimmingCharacters(in: .whitespaces))
    }

    /// The description as plain text, or nothing when it's only a tag ("cinema-sorties") or the title again.
    static func readableDescription(_ html: String, title: String) -> String {
        var text = html.replacingOccurrences(of: #"<br\s*/?>|</p>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"#+\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n\s*\n+"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "cinema-sorties" || Search.fold(text) == Search.fold(title) { return "" }
        return String(text.prefix(3000))
    }

    /// A negative number derived from the episode's guid: the same on every launch, and never
    /// clashing with the (positive) ids 5heures.be gives its own episodes.
    static func stableID(_ guid: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in guid.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return -Int(hash % 2_000_000_000) - 1
    }

    /// "1:23:07", "04:22" or plain seconds.
    static func parseDuration(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }
}

private final class FeedParser: NSObject, XMLParserDelegate {
    struct Item {
        var title = ""
        var guid: String?
        var date: Date?
        var audio: URL?
        var artwork: URL?
        var duration: Double?
        var keywords: [String] = []
        var description = ""
    }

    var items: [Item] = []
    var channelArtwork: URL?
    private var current: Item?
    private var text = ""

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        text = ""
        switch name {
        case "item": current = Item()
        case "enclosure": current?.audio = attributes["url"].flatMap(URL.init(string:))
        case "itunes:image":
            // Ausha serves 1400 px covers; the 400 px version is plenty for a list.
            let url = attributes["href"].flatMap { URL(string: $0.replacingOccurrences(of: "_1400x1400", with: "_400x400")) }
            if current != nil { current?.artwork = url } else if channelArtwork == nil { channelArtwork = url }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard current != nil else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title": current?.title = value
        case "guid": current?.guid = value
        case "pubDate": current?.date = Self.dateFormatter.date(from: value)
        case "description": current?.description = value
        case "itunes:duration": current?.duration = FeedClient.parseDuration(value)
        case "itunes:keywords":
            current?.keywords = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case "item":
            if let item = current { items.append(item) }
            current = nil
        default: break
        }
    }
}
