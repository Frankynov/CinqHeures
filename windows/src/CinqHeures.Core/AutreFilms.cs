using System.Globalization;
using System.Text.RegularExpressions;

namespace CinqHeures.Core;

/// <summary>A film an "Autre" episode's description names: "La Main au collet (Alfred Hitchcock)".</summary>
public sealed record NamedFilm(string Title, IReadOnlyList<string> Directors, IReadOnlyList<string> Alternatives)
{
    public NamedFilm(string title, IReadOnlyList<string> directors) : this(title, directors, []) { }

    public bool Equals(NamedFilm? other) =>
        other is not null && Title == other.Title && Directors.SequenceEqual(other.Directors)
        && Alternatives.SequenceEqual(other.Alternatives);

    public override int GetHashCode() => Title.GetHashCode();
}

/// <summary>The "Autre" episodes (themed specials, summer shows) have no timecodes and no segments on 5heures.be, only a
/// description: "Thème : Monaco Cinéma : La Main au collet (Alfred Hitchcock), Le roman d'un tricheur (Sacha Guitry) et
/// La fille de Monaco (Anne Fontaine) Musique : …". Its films are read from there. Songs are left out.</summary>
public static class AutreProgramme
{
    /// <summary>Where a film list starts.</summary>
    private static readonly Regex FilmLabel = new(@"\b(cinéma|cinema|films?)\s*:", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    /// <summary>Where it stops at the latest: the next section.</summary>
    private static readonly Regex NextLabel = new(
        @"\b(musiques?|th[èe]me|thématique|bd|livres?|littérature|séries?(\s+télé)?|présentation|cinéma|cinema|films?)\s*:",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    public static List<NamedFilm> Films(string description)
    {
        var text = Cleaned(description);
        var films = new List<NamedFilm>();
        var searchFrom = 0;
        while (searchFrom <= text.Length && FilmLabel.Match(text, searchFrom) is { Success: true } label)
        {
            var upper = label.Index + label.Length;
            var next = NextLabel.Match(text, upper);
            var end = next.Success ? next.Index : text.Length;
            films.AddRange(List(text[upper..end]));
            searchFrom = Math.Max(end, upper);
            if (searchFrom >= text.Length) break;
        }
        // The same film twice in one description is one film.
        var seen = new HashSet<string>();
        return films.Where(f => seen.Add(Search.Fold(f.Title))).ToList();
    }

    /// <summary>Spaces and tabs only (not line breaks): Foundation's <c>.whitespaces</c>.</summary>
    private static string TrimSpaces(string s)
    {
        var start = 0;
        var end = s.Length;
        static bool Blank(char c) => c == '\t' || char.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;
        while (start < end && Blank(s[start])) start++;
        while (end > start && Blank(s[end - 1])) end--;
        return s[start..end];
    }

    private static readonly char[] QuoteChars = [' ', '«', '»', '“', '”', '"', '\'', '’'];

    /// <summary>"A (X), B (Y) et C (Z)": items until the one after "et", which ends a French list (songs sometimes follow
    /// without a label of their own).</summary>
    internal static List<NamedFilm> List(string section)
    {
        var films = new List<NamedFilm>();
        var rest = section;
        while (true)
        {
            var open = rest.IndexOf('(');
            if (open < 0) break;
            var close = rest.IndexOf(')', open);
            if (close < 0) break;
            var raw = TrimSpaces(rest[..open]);
            var inside = rest[(open + 1)..close];
            rest = rest[(close + 1)..];
            var last = false;
            if (films.Count == 0)
            {
                // The first title as it stands: the part after a comma is tried as well, below.
            }
            else if (raw.StartsWith(',') || raw.StartsWith(';'))
            {
                raw = TrimSpaces(raw[1..]);
            }
            else if (raw.StartsWith("et ", StringComparison.Ordinal))
            {
                raw = raw[3..]; last = true;
            }
            else if (raw.LastIndexOf(" et ", StringComparison.Ordinal) is var and && and >= 0)
            {
                // A remark between two films: "Le Triporteur (…) d'après le roman de René Fallet et René La Canne (…)".
                raw = raw[(and + 4)..]; last = true;
            }
            else if (raw.LastIndexOf(", ", StringComparison.Ordinal) is var comma && comma >= 0)
            {
                raw = raw[(comma + 2)..];
            }
            else break;

            var title = TrimSpaces(raw.Trim(QuoteChars));
            // A title can carry what came before it ("Simenon au cinéma, Mon père ce héros"): the part after its last
            // comma is tried too, after the whole ("Cousin, cousine").
            var lastComma = title.LastIndexOf(", ", StringComparison.Ordinal);
            var alternatives = lastComma >= 0 ? new List<string> { title[(lastComma + 2)..] } : [];
            var directors = inside.Replace(" & ", ", ").Replace(" et ", ", ")
                .Split(',').Select(TrimSpaces).Where(d => d.Length > 0).ToList();
            if (title.Length > 0 && title.Length <= 90 && directors.Count > 0)
                films.Add(new NamedFilm(title, directors, alternatives.Where(a => a != title).ToList()));
            if (last) break;
        }
        return films;
    }

    /// <summary>The site's descriptions come with HTML entities, sometimes encoded twice ("&amp;amp;"), and line breaks.</summary>
    internal static string Cleaned(string text)
    {
        for (var i = 0; i < 2; i++) text = text.Replace("&amp;", "&");
        foreach (var (entity, character) in new[] { ("&#39;", "'"), ("&quot;", "\""), ("&nbsp;", " "), ("&rsquo;", "’") })
            text = text.Replace(entity, character);
        return string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
    }
}

public static class AutreExtensions
{
    /// <summary>An "Autre" episode with the films its description names as its programme: no start (these episodes have no
    /// timecodes), each with TMDB's poster, synopsis and archive title once found, so it links up with the other passages
    /// about the same film. Other episodes are unchanged.</summary>
    public static Episode WithNamedFilms(this Episode episode, FilmLibrary library) =>
        episode.WithNamedFilms(AutreProgramme.Films(episode.Summary), library);

    /// <summary>The same, with the films already read from the description (reading all of them takes a while).</summary>
    public static Episode WithNamedFilms(this Episode episode, IReadOnlyList<NamedFilm> named, FilmLibrary library)
    {
        if (episode.Series != Series.Autre || !episode.Segments.All(s => s.Id < 0)) return episode;
        var programme = new List<Segment>();
        for (var index = 0; index < named.Count; index++)
        {
            var film = named[index];
            // Below zero, out of the way of the site's own ids; far from the feeds' (see FeedClient.StableId).
            var segmentId = -(3_000_000_000L + episode.Id * 100 + index);
            if (library.Info(film.Title, episode.Date) is not { } info)
            {
                // Not found on TMDB: most often not a film at all (a book's author in the brackets, a remark).
                if (library.Knows(film.Title, episode.Date)) continue;
                programme.Add(new Segment(segmentId, film.Title, SegmentKind.Movie, null, null, director: string.Join(" et ", film.Directors)));
                continue;
            }
            programme.Add(new Segment(segmentId, info.ArchiveTitle, SegmentKind.Movie, null, null, null, info.PosterUrl,
                                      info.Overview.Length == 0 ? null : info.Overview, info.Director,
                                      info.Title == info.OriginalTitle ? null : info.Title));
        }
        return programme.SequenceEqual(episode.Segments) ? episode : episode with { Segments = programme };
    }
}

public sealed partial class TMDBClient
{
    /// <summary>The film an "Autre" description names: one of that title made by the director in brackets (a misspelt
    /// surname still counts). These are classics as often as new films, so no date limit.</summary>
    public async Task<FilmInfo?> FilmAsync(NamedFilm film, CancellationToken cancel = default)
    {
        foreach (var language in new[] { "fr-FR", "en-US" })
        {
            foreach (var title in new[] { film.Title }.Concat(film.Alternatives))
            {
                var page = await GetAsync<SearchPage>("search/movie",
                    [P("query", title), P("language", language), P("include_adult", "false")], cancel);
                var candidates = page.Results
                    .Select(r => (Result: r, Score: Similarity(title, [r.Title, r.OriginalTitle])))
                    .Where(c => c.Score >= 6)
                    .OrderByDescending(c => c.Score).ThenByDescending(c => c.Result.Popularity ?? 0)
                    .Take(4);
                foreach (var (candidate, _) in candidates)
                {
                    var details = await GetAsync<Details>($"movie/{candidate.Id}",
                        [P("language", "fr-FR"), P("append_to_response", "credits")], cancel);
                    var directors = details.Credits?.Crew.Where(c => c.Job == "Director").Select(c => c.Name).ToList() ?? [];
                    if (SameDirector(film.Directors, directors)) return Info(details);
                }
            }
        }
        return null;
    }

    /// <summary>Whether any surname in brackets is a TMDB director's, give or take a typo or two.</summary>
    internal static bool SameDirector(IEnumerable<string> named, IEnumerable<string> found)
    {
        var theirs = found.SelectMany(f => Search.Fold(f).Split(' ', StringSplitOptions.RemoveEmptyEntries)).Where(w => w.Length >= 3).ToList();
        return named.Any(name =>
        {
            var surname = Search.Fold(name).Split(' ', StringSplitOptions.RemoveEmptyEntries).LastOrDefault();
            if (surname is null || surname.Length < 3) return false;
            return theirs.Any(t => t == surname || (surname.Length >= 5 && EditDistance(t, surname) <= 2));
        });
    }

    internal static int EditDistance(string a, string b)
    {
        if (a.Length == 0) return b.Length;
        var row = Enumerable.Range(0, b.Length + 1).ToArray();
        for (var i = 1; i <= a.Length; i++)
        {
            var previous = row[0];
            row[0] = i;
            for (var j = 1; j <= b.Length; j++)
            {
                var current = row[j];
                row[j] = Math.Min(Math.Min(row[j] + 1, row[j - 1] + 1), previous + (a[i - 1] == b[j - 1] ? 0 : 1));
                previous = current;
            }
        }
        return row[b.Length];
    }
}
