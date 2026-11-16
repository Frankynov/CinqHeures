using System.Text.Json;
using System.Text.Json.Serialization;

namespace CinqHeures.Core;

/// <summary>Where a film or series can be watched in a country: the streaming services that include it, else the free
/// ones, else where to rent it. TMDB's data, from JustWatch (who must be credited).</summary>
public sealed record Streaming(StreamingKind Kind, IReadOnlyList<Streaming.Service> Services, Uri? Link)
{
    public sealed record Service(string Name, string? LogoPath)
    {
        public Uri? LogoUrl => LogoPath is null ? null : new Uri("https://image.tmdb.org/t/p/w92" + LogoPath);
    }
}

public enum StreamingKind { Subscription, Free, Rent }

/// <summary>What a film or series page shows beyond its reviews, for titles 5heures.be discusses: a synopsis, the French
/// title, the director. Dayez's films get theirs from TMDB along with their posters (<see cref="FilmInfo"/>).</summary>
public sealed record WorkDetails
{
    /// <summary>"site": the film's page on 5heures.be. "tmdb": a TMDB search, for series: the site has no page for them.</summary>
    [JsonPropertyName("overview")] public string Overview { get; init; } = "";
    /// <summary>The French title, when it isn't the one 5heures.be uses.</summary>
    [JsonPropertyName("localTitle")] public string? LocalTitle { get; init; }
    [JsonPropertyName("director")] public string? Director { get; init; }
    [JsonPropertyName("source")] public string Source { get; init; } = "site";

    public bool FromTmdb => Source == "tmdb";

    /// <summary>Which details a work has, if any can be looked up: a film by its page on the site, a series by name.</summary>
    public static string? KeyFor(Work work) => work.Kind switch
    {
        SegmentKind.Movie => work.Mentions.Select(m => m.Segment.Slug).FirstOrDefault(s => s is not null) is { } slug
            ? "movie:" + slug : null,
        SegmentKind.TvShow => "tv:" + Search.Fold(work.Mentions.FirstOrDefault()?.Segment.DisplayTitle ?? work.Title),
        _ => null,
    };
}

public static class SiteClientDetailsExtensions
{
    private sealed class MoviePage
    {
        public sealed class MovieData
        {
            public sealed class PersonData
            {
                public sealed class JobData { [JsonPropertyName("name")] public string? Name { get; set; } }
                [JsonPropertyName("name")] public string? Name { get; set; }
                [JsonPropertyName("job")] public JobData? Job { get; set; }
            }
            [JsonPropertyName("name")] public string? Name { get; set; }
            [JsonPropertyName("name_fr")] public string? NameFr { get; set; }
            [JsonPropertyName("overview")] public string? Overview { get; set; }
            [JsonPropertyName("people")] public List<PersonData>? People { get; set; }
        }
        [JsonPropertyName("movie")] public MovieData Movie { get; set; } = new();
    }

    /// <summary>A film's synopsis, French title and director, from its page on the site. Null when the page has no synopsis.</summary>
    public static async Task<WorkDetails?> MovieDetailsAsync(this SiteClient client, string slug, CancellationToken cancel = default) =>
        FromMoviePage(await client.GetAsync("api/movies/" + Uri.EscapeDataString(slug), [], cancel));

    internal static WorkDetails? FromMoviePage(byte[] data)
    {
        MoviePage.MovieData movie;
        try { movie = JsonSerializer.Deserialize<MoviePage>(data, CoreJson.Options)?.Movie ?? throw new JsonException(); }
        catch (JsonException) { return null; }
        var overview = movie.Overview?.Trim();
        if (string.IsNullOrEmpty(overview)) return null;
        var directors = (movie.People ?? []).Where(p => p.Job?.Name == "Director").Select(p => p.Name).OfType<string>().ToList();
        var local = string.IsNullOrEmpty(movie.NameFr) || movie.NameFr == movie.Name ? null : movie.NameFr;
        return new WorkDetails
        {
            Overview = overview, LocalTitle = local, Source = "site",
            Director = directors.Count == 0 ? null : string.Join(" et ", directors.Take(2)),
        };
    }
}

