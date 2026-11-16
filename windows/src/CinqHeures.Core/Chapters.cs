using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CinqHeures.Core;

/// <summary>A chapter of an audio file: where it starts and what it's called.</summary>
public sealed record AudioChapter(
    [property: JsonPropertyName("title")] string Title,
    [property: JsonPropertyName("start")] double Start);

/// <summary>Chapters the way podcast tools write them into an MP3: ID3v2.3 or 2.4 <c>CHAP</c> frames, each with its
/// start time and a <c>TIT2</c> title (the ID3v2 Chapter Frame Addendum). ID3v2.2 has no chapters.</summary>
public static class ID3Chapters
{
    /// <summary>The whole tag's length in bytes, its header included, from the file's first ten bytes; null when the file
    /// doesn't start with an ID3v2 tag.</summary>
    public static int? TagLength(ReadOnlySpan<byte> header)
    {
        if (header.Length < 10) return null;
        var b = header[..10];
        if (b[0] != 0x49 || b[1] != 0x44 || b[2] != 0x33 || b[3] == 0xFF || b[4] == 0xFF) return null;
        for (var i = 6; i <= 9; i++) if (b[i] >= 0x80) return null;
        var footer = b[3] == 4 && (b[5] & 0x10) != 0 ? 10 : 0;
        return 10 + Syncsafe(b.Slice(6, 4)) + footer;
    }

    /// <summary>The chapters in a tag (the file's first <c>TagLength</c> bytes, or more), by start time.</summary>
    public static List<AudioChapter> Chapters(byte[] tag)
    {
        if (TagLength(tag) is not { } length) return [];
        var version = tag[3];
        if (version is not (3 or 4)) return [];
        var flags = tag[5];
        var body = tag.AsSpan(10, Math.Min(tag.Length, length) - 10).ToArray();
        if (version == 3 && (flags & 0x80) != 0) body = RemovingUnsynchronisation(body);
        var start = 0;
        if ((flags & 0x40) != 0)
        {
            // An extended header: its size counts itself in 2.4, not in 2.3.
            if (body.Length < 4) return [];
            start = version == 3 ? BigEndian(body.AsSpan(0, 4)) + 4 : Syncsafe(body.AsSpan(0, 4));
        }
        return Frames(body, start, version)
            .Where(f => f.Id == "CHAP")
            .Select(f => Chapter(f.Data, version))
            .OfType<AudioChapter>()
            .OrderBy(c => c.Start)
            .ToList();
    }

    private sealed record Frame(string Id, byte[] Data);

    /// <summary>The frames from <paramref name="start"/> until the padding (or anything that isn't a frame).</summary>
    private static List<Frame> Frames(byte[] bytes, int start, byte version)
    {
        var frames = new List<Frame>();
        var position = start;
        while (position + 10 <= bytes.Length)
        {
            var idBytes = bytes.AsSpan(position, 4);
            var valid = true;
            foreach (var c in idBytes)
                if (!((c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39))) { valid = false; break; }
            if (!valid) break;
            var sizeBytes = bytes.AsSpan(position + 4, 4);
            var size = version == 4 ? Syncsafe(sizeBytes) : BigEndian(sizeBytes);
            int format = bytes[position + 9];            // the format byte: how the data is stored
            var dataStart = position + 10;
            if (size < 0 || dataStart + size > bytes.Length) break;
            var data = bytes.AsSpan(dataStart, size).ToArray();
            position = dataStart + size;
            if (version == 3)
            {
                if ((format & 0xC0) != 0) continue;                         // compressed or encrypted
                if ((format & 0x20) != 0) data = data.Skip(1).ToArray();      // a group byte in front
            }
            else
            {
                if ((format & 0x0C) != 0) continue;                         // compressed or encrypted
                if ((format & 0x40) != 0) data = data.Skip(1).ToArray();      // a group byte in front
                if ((format & 0x01) != 0) data = data.Skip(4).ToArray();      // its length in front
                if ((format & 0x02) != 0) data = RemovingUnsynchronisation(data);
            }
            frames.Add(new Frame(Encoding.ASCII.GetString(idBytes), data));
        }
        return frames;
    }

