using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml;
using System.Xml.Linq;

namespace CinqHeures.Core;

/// <summary>Reads the shows that come as plain podcast feeds: Rudy Léonet's weekly "Il est toujours 5 heures quelque
/// part", from Ausha, and Hugues Dayez's weekly reviews, from Franky's own Audiobookshelf (RTBF's Auvio needs a login).
/// Their episodes have no per-film timecodes (Dayez's films get theirs from the chapters of the MP3). Dayez's titles
/// name the three films, which become segments without a start, so they're searchable and listed.</summary>
public sealed class FeedClient
{
    public static readonly Uri QuelquePartFeed = new("https://feed.ausha.co/j0n2zsQR3XOG");
    public static readonly Uri DayezFeed = new("https://audio.frankynov.ovh/audiobookshelf/feed/9a2355b5-d416-42fa-929c-45bea81d29c5");

    private static readonly XNamespace Itunes = "http://www.itunes.com/dtds/podcast-1.0.dtd";

    private readonly Uri _feed;
    private readonly HttpClient _http;
    public Series Series { get; }

    public FeedClient(Uri feed, Series series, HttpClient? http = null)
    {
        _feed = feed; Series = series; _http = http ?? SiteClient.Http;
    }

    public static IReadOnlyList<FeedClient> All { get; } =
        [new(QuelquePartFeed, Series.QuelquePart), new(DayezFeed, Series.Dayez)];

    public async Task<List<Episode>> EpisodesAsync(CancellationToken cancel = default)
    {
        using var response = await _http.GetAsync(_feed, cancel);
        var status = (int)response.StatusCode;
        if (status != 200) throw SiteException.Http(status);
        return Parse(await response.Content.ReadAsByteArrayAsync(cancel), Series);
    }

    private sealed class Item
    {
        public string Title = "";
        public string? Guid;
        public DateTime? Date;
        public Uri? Audio;
        public Uri? Artwork;
        public double? Duration;
        public List<string> Keywords = [];
        public string Description = "";
    }

    /// <summary>The feed's episodes, newest first. Parsing is separate from fetching so it can be tested.</summary>
    public static List<Episode> Parse(byte[] data, Series series = Series.QuelquePart)
    {
        XDocument document;
        try
        {
            using var stream = new MemoryStream(data);
            document = XDocument.Load(stream);
        }
        catch (XmlException) { throw SiteException.Unreadable(); }

        var channel = document.Root?.Element("channel") ?? throw SiteException.Unreadable();
        var channelArtwork = Small(channel.Elements(Itunes + "image").FirstOrDefault()?.Attribute("href")?.Value);
        var items = new List<Item>();
        foreach (var node in channel.Elements("item"))
        {
            var item = new Item
            {
                Title = node.Element("title")?.Value.Trim() ?? "",
                Guid = node.Element("guid")?.Value.Trim(),
                Date = ParseDate(node.Element("pubDate")?.Value.Trim()),
                Description = node.Element("description")?.Value.Trim() ?? "",
                Duration = ParseDuration(node.Element(Itunes + "duration")?.Value ?? ""),
                Keywords = (node.Element(Itunes + "keywords")?.Value ?? "")
                    .Split(',').Select(k => k.Trim()).Where(k => k.Length > 0).ToList(),
                Artwork = Small(node.Element(Itunes + "image")?.Attribute("href")?.Value),
            };
            if (node.Element("enclosure")?.Attribute("url")?.Value is { } url && Uri.TryCreate(url, UriKind.Absolute, out var audio))
                item.Audio = audio;
            items.Add(item);
        }
        items = items.Where(i => i.Audio is not null && i.Date is not null).ToList();

        // Every episode carries the same generic tags (Concerts, pop culture…): the ones that are only on some
        // episodes name the artists discussed.
        var frequency = new Dictionary<string, int>();
        foreach (var item in items)
            foreach (var keyword in item.Keywords.Select(k => k.ToLowerInvariant()).Distinct())
                frequency[keyword] = frequency.GetValueOrDefault(keyword) + 1;
        var generic = frequency.Where(f => f.Value >= Math.Max(items.Count, 1) * 0.4).Select(f => f.Key).ToHashSet();

        var episodes = items.Select(item =>
        {
            // "Il est toujours 5 heures quelque part" keeps the ids it always had (its guid alone); others are
            // prefixed by their show.
            var key = (series == Series.QuelquePart ? "" : series.Raw() + "|") + (item.Guid ?? item.Title);
            var artwork = item.Artwork ?? channelArtwork;
            if (series == Series.Dayez)
            {
                var films = FilmTitles(item.Title);
                var segments = films.Select((film, index) =>
                    new Segment(StableId(key + "#" + index), film, SegmentKind.Movie, null, null)).ToList();
                return new Episode(StableId(key), series, DateInTitle(item.Title) ?? item.Date!.Value,
                                   ReadableDescription(item.Description, item.Title), item.Audio!, segments,
                                   films.Count == 0 ? item.Title : string.Join(" · ", films), artwork, item.Duration);
            }
            var artists = item.Keywords.Where(k => !generic.Contains(k.ToLowerInvariant())).ToList();
            return new Episode(StableId(key), series, item.Date!.Value,
                               artists.Count == 0 ? "" : "Au menu : " + string.Join(", ", artists),
                               item.Audio!, [], item.Title, artwork, item.Duration);
        });
        return episodes.OrderByDescending(e => e.Date).ToList();
    }