public sealed partial class TMDBClient
{
    internal sealed class ProvidersPage
    {
        public sealed class Country
        {
            [JsonPropertyName("link")] public string? Link { get; set; }
            [JsonPropertyName("flatrate")] public List<Provider>? Flatrate { get; set; }
            [JsonPropertyName("free")] public List<Provider>? Free { get; set; }
            [JsonPropertyName("ads")] public List<Provider>? Ads { get; set; }
            [JsonPropertyName("rent")] public List<Provider>? Rent { get; set; }
        }
        public sealed class Provider
        {
            [JsonPropertyName("provider_name")] public string ProviderName { get; set; } = "";
            [JsonPropertyName("logo_path")] public string? LogoPath { get; set; }
            [JsonPropertyName("display_priority")] public int? DisplayPriority { get; set; }
        }
        [JsonPropertyName("results")] public Dictionary<string, Country> Results { get; set; } = [];
    }

    internal sealed class SeriesPage
    {
        public sealed class Result
        {
            [JsonPropertyName("id")] public int Id { get; set; }
            [JsonPropertyName("name")] public string Name { get; set; } = "";
            [JsonPropertyName("original_name")] public string OriginalName { get; set; } = "";
            [JsonPropertyName("first_air_date")] public string? FirstAirDate { get; set; }
            [JsonPropertyName("overview")] public string? Overview { get; set; }
            [JsonPropertyName("popularity")] public double? Popularity { get; set; }
        }
        [JsonPropertyName("results")] public List<Result> Results { get; set; } = [];
    }

    /// <summary>The TMDB id of a film 5heures.be calls <paramref name="title"/> (its original title, as a rule), released around <paramref name="year"/>.</summary>
    public async Task<int?> MovieIdAsync(string title, int? year, CancellationToken cancel = default)
    {
        var page = await GetAsync<SearchPage>("search/movie",
            [P("query", title), P("language", "fr-FR"), P("include_adult", "false")], cancel);
        return MovieIdIn(page, title, year);
    }

    internal static int? MovieIdIn(SearchPage page, string title, int? year)
    {
        var fitting = page.Results.Where(r =>
        {
            if (Similarity(title, [r.Title, r.OriginalTitle]) != 10) return false;
            if (year is null) return true;
            return ReleaseDate(r.ReleaseDate) is { } released && Math.Abs(EpisodeDates.Year(released) - year.Value) <= 1;
        }).ToList();
        return fitting.Count == 0 ? null : fitting.MaxBy(r => r.Popularity ?? 0)!.Id;
    }

    /// <summary>The TMDB id of a series of that exact name that had started by the time it was discussed.</summary>
    public async Task<int?> SeriesIdAsync(string title, DateTime discussedOn, CancellationToken cancel = default)
    {
        var page = await GetAsync<SeriesPage>("search/tv",
            [P("query", title), P("language", "fr-FR"), P("include_adult", "false")], cancel);
        var fitting = page.Results.Where(r => Similarity(title, [r.Name, r.OriginalName]) == 10
            && ReleaseDate(r.FirstAirDate) is { } started && started < discussedOn.AddDays(60)).ToList();
        return fitting.Count == 0 ? null : fitting.MaxBy(r => r.Popularity ?? 0)!.Id;
    }

    /// <summary>Where the film (<paramref name="series"/> false) or series with that TMDB id can be watched in
    /// <paramref name="region"/> ("BE").</summary>
    public async Task<Streaming?> StreamingAsync(int id, bool series, string region, CancellationToken cancel = default) =>
        StreamingIn(await GetAsync<ProvidersPage>($"{(series ? "tv" : "movie")}/{id}/watch/providers", [], cancel), region);

