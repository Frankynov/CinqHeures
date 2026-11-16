using System.Text;
using CinqHeures.Core;

namespace CinqHeures.Core.Tests;

/// <summary>Builds ID3 tags the way chapter tools write them, for the tests to read.</summary>
internal static class Tag
{
    public static byte[] Syncsafe(int value) =>
        [(byte)(value >> 21 & 0x7F), (byte)(value >> 14 & 0x7F), (byte)(value >> 7 & 0x7F), (byte)(value & 0x7F)];

    public static byte[] BigEndian(int value) =>
        [(byte)(value >> 24 & 0xFF), (byte)(value >> 16 & 0xFF), (byte)(value >> 8 & 0xFF), (byte)(value & 0xFF)];

    private static byte[] Cat(params byte[][] parts) => parts.SelectMany(p => p).ToArray();

    public static byte[] Frame(string id, byte[] data, byte version) =>
        Cat(Encoding.ASCII.GetBytes(id), version == 4 ? Syncsafe(data.Length) : BigEndian(data.Length), [0, 0], data);

    /// <summary>A text frame: 0 ISO-8859-1, 1 UTF-16 with a byte-order mark, 3 UTF-8.</summary>
    public static byte[] Text(string id, string value, byte encoding, byte version)
    {
        var bytes = encoding switch
        {
            0 => Cat(Encoding.Latin1.GetBytes(value), [0]),
            1 => Cat([0xFF, 0xFE], Encoding.Unicode.GetBytes(value), [0, 0]),
            _ => Cat(Encoding.UTF8.GetBytes(value), [0]),
        };
        return Frame(id, Cat([encoding], bytes), version);
    }

    public static byte[] Chapter(string id, double start, double end, string title, byte encoding = 0, byte version = 3)
    {
        byte[] unused = [0xFF, 0xFF, 0xFF, 0xFF];
        var data = Cat(Encoding.ASCII.GetBytes(id), [0], BigEndian((int)(start * 1000)), BigEndian((int)(end * 1000)), unused, unused,
                       Text("TIT2", title, encoding, version));
        return Frame("CHAP", data, version);
    }

    public static byte[] TagOf(byte version, byte[][] frames, int padding = 64)
    {
        var body = Cat(Cat(frames), new byte[padding]);
        return Cat([0x49, 0x44, 0x33, version, 0, 0], Syncsafe(body.Length), body);
    }

    /// <summary>RTBF's own frames, then the four chapters a Dayez file would get.</summary>
    public static byte[] Dayez(byte version = 3, byte encoding = 0, int padding = 64)
    {
        var toc = Frame("CTOC", Cat(Encoding.ASCII.GetBytes("toc"), [0, 0x03, 4], Encoding.ASCII.GetBytes("ch0\0ch1\0ch2\0ch3\0")), version);
        return TagOf(version,
        [
            Text("TIT2", "Les chroniques de la Grande matinée, avec Hugues Dayez", encoding, version),
            Text("TPE1", "Hugues DAYEZ", encoding, version),
            toc,
            // Written out of order on purpose: they're read by start time.
            Chapter("ch2", 200.25, 381, "Wicker", encoding, version),
            Chapter("ch0", 0, 41.5, "Introduction", encoding, version),
            Chapter("ch1", 41.5, 200.25, "Coward", encoding, version),
            Chapter("ch3", 381, 552, "Karma", encoding, version),
        ], padding);
    }
}

/// <summary>A file "server" that ignores the Range header and sends everything.</summary>
internal sealed class WholeFileHandler(byte[] file) : HttpMessageHandler
{
    public int Requests { get; private set; }

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Requests++;
        return Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new ByteArrayContent(file) });
    }
}

public class ChapterTests
{
    private static Episode DayezEpisode(string name, string url = "https://example.org/dayez.mp3", DateTime? date = null)
    {
        var films = name.Split(" · ");
        var segments = films.Select((f, i) => new Segment(i, f, SegmentKind.Movie, null, null)).ToList();
        return new Episode(1, Series.Dayez, date ?? Fixture.Unix(1_792_000_000), "", new Uri(url), segments, name);
    }

    [Fact]
    public void ReadsTheChaptersOfAnId3v23Tag()
    {
        var chapters = ID3Chapters.Chapters(Tag.Dayez());
        Assert.Equal([new AudioChapter("Introduction", 0), new AudioChapter("Coward", 41.5),
                      new AudioChapter("Wicker", 200.25), new AudioChapter("Karma", 381)], chapters);
    }