    /// <summary>Ausha serves 1400 px covers; the 400 px version is plenty for a list.</summary>
    private static Uri? Small(string? href) =>
        href is not null && Uri.TryCreate(href.Replace("_1400x1400", "_400x400"), UriKind.Absolute, out var uri) ? uri : null;

    private static readonly string[] DateFormats =
        ["ddd, dd MMM yyyy HH:mm:ss zzz", "ddd, d MMM yyyy HH:mm:ss zzz"];
    private static readonly Regex Offset = new(@"([+-])([0-9]{2})([0-9]{2})$", RegexOptions.Compiled);

    private static DateTime? ParseDate(string? text)
    {
        if (string.IsNullOrEmpty(text)) return null;
        text = Regex.Replace(text, @"\s(GMT|UT|Z)$", " +0000");
        text = Offset.Replace(text, "$1$2:$3");
        return DateTimeOffset.TryParseExact(text, DateFormats, CultureInfo.InvariantCulture, DateTimeStyles.None, out var date)
            ? date.UtcDateTime : null;
    }

    private static readonly RegexOptions Ci = RegexOptions.IgnoreCase;
    private static readonly Regex TrailingDate = new(@"\s*-\s*[0-9]{2}/[0-9]{2}/[0-9]{4}\s*$", RegexOptions.Compiled);
    private static readonly Regex ChroniquesPrefix =
        new(@"^\s*Les chroniques de la Grande matin[ée]e,\s*avec Hugues Dayez\s*-\s*", RegexOptions.Compiled | Ci);
    private static readonly Regex RtbfStyle = new(@"^\s*Cin[ée]ma\b", RegexOptions.Compiled | Ci);
    private static readonly Regex CinemaPrefix =
        new(@"^\s*Cin[ée]ma\s*(,\s*avec Hugues Dayez)?\s*[:\-–]\s*", RegexOptions.Compiled | Ci);
    private static readonly Regex Quoted =
        new(@"(?:^|[\s,;:\-–(])[""“«']\s*([^""”»]+?)\s*[""”»]", RegexOptions.Compiled);
    private static readonly Regex Strong = new(@"\s+[-–—/]\s+|\s*;\s*", RegexOptions.Compiled);
    private static readonly Regex Hyphens = new(@"\s*-\s*", RegexOptions.Compiled);
    private static readonly Regex CommasAndEt = new(@"\s*,\s*|\s+et\s+", RegexOptions.Compiled);
    private static readonly Regex Descriptors =
        new(@"(,\s*film d['’]animation|\s+avec\s+.+)$", RegexOptions.Compiled | Ci);
    private static readonly Regex ByDirector =
        new(@"\s+de\s+\p{Lu}[\p{L}'’-]+(\s+\p{Lu}[\p{L}'’-]+)+$", RegexOptions.Compiled);
    private static readonly char[] TrimChars = [' ', '"', '«', '»', '“', '”', '\'', ',', '.', '\n', '\r', '\t'];