    /// <summary>A <c>CHAP</c> frame: an element ID ending in a zero, start and end in milliseconds, start and end in
    /// bytes, then frames of its own, <c>TIT2</c> being its title.</summary>
    private static AudioChapter? Chapter(byte[] data, byte version)
    {
        var zero = Array.IndexOf(data, (byte)0);
        if (zero < 0 || zero + 17 > data.Length) return null;
        var milliseconds = BigEndian(data.AsSpan(zero + 1, 4));
        var inner = Frames(data[(zero + 17)..], 0, version);
        var title = inner.FirstOrDefault(f => f.Id == "TIT2") is { } frame ? Text(frame.Data) : null;
        return new AudioChapter(title ?? "", milliseconds / 1000.0);
    }

    /// <summary>A text frame's first string, in whichever of ID3's four encodings it's written.</summary>
    private static string? Text(byte[] data)
    {
        if (data.Length == 0) return null;
        var encoding = data[0];
        var body = data.AsSpan(1);
        string? text;
        switch (encoding)
        {
            case 0:
                text = Encoding.Latin1.GetString(Until(body, wide: false));
                break;
            case 3:
                text = Encoding.UTF8.GetString(Until(body, wide: false));
                break;
            case 1:
            case 2:
                // UTF-16 with a byte-order mark (1), or big-endian without one (2); a 16-bit zero ends it.
                var units = Until(body, wide: true);
                if (encoding == 1 && units.Length >= 2 && units[0] == 0xFF && units[1] == 0xFE)
                    text = Encoding.Unicode.GetString(units, 2, units.Length - 2);
                else if (encoding == 1 && units.Length >= 2 && units[0] == 0xFE && units[1] == 0xFF)
                    text = Encoding.BigEndianUnicode.GetString(units, 2, units.Length - 2);
                else
                    text = Encoding.BigEndianUnicode.GetString(units);
                break;
            default:
                return null;
        }
        return text.Trim();
    }

    private static byte[] Until(ReadOnlySpan<byte> body, bool wide)
    {
        if (!wide)
        {
            var end = body.IndexOf((byte)0);
            return (end < 0 ? body : body[..end]).ToArray();
        }
        var i = 0;
        while (i + 1 < body.Length && (body[i] != 0 || body[i + 1] != 0)) i += 2;
        return body[..i].ToArray();
    }

    private static int Syncsafe(ReadOnlySpan<byte> bytes)
    {
        var value = 0;
        foreach (var b in bytes) value = value << 7 | (b & 0x7F);
        return value;
    }

    private static int BigEndian(ReadOnlySpan<byte> bytes)
    {
        var value = 0;
        foreach (var b in bytes) value = value << 8 | b;
        return value;
    }

    /// <summary>Unsynchronised data has a zero after every 0xFF byte that could look like an MPEG sync.</summary>
    private static byte[] RemovingUnsynchronisation(byte[] bytes)
    {
        var result = new List<byte>(bytes.Length);
        byte previous = 0;
        foreach (var b in bytes)
        {
            if (!(previous == 0xFF && b == 0)) result.Add(b);
            previous = b;
        }
        return result.ToArray();
    }
}

/// <summary>Reads an MP3's chapters over the network without downloading the file: only its tag, at the start, a few
/// kilobytes.</summary>
public sealed class ChapterReader
{
    /// <summary>Enough for most tags in one request; one with large artwork takes a second.</summary>
    internal const int FirstRead = 64 << 10;
    /// <summary>A tag larger than this isn't read.</summary>
    internal const int LargestTag = 4 << 20;

    private readonly HttpClient _http;

    public ChapterReader(HttpClient? http = null) { _http = http ?? SiteClient.Http; }

    public async Task<List<AudioChapter>> ChaptersAsync(Uri url, CancellationToken cancel = default)
    {
        var data = await FirstBytesAsync(url, FirstRead, cancel);
        if (ID3Chapters.TagLength(data) is not { } length || length > LargestTag) return [];
        if (data.Length < length) data = await FirstBytesAsync(url, length, cancel);
        return ID3Chapters.Chapters(data);
    }

    /// <summary>The file's first <paramref name="count"/> bytes (fewer if it's shorter): asked for as a range, and read
    /// only that far even from a server that sends the whole file.</summary>
    private async Task<byte[]> FirstBytesAsync(Uri url, int count, CancellationToken cancel)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(0, count - 1);
        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancel);
        var status = (int)response.StatusCode;
        if (status is not (200 or 206)) throw SiteException.Http(status);
        await using var stream = await response.Content.ReadAsStreamAsync(cancel);
        var buffer = new byte[count];
        var read = 0;
        while (read < count)
        {
            var n = await stream.ReadAsync(buffer.AsMemory(read, count - read), cancel);
            if (n == 0) break;
            read += n;
        }
        return buffer.AsSpan(0, read).ToArray();
    }
}

