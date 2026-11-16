using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace CinqHeures.Core;

/// <summary>A film, series or person, with every time it has been discussed (some films come back).</summary>
public sealed class Work
{
    public sealed record Mention(Episode Episode, Segment Segment)
    {
        public long Id => Segment.Id;
    }

    public string Title { get; }
    public SegmentKind Kind { get; }
    /// <summary>Newest first.</summary>
    public IReadOnlyList<Mention> Mentions { get; }
    public string Id => $"{Kind.Raw()}|{Title}";
    public Uri? PosterUrl => Mentions.Select(m => m.Segment.PosterUrl).FirstOrDefault(u => u is not null);

    public Work(string title, SegmentKind kind, IReadOnlyList<Mention> mentions)
    {
        Title = title; Kind = kind; Mentions = mentions;
    }
}

public enum SearchScope { All, Movies, Shows, People }

public static class SearchScopeInfo
{
    public static string Title(this SearchScope s) => s switch
    {
        SearchScope.All => "Tout",
        SearchScope.Movies => "Films",
        SearchScope.Shows => "Séries",
        _ => "Personnalités",
    };

    internal static bool Includes(this SearchScope s, SegmentKind kind) => s switch
    {
        SearchScope.All => kind.IsSubject(),
        SearchScope.Movies => kind == SegmentKind.Movie,
        SearchScope.Shows => kind == SegmentKind.TvShow,
        _ => kind == SegmentKind.Person,
    };
}

public static class Search
{
    /// <summary>Lower case, no accents, punctuation as spaces: "Amélie Poulain" and "amelie-poulain" match.</summary>
    public static string Fold(string text)
    {
        var sb = new StringBuilder(text.Length);
        var lastWasSpace = true;
        // Compatibility full-width forms, a few letters Unicode doesn't decompose, then accents off.
        var decomposed = Prepare(text).Normalize(NormalizationForm.FormD);
        foreach (var rune in decomposed.EnumerateRunes())
        {
            var category = Rune.GetUnicodeCategory(rune);
            if (category == UnicodeCategory.NonSpacingMark) continue;
            if (IsAlphanumeric(category))
            {
                sb.Append(Rune.ToLowerInvariant(rune).ToString());
                lastWasSpace = false;
            }
            else if (!lastWasSpace)
            {
                sb.Append(' ');
                lastWasSpace = true;
            }
        }
        if (sb.Length > 0 && sb[^1] == ' ') sb.Length--;
        return sb.ToString();
    }

    private static bool IsAlphanumeric(UnicodeCategory c) => c is
        UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter
        or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter or UnicodeCategory.SpacingCombiningMark
        or UnicodeCategory.EnclosingMark or UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber
        or UnicodeCategory.OtherNumber;

    private static string Prepare(string text)
    {
        var plain = true;
        foreach (var c in text)
        {
            if (c > 0x7F) { plain = false; break; }
        }
        if (plain) return text;
        var sb = new StringBuilder(text.Length);
        foreach (var c in text)
        {
            if (c is >= '！' and <= '～') sb.Append((char)(c - 0xFEE0));       // full-width ASCII
            else if (c == '　') sb.Append(' ');
            else switch (c)
            {
                case 'ß': sb.Append("ss"); break;
                case 'ø': case 'Ø': sb.Append('o'); break;
                case 'ł': case 'Ł': sb.Append('l'); break;
                case 'đ': case 'Đ': sb.Append('d'); break;
                default: sb.Append(c); break;
            }
        }
        return sb.ToString();
    }

    /// <summary>Finder-like ordering: accents and case ignored, numbers by value ("2 Fast" before "10 Things").</summary>
    public static int LocalizedStandardCompare(string a, string b) =>
        EpisodeDates.Culture.CompareInfo.Compare(a, b,
            CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace | CompareOptions.IgnoreSymbols | CompareOptions.NumericOrdering);

    private static readonly Regex TrailingYearPattern = new(@" [0-9]{4}$", RegexOptions.Compiled);

    /// <summary>0 the whole title, 1 starts with it, 2 a word starts with it, 3 anywhere inside.</summary>
    internal static int Rank(string title, string phrase, string[] tokens)
    {
        // Titles end with their year, "the substance 2024": ignore it when it isn't being searched.
        var bare = TrailingYearPattern.Replace(title, "");
        if (bare == phrase || title == phrase) return 0;
        if (title.StartsWith(phrase, StringComparison.Ordinal)) return 1;
        var words = title.Split(' ');
        var wordStarts = tokens.All(token => words.Any(w => w.StartsWith(token, StringComparison.Ordinal)));
        return wordStarts ? 2 : 3;
    }

    /// <summary>Everything that matches, best title first. Builds an index each time: for repeated searches keep a
    /// <see cref="SearchIndex"/> instead.</summary>
    public static List<Work> Works(string query, Catalogue catalogue, SearchScope scope = SearchScope.All,
                                   ISet<Series>? series = null, int? stars = null) =>
        new SearchIndex(catalogue).Works(query, scope, series, stars);

