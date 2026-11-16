using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CinqHeures.Core;

/// <summary>What TMDB knows about a film, kept once looked up. TMDB is also where 5heures.be's posters come from.</summary>
public sealed record FilmInfo
{
    [JsonPropertyName("tmdbID")] public int TmdbId { get; init; }
    /// <summary>The French title, as released here.</summary>
    [JsonPropertyName("title")] public string Title { get; init; } = "";
    /// <summary>The title in its own language: what 5heures.be names films by, so the same film links up.</summary>
    [JsonPropertyName("originalTitle")] public string OriginalTitle { get; init; } = "";
    [JsonPropertyName("year")] public int? Year { get; init; }
    [JsonPropertyName("overview")] public string Overview { get; init; } = "";
    [JsonPropertyName("posterPath")] public string? PosterPath { get; init; }
    [JsonPropertyName("director")] public string? Director { get; init; }

    [JsonIgnore]
    public Uri? PosterUrl => PosterPath is null ? null : new Uri("https://image.tmdb.org/t/p/w500" + PosterPath);

    /// <summary>"Coward (2026)": the way 5heures.be titles its films. The original title, unless it's in another script
    /// (Chinese, Arabic…), where the French one reads better.</summary>
    [JsonIgnore]
    public string ArchiveTitle
    {
        get
        {
            var latin = OriginalTitle.EnumerateRunes().All(r => !Rune.IsLetter(r) || r.Value < 0x0250 || (r.Value is >= 0x1E00 and <= 0x1EFF));
            var name = latin ? OriginalTitle : Title;
            return Year is { } y ? $"{name} ({y})" : name;
        }
    }
}

/// <summary>Looks films up on TMDB, through Franky's proxy (which holds the token) or, in tests, directly.</summary>
public sealed partial class TMDBClient
{
    public static readonly Uri ProxyUrl = new("https://frankynov.ovh/cinqheures/tmdb.php");

    private readonly Uri? _proxy;
    private readonly string? _token;
    private readonly HttpClient _http;

    /// <summary>Through the proxy by default; with a <paramref name="directToken"/>, straight to TMDB (tests only).</summary>
    public TMDBClient(Uri? proxy = null, string? directToken = null, HttpClient? http = null)
    {
        _token = directToken;
        _proxy = directToken is null ? proxy ?? ProxyUrl : null;
        _http = http ?? SiteClient.Http;
    }

    // MARK: Requests

    internal sealed class SearchPage
    {
        public sealed class Result
        {
            [JsonPropertyName("id")] public int Id { get; set; }
            [JsonPropertyName("title")] public string Title { get; set; } = "";
            [JsonPropertyName("original_title")] public string OriginalTitle { get; set; } = "";
            [JsonPropertyName("release_date")] public string? ReleaseDate { get; set; }
            [JsonPropertyName("overview")] public string? Overview { get; set; }
            [JsonPropertyName("poster_path")] public string? PosterPath { get; set; }
            [JsonPropertyName("popularity")] public double? Popularity { get; set; }
        }
        [JsonPropertyName("results")] public List<Result> Results { get; set; } = [];
    }

    internal sealed class Details
    {
        public sealed class CreditsData
        {
            public sealed class Person
            {
                [JsonPropertyName("name")] public string Name { get; set; } = "";
                [JsonPropertyName("job")] public string? Job { get; set; }
            }
            [JsonPropertyName("cast")] public List<Person> Cast { get; set; } = [];
            [JsonPropertyName("crew")] public List<Person> Crew { get; set; } = [];
        }
        [JsonPropertyName("id")] public int Id { get; set; }
        [JsonPropertyName("title")] public string Title { get; set; } = "";
        [JsonPropertyName("original_title")] public string OriginalTitle { get; set; } = "";
        [JsonPropertyName("release_date")] public string? ReleaseDate { get; set; }
        [JsonPropertyName("overview")] public string? Overview { get; set; }
        [JsonPropertyName("poster_path")] public string? PosterPath { get; set; }
        [JsonPropertyName("credits")] public CreditsData? Credits { get; set; }
    }