    [Fact]
    public void ReadsId3v24AndEveryTextEncoding()
    {
        foreach (byte encoding in new byte[] { 0, 1, 3 })
            Assert.Equal(["Introduction", "Coward", "Wicker", "Karma"], ID3Chapters.Chapters(Tag.Dayez(4, encoding)).Select(c => c.Title));
        // Accents in each encoding, and frames over 127 bytes, whose 2.4 size is syncsafe.
        var longText = new string('a', 300);
        foreach (byte version in new byte[] { 3, 4 })
        foreach (byte encoding in new byte[] { 0, 1, 3 })
        {
            var tag = Tag.TagOf(version,
            [
                Tag.Text("COMM", longText, encoding, version),
                Tag.Chapter("c", 12, 20, "Les Misérables", encoding, version),
            ]);
            Assert.Equal([new AudioChapter("Les Misérables", 12)], ID3Chapters.Chapters(tag));
        }
    }

    [Fact]
    public void TagLengthComesFromTheHeader()
    {
        // RTBF's tag on a Dayez file: 308 bytes after the header.
        Assert.Equal(318, ID3Chapters.TagLength([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0x02, 0x34]));
        Assert.Null(ID3Chapters.TagLength(Encoding.UTF8.GetBytes("RIFF0000WAVE")));
        Assert.Empty(ID3Chapters.Chapters([0xFF, 0xFB, 0x90, 0x64]));
    }

    [Fact]
    public void ATagWithoutChaptersHasNone()
    {
        var tag = Tag.TagOf(3, [Tag.Text("TIT2", "Coward - Wicker - Karma", 0, 3)]);
        Assert.Empty(ID3Chapters.Chapters(tag));
        // ID3v2.2 can't hold chapters.
        Assert.Empty(ID3Chapters.Chapters([0x49, 0x44, 0x33, 2, 0, 0, 0, 0, 0, 10, .. new byte[10]]));
    }

    [Fact]
    public async Task ReadsOnlyTheTagOfAFile()
    {
        var audio = Enumerable.Repeat((byte)0xAA, 300_000).ToArray();
        // A small tag, read in one go; and one with 100 KB of padding (as big artwork would make it), which takes a second read.
        foreach (var padding in new[] { 64, 100_000 })
        {
            var handler = new WholeFileHandler([.. Tag.Dayez(padding: padding), .. audio]);
            var reader = new ChapterReader(new HttpClient(handler));
            var chapters = await reader.ChaptersAsync(new Uri("https://example.org/dayez.mp3"));
            Assert.Equal([0, 41.5, 200.25, 381], chapters.Select(c => c.Start));
            Assert.Equal(padding == 64 ? 1 : 2, handler.Requests);
        }
        Assert.Empty(await new ChapterReader(new HttpClient(new WholeFileHandler(audio))).ChaptersAsync(new Uri("https://example.org/plain.mp3")));
    }

    [Fact]
    public void FilmsStartWhereTheirChaptersDo()
    {
        var episode = DayezEpisode("Coward · Wicker · Karma");
        var timed = episode.StartingFilms(ID3Chapters.Chapters(Tag.Dayez()));
        Assert.Equal<double?>([41.5, 200.25, 381], timed.Segments.Select(s => s.Start));
        Assert.Equal(episode.Segments.Select(s => s.Title), timed.Segments.Select(s => s.Title));
        Assert.Equal(episode.Segments.Select(s => s.Id), timed.Segments.Select(s => s.Id));
    }

    [Fact]
    public void NamesMatchWhateverTheirCaseAccentsAndPunctuation()
    {
        var episode = DayezEpisode("Les Misérables · Le Corset · Franz");
        var chapters = new[] { new AudioChapter("LES MISERABLES", 30), new AudioChapter("Corset", 190), new AudioChapter("Franz !", 350) };
        Assert.Equal<double?>([30, 190, 350], episode.StartingFilms(chapters).Segments.Select(s => s.Start));
    }

