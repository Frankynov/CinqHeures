import Foundation
import Testing
@testable import CinqHeuresCore

/// Builds ID3 tags the way chapter tools write them, for the tests to read.
private enum Tag {
    static func syncsafe(_ value: Int) -> [UInt8] {
        [UInt8(value >> 21 & 0x7F), UInt8(value >> 14 & 0x7F), UInt8(value >> 7 & 0x7F), UInt8(value & 0x7F)]
    }

    static func bigEndian(_ value: Int) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    static func frame(_ id: String, _ data: [UInt8], version: UInt8) -> [UInt8] {
        Array(id.utf8) + (version == 4 ? syncsafe(data.count) : bigEndian(data.count)) + [0, 0] + data
    }

    /// A text frame: 0 ISO-8859-1, 1 UTF-16 with a byte-order mark, 3 UTF-8.
    static func text(_ id: String, _ string: String, encoding: UInt8, version: UInt8) -> [UInt8] {
        let bytes: [UInt8] = switch encoding {
        case 0: Array(string.data(using: .isoLatin1)!) + [0]
        case 1: [0xFF, 0xFE] + Array(string.data(using: .utf16LittleEndian)!) + [0, 0]
        default: Array(string.utf8) + [0]
        }
        return frame(id, [encoding] + bytes, version: version)
    }

    static func chapter(_ id: String, at start: Double, until end: Double, _ title: String,
                        encoding: UInt8 = 0, version: UInt8 = 3) -> [UInt8] {
        let unused: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF]
        let data = Array(id.utf8) + [0] + bigEndian(Int(start * 1000)) + bigEndian(Int(end * 1000)) + unused + unused
            + text("TIT2", title, encoding: encoding, version: version)
        return frame("CHAP", data, version: version)
    }

    static func tag(version: UInt8, frames: [[UInt8]], padding: Int = 64) -> Data {
        let body = frames.flatMap { $0 } + [UInt8](repeating: 0, count: padding)
        return Data([0x49, 0x44, 0x33, version, 0, 0] + syncsafe(body.count) + body)
    }

    /// RTBF's own frames, then the four chapters a Dayez file would get.
    static func dayez(version: UInt8 = 3, encoding: UInt8 = 0, padding: Int = 64) -> Data {
        let toc = frame("CTOC", Array("toc".utf8) + [0, 0x03, 4] + Array("ch0\0ch1\0ch2\0ch3\0".utf8), version: version)
        return tag(version: version, frames: [
            text("TIT2", "Les chroniques de la Grande matinée, avec Hugues Dayez", encoding: encoding, version: version),
            text("TPE1", "Hugues DAYEZ", encoding: encoding, version: version),
            toc,
            // Written out of order on purpose: they're read by start time.
            chapter("ch2", at: 200.25, until: 381, "Wicker", encoding: encoding, version: version),
            chapter("ch0", at: 0, until: 41.5, "Introduction", encoding: encoding, version: version),
            chapter("ch1", at: 41.5, until: 200.25, "Coward", encoding: encoding, version: version),
            chapter("ch3", at: 381, until: 552, "Karma", encoding: encoding, version: version),
        ], padding: padding)
    }
}

private func dayezEpisode(_ name: String, url: String = "https://example.org/dayez.mp3",
                          date: Date = Date(timeIntervalSince1970: 1_792_000_000)) -> Episode {
    let films = name.components(separatedBy: " · ")
    let segments = films.enumerated().map {
        Segment(id: $0.offset, title: $0.element, kind: .movie, start: nil, verdict: nil, posterURL: nil)
    }
    return Episode(id: 1, series: .dayez, date: date, summary: "", audioURL: URL(string: url)!,
                   segments: segments, name: name)
}