    /// <summary>Spaces requests out over the whole app: the proxy lets each visitor make 120 a minute, and one film can
    /// take ten (a title not found at once is searched in two languages, candidates checked).</summary>
    private static class Pacer
    {
        private static readonly TimeSpan Gap = TimeSpan.FromMilliseconds(600);
        private static readonly object Lock = new();
        private static DateTime _next = DateTime.MinValue;

        public static async Task WaitAsync(CancellationToken cancel)
        {
            TimeSpan wait;
            lock (Lock)
            {
                var now = DateTime.UtcNow;
                var slot = now > _next ? now : _next;
                _next = slot + Gap;
                wait = slot - now;
            }
            if (wait > TimeSpan.Zero) await Task.Delay(wait, cancel);
        }
    }

    internal async Task<T> GetAsync<T>(string path, IEnumerable<KeyValuePair<string, string>> parameters, CancellationToken cancel = default)
    {
        var sorted = parameters.OrderBy(p => p.Key, StringComparer.Ordinal).ToList();
        Uri url;
        if (_proxy is not null)
        {
            await Pacer.WaitAsync(cancel);
            var query = new[] { new KeyValuePair<string, string>("path", path) }.Concat(sorted);
            url = new UriBuilder(_proxy) { Query = Query(query) }.Uri;
        }
        else
        {
            url = new UriBuilder("https://api.themoviedb.org/3/" + path) { Query = Query(sorted) }.Uri;
        }
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        if (_token is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _token);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        using var response = await _http.SendAsync(request, timeout.Token);
        var status = (int)response.StatusCode;
        if (status != 200) throw SiteException.Http(status);
        await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
        return await JsonSerializer.DeserializeAsync<T>(stream, CoreJson.Options, timeout.Token)
               ?? throw SiteException.Unreadable();
    }

    private static string Query(IEnumerable<KeyValuePair<string, string>> pairs) =>
        string.Join("&", pairs.Select(p => $"{Uri.EscapeDataString(p.Key)}={Uri.EscapeDataString(p.Value)}"));

    private static KeyValuePair<string, string> P(string key, string value) => new(key, value);

    // MARK: Matching

    /// <summary>The film Dayez means by <paramref name="title"/> in an episode recorded on <paramref name="date"/>.
    /// <paramref name="hints"/> is the episode's description, which often names the director or an actor ("Wicker avec
    /// Olivia Colman"): when it does, the candidate whose credits contain that name wins. Null when nothing fits.</summary>
    public async Task<FilmInfo?> FilmAsync(string title, DateTime date, string hints, CancellationToken cancel = default)
    {
        // French titles first; then English ones, for a film known here by its English name ("The Blue Trail").
        foreach (var language in new[] { "fr-FR", "en-US" })
        {
            if (await FilmAsync(title, date, hints, language, cancel) is { } info) return info;
        }
        return null;
    }

    private async Task<FilmInfo?> FilmAsync(string title, DateTime date, string hints, string language, CancellationToken cancel)
    {
        var page = await GetAsync<SearchPage>("search/movie",
            [P("query", title), P("language", language), P("include_adult", "false")], cancel);
        var ranked = Rank(page.Results, title, date);
        if (ranked.Count == 0) return null;

        var foldedHints = Search.Fold(hints);
        var chosen = ranked[0];
        if (foldedHints.Length > 0)
        {
            foreach (var candidate in ranked.Take(3))
            {
                var details = await GetAsync<Details>($"movie/{candidate.Id}",
                    [P("language", "fr-FR"), P("append_to_response", "credits")], cancel);
                if (Names(details).Any(n => foldedHints.Contains(Search.Fold(n), StringComparison.Ordinal)))
                    return Info(details);
            }
        }
        // No name to go by (or none matched): the best-ranked one, if it's a clear fit.
        if (!IsConfident(chosen, title, date)) return null;
        return Info(await GetAsync<Details>($"movie/{chosen.Id}",
            [P("language", "fr-FR"), P("append_to_response", "credits")], cancel));
    }