    [Fact]
    public void ChaptersNamedOtherwiseGoInOrder()
    {
        var episode = DayezEpisode("Coward · Wicker · Karma");
        var numbered = new[] { new AudioChapter("Début", 0), new AudioChapter("Film 1", 40), new AudioChapter("Film 2", 200), new AudioChapter("Film 3", 380) };
        Assert.Equal<double?>([40, 200, 380], episode.StartingFilms(numbered).Segments.Select(s => s.Start));
        Assert.Equal<double?>([40, 200, 380], episode.StartingFilms(numbered.Skip(1).ToArray()).Segments.Select(s => s.Start));
        // Two chapters for three films, none named after one: nothing to go by.
        var two = new[] { new AudioChapter("A", 0), new AudioChapter("B", 100) };
        Assert.Equal(episode, episode.StartingFilms(two));
    }

    [Fact]
    public void TheLibraryTimesDayezFilmsAndReadsFilesAgain()
    {
        var now = Fixture.Unix(1_800_000_000);
        var recent = DayezEpisode("Coward · Wicker · Karma", date: now.AddDays(-7));
        var old = DayezEpisode("Moulin · La Gradiva", "https://example.org/old.mp3", now.AddDays(-400));
        var library = new ChapterLibrary();
        Assert.True(library.NeedsLookup(recent, now) && library.NeedsLookup(old, now));
        Assert.Equal(recent, library.Apply(recent));                  // not read yet: unchanged
        Assert.Null(library.LastRead(recent));

        library.Record([], recent, now.AddSeconds(-60));
        // The file replaced with one that has chapters: they're news; the same ones read again aren't.
        var added = library.Record(ID3Chapters.Chapters(Tag.Dayez()), recent, now);
        var readAgain = library.Record(ID3Chapters.Chapters(Tag.Dayez()), recent, now);
        Assert.True(added && !readAgain);
        Assert.Equal(now, library.LastRead(recent));
        library.Record([], old, now);
        Assert.Equal<double?>([41.5, 200.25, 381], library.Apply(recent).Segments.Select(s => s.Start));
        Assert.Equal(old, library.Apply(old));

        // Read again after 6 hours when recent (chapters often come after the file), after a week when old.
        Assert.False(library.NeedsLookup(recent, now.AddHours(5)));
        Assert.True(library.NeedsLookup(recent, now.AddHours(7)));
        Assert.False(library.NeedsLookup(old, now.AddDays(6)));
        Assert.True(library.NeedsLookup(old, now.AddDays(8)));

        // Chapters taken out of the file: the films lose their starts.
        var timed = library.Apply(recent);
        library.Record([], recent, now);
        Assert.All(library.Apply(timed).Segments, s => Assert.Null(s.Start));

        // Another show's episode is left alone.
        var other = new Episode(2, Series.QuelquePart, now, "", recent.AudioUrl, [], "Episode #44");
        Assert.Equal(other, library.Apply(other));
    }

    [Fact]
    public void FilmDetailsKeepTheChapterStarts()
    {
        var episode = DayezEpisode("Coward · Wicker · Karma");
        var chapters = new ChapterLibrary();
        chapters.Record(ID3Chapters.Chapters(Tag.Dayez()), episode);
        var films = new FilmLibrary();
        films.Record(new FilmInfo { TmdbId = 1, Title = "Coward", OriginalTitle = "Coward", Year = 2026, Overview = "Guerre.",
                                    PosterPath = "/coward.jpg", Director = "Lukas Dhont" }, "Coward", episode.Date);
        var detailed = films.Enrich(chapters.Apply(episode));
        Assert.Equal<double?>([41.5, 200.25, 381], detailed.Segments.Select(s => s.Start));
        Assert.Equal("Coward (2026)", detailed.Segments[0].Title);
        Assert.Equal("Lukas Dhont", detailed.Segments[0].Director);
    }

    [Fact]
    public void SavesAndLoadsBack()
    {
        var file = Path.Combine(Path.GetTempPath(), $"chapters-{Guid.NewGuid()}.json");
        try
        {
            var episode = DayezEpisode("Coward · Wicker · Karma");
            var library = new ChapterLibrary();
            library.Record([new AudioChapter("Coward", 41.5)], episode);
            library.Save(file);
            Assert.Equal([new AudioChapter("Coward", 41.5)], ChapterLibrary.Load(file).Entries[episode.AudioUrl.AbsoluteUri].Chapters);
        }
        finally { File.Delete(file); }
    }
}
