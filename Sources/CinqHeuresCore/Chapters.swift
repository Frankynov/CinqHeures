import Foundation

/// A chapter of an audio file: where it starts and what it's called.
public struct AudioChapter: Codable, Hashable, Sendable {
    public let title: String
    /// Seconds from the start of the file.
    public let start: Double

    public init(title: String, start: Double) {
        self.title = title
        self.start = start
    }
}

/// Chapters the way podcast tools write them into an MP3: ID3v2.3 or 2.4 `CHAP` frames, each with
/// its start time and a `TIT2` title (the ID3v2 Chapter Frame Addendum). ID3v2.2 has no chapters.
public enum ID3Chapters {
    /// The whole tag's length in bytes, its header included, from the file's first ten bytes; nil
    /// when the file doesn't start with an ID3v2 tag.
    public static func tagLength(header: Data) -> Int? {
        let bytes = [UInt8](header.prefix(10))
        guard bytes.count == 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33,      // "ID3"
              bytes[3] != 0xFF, bytes[4] != 0xFF, bytes[6...9].allSatisfy({ $0 < 0x80 }) else { return nil }
        let footer = bytes[3] == 4 && bytes[5] & 0x10 != 0 ? 10 : 0
        return 10 + syncsafe(bytes[6...9]) + footer
    }

    /// The chapters in a tag (the file's first `tagLength` bytes, or more), by start time.
    public static func chapters(in tag: Data) -> [AudioChapter] {
        let bytes = [UInt8](tag)
        guard let length = tagLength(header: tag) else { return [] }
        let version = bytes[3]
        guard version == 3 || version == 4 else { return [] }
        let flags = bytes[5]
        var body = Array(bytes[10..<min(bytes.count, length)])
        if version == 3, flags & 0x80 != 0 { body = removingUnsynchronisation(body) }
        var start = 0
        if flags & 0x40 != 0 {
            // An extended header: its size counts itself in 2.4, not in 2.3.
            guard body.count >= 4 else { return [] }
            start = version == 3 ? bigEndian(body[0..<4]) + 4 : syncsafe(body[0..<4])
        }
        return frames(in: body, from: start, version: version)
            .filter { $0.id == "CHAP" }
            .compactMap { chapter(in: $0.data, version: version) }
            .sorted { $0.start < $1.start }
    }

    private struct Frame {
        let id: String
        let data: [UInt8]
    }

    /// The frames from `start` until the padding (or anything that isn't a frame).
    private static func frames(in bytes: [UInt8], from start: Int, version: UInt8) -> [Frame] {
        var frames: [Frame] = []
        var position = start
        while position + 10 <= bytes.count {
            let id = bytes[position..<position + 4]
            guard id.allSatisfy({ (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) }) else { break }
            let sizeBytes = bytes[position + 4..<position + 8]
            let size = version == 4 ? syncsafe(sizeBytes) : bigEndian(sizeBytes)
            let flags = Int(bytes[position + 9])        // the format byte: how the data is stored
            let dataStart = position + 10
            guard dataStart + size <= bytes.count else { break }
            var data = Array(bytes[dataStart..<dataStart + size])
            position = dataStart + size
            if version == 3 {
                guard flags & 0xC0 == 0 else { continue }                     // compressed or encrypted
                if flags & 0x20 != 0 { data = Array(data.dropFirst()) }        // a group byte in front
            } else {
                guard flags & 0x0C == 0 else { continue }                     // compressed or encrypted
                if flags & 0x40 != 0 { data = Array(data.dropFirst()) }        // a group byte in front
                if flags & 0x01 != 0 { data = Array(data.dropFirst(4)) }       // its length in front
                if flags & 0x02 != 0 { data = removingUnsynchronisation(data) }
            }
            frames.append(Frame(id: String(decoding: id, as: UTF8.self), data: data))
        }
        return frames
    }

    /// A `CHAP` frame: an element ID ending in a zero, start and end in milliseconds, start and end
    /// in bytes, then frames of its own, `TIT2` being its title.
    private static func chapter(in data: [UInt8], version: UInt8) -> AudioChapter? {
        guard let zero = data.firstIndex(of: 0), zero + 17 <= data.count else { return nil }
        let milliseconds = bigEndian(data[zero + 1..<zero + 5])
        let inner = frames(in: Array(data[(zero + 17)...]), from: 0, version: version)
        let title = inner.first { $0.id == "TIT2" }.flatMap { text(in: $0.data) } ?? ""
        return AudioChapter(title: title, start: Double(milliseconds) / 1000)
    }