    /// <summary>Candidates released close to the episode, best first: same title, then release nearest the episode.</summary>
    internal static List<SearchPage.Result> Rank(IEnumerable<SearchPage.Result> results, string query, DateTime around)
    {
        var scored = new List<(SearchPage.Result Result, double Score)>();
        foreach (var result in results)
        {
            if (ReleaseDate(result.ReleaseDate) is not { } released) continue;
            var days = (around - released).TotalDays;
            // Reviewed in the weeks around the release in Belgium; festival dates can be a year or two earlier.
            if (days <= -120 || days >= 900) continue;
            // The same title outweighs everything else: "Chopin, Chopin!" isn't "Chopin", however near its date.
            var similarity = Similarity(query, [result.Title, result.OriginalTitle]);
            double score = similarity == 10 ? 20 : similarity;
            score += Math.Max(0, 6 - Math.Abs(days) / 60);                 // the nearer the release, the better
            score += Math.Min(2, (result.Popularity ?? 0) / 20);
            scored.Add((result, score));
        }
        return scored.OrderByDescending(s => s.Score).Select(s => s.Result).ToList();
    }

    /// <summary>10 the same title, 6 every word of it starts a word of theirs ("Miroirs n°3" and "Miroirs No. 3",
    /// "Downton Abbey, le grand final" and "Downton Abbey III : Le Grand Final"), 3 one inside the other, 0 else.</summary>
    internal static int Similarity(string query, IEnumerable<string> titles)
    {
        var wanted = Search.Fold(query);
        var compact = wanted.Replace(" ", "");
        var best = 0;
        foreach (var title in titles.Select(Search.Fold))
        {
            if (title == wanted || title.Replace(" ", "") == compact) return 10;
            var theirs = title.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (wanted.Split(' ', StringSplitOptions.RemoveEmptyEntries).All(word => theirs.Any(t => t.StartsWith(word, StringComparison.Ordinal))))
                best = Math.Max(best, 6);
            else if (title.Contains(wanted, StringComparison.Ordinal) || wanted.Contains(title, StringComparison.Ordinal))
                best = Math.Max(best, 3);
        }
        return best;
    }

    internal static bool IsConfident(SearchPage.Result result, string query, DateTime around)
    {
        if (Similarity(query, [result.Title, result.OriginalTitle]) < 6) return false;
        if (ReleaseDate(result.ReleaseDate) is not { } released) return false;
        return Math.Abs((around - released).TotalSeconds) < 400 * 86_400;
    }

    internal static List<string> Names(Details details)
    {
        var crew = details.Credits?.Crew.Where(c => c.Job == "Director").Select(c => c.Name) ?? [];
        var cast = details.Credits?.Cast.Take(10).Select(c => c.Name) ?? [];
        return crew.Concat(cast).ToList();
    }

    internal static FilmInfo Info(Details details) => new()
    {
        TmdbId = details.Id,
        Title = details.Title,
        OriginalTitle = details.OriginalTitle,
        Year = ReleaseDate(details.ReleaseDate) is { } d ? EpisodeDates.Year(d) : null,
        Overview = details.Overview ?? "",
        PosterPath = details.PosterPath,
        Director = details.Credits?.Crew.FirstOrDefault(c => c.Job == "Director")?.Name,
    };

    internal static DateTime? ReleaseDate(string? text) =>
        text is { Length: >= 10 } ? EpisodeDates.ParseIso(text[..10]) : null;
}

