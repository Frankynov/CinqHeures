using System.Globalization;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace CinqHeures.Core;

/// <summary>The shows 5heures.be publishes, named the way the site's API names them, and the two that come as
/// podcast feeds. The order of the cases is the sidebar's order.</summary>
public enum Series { Podcast, QuelquePart, Dayez, CodLive, Soir, Autre }

public static class SeriesInfo
{
    public static readonly IReadOnlyList<Series> All =
        [Series.Podcast, Series.QuelquePart, Series.Dayez, Series.CodLive, Series.Soir, Series.Autre];

    /// <summary>The shows read from a podcast feed rather than from 5heures.be.</summary>
    public static readonly IReadOnlyList<Series> FromFeeds = [Series.QuelquePart, Series.Dayez];

    public static string Raw(this Series s) => s switch
    {
        Series.Podcast => "cinq_heures",
        Series.QuelquePart => "ausha_quelque_part",
        Series.Dayez => "feed_dayez",
        Series.CodLive => "cod_live",
        Series.Soir => "cinq_heures_du_soir",
        _ => "other",
    };

    public static Series? FromRaw(string? raw) => raw switch
    {
        "cinq_heures" => Series.Podcast,
        "ausha_quelque_part" => Series.QuelquePart,
        "feed_dayez" => Series.Dayez,
        "cod_live" => Series.CodLive,
        "cinq_heures_du_soir" => Series.Soir,
        "other" => Series.Autre,
        _ => null,
    };

    public static string Title(this Series s) => s switch
    {
        Series.Podcast => "Podcast",
        Series.Soir => "5 heures du soir",
        Series.CodLive => "COD Live",
        Series.Autre => "Autre",
        Series.QuelquePart => "Il est toujours 5 heures quelque part",
        _ => "Hugues Dayez",
    };

    /// <summary>Who makes it, for the shows that aren't 5heures.be's own.</summary>
    public static string? Host(this Series s) => s switch
    {
        Series.QuelquePart => "Rudy Léonet",
        Series.Dayez => "Hugues Dayez",
        _ => null,
    };

    /// <summary>Short label for the badge in a list row.</summary>
    public static string Badge(this Series s) => s switch
    {
        Series.Podcast => "Podcast",
        Series.Soir => "5H du soir",
        Series.CodLive => "COD Live",
        Series.Autre => "Autre",
        Series.QuelquePart => "Quelque part",
        _ => "Dayez",
    };

    public static string FullTitle(this Series s) => s switch
    {
        Series.QuelquePart => "Il est toujours 5 heures quelque part",
        Series.Dayez => "Les critiques d'Hugues Dayez",
        _ => s.Title(),
    };

    /// <summary>Whether the audio comes from 5heures.be's own (slow when cold) server.</summary>
    public static bool IsOnSite(this Series s) => s != Series.QuelquePart && s != Series.Dayez;
}

public enum SegmentKind { Introduction, Movie, Conclusion, Other, Person, TvShow }

public static class SegmentKindInfo
{
    public static string Raw(this SegmentKind k) => k switch
    {
        SegmentKind.Introduction => "introduction",
        SegmentKind.Movie => "movie",
        SegmentKind.Conclusion => "conclusion",
        SegmentKind.Person => "person",
        SegmentKind.TvShow => "tv_show",
        _ => "other",
    };

    public static SegmentKind? FromRaw(string? raw) => raw switch
    {
        "introduction" => SegmentKind.Introduction,
        "movie" => SegmentKind.Movie,
        "conclusion" => SegmentKind.Conclusion,
        "other" => SegmentKind.Other,
        "person" => SegmentKind.Person,
        "tv_show" => SegmentKind.TvShow,
        _ => null,
    };

    /// <summary>Films, series and people are what you look up; the rest is the show's own chatter.</summary>
    public static bool IsSubject(this SegmentKind k) => k is SegmentKind.Movie or SegmentKind.TvShow or SegmentKind.Person;

    public static string Label(this SegmentKind k) => k switch
    {
        SegmentKind.Movie => "Film",
        SegmentKind.TvShow => "Série",
        SegmentKind.Person => "Personnalité",
        SegmentKind.Introduction => "Introduction",
        SegmentKind.Conclusion => "Conclusion",
        _ => "Divers",
    };
}