    /// A text frame's first string, in whichever of ID3's four encodings it's written.
    private static func text(in data: [UInt8]) -> String? {
        guard let encoding = data.first else { return nil }
        let body = Array(data.dropFirst())
        let string: String?
        switch encoding {
        case 0: string = String(bytes: body.prefix { $0 != 0 }, encoding: .isoLatin1)
        case 3: string = String(bytes: body.prefix { $0 != 0 }, encoding: .utf8)
        case 1, 2:
            // UTF-16 with a byte-order mark (1), or big-endian without one (2); a 16-bit zero ends it.
            var units: [UInt8] = []
            var index = 0
            while index + 1 < body.count, body[index] != 0 || body[index + 1] != 0 {
                units += [body[index], body[index + 1]]
                index += 2
            }
            string = String(bytes: units, encoding: encoding == 1 ? .utf16 : .utf16BigEndian)
        default: string = nil
        }
        return string?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func syncsafe<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> Int {
        bytes.reduce(0) { $0 << 7 | Int($1 & 0x7F) }
    }

    private static func bigEndian<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> Int {
        bytes.reduce(0) { $0 << 8 | Int($1) }
    }

    /// Unsynchronised data has a zero after every 0xFF byte that could look like an MPEG sync.
    private static func removingUnsynchronisation(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var previous: UInt8 = 0
        for byte in bytes {
            if !(previous == 0xFF && byte == 0) { result.append(byte) }
            previous = byte
        }
        return result
    }
}

/// Reads an MP3's chapters over the network without downloading the file: only its tag, at the
/// start, a few kilobytes.
public struct ChapterReader: Sendable {
    /// Enough for most tags in one request; one with large artwork takes a second.
    static let firstRead = 64 << 10
    /// A tag larger than this isn't read.
    static let largestTag = 4 << 20

    private let session: URLSession

    public init(session: URLSession = SiteClient.uncachedSession) {
        self.session = session
    }

    public func chapters(of url: URL) async throws -> [AudioChapter] {
        var data = try await firstBytes(of: url, count: Self.firstRead)
        guard let length = ID3Chapters.tagLength(header: data), length <= Self.largestTag else { return [] }
        if data.count < length { data = try await firstBytes(of: url, count: length) }
        return ID3Chapters.chapters(in: data)
    }

    /// The file's first `count` bytes (fewer if it's shorter): asked for as a range, and read only
    /// that far even from a server that sends the whole file.
    private func firstBytes(of url: URL, count: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(count - 1)", forHTTPHeaderField: "Range")
        request.setValue(SiteClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200, status != 206 {
            throw SiteError.http(status)
        }
        var data = Data()
        data.reserveCapacity(count)
        for try await byte in bytes {
            data.append(byte)
            if data.count == count { break }
        }
        return data
    }
}

/// The chapters found in the Dayez files, and when each file was last read, kept between launches.
public struct ChapterLibrary: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let chapters: [AudioChapter]
        public let checked: Date
    }

    /// By the file's address.
    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    /// Not read yet, or read a while ago: a file can get its chapters, or new times, after it was
    /// published, so a recent episode's is read again after 6 hours, an older one's after a week.
    public func needsLookup(_ episode: Episode, now: Date = Date()) -> Bool {
        guard let entry = entries[episode.audioURL.absoluteString] else { return true }
        let recent = now.timeIntervalSince(episode.date) < 60 * 86_400
        return now.timeIntervalSince(entry.checked) > (recent ? 6 * 3600 : 7 * 86_400)
    }

    public mutating func record(_ chapters: [AudioChapter], for episode: Episode, at now: Date = Date()) {
        entries[episode.audioURL.absoluteString] = Entry(chapters: chapters, checked: now)
    }

    /// A Dayez episode with each film starting where its chapter does (see `Episode.startingFilms(at:)`);
    /// unchanged while its file hasn't been read.
    public func apply(to episode: Episode) -> Episode {
        guard episode.series == .dayez, let chapters = entries[episode.audioURL.absoluteString]?.chapters else { return episode }
        return episode.startingFilms(at: chapters)
    }

    // MARK: Saving

    public static var defaultLocation: URL {
        URL.applicationSupportDirectory.appendingPathComponent("CinqHeures/chapters.json")
    }

    public static func load(from url: URL = defaultLocation) -> ChapterLibrary {
        guard let data = try? Data(contentsOf: url), let library = try? JSONDecoder().decode(ChapterLibrary.self, from: data)
        else { return ChapterLibrary() }
        return library
    }

    public func save(to url: URL = defaultLocation) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

extension Episode {
    /// The films a Dayez episode's title names, each starting where its chapter does: matched by name
    /// (case, accents and punctuation aside, or one name inside the other), or in order when no name
    /// matches and the chapters are the films one for one, an opening chapter at 0:00 aside. A film
    /// left without a chapter has no start.
    public func startingFilms(at chapters: [AudioChapter]) -> Episode {
        let films = spokenFilms
        guard !films.isEmpty, films.count == segments.count else { return self }
        let names = chapters.map { Search.fold($0.title) }
        func overlap(_ a: String, _ b: String) -> Bool { min(a.count, b.count) >= 4 && (a.contains(b) || b.contains(a)) }
        var starts: [Double?] = films.map { film in
            let name = Search.fold(film)
            let found = names.firstIndex(of: name) ?? names.firstIndex { overlap($0, name) }
            return found.map { chapters[$0].start }
        }
        if starts.allSatisfy({ $0 == nil }) {
            let opening = chapters.count == films.count + 1 && chapters[0].start < 1
            let rest = opening ? Array(chapters.dropFirst()) : chapters
            if rest.count == films.count { starts = rest.map(\.start) }
        }
        let timed = zip(segments, starts).map { $0.starting(at: $1) }
        guard timed != segments else { return self }
        return Episode(id: id, series: series, date: date, summary: summary, audioURL: audioURL, segments: timed,
                       name: name, artwork: artwork, duration: duration)
    }
}

extension Segment {
    /// The same segment, starting at `start`.
    func starting(at start: Double?) -> Segment {
        Segment(id: id, title: title, kind: kind, start: start, verdict: verdict, score: score, posterURL: posterURL,
                overview: overview, director: director, localTitle: localTitle)
    }
}