    public static List<Episode> Episodes(string query, Catalogue catalogue, ISet<Series>? series = null) =>
        new SearchIndex(catalogue).Episodes(query, series);
}

/// <summary>A catalogue prepared for searching: every title and summary is folded once, here, instead of on every
/// keystroke.</summary>
public sealed class SearchIndex
{
    private readonly record struct Entry(int Episode, int Segment, string Folded);

    private readonly IReadOnlyList<Episode> _episodes;
    private readonly Entry[] _entries;
    private readonly string[] _summaries;

    public SearchIndex(Catalogue catalogue)
    {
        _episodes = catalogue.Episodes;
        _summaries = _episodes.Select(e => Search.Fold((e.Name ?? "") + " " + e.Summary)).ToArray();
        var entries = new List<Entry>();
        for (var e = 0; e < _episodes.Count; e++)
        {
            var segments = _episodes[e].Segments;
            for (var s = 0; s < segments.Count; s++)
                if (segments[s].Kind.IsSubject()) entries.Add(new Entry(e, s, Search.Fold(segments[s].Title)));
        }
        _entries = entries.ToArray();
    }

    private static readonly string[] NoTokens = [];

    private static string[] Tokens(string query) =>
        Search.Fold(query).Split(' ', StringSplitOptions.RemoveEmptyEntries);

    private sealed class Hit(string title, SegmentKind kind)
    {
        public string Title = title;
        public SegmentKind Kind = kind;
        public List<Work.Mention> Mentions = [];
        public int Rank = int.MaxValue;
    }

    /// <summary>Works matching every word of <paramref name="query"/>. With <paramref name="stars"/>, only the passages
    /// given that score, and then an empty query lists them all, newest first.</summary>
    public List<Work> Works(string query, SearchScope scope = SearchScope.All, ISet<Series>? series = null, int? stars = null)
    {
        var tokens = Tokens(query);
        if (tokens.Length == 0 && stars is null) return [];
        var phrase = string.Join(' ', tokens);

        var hits = new Dictionary<string, Hit>();
        var order = new List<Hit>();
        foreach (var entry in _entries)
        {
            var episode = _episodes[entry.Episode];
            var segment = episode.Segments[entry.Segment];
            if (!scope.Includes(segment.Kind) || (series is not null && !series.Contains(episode.Series))) continue;
            if (stars is not null && segment.Stars != stars) continue;
            var matches = true;
            foreach (var token in tokens)
            {
                if (!entry.Folded.Contains(token, StringComparison.Ordinal)) { matches = false; break; }
            }
            if (!matches) continue;
            var key = segment.Kind.Raw() + "|" + segment.Title;
            if (!hits.TryGetValue(key, out var hit))
            {
                hit = new Hit(segment.Title, segment.Kind);
                hits[key] = hit;
                order.Add(hit);
            }
            hit.Mentions.Add(new Work.Mention(episode, segment));
            hit.Rank = Math.Min(hit.Rank, Search.Rank(entry.Folded, phrase, tokens));
        }

        IEnumerable<Hit> sorted = tokens.Length == 0
            ? order.OrderByDescending(h => h.Mentions.Max(m => m.Episode.Date))
            : order.OrderBy(h => h.Rank).ThenBy(h => h.Title, Comparer<string>.Create(Search.LocalizedStandardCompare));
        return sorted
            .Select(h => new Work(h.Title, h.Kind, h.Mentions.OrderByDescending(m => m.Episode.Date).ToList()))
            .ToList();
    }

    /// <summary>One film, series or person with every passage about it.</summary>
    public Work? FindWork(SegmentKind kind, string title)
    {
        var mentions = new List<Work.Mention>();
        foreach (var entry in _entries)
        {
            var episode = _episodes[entry.Episode];
            var segment = episode.Segments[entry.Segment];
            if (segment.Kind == kind && segment.Title == title) mentions.Add(new Work.Mention(episode, segment));
        }
        return mentions.Count == 0 ? null : new Work(title, kind, mentions.OrderByDescending(m => m.Episode.Date).ToList());
    }

    /// <summary>Episodes whose title or description (which names directors, actors and artists) mentions every word.</summary>
    public List<Episode> Episodes(string query, ISet<Series>? series = null)
    {
        var tokens = Tokens(query);
        if (tokens.Length == 0) return [];
        var result = new List<Episode>();
        for (var i = 0; i < _episodes.Count; i++)
        {
            if (series is not null && !series.Contains(_episodes[i].Series)) continue;
            var text = _summaries[i];
            if (tokens.All(t => text.Contains(t, StringComparison.Ordinal))) result.Add(_episodes[i]);
        }
        return result;
    }
}