    /// <summary>The films named in a Dayez episode title, whichever way it was written:
    /// <c>Coward - Wicker - Karma</c>, <c>"Les Misérables", "Le Corset", "Franz"</c>, <c>Digger, Notre Salut et Verity</c>,
    /// <c>Cinéma, avec Hugues Dayez - "Un simple accident"-"Rembrandt" - 01/10/2025</c>.</summary>
    internal static List<string> FilmTitles(string raw)
    {
        var title = TrailingDate.Replace(raw, "");
        title = ChroniquesPrefix.Replace(title, "");
        var rtbfStyle = RtbfStyle.IsMatch(title);
        title = CinemaPrefix.Replace(title, "");

        List<string> Split(Regex pattern) => pattern.Replace(title, "\u0001").Split('\u0001').ToList();

        // Quoted titles first ("…", “…”, «…», and the odd '…" mix); then clear separators; then, in RTBF's
        // "Cinéma : A-B-C" style, bare hyphens; commas and "et" last, as they also occur inside titles.
        var quoted = Quoted.Matches(title).Select(m => m.Groups[1].Value).ToList();
        var strong = Split(Strong);
        var hyphens = Split(Hyphens);
        var pieces = quoted.Count >= 2 ? quoted
            : strong.Count >= 2 ? strong
            : rtbfStyle && hyphens.Count >= 3 ? hyphens
            : Split(CommasAndEt);

        return pieces
            .Select(p => p.Trim(TrimChars).Trim())
            // Descriptors after the title: "The end avec Tilda Swinton", "Mary Anning, film d'animation".
            .Select(p => Descriptors.Replace(p, ""))
            // A one-film title may end with its director, "The Death of Robin Hood de Michael Sarnoski".
            // Not in a list: "La voix de Hind Rajab" is a whole title.
            .Select(p => pieces.Count == 1 ? ByDirector.Replace(p, "") : p)
            // Interviews and asides aren't films.
            .Where(p => p.Length > 0 && p.Length <= 80 && !p.EndsWith('?')
                        && !p.Contains("interview", StringComparison.OrdinalIgnoreCase))
            .ToList();
    }

    private static readonly Regex DateAtEnd = new(@"[0-9]{2}/[0-9]{2}/[0-9]{4}\s*$", RegexOptions.Compiled);

    /// <summary>"… - 01/10/2025" at the end of a title: some episodes have a wrong publication date but a right title.</summary>
    internal static DateTime? DateInTitle(string title)
    {
        var match = DateAtEnd.Match(title);
        return match.Success ? EpisodeDates.ParseShort(match.Value.Trim()) : null;
    }

    private static readonly Regex Breaks = new(@"<br\s*/?>|</p>", RegexOptions.Compiled | Ci);
    private static readonly Regex Tags = new(@"<[^>]+>", RegexOptions.Compiled);
    private static readonly Regex Hashes = new(@"#+\s*", RegexOptions.Compiled);
    private static readonly Regex Blanks = new(@"[ \t]+", RegexOptions.Compiled);
    private static readonly Regex Lines = new(@"\n\s*\n+", RegexOptions.Compiled);

    /// <summary>The description as plain text, or nothing when it's only a tag ("cinema-sorties") or the title again.</summary>
    internal static string ReadableDescription(string html, string title)
    {
        var text = Breaks.Replace(html, "\n");
        text = Tags.Replace(text, "");
        text = Hashes.Replace(text, "");
        text = Blanks.Replace(text, " ");
        text = Lines.Replace(text, "\n").Trim();
        if (text.Length == 0 || text == "cinema-sorties" || Search.Fold(text) == Search.Fold(title)) return "";
        return text.Length > 3000 ? text[..3000] : text;
    }

    /// <summary>A negative number derived from the episode's guid: the same on every launch (and on the Mac, whose ids
    /// the shipped catalogue carries), and never clashing with the (positive) ids 5heures.be gives its own episodes.
    /// FNV-1a over the UTF-8 bytes.</summary>
    internal static long StableId(string guid)
    {
        unchecked
        {
            ulong hash = 0xcbf29ce484222325UL;
            foreach (var b in Encoding.UTF8.GetBytes(guid)) hash = (hash ^ b) * 0x100000001b3UL;
            return -(long)(hash % 2_000_000_000UL) - 1;
        }
    }

    /// <summary>"1:23:07", "04:22" or plain seconds.</summary>
    internal static double? ParseDuration(string text)
    {
        var parts = text.Trim().Split(':', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return null;
        double total = 0;
        foreach (var part in parts)
        {
            if (!double.TryParse(part, NumberStyles.Float, CultureInfo.InvariantCulture, out var value)) return null;
            total = total * 60 + value;
        }
        return total;
    }
}
