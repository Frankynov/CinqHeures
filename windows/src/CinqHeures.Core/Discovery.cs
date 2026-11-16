namespace CinqHeures.Core;

/// <summary>A repeatable shuffle (SplitMix64): the same seed gives the same "random" shelves, which keeps tests stable
/// and lets the app reshuffle on demand.</summary>
public sealed class SeededRandom
{
    private ulong _state;

    public SeededRandom(ulong seed) { unchecked { _state = seed + 0x9E3779B97F4A7C15UL; } }

    public ulong Next()
    {
        unchecked
        {
            _state += 0x9E3779B97F4A7C15UL;
            var z = _state;
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
            return z ^ (z >> 31);
        }
    }

    /// <summary>0 ≤ n &lt; <paramref name="upperBound"/>.</summary>
    public int Next(int upperBound) => (int)(Next() % (ulong)upperBound);

    public List<T> Shuffled<T>(IEnumerable<T> source)
    {
        var list = source.ToList();
        for (var i = list.Count - 1; i > 0; i--)
        {
            var j = Next(i + 1);
            (list[i], list[j]) = (list[j], list[i]);
        }
        return list;
    }
}

public enum ListingKind { Latest, Rediscover, Series, People, Repeats, CodLive, Stars, Show, Unrated, Decade }

/// <summary>A way of browsing the archive: what a shelf's "Tout voir" opens.</summary>
public readonly record struct Listing(ListingKind Kind, int Number = 0, Series? Show = null)
{
    public static Listing Latest => new(ListingKind.Latest);
    public static Listing Rediscover => new(ListingKind.Rediscover);
    public static Listing SeriesShows => new(ListingKind.Series);
    public static Listing People => new(ListingKind.People);
    public static Listing Repeats => new(ListingKind.Repeats);
    public static Listing CodLive => new(ListingKind.CodLive);
    public static Listing Unrated => new(ListingKind.Unrated);
    public static Listing OfStars(int n) => new(ListingKind.Stars, n);
    /// <summary>The films and series one show discussed, newest first: its page's poster grid.</summary>
    public static Listing OfShow(Series series) => new(ListingKind.Show, 0, series);
    /// <summary>A decade by its first year; 0 is everything before 1960.</summary>
    public static Listing OfDecade(int decade) => new(ListingKind.Decade, decade);

    public string Title => Kind switch
    {
        ListingKind.Latest => "Derniers passages",
        ListingKind.Rediscover => "À redécouvrir",
        ListingKind.Series => "Séries",
        ListingKind.People => "Personnalités",
        ListingKind.Repeats => "Revenus plusieurs fois",
        ListingKind.CodLive => "Critic On Demand Live",
        ListingKind.Stars => $"Films notés {Number}/4",
        ListingKind.Unrated => "Films sans note",
        ListingKind.Decade => Decades.Title(Number),
        _ => Show!.Value.FullTitle(),
    };
}

public static class Decades
{
    public static readonly int[] All = [0, 1960, 1970, 1980, 1990, 2000, 2010, 2020];

    public static int Of(int year) => year < 1960 ? 0 : year / 10 * 10;

    public static string Title(int decade) => decade switch
    {
        0 => "Avant 1960",
        2000 => "Années 2000",
        2010 => "Années 2010",
        2020 => "Années 2020",
        _ => $"Années {decade % 100}",
    };
}

public sealed record DecadeTile(int Decade, int Count, IReadOnlyList<Uri> Posters)
{
    public string Title => Decades.Title(Decade);
}

/// <summary>What a shelf holds: a passage about a film, series or person, or a whole episode.</summary>
public abstract record ShelfItem
{
    public abstract string Id { get; }

    public sealed record Passage(Work.Mention Mention) : ShelfItem
    {
        public override string Id => $"p|{Mention.Segment.Kind.Raw()}|{Mention.Segment.Title}";
    }

    public sealed record EpisodeItem(Episode Episode, double? Resume) : ShelfItem
    {
        public override string Id => $"e|{Episode.Id}";
    }
}

public sealed record Shelf(string Id, string Title, IReadOnlyList<ShelfItem> Items, Listing? Listing, Series? Show);

/// <summary>What the home page and the browse pages show, drawn from the catalogue.</summary>
public sealed class Discovery
{
    /// <summary>Every film, series and person passage, newest first.</summary>
    private readonly List<Work.Mention> _passages;
    /// <summary>The film passages among them, and the newest passage of each film. Worked out once, when the catalogue
    /// changes (off the UI thread), rather than again for every shelf each time the home page is rebuilt.</summary>
    private readonly List<Work.Mention> _films;
    private readonly List<Work.Mention> _latestFilms;
    private readonly IReadOnlyList<Episode> _episodes;

    public Discovery(Catalogue catalogue)
    {
        _episodes = catalogue.Episodes;
        _passages = catalogue.Episodes
            .SelectMany(e => e.Segments.Where(s => s.Kind.IsSubject()).Select(s => new Work.Mention(e, s)))
            .ToList();
        _films = _passages.Where(m => m.Segment.Kind == SegmentKind.Movie).ToList();
        _latestFilms = Unique(_films);
    }

    /// <summary>One passage per work: the newest.</summary>
    private static List<Work.Mention> Unique(IEnumerable<Work.Mention> list)
    {
        var seen = new HashSet<(SegmentKind, string)>();
        return list.Where(m => seen.Add((m.Segment.Kind, m.Segment.Title))).ToList();
    }

    private static bool HasPoster(Work.Mention m) => m.Segment.PosterUrl is not null;

    // MARK: Whole listings