/// <summary>Films already looked up, saved between launches so each is asked about once.</summary>
public sealed class FilmLibrary
{
    public sealed record Entry(
        [property: JsonPropertyName("info")] FilmInfo? Info,
        [property: JsonPropertyName("checked")] DateTime Checked);

    private sealed class Stored
    {
        [JsonPropertyName("entries")] public Dictionary<string, Entry> Entries { get; set; } = [];
    }

    public Dictionary<string, Entry> Entries { get; private set; } = [];

    /// <summary>The key every Mac and Windows copy agrees on: the folded title and the year it was discussed.</summary>
    public static string Key(string title, DateTime date) => $"{Search.Fold(title)}|{EpisodeDates.Year(date)}";

    public FilmInfo? Info(string title, DateTime date) => Entries.GetValueOrDefault(Key(title, date))?.Info;

    /// <summary>Whether the film was looked up, found or not.</summary>
    public bool Knows(string title, DateTime date) => Entries.ContainsKey(Key(title, date));

    /// <summary>Not looked up yet, or not found a while ago. TMDB fills in new releases over their first days, so a film
    /// from the last two months is asked about again after 6 hours; an older one after a week.</summary>
    public bool NeedsLookup(string title, DateTime date, DateTime? now = null)
    {
        var at = now ?? DateTime.UtcNow;
        if (!Entries.TryGetValue(Key(title, date), out var entry)) return true;
        if (entry.Info is not null) return false;
        var recent = (at - date).TotalSeconds < 60 * 86_400;
        return (at - entry.Checked).TotalSeconds > (recent ? 6 * 3600 : 7 * 86_400);
    }

    public void Record(FilmInfo? info, string title, DateTime date, DateTime? now = null) =>
        Entries[Key(title, date)] = new Entry(info, now ?? DateTime.UtcNow);

    /// <summary>Takes what <paramref name="other"/> knows and this library doesn't (the films shipped with the app, say):
    /// films found, and titles not found. Returns whether it took any.</summary>
    public bool Adopt(FilmLibrary other)
    {
        var took = false;
        foreach (var (key, entry) in other.Entries)
        {
            if (!Entries.TryGetValue(key, out var mine) || (entry.Info is not null && mine.Info is null))
            {
                Entries[key] = entry;
                took = true;
            }
        }
        return took;
    }

    /// <summary>The episode with each film it names replaced by what TMDB knows: the archive's title format (so it links
    /// up with 5heures.be's own reviews of it), a poster, a synopsis and its director.</summary>
    public Episode Enrich(Episode episode)
    {
        if (episode.Series != Series.Dayez) return episode;
        var spoken = episode.SpokenFilms;
        var segments = episode.Segments.Select((segment, index) =>
        {
            var name = index < spoken.Count ? spoken[index] : segment.Title;
            if (Info(name, episode.Date) is not { } info) return segment;
            return new Segment(segment.Id, info.ArchiveTitle, SegmentKind.Movie, segment.Start, null, null, info.PosterUrl,
                               info.Overview.Length == 0 ? null : info.Overview, info.Director,
                               info.Title == info.OriginalTitle ? null : info.Title);
        }).ToList();
        return episode with { Segments = segments };
    }

    public static FilmLibrary Load(string? path = null) => Load(File.Exists(path ?? AppPaths.Films) ? File.OpenRead(path ?? AppPaths.Films) : null);

    public static FilmLibrary Load(Stream? stream)
    {
        if (stream is null) return new FilmLibrary();
        try
        {
            using (stream)
            {
                var stored = JsonSerializer.Deserialize<Stored>(stream, CoreJson.Options);
                return new FilmLibrary { Entries = stored?.Entries ?? [] };
            }
        }
        catch (Exception) { return new FilmLibrary(); }
    }

    public void Save(string? path = null) =>
        CoreJson.SaveAtomically(path ?? AppPaths.Films,
            stream => JsonSerializer.Serialize(stream, new Stored { Entries = Entries }, CoreJson.Options));
}