/// <summary>One thing discussed in an episode: a film, a series, a person, the intro…</summary>
public sealed record Segment
{
    // Ids are 64-bit: the "Autre" specials' segments are numbered below -3,000,000,000.
    [JsonPropertyName("id")] public long Id { get; init; }
    [JsonPropertyName("title")] public string Title { get; init; } = "";
    [JsonPropertyName("kind")] public SegmentKind Kind { get; init; }
    /// <summary>Where it starts in the episode's audio. Missing for a few old entries.</summary>
    [JsonPropertyName("start")] public double? Start { get; init; }
    /// <summary>The hosts' verdict in their own words ("4 bonnes doses"): only the number means anything.</summary>
    [JsonPropertyName("verdict")] public string? Verdict { get; init; }
    /// <summary>That number, 0 to 4. Missing before 2011 and when they didn't give one.</summary>
    [JsonPropertyName("score")] public double? Score { get; init; }
    [JsonPropertyName("posterURL")] public Uri? PosterUrl { get; init; }
    /// <summary>From TMDB, for films that don't come from 5heures.be.</summary>
    [JsonPropertyName("overview")] public string? Overview { get; init; }
    [JsonPropertyName("director")] public string? Director { get; init; }
    [JsonPropertyName("localTitle")] public string? LocalTitle { get; init; }
    /// <summary>The film's page on 5heures.be (<c>/api/movies/slug</c>), which has its synopsis.</summary>
    [JsonPropertyName("slug")] public string? Slug { get; init; }

    public Segment() { }

    public Segment(long id, string title, SegmentKind kind, double? start, string? verdict, double? score = null,
                   Uri? posterUrl = null, string? overview = null, string? director = null, string? localTitle = null,
                   string? slug = null)
    {
        Id = id; Title = title; Kind = kind; Start = start; Verdict = verdict; Score = score; PosterUrl = posterUrl;
        Overview = overview; Director = director; LocalTitle = localTitle; Slug = slug;
    }

    /// <summary>The release year at the end of a film's title: "Oblivion (2013)" is 2013.</summary>
    [JsonIgnore] public int? Year => TrailingYear(Title, out var year, out _) ? year : null;

    /// <summary>The title without that year.</summary>
    [JsonIgnore]
    public string DisplayTitle
    {
        get
        {
            if (!TrailingYear(Title, out _, out var start)) return Title;
            var end = start;
            while (end > 0 && char.IsWhiteSpace(Title[end - 1])) end--;
            return Title[..end];
        }
    }

    /// <summary>"(dddd)" closing a title, spaces after it allowed: the year, and where its "(" is. Read by hand, from
    /// the end: the shelves and listings ask for it thousands of times.</summary>
    internal static bool TrailingYear(string title, out int year, out int start)
    {
        year = 0; start = 0;
        var i = title.Length;
        while (i > 0 && char.IsWhiteSpace(title[i - 1])) i--;
        if (i == 0 || title[i - 1] != ')') return false;
        i--;
        var scale = 1;
        for (var n = 0; n < 4; n++)
        {
            if (i == 0) return false;
            var c = title[i - 1];
            if (c < '0' || c > '9') return false;
            year += (c - '0') * scale;
            scale *= 10;
            i--;
        }
        if (i == 0 || title[i - 1] != '(') return false;
        start = i - 1;
        return true;
    }

    /// <summary>The score as whole stars, 0 to 4.</summary>
    [JsonIgnore] public int? Stars => Score is { } s ? (int)Math.Floor(Math.Min(Math.Max(s, 0), 4)) : null;

    /// <summary>The verdict without the "Pas de cotation" placeholder.</summary>
    [JsonIgnore] public string? SpokenVerdict => Verdict is null or "Pas de cotation" ? null : Verdict;