    /// <summary>Everything in a listing, in the order its page shows it.</summary>
    public List<ShelfItem> Items(Listing listing, DateTime? now = null)
    {
        var thisYear = EpisodeDates.Year(now ?? DateTime.UtcNow);
        IEnumerable<Work.Mention> chosen;
        switch (listing.Kind)
        {
            case ListingKind.Latest:
                chosen = _latestFilms;
                break;
            case ListingKind.Stars:
                chosen = Unique(_films.Where(m => m.Segment.Stars == listing.Number));
                break;
            case ListingKind.Unrated:
                // Reviewed without a score: not the films an "Autre" special only talks about.
                chosen = Unique(_films.Where(m => m.Segment.Stars is null && m.Episode.Series != Series.Autre));
                break;
            case ListingKind.Rediscover:
                chosen = Unique(_films.Where(m => (m.Segment.Year ?? thisYear) <= thisYear - 10 && (m.Segment.Stars ?? 0) >= 3));
                break;
            case ListingKind.Series:
                chosen = Unique(_passages.Where(m => m.Segment.Kind == SegmentKind.TvShow));
                break;
            case ListingKind.People:
                chosen = Unique(_passages.Where(m => m.Segment.Kind == SegmentKind.Person));
                break;
            case ListingKind.CodLive:
                chosen = Unique(_films.Where(m => m.Episode.Series == Series.CodLive));
                break;
            case ListingKind.Show:
                chosen = Unique(_passages.Where(m => m.Episode.Series == listing.Show && m.Segment.Kind != SegmentKind.Person));
                break;
            case ListingKind.Repeats:
                var counts = new Dictionary<string, int>();
                foreach (var film in _films) counts[film.Segment.Title] = counts.GetValueOrDefault(film.Segment.Title) + 1;
                chosen = Unique(_films.Where(m => counts[m.Segment.Title] >= 2))
                    .OrderByDescending(m => counts[m.Segment.Title]).ToList();
                break;
            default:
                // The year is in the title, the same in every passage of a film: the newest passages of the decade's
                // films are the decade's newest passages.
                chosen = _latestFilms.Where(m => m.Segment.Year is { } y && Decades.Of(y) == listing.Number)
                    .OrderByDescending(m => m.Segment.Stars ?? -1).ToList();
                break;
        }
        return chosen.Select(m => (ShelfItem)new ShelfItem.Passage(m)).ToList();
    }

    // MARK: Home

    /// <summary>The home page's poster shelves. <paramref name="seed"/> picks the random ones; the same seed gives the
    /// same shelves.</summary>
    public List<Shelf> Shelves(ulong seed, int size = 20)
    {
        var rng = new SeededRandom(seed);
        Shelf Sample(Listing listing, string title, string id)
        {
            var withPoster = Items(listing).Where(i => i is ShelfItem.Passage p && HasPoster(p.Mention));
            return new Shelf(id, title, rng.Shuffled(withPoster).Take(size).ToList(), listing, null);
        }
        // No "latest" shelf: the 5heures.be archive no longer grows, so it would never change. The feed shows, which
        // do, come right after the first shelf. "À redécouvrir" leads: it draws on far more films than the 4-star
        // shelf, so a shuffle changes it more.
        var shelves = new List<Shelf>
        {
            Sample(Listing.Rediscover, "À redécouvrir", "rediscover"),
            Sample(Listing.OfStars(4), "Coups de cœur ★★★★", "stars4"),
            Sample(Listing.SeriesShows, "Séries", "series"),
            Sample(Listing.Repeats, "Revenus plusieurs fois", "repeats"),
            Sample(Listing.People, "Personnalités", "people"),
            Sample(Listing.CodLive, "Critic On Demand Live", "cod"),
        };
        for (var offset = 0; offset < SeriesInfo.FromFeeds.Count; offset++)
        {
            var show = SeriesInfo.FromFeeds[offset];
            var latest = _episodes.Where(e => e.Series == show).Take(12).ToList();
            if (latest.Count == 0) continue;
            shelves.Insert(Math.Min(1 + offset, shelves.Count),
                new Shelf("feed-" + show.Raw(), show.FullTitle(),
                          latest.Select(e => (ShelfItem)new ShelfItem.EpisodeItem(e, null)).ToList(), null, show));
        }
        return shelves.Where(s => s.Items.Count > 0).ToList();
    }

    /// <summary>Whether a passage is still in the catalogue this was built from.</summary>
    public bool Contains(Work.Mention mention) => _passages.Any(m => m.Segment.Id == mention.Segment.Id);

    /// <summary>A well-rated review to feature at the top of the home page.</summary>
    public Work.Mention? Hero(ulong seed)
    {
        var rng = new SeededRandom(unchecked(seed + 7));
        var candidates = Unique(_films.Where(m => (m.Segment.Stars ?? 0) >= 3 && HasPoster(m)));
        return candidates.Count == 0 ? null : candidates[rng.Next(candidates.Count)];
    }

    /// <summary>The decades that have films, each with some posters for its tile.</summary>
    public List<DecadeTile> DecadeTiles(ulong seed)
    {
        var rng = new SeededRandom(unchecked(seed + 13));
        var byDecade = _latestFilms.Where(m => m.Segment.Year is not null)
            .GroupBy(m => Decades.Of(m.Segment.Year!.Value)).ToDictionary(g => g.Key, g => g.ToList());
        var tiles = new List<DecadeTile>();
        foreach (var decade in Decades.All)
        {
            if (!byDecade.TryGetValue(decade, out var inDecade) || inDecade.Count == 0) continue;
            var posters = inDecade.Select(m => m.Segment.PosterUrl).OfType<Uri>().ToList();
            tiles.Add(new DecadeTile(decade, inDecade.Count, rng.Shuffled(posters).Take(3).ToList()));
        }
        return tiles;
    }
}