/// <summary>The chapters found in the Dayez files, and when each file was last read, kept between launches.</summary>
public sealed class ChapterLibrary
{
    public sealed record Entry(
        [property: JsonPropertyName("chapters")] List<AudioChapter> Chapters,
        [property: JsonPropertyName("checked")] DateTime Checked);

    private sealed class Stored
    {
        [JsonPropertyName("entries")] public Dictionary<string, Entry> Entries { get; set; } = [];
    }

    /// <summary>By the file's address.</summary>
    public Dictionary<string, Entry> Entries { get; private set; } = [];

    /// <summary>Not read yet, or read a while ago: a file can get its chapters, or new times, after it was published, so
    /// a recent episode's is read again after 6 hours, an older one's after a week.</summary>
    public bool NeedsLookup(Episode episode, DateTime? now = null)
    {
        var at = now ?? DateTime.UtcNow;
        if (!Entries.TryGetValue(episode.AudioUrl.AbsoluteUri, out var entry)) return true;
        var recent = (at - episode.Date).TotalSeconds < 60 * 86_400;
        return (at - entry.Checked).TotalSeconds > (recent ? 6 * 3600 : 7 * 86_400);
    }

    /// <summary>When the episode's file was last read, if it was.</summary>
    public DateTime? LastRead(Episode episode) =>
        Entries.TryGetValue(episode.AudioUrl.AbsoluteUri, out var entry) ? entry.Checked : null;

    /// <summary>Returns whether the chapters differ from the ones found last time.</summary>
    public bool Record(List<AudioChapter> chapters, Episode episode, DateTime? now = null)
    {
        var key = episode.AudioUrl.AbsoluteUri;
        var changed = !Entries.TryGetValue(key, out var old) || !old.Chapters.SequenceEqual(chapters);
        Entries[key] = new Entry(chapters, now ?? DateTime.UtcNow);
        return changed;
    }

    /// <summary>A Dayez episode with each film starting where its chapter does (see
    /// <see cref="ChapterExtensions.StartingFilms"/>); unchanged while its file hasn't been read.</summary>
    public Episode Apply(Episode episode) =>
        episode.Series == Series.Dayez && Entries.TryGetValue(episode.AudioUrl.AbsoluteUri, out var entry)
            ? episode.StartingFilms(entry.Chapters) : episode;

    public static ChapterLibrary Load(string? path = null)
    {
        try
        {
            using var stream = File.OpenRead(path ?? AppPaths.Chapters);
            var stored = JsonSerializer.Deserialize<Stored>(stream, CoreJson.Options);
            return new ChapterLibrary { Entries = stored?.Entries ?? [] };
        }
        catch (Exception) { return new ChapterLibrary(); }
    }

    public void Save(string? path = null) =>
        CoreJson.SaveAtomically(path ?? AppPaths.Chapters,
            stream => JsonSerializer.Serialize(stream, new Stored { Entries = Entries }, CoreJson.Options));
}

public static class ChapterExtensions
{
    /// <summary>The films a Dayez episode's title names, each starting where its chapter does: matched by name (case,
    /// accents and punctuation aside, or one name inside the other), or in order when no name matches and the chapters
    /// are the films one for one, an opening chapter at 0:00 aside. A film left without a chapter has no start.</summary>
    public static Episode StartingFilms(this Episode episode, IReadOnlyList<AudioChapter> chapters)
    {
        var films = episode.SpokenFilms;
        if (films.Count == 0 || films.Count != episode.Segments.Count) return episode;
        var names = chapters.Select(c => Search.Fold(c.Title)).ToList();
        static bool Overlap(string a, string b) => Math.Min(a.Length, b.Length) >= 4 && (a.Contains(b) || b.Contains(a));
        var starts = films.Select(film =>
        {
            var name = Search.Fold(film);
            var found = names.IndexOf(name);
            if (found < 0) found = names.FindIndex(n => Overlap(n, name));
            return found < 0 ? (double?)null : chapters[found].Start;
        }).ToList();
        if (starts.All(s => s is null))
        {
            var opening = chapters.Count == films.Count + 1 && chapters[0].Start < 1;
            var rest = opening ? chapters.Skip(1).ToList() : chapters.ToList();
            if (rest.Count == films.Count) starts = rest.Select(c => (double?)c.Start).ToList();
        }
        var timed = episode.Segments.Zip(starts, (segment, start) => segment.Starting(start)).ToList();
        return timed.SequenceEqual(episode.Segments) ? episode : episode with { Segments = timed };
    }
}