    internal static Streaming? StreamingIn(ProvidersPage page, string region)
    {
        if (!page.Results.TryGetValue(region, out var country)) return null;
        var choices = new (StreamingKind, List<ProvidersPage.Provider>)[]
        {
            (StreamingKind.Subscription, country.Flatrate ?? []),
            (StreamingKind.Free, (country.Free ?? []).Concat(country.Ads ?? []).ToList()),
            (StreamingKind.Rent, country.Rent ?? []),
        };
        var chosen = choices.FirstOrDefault(c => c.Item2.Count > 0);
        if (chosen.Item2 is null) return null;
        // One line each: "Netflix", not also "Netflix Standard with Ads"; "Prime Video", not its channels too.
        var seen = new HashSet<string>();
        var services = chosen.Item2
            .OrderBy(p => p.DisplayPriority ?? int.MaxValue)
            .Where(p => !p.ProviderName.Contains("with ads", StringComparison.OrdinalIgnoreCase)
                        && !p.ProviderName.EndsWith("Amazon Channel", StringComparison.Ordinal))
            .Where(p => seen.Add(Search.Fold(p.ProviderName)))
            .Take(3)
            .Select(p => new Streaming.Service(p.ProviderName, p.LogoPath))
            .ToList();
        if (services.Count == 0) return null;
        return new Streaming(chosen.Item1, services,
            country.Link is not null && Uri.TryCreate(country.Link, UriKind.Absolute, out var link) ? link : null);
    }

    /// <summary>The series 5heures.be calls <paramref name="title"/>, discussed on <paramref name="date"/>: one of the same
    /// name that had started by then (a series is reviewed at any season). Null when none fits or it has no French synopsis.</summary>
    public async Task<WorkDetails?> SeriesDetailsAsync(string title, DateTime date, CancellationToken cancel = default)
    {
        var page = await GetAsync<SeriesPage>("search/tv",
            [P("query", title), P("language", "fr-FR"), P("include_adult", "false")], cancel);
        return SeriesIn(page, title, date);
    }

    internal static WorkDetails? SeriesIn(SeriesPage page, string title, DateTime date)
    {
        var fitting = page.Results.Where(r => Similarity(title, [r.Name, r.OriginalName]) == 10
            && ReleaseDate(r.FirstAirDate) is { } started && started < date.AddDays(60)).ToList();
        if (fitting.Count == 0) return null;
        var chosen = fitting.MaxBy(r => r.Popularity ?? 0)!;
        var overview = chosen.Overview?.Trim();
        if (string.IsNullOrEmpty(overview)) return null;
        var local = chosen.Name == chosen.OriginalName || Search.Fold(chosen.Name) == Search.Fold(title) ? null : chosen.Name;
        return new WorkDetails { Overview = overview, LocalTitle = local, Source = "tmdb" };
    }
}

/// <summary>The details found so far, by <see cref="WorkDetails.KeyFor"/>, kept between launches. A title is looked up when
/// its page is opened; one with nothing to show is asked about again after a week.</summary>
public sealed class WorkDetailsLibrary
{
    public sealed record Entry(
        [property: JsonPropertyName("details")] WorkDetails? Details,
        [property: JsonPropertyName("checked")] DateTime Checked);

    private sealed class Stored
    {
        [JsonPropertyName("entries")] public Dictionary<string, Entry> Entries { get; set; } = [];
    }

    public Dictionary<string, Entry> Entries { get; private set; } = [];

    public WorkDetails? Details(string key) => Entries.GetValueOrDefault(key)?.Details;

    public bool NeedsLookup(string key, DateTime? now = null)
    {
        if (!Entries.TryGetValue(key, out var entry)) return true;
        return entry.Details is null && ((now ?? DateTime.UtcNow) - entry.Checked).TotalSeconds > 7 * 86_400;
    }

    public void Record(WorkDetails? details, string key, DateTime? now = null) =>
        Entries[key] = new Entry(details, now ?? DateTime.UtcNow);

    public static WorkDetailsLibrary Load(string? path = null)
    {
        try
        {
            using var stream = File.OpenRead(path ?? AppPaths.Details);
            return new WorkDetailsLibrary { Entries = JsonSerializer.Deserialize<Stored>(stream, CoreJson.Options)?.Entries ?? [] };
        }
        catch (Exception) { return new WorkDetailsLibrary(); }
    }

    public void Save(string? path = null) =>
        CoreJson.SaveAtomically(path ?? AppPaths.Details,
            stream => JsonSerializer.Serialize(stream, new Stored { Entries = Entries }, CoreJson.Options));
}