@Suite struct ChapterTests {
    @Test func readsTheChaptersOfAnID3v23Tag() {
        let chapters = ID3Chapters.chapters(in: Tag.dayez())
        #expect(chapters == [AudioChapter(title: "Introduction", start: 0), AudioChapter(title: "Coward", start: 41.5),
                             AudioChapter(title: "Wicker", start: 200.25), AudioChapter(title: "Karma", start: 381)])
    }

    @Test func readsID3v24AndEveryTextEncoding() {
        for encoding: UInt8 in [0, 1, 3] {
            #expect(ID3Chapters.chapters(in: Tag.dayez(version: 4, encoding: encoding)).map(\.title)
                    == ["Introduction", "Coward", "Wicker", "Karma"])
        }
        // Accents in each encoding, and frames over 127 bytes, whose 2.4 size is syncsafe.
        let long = String(repeating: "a", count: 300)
        for version: UInt8 in [3, 4] {
            for encoding: UInt8 in [0, 1, 3] {
                let tag = Tag.tag(version: version, frames: [
                    Tag.text("COMM", long, encoding: encoding, version: version),
                    Tag.chapter("c", at: 12, until: 20, "Les Misérables", encoding: encoding, version: version),
                ])
                #expect(ID3Chapters.chapters(in: tag) == [AudioChapter(title: "Les Misérables", start: 12)])
            }
        }
    }

    @Test func tagLengthComesFromTheHeader() {
        // RTBF's tag on a Dayez file: 308 bytes after the header.
        #expect(ID3Chapters.tagLength(header: Data([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0x02, 0x34])) == 318)
        #expect(ID3Chapters.tagLength(header: Data("RIFF0000WAVE".utf8)) == nil)
        #expect(ID3Chapters.chapters(in: Data([0xFF, 0xFB, 0x90, 0x64])) == [])
    }

    @Test func aTagWithoutChaptersHasNone() {
        let tag = Tag.tag(version: 3, frames: [Tag.text("TIT2", "Coward - Wicker - Karma", encoding: 0, version: 3)])
        #expect(ID3Chapters.chapters(in: tag) == [])
        // ID3v2.2 can't hold chapters.
        #expect(ID3Chapters.chapters(in: Data([0x49, 0x44, 0x33, 2, 0, 0, 0, 0, 0, 10] + [UInt8](repeating: 0, count: 10))) == [])
    }

    @Test func readsOnlyTheTagOfAFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = Data(repeating: 0xAA, count: 300_000)
        // A small tag, read in one go; and one with 100 KB of padding (as big artwork would make it),
        // which takes a second read. A file "server" sends everything: only the tag is kept.
        for padding in [64, 100_000] {
            let file = folder.appendingPathComponent("dayez-\(padding).mp3")
            try (Tag.dayez(padding: padding) + audio).write(to: file)
            #expect(try await ChapterReader().chapters(of: file).map(\.start) == [0, 41.5, 200.25, 381])
        }
        let plain = folder.appendingPathComponent("plain.mp3")
        try audio.write(to: plain)
        #expect(try await ChapterReader().chapters(of: plain) == [])
    }

    @Test func filmsStartWhereTheirChaptersDo() {
        let episode = dayezEpisode("Coward · Wicker · Karma")
        let timed = episode.startingFilms(at: ID3Chapters.chapters(in: Tag.dayez()))
        #expect(timed.segments.map(\.start) == [41.5, 200.25, 381])
        #expect(timed.segments.map(\.title) == episode.segments.map(\.title))
        #expect(timed.segments.map(\.id) == episode.segments.map(\.id))
    }

    @Test func namesMatchWhateverTheirCaseAccentsAndPunctuation() {
        let episode = dayezEpisode("Les Misérables · Le Corset · Franz")
        let chapters = [AudioChapter(title: "LES MISERABLES", start: 30), AudioChapter(title: "Corset", start: 190),
                        AudioChapter(title: "Franz !", start: 350)]
        #expect(episode.startingFilms(at: chapters).segments.map(\.start) == [30, 190, 350])
    }

    @Test func chaptersNamedOtherwiseGoInOrder() {
        let episode = dayezEpisode("Coward · Wicker · Karma")
        let numbered = [AudioChapter(title: "Début", start: 0), AudioChapter(title: "Film 1", start: 40),
                        AudioChapter(title: "Film 2", start: 200), AudioChapter(title: "Film 3", start: 380)]
        #expect(episode.startingFilms(at: numbered).segments.map(\.start) == [40, 200, 380])
        #expect(episode.startingFilms(at: Array(numbered.dropFirst())).segments.map(\.start) == [40, 200, 380])
        // Two chapters for three films, none named after one: nothing to go by.
        let two = [AudioChapter(title: "A", start: 0), AudioChapter(title: "B", start: 100)]
        #expect(episode.startingFilms(at: two) == episode)
    }

    @Test func theLibraryTimesDayezFilmsAndReadsFilesAgain() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = dayezEpisode("Coward · Wicker · Karma", date: now.addingTimeInterval(-7 * 86_400))
        let old = dayezEpisode("Moulin · La Gradiva", url: "https://example.org/old.mp3", date: now.addingTimeInterval(-400 * 86_400))
        var library = ChapterLibrary()
        #expect(library.needsLookup(recent, now: now) && library.needsLookup(old, now: now))
        #expect(library.apply(to: recent) == recent)                  // not read yet: unchanged
        #expect(library.lastRead(recent) == nil)

        library.record([], for: recent, at: now.addingTimeInterval(-60))
        // The file replaced with one that has chapters: they're news; the same ones read again aren't.
        let added = library.record(ID3Chapters.chapters(in: Tag.dayez()), for: recent, at: now)
        let readAgain = library.record(ID3Chapters.chapters(in: Tag.dayez()), for: recent, at: now)
        #expect(added && !readAgain)
        #expect(library.lastRead(recent) == now)
        library.record([], for: old, at: now)
        #expect(library.apply(to: recent).segments.map(\.start) == [41.5, 200.25, 381])
        #expect(library.apply(to: old) == old)

        // Read again after 6 hours when recent (chapters often come after the file), after a week when old.
        #expect(!library.needsLookup(recent, now: now.addingTimeInterval(5 * 3600)))
        #expect(library.needsLookup(recent, now: now.addingTimeInterval(7 * 3600)))
        #expect(!library.needsLookup(old, now: now.addingTimeInterval(6 * 86_400)))
        #expect(library.needsLookup(old, now: now.addingTimeInterval(8 * 86_400)))

        // Chapters taken out of the file: the films lose their starts.
        let timed = library.apply(to: recent)
        library.record([], for: recent, at: now)
        #expect(library.apply(to: timed).segments.allSatisfy { $0.start == nil })

        // Another show's episode is left alone.
        let other = Episode(id: 2, series: .quelquePart, date: now, summary: "", audioURL: recent.audioURL, segments: [], name: "Episode #44")
        #expect(library.apply(to: other) == other)
    }

    @Test func filmDetailsKeepTheChapterStarts() {
        let episode = dayezEpisode("Coward · Wicker · Karma")
        var chapters = ChapterLibrary()
        chapters.record(ID3Chapters.chapters(in: Tag.dayez()), for: episode)
        var films = FilmLibrary()
        films.record(FilmInfo(tmdbID: 1, title: "Coward", originalTitle: "Coward", year: 2026, overview: "Guerre.",
                              posterPath: "/coward.jpg", director: "Lukas Dhont"), title: "Coward", date: episode.date)
        let detailed = films.enrich(chapters.apply(to: episode))
        #expect(detailed.segments.map(\.start) == [41.5, 200.25, 381])
        #expect(detailed.segments[0].title == "Coward (2026)" && detailed.segments[0].director == "Lukas Dhont")
    }

    @Test func savesAndLoadsBack() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("chapters-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let episode = dayezEpisode("Coward · Wicker · Karma")
        var library = ChapterLibrary()
        library.record([AudioChapter(title: "Coward", start: 41.5)], for: episode)
        try library.save(to: file)
        #expect(ChapterLibrary.load(from: file).entries[episode.audioURL.absoluteString]?.chapters == [AudioChapter(title: "Coward", start: 41.5)])
    }
}