    /// <summary>"4", "1,5" and "3 porte-avions" are all scores; "Pas de cotation" and "" aren't.</summary>
    public static double? ParseScore(string? text)
    {
        if (text is null) return null;
        var m = ScorePattern.Match(text);
        if (!m.Success) return null;
        return double.TryParse(m.Value.Trim().Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : null;
    }

    private static readonly Regex ScorePattern = new(@"^\s*[0-9]+(?:[.,][0-9]+)?", RegexOptions.Compiled);

    /// <summary>"★★★☆" for 3.</summary>
    public static string StarString(int stars) => new string('★', stars) + new string('☆', Math.Max(0, 4 - stars));

    /// <summary>The same segment, starting at <paramref name="start"/>.</summary>
    internal Segment Starting(double? start) => this with { Start = start };
}

public sealed record Episode
{
    [JsonPropertyName("id")] public long Id { get; init; }
    [JsonPropertyName("series")] public Series Series { get; init; }
    /// <summary>The day it was recorded, which is what the site's title says ("Podcast du 27/06/2025").</summary>
    [JsonPropertyName("date")] public DateTime Date { get; init; }
    [JsonPropertyName("summary")] public string Summary { get; init; } = "";
    [JsonPropertyName("audioURL")] public Uri AudioUrl { get; init; } = new("about:blank");
    [JsonPropertyName("segments")] public IReadOnlyList<Segment> Segments { get; init; } = [];
    /// <summary>The episode's own title, for shows whose episodes have one.</summary>
    [JsonPropertyName("name")] public string? Name { get; init; }
    /// <summary>A square cover, for shows that have one instead of film posters.</summary>
    [JsonPropertyName("artwork")] public Uri? Artwork { get; init; }
    /// <summary>Length in seconds, when the source says.</summary>
    [JsonPropertyName("duration")] public double? Duration { get; init; }

    public Episode() { }

    public Episode(long id, Series series, DateTime date, string summary, Uri audioUrl, IReadOnlyList<Segment> segments,
                   string? name = null, Uri? artwork = null, double? duration = null)
    {
        Id = id; Series = series; Date = date; Summary = summary; AudioUrl = audioUrl; Segments = segments;
        Name = name; Artwork = artwork; Duration = duration;
    }

    [JsonIgnore] public string Title => Name ?? $"{Series.Title()} du {EpisodeDates.Short(Date)}";

    /// <summary>For a Dayez episode, the films as its title names them ("Coward · Wicker · Karma"), whatever its
    /// segments have since been renamed to: what TMDB lookups are keyed by.</summary>
    [JsonIgnore]
    public IReadOnlyList<string> SpokenFilms =>
        Series == Series.Dayez && Segments.Count > 0 && Name is not null ? Name.Split(" · ") : [];

    /// <summary>The films, series and people, in the order they're discussed.</summary>
    [JsonIgnore] public IEnumerable<Segment> Subjects => Segments.Where(s => s.Kind.IsSubject());

    [JsonIgnore] public int Year => EpisodeDates.Year(Date);

    public bool Equals(Episode? other) =>
        other is not null && Id == other.Id && Series == other.Series && Date == other.Date && Summary == other.Summary
        && AudioUrl == other.AudioUrl && Name == other.Name && Artwork == other.Artwork && Duration == other.Duration
        && Segments.SequenceEqual(other.Segments);

    public override int GetHashCode() => HashCode.Combine(Id, Series, Date, Name);
}

/// <summary>Dates in the shows' own time zone and language.</summary>
public static class EpisodeDates
{
    public static readonly TimeZoneInfo Zone = FindZone();
    public static readonly CultureInfo Culture = FindCulture();

    private static TimeZoneInfo FindZone()
    {
        foreach (var id in new[] { "Europe/Brussels", "Romance Standard Time" })
        {
            try { return TimeZoneInfo.FindSystemTimeZoneById(id); } catch (Exception) { }
        }
        return TimeZoneInfo.Utc;
    }

    private static CultureInfo FindCulture()
    {
        try { return CultureInfo.GetCultureInfo("fr-BE"); } catch (Exception) { return CultureInfo.GetCultureInfo("fr"); }
    }

    public static DateTime ToLocal(DateTime utc) =>
        TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(utc, DateTimeKind.Utc), Zone);

    /// <summary>The instant a Brussels wall-clock time is.</summary>
    public static DateTime FromLocal(DateTime local) =>
        TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(local, DateTimeKind.Unspecified), Zone);

    public static int Year(DateTime utc) => ToLocal(utc).Year;

    /// <summary>"27/06/2025".</summary>
    public static string Short(DateTime utc) => ToLocal(utc).ToString("dd/MM/yyyy", CultureInfo.InvariantCulture);

    /// <summary>"vendredi 27 juin 2025".</summary>
    public static string Long(DateTime utc) => ToLocal(utc).ToString("dddd d MMMM yyyy", Culture);

    /// <summary>"27/06/2025" → that day, in Brussels.</summary>
    public static DateTime? ParseShort(string text) =>
        DateTime.TryParseExact(text, "dd/MM/yyyy", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? FromLocal(d) : null;

    public static DateTime? ParseIso(string text) =>
        DateTime.TryParseExact(text, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? FromLocal(d) : null;
}
