using System.Reflection;
using CinqHeures.Core;
using Microsoft.UI.Dispatching;

namespace CinqHeures;

/// <summary>A row of the sidebar.</summary>
public enum SidebarKind { Home, Favorites, All, Show, Score, Unrated }

public readonly record struct SidebarItem(SidebarKind Kind, Series? Show = null, int Score = 0)
{
    public static SidebarItem Home => new(SidebarKind.Home);
    public static SidebarItem Favorites => new(SidebarKind.Favorites);
    public static SidebarItem All => new(SidebarKind.All);
    public static SidebarItem Unrated => new(SidebarKind.Unrated);
    public static SidebarItem OfShow(Series s) => new(SidebarKind.Show, s);
    public static SidebarItem OfScore(int n) => new(SidebarKind.Score, null, n);
}

/// <summary>Where a click leads. The window is one navigation stack: pages push onto it and the back button undoes them.</summary>
public abstract record Route
{
    /// <summary>A film, series or person with every passage about it.</summary>
    public sealed record Work(SegmentKind Kind, string Title) : Route;
    /// <summary>An episode and its programme, optionally with one segment highlighted.</summary>
    public sealed record EpisodePage(long Id, long? Highlight) : Route;
    /// <summary>A shelf's "Tout voir".</summary>
    public sealed record ListingPage(Listing Listing) : Route;
    /// <summary>A show's episodes (null: every episode of every show, "Récents").</summary>
    public sealed record ShowPage(Series? Series) : Route;
    public sealed record FavoritesPage : Route;
}

public enum ListingOrder { Date, Name }

public static class ListingOrderInfo
{
    public static string Title(this ListingOrder o) => o == ListingOrder.Date ? "Date" : "Nom";

    public static string Direction(this ListingOrder o, bool reversed) => o switch
    {
        ListingOrder.Date => reversed ? "Les plus anciens d'abord" : "Les plus récents d'abord",
        _ => reversed ? "De Z à A" : "De A à Z",
    };

    /// <summary>Newest first, or A to Z (reversing is the page's business).</summary>
    public static List<ShelfItem> Sorted(this ListingOrder order, IEnumerable<ShelfItem> items) => order switch
    {
        ListingOrder.Date => items.OrderByDescending(Date).ToList(),
        // Each name worked out once, rather than twice per comparison.
        _ => items.Select(i => (Name: Name(i), Item: i))
            .OrderBy(p => p.Name, Comparer<string>.Create(Search.LocalizedStandardCompare)).Select(p => p.Item).ToList(),
    };

    private static DateTime Date(ShelfItem item) => item switch
    {
        ShelfItem.Passage p => p.Mention.Episode.Date,
        ShelfItem.EpisodeItem e => e.Episode.Date,
        _ => DateTime.MinValue,
    };

    private static string Name(ShelfItem item) => item switch
    {
        ShelfItem.Passage p => p.Mention.Segment.DisplayTitle,
        ShelfItem.EpisodeItem e => e.Episode.Name ?? e.Episode.Title,
        _ => "",
    };
}

/// <summary>The outcome of a search: the works that matched and the episodes whose title or summary did.</summary>
public sealed record SearchOutcome(string Query, List<Work> Works, List<Episode> Described)
{
    public static SearchOutcome Empty { get; } = new("", [], []);
    public bool IsEmpty => Works.Count == 0 && Described.Count == 0;
}

public sealed class AppModel
{
    public enum SyncKind { Idle, Running, Failed }

    public sealed record SyncState(SyncKind Kind, int Done = 0, int Of = 0, string Message = "");

    private const int UnratedKey = -1;

    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    private readonly SiteClient _site = new();
    private readonly TMDBClient _tmdb = new();
    private readonly ChapterReader _chapterReader = new();
    private FilmLibrary _films;
    private ChapterLibrary _chapters;
    private readonly Dictionary<string, (string Summary, List<NamedFilm> Films)> _autre = [];
    private readonly HashSet<string> _detailLookups = [];
    private readonly HashSet<string> _streamingAsked = [];
    private readonly HashSet<Uri> _chapterChecks = [];
    private Task? _filmLookup, _chapterLookup, _catalogueSave = Task.CompletedTask, _hourlyFeeds;
    private DateTime _lastFeedRefresh = DateTime.MinValue;
    private int _indexGeneration;
    private readonly Dictionary<(Listing, ListingOrder), List<ShelfItem>> _listings = [];
    private readonly List<string> _recentHeroes = [];
    private CancellationTokenSource? _search;

    public UserData Data { get; } = UserData.Load();
    public PlayerModel Player { get; }
    public Catalogue Catalogue { get; private set; }
    public SyncState Sync { get; private set; } = new(SyncKind.Idle);
    public SearchIndex Index { get; private set; } = new(new Catalogue());
    public Discovery Discovery { get; private set; } = new(new Catalogue());
    public ulong ShuffleSeed { get; private set; } = (ulong)Random.Shared.NextInt64();
    public List<object> HomeSections { get; private set; } = [];
    public Work.Mention? Hero { get; private set; }
    public Dictionary<Series, int> EpisodeCounts { get; private set; } = [];
    public Dictionary<int, int> StarCounts { get; private set; } = [];
    public bool IsBrowsable { get; private set; }
    public Dictionary<string, Streaming> Streamings { get; } = [];
    public WorkDetailsLibrary WorkDetails { get; private set; } = WorkDetailsLibrary.Load();

    public string SearchText { get; private set; } = "";
    public SearchScope Scope { get; private set; } = SearchScope.All;
    public SearchOutcome Results { get; private set; } = SearchOutcome.Empty;
    public Series? SearchSeries { get; set; }

    /// <summary>The catalogue changed: the home page and the counts are new.</summary>
    public event Action? CatalogueChanged;
    public event Action? SyncChanged;
    public event Action? FavoritesChanged;
    public event Action? SearchChanged;
    public event Action? DetailsChanged;

    public AppModel()
    {
        Directory.CreateDirectory(AppPaths.Data);
        Player = new PlayerModel(Data);
        _films = FilmLibrary.Load();
        _chapters = ChapterLibrary.Load();
        // What this device saved; else (a first launch, or a catalogue kept with fewer fields) the one shipped with the
        // app, which only needs its newest episodes.
        var saved = Catalogue.Load(AppPaths.Catalogue);
        Catalogue = (saved is { NeedsFullDownload: false } ? saved : null) ?? ShippedCatalogue() ?? saved ?? new Catalogue();
        if (_films.Adopt(ShippedFilms())) _films.Save();
        RebuildIndex();
    }

    // MARK: The catalogue that ships with the app

    private static Stream? Resource(string name) => Assembly.GetExecutingAssembly().GetManifestResourceStream(name);

    /// <summary>The catalogue as it was when this version was built: a first launch starts from it instead of downloading
    /// some 35 pages from 5heures.be, whose shows have stopped. Its newest year and the two feeds are then checked as on any launch.</summary>
    public static Catalogue? ShippedCatalogue()
    {
        using var stream = Resource("snapshot-catalogue.json");
        var catalogue = stream is null ? null : Catalogue.Load(stream);
        return catalogue is { NeedsFullDownload: false, IsEmpty: false } ? catalogue : null;
    }

    /// <summary>The films matched on TMDB when the snapshot was made, so a first launch doesn't look them up again.</summary>
    public static FilmLibrary ShippedFilms() => FilmLibrary.Load(Resource("snapshot-films.json"));

    // MARK: Things the pages ask

    public bool IsSyncing => Sync.Kind == SyncKind.Running;

    public Series? SelectedSeries { get; set; }

    public int CountOf(Series? series) =>
        series is { } s ? EpisodeCounts.GetValueOrDefault(s) : EpisodeCounts.Values.Sum();

    public int CountOfStars(int stars) => StarCounts.GetValueOrDefault(stars);
    public int UnratedCount => StarCounts.GetValueOrDefault(UnratedKey);

    /// <summary>A listing's titles, in this order.</summary>
    public List<ShelfItem> Items(Listing listing, ListingOrder order)
    {
        if (_listings.TryGetValue((listing, order), out var known)) return known;
        var by = _listings.TryGetValue((listing, ListingOrder.Date), out var dated) ? dated : Discovery.Items(listing);
        var items = order.Sorted(by);
        _listings[(listing, order)] = items;
        return items;
    }

    public Work? FindWork(SegmentKind kind, string title) => Index.FindWork(kind, title);
    /// <summary>The episode being played, as a page.</summary>
    public void OpenCurrentEpisode()
    {
        if (Player.Episode is { } e) Shell.Open(new Route.EpisodePage(e.Id, Player.CurrentSegmentId));
    }

    public Episode? EpisodeById(long id) => Catalogue.Episode(id);

    public List<Episode> FavoriteEpisodes
    {
        get
        {
            var found = Catalogue.Episodes.Where(e => Data.Favorites.Contains(e.Id)).ToDictionary(e => e.Id);
            return Data.Favorites.Where(found.ContainsKey).Select(id => found[id]).ToList();
        }
    }

    public bool IsFavorite(Episode e) => Data.Favorites.Contains(e.Id);

    public void ToggleFavorite(Episode e)
    {
        if (!Data.Favorites.Remove(e.Id)) Data.Favorites.Insert(0, e.Id);
        Data.Save();
        FavoritesChanged?.Invoke();
    }

    /// <summary>Episodes started and left unfinished, most recent first.</summary>
    public List<(Episode Episode, double Seconds)> ContinueListening =>
        Player.Unfinished().Select(u => Catalogue.Episode(u.Id) is { } e ? (e, u.Seconds) : default).Where(p => p.Item1 is not null).ToList()!;

    public void Play(Episode episode, Segment? segment = null)
    {
        Player.Play(episode, segment);
        LookUpChapters(episode);
    }

    /// <summary>The review someone is looking at, likely to be played next: warm its file on 5heures.be's server, or read
    /// a Dayez file's chapters again.</summary>
    public void Warm(Episode episode, Segment? segment = null)
    {
        Player.Warm(episode, segment);
        LookUpChapters(episode);
    }

    // MARK: Cache

    public sealed record CacheUsage(long Catalogue, long Episodes)
    {
        public long Total => Catalogue + Episodes;

        public static string Text(long bytes) => bytes switch
        {
            < 1024 => $"{bytes} o",
            < 1024 * 1024 => $"{bytes / 1024.0:0.#} Ko".Replace('.', ','),
            < 1024L * 1024 * 1024 => $"{bytes / 1048576.0:0.#} Mo".Replace('.', ','),
            _ => $"{bytes / 1073741824.0:0.##} Go".Replace('.', ','),
        };
    }

    public CacheUsage MeasureCache() =>
        new(File.Exists(AppPaths.Catalogue) ? new FileInfo(AppPaths.Catalogue).Length : 0, AudioCache.Shared.Size());

    /// <summary>Forgets listening progress and/or the cache, as chosen in the "Réinitialiser" sheet.
    /// Progress: every resume position, so "Continuer l'écoute" empties. Cache: back to a first launch (no catalogue,
    /// nothing playing), then the download starts again as the very first time.</summary>
    public async Task ResetAsync(bool cache, bool progress)
    {
        if (progress) Player.ForgetAllProgress();
        if (!cache || IsSyncing) return;
        Player.Stop();
        await _catalogueSave!;          // a save still running would write it back
        try { File.Delete(AppPaths.Catalogue); } catch (IOException) { }
        Catalogue = ShippedCatalogue() ?? new Catalogue();
        AudioCache.Shared.Clear();
        Hero = null; _recentHeroes.Clear(); HomeSections = [];
        Results = SearchOutcome.Empty;
        _lastFeedRefresh = DateTime.MinValue;
        RebuildIndex();
        await StartAsync();
    }

    // MARK: Home

    public void Shuffle()
    {
        ShuffleSeed = (ulong)Random.Shared.NextInt64();
        RebuildHome();
        AnotherHero();
        CatalogueChanged?.Invoke();
    }

    /// <summary>Cheap enough to do on the UI thread: a few milliseconds over the whole catalogue.</summary>
    private void RebuildHome()
    {
        var sections = Discovery.Shelves(ShuffleSeed).Cast<object>().ToList();
        var tiles = Discovery.DecadeTiles(ShuffleSeed);
        if (tiles.Count > 0) sections.Insert(Math.Min(3, sections.Count), tiles);
        HomeSections = sections;
        if (Hero is null || !Discovery.Contains(Hero)) ShowHero(Discovery.Hero(ShuffleSeed));
    }

    /// <summary>A well-rated review at random, as the home page's banner picks them.</summary>
    public Work.Mention? Surprise() => Discovery.Hero((ulong)Random.Shared.NextInt64());

    /// <summary>Another random review in the banner, not one featured in the last thirty.</summary>
    public void AnotherHero()
    {
        for (var i = 0; i < 12; i++)
        {
            var candidate = Discovery.Hero((ulong)Random.Shared.NextInt64());
            if (candidate is not null && !_recentHeroes.Contains(candidate.Segment.Title))
            {
                ShowHero(candidate);
                return;
            }
        }
        ShowHero(Discovery.Hero((ulong)Random.Shared.NextInt64()));
    }

    private void ShowHero(Work.Mention? mention)
    {
        Hero = mention;
        if (mention is null) return;
        _recentHeroes.Add(mention.Segment.Title);
        if (_recentHeroes.Count > 30) _recentHeroes.RemoveAt(0);
    }

    // MARK: Searching

    public bool IsSearching => Search.Fold(SearchText).Length > 0;
    public bool SearchIsSettled => Results.Query == Search.Fold(SearchText);
    private ISet<Series> ActiveSeries => SearchSeries is { } s ? new HashSet<Series> { s } : SeriesInfo.All.ToHashSet();

    /// <summary>Call whenever the query, the scope or the chosen show changes. The text field stays instant: the search
    /// runs after a short pause in typing, off the UI thread, and a newer keystroke cancels an older search.</summary>
    public async void SetSearch(string text, SearchScope? scope = null, bool typing = true)
    {
        SearchText = text;
        if (scope is { } s) Scope = s;
        _search?.Cancel();
        if (!IsSearching) { Results = SearchOutcome.Empty; SearchChanged?.Invoke(); return; }
        var cancel = _search = new CancellationTokenSource();
        var (query, current, series, index) = (SearchText, Scope, ActiveSeries, Index);
        try
        {
            // Wait out a burst of typing; a click on the scope doesn't need to.
            if (typing) await Task.Delay(140, cancel.Token);
            var outcome = await Task.Run(() => new SearchOutcome(Search.Fold(query), index.Works(query, current, series),
                current == SearchScope.All ? index.Episodes(query, series) : []), cancel.Token);
            if (cancel.IsCancellationRequested) return;
            Results = outcome;
            SearchChanged?.Invoke();
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>Folding every title takes a moment, so it's done in the background; searches use the old index until the
    /// new one is ready.</summary>
    private async void RebuildIndex()
    {
        var snapshot = Catalogue.Snapshot();
        var generation = ++_indexGeneration;
        var (fresh, browse, scored) = await Task.Run(() =>
        {
            var browse = new Discovery(snapshot);
            // The sidebar's lists, ready before they're opened. Their badges count these titles.
            var scored = new Dictionary<int, List<ShelfItem>>();
            for (var stars = 0; stars <= 4; stars++) scored[stars] = ListingOrder.Date.Sorted(browse.Items(Listing.OfStars(stars)));
            scored[UnratedKey] = ListingOrder.Date.Sorted(browse.Items(Listing.Unrated));
            return (new SearchIndex(snapshot), browse, scored);
        });
        if (generation != _indexGeneration) return;     // a newer catalogue is being indexed
        Index = fresh;
        Discovery = browse;
        _listings.Clear();
        foreach (var (stars, items) in scored)
            _listings[(stars == UnratedKey ? Listing.Unrated : Listing.OfStars(stars), ListingOrder.Date)] = items;
        EpisodeCounts = snapshot.Episodes.GroupBy(e => e.Series).ToDictionary(g => g.Key, g => g.Count());
        StarCounts = scored.ToDictionary(p => p.Key, p => p.Value.Count);
        RebuildHome();
        if (IsSearching) SetSearch(SearchText, typing: false);
        IsBrowsable = true;
        CatalogueChanged?.Invoke();
    }

    // MARK: Keeping the catalogue

    /// <summary>First launch downloads everything; later launches only look at each show's newest year, and only when the
    /// last look was a while ago.</summary>
    public async Task StartAsync()
    {
        if (Catalogue.IsEmpty || Catalogue.NeedsFullDownload) await RefreshAsync(everything: true);
        else if ((DateTime.UtcNow - (Catalogue.UpdatedAt ?? DateTime.MinValue)).TotalHours > 12) await RefreshAsync(everything: false);
        await RefreshFeedAsync();
        ApplyDetails();
        LookUpFilms();
        LookUpChapters();
        // New episodes while the app stays open: the feeds again every hour.
        _hourlyFeeds ??= Task.Run(async () =>
        {
            while (true)
            {
                await Task.Delay(TimeSpan.FromHours(1));
                _ui.TryEnqueue(async () => await RefreshFeedAsync());
            }
        });
    }

    public async Task RefreshAsync(bool everything)
    {
        if (Sync.Kind == SyncKind.Running) return;
        SetSync(new SyncState(SyncKind.Running, 0, 1));
        _lastFeedRefresh = DateTime.MinValue;
        try
        {
            var years = await _site.YearsPerSeriesAsync();
            var jobs = new List<(Series Series, int Year)>();
            foreach (var (series, list) in years)
                jobs.AddRange((everything ? list : list.OrderByDescending(y => y).Take(1)).Select(y => (series, y)));
            jobs = jobs.OrderByDescending(j => j.Year).ThenByDescending(j => j.Series.Raw(), StringComparer.Ordinal).ToList();
            SetSync(new SyncState(SyncKind.Running, 0, jobs.Count));
            for (var i = 0; i < jobs.Count; i++)
            {
                var episodes = await _site.EpisodesAsync(jobs[i].Series, jobs[i].Year);
                // Merged into the live catalogue, not a copy taken at the start: the music feed can be merged while this
                // runs, and writing a stale copy back would drop its episodes.
                Catalogue.Merge(episodes);
                SetSync(new SyncState(SyncKind.Running, i + 1, jobs.Count));
            }
            if (everything) Catalogue.MarkDownloadedInFull();
            ApplyDetails();          // the "Autre" specials come without their films
            SaveCatalogue();
            RebuildIndex();
            SetSync(new SyncState(SyncKind.Idle));
        }
        catch (Exception e)
        {
            // Keep whatever was fetched so far: it's still searchable.
            if (!Catalogue.IsEmpty) { SaveCatalogue(); RebuildIndex(); }
            SetSync(new SyncState(SyncKind.Failed, Message: e.Message));
        }
    }

    private void SetSync(SyncState state)
    {
        Sync = state;
        SyncChanged?.Invoke();
    }

    /// <summary>The feed shows are weekly: one small request when the app starts and whenever it comes back to the front
    /// after an hour or more. Failing is fine; the saved episodes stay.</summary>
    public async Task RefreshFeedAsync()
    {
        if ((DateTime.UtcNow - _lastFeedRefresh).TotalHours < 1) return;
        _lastFeedRefresh = DateTime.UtcNow;
        var changed = false;
        foreach (var feed in FeedClient.All)
        {
            // One feed being down (Franky's server, say) doesn't keep the other from updating, and an empty answer never
            // wipes what's known.
            List<Episode> episodes;
            try { episodes = await feed.EpisodesAsync(); } catch (Exception) { continue; }
            if (episodes.Count == 0) continue;
            var fresh = episodes.Select(Detailed).ToList();
            // Most times nothing is new: then nothing is saved or indexed again, and the home page isn't rebuilt under the
            // listener's eyes.
            var known = Catalogue.Episodes.Where(e => e.Series == feed.Series).ToList();
            if (known.Count == fresh.Count && known.ToHashSet().SetEquals(fresh)) continue;
            Catalogue.ReplaceEpisodes(feed.Series, fresh, Catalogue.UpdatedAt ?? DateTime.UtcNow);
            changed = true;
        }
        if (changed) { SaveCatalogue(); RebuildIndex(); }
        LookUpFilms();          // this week's three films, and any not found last time
        LookUpChapters();
    }

    private void SaveCatalogue()
    {
        var snapshot = Catalogue.Snapshot();
        var previous = _catalogueSave!;
        _catalogueSave = Task.Run(async () =>
        {
            await previous;
            try { snapshot.Save(AppPaths.Catalogue); } catch (IOException) { }
        });
    }

    // MARK: Film details from TMDB

    /// <summary>An episode with its films' TMDB details and, for Dayez's, their chapter starts.</summary>
    private Episode Detailed(Episode episode)
    {
        var enriched = _films.Enrich(_chapters.Apply(episode));
        return episode.Series == Series.Autre ? enriched.WithNamedFilms(NamedFilmsIn(episode), _films) : enriched;
    }

    /// <summary>An "Autre" episode's films, read from its description once.</summary>
    private List<NamedFilm> NamedFilmsIn(Episode episode)
    {
        var key = episode.Id.ToString();
        if (_autre.TryGetValue(key, out var known) && known.Summary == episode.Summary) return known.Films;
        var films = AutreProgramme.Films(episode.Summary);
        _autre[key] = (episode.Summary, films);
        return films;
    }

    /// <summary>Dayez's episodes with what TMDB knows about their films (title, poster, synopsis, director), and where each
    /// film starts in the file. The one playing takes them too. Returns whether any changed.</summary>
    private bool ApplyDetails()
    {
        var changed = false;
        // Dayez's episodes, and the "Autre" specials, whose films come from their descriptions.
        foreach (var series in new[] { Series.Dayez, Series.Autre })
        {
            var episodes = Catalogue.Episodes.Where(e => e.Series == series).ToList();
            if (episodes.Count == 0) continue;
            var enriched = episodes.Select(Detailed).ToList();
            if (enriched.Zip(episodes).All(p => p.First.Segments.SequenceEqual(p.Second.Segments))) continue;
            Catalogue.ReplaceEpisodes(series, enriched, Catalogue.UpdatedAt ?? DateTime.UtcNow);
            if (Player.Episode is { } playing && enriched.FirstOrDefault(e => e.Id == playing.Id) is { } updated) Player.Update(updated);
            changed = true;
        }
        return changed;
    }

    /// <summary>Looks up, in the background, the films not asked about yet. Every request is paced under the proxy's limit;
    /// a film that fails is skipped, three failures in a row stop the round, and what wasn't reached is asked about at the
    /// next launch.</summary>
    public void LookUpFilms()
    {
        if (_filmLookup is not null) return;
        var dayez = Catalogue.Episodes.Where(e => e.Series == Series.Dayez).SelectMany(e =>
            e.SpokenFilms.Where(f => _films.NeedsLookup(f, e.Date)).Select(f => (Title: f, e.Date, Hints: e.Summary, Named: (NamedFilm?)null)));
        // The "Autre" specials' films, named with their director: about 270, looked up once.
        var autre = Catalogue.Episodes.Where(e => e.Series == Series.Autre).SelectMany(e =>
            AutreProgramme.Films(e.Summary).Where(f => _films.NeedsLookup(f.Title, e.Date)).Select(f => (Title: f.Title, e.Date, Hints: "", Named: (NamedFilm?)f)));
        var pending = dayez.Concat(autre).ToList();
        if (pending.Count == 0) return;
        _filmLookup = RunFilmLookupsAsync(pending);
    }

    private async Task RunFilmLookupsAsync(List<(string Title, DateTime Date, string Hints, NamedFilm? Named)> pending)
    {
        var done = 0;
        var failures = 0;
        var shown = DateTime.UtcNow;
        try
        {
            foreach (var film in pending)
            {
                for (var attempt = 0; attempt < 3; attempt++)
                {
                    try
                    {
                        var info = film.Named is { } named ? await _tmdb.FilmAsync(named) : await _tmdb.FilmAsync(film.Title, film.Date, film.Hints);
                        _films.Record(info, film.Title, film.Date);
                        failures = 0;
                        break;
                    }
                    catch (SiteException e) when (e.Status == 429 && attempt < 2)
                    {
                        await Task.Delay(TimeSpan.FromSeconds(65));       // the proxy's minute is over
                    }
                    catch (Exception)
                    {
                        // A film that can't be asked about now (a timeout, the server busy) is left for the next launch;
                        // three in a row and the server is down, so the rest waits too.
                        failures++;
                        break;
                    }
                }
                if (failures == 3) break;
                done++;
                // Posters appear as they come, but at most every 20 seconds: each time redraws the pages, and a first
                // launch looks up some 270 films.
                if (done % 6 == 0 && (DateTime.UtcNow - shown).TotalSeconds > 20)
                {
                    FinishFilmBatch();
                    shown = DateTime.UtcNow;
                }
                await Task.Delay(500);
            }
        }
        finally
        {
            FinishFilmBatch();
            _filmLookup = null;
        }
    }

    private void FinishFilmBatch()
    {
        _films.Save();
        ApplyDetails();
        SaveCatalogue();
        RebuildIndex();
    }

    // MARK: Chapters in Dayez's files

    /// <summary>Reads, in the background, the chapters of the Dayez files not read lately (a request for the first few
    /// kilobytes of each). A film with a chapter then starts there everywhere: its marks on the bar, the episode's programme,
    /// "Écouter la critique".</summary>
    public void LookUpChapters()
    {
        if (_chapterLookup is not null) return;
        var pending = Catalogue.Episodes.Where(e => e.Series == Series.Dayez && _chapters.NeedsLookup(e)).ToList();
        if (pending.Count == 0) return;
        _chapterLookup = Task.Run(async () =>
        {
            var failures = 0;
            foreach (var episode in pending)
            {
                try
                {
                    var found = await _chapterReader.ChaptersAsync(episode.AudioUrl);
                    _ui.TryEnqueue(() => _chapters.Record(found, episode));
                    failures = 0;
                }
                catch (Exception)
                {
                    // A file that can't be read is tried again next time; three in a row, the server is down.
                    if (++failures == 3) break;
                }
            }
            _ui.TryEnqueue(() => { ChaptersRead(); _chapterLookup = null; });
        });
    }

    /// <summary>Reads one Dayez file again as soon as its episode, or a film in it, is opened or played, unless that was
    /// done in the last minute: chapters are added to a file after uploading it, which the reads above would only notice hours later.</summary>
    public async void LookUpChapters(Episode episode)
    {
        if (episode.Series != Series.Dayez || _chapterChecks.Contains(episode.AudioUrl)
            || (DateTime.UtcNow - (_chapters.LastRead(episode) ?? DateTime.MinValue)).TotalSeconds <= 60) return;
        _chapterChecks.Add(episode.AudioUrl);
        try
        {
            var found = await _chapterReader.ChaptersAsync(episode.AudioUrl);
            if (_chapters.Record(found, episode)) ChaptersRead();
        }
        catch (Exception) { }
        finally { _chapterChecks.Remove(episode.AudioUrl); }
    }

    /// <summary>What was found is kept, and the films start at their chapters everywhere.</summary>
    private void ChaptersRead()
    {
        try { _chapters.Save(); } catch (IOException) { }
        if (!ApplyDetails()) return;
        SaveCatalogue();
        RebuildIndex();
    }

    // MARK: Synopses

    public WorkDetails? DetailsOf(Work work) => Core.WorkDetails.KeyFor(work) is { } key ? WorkDetails.Details(key) : null;

    /// <summary>Looks up a film's synopsis on its 5heures.be page, or a series' on TMDB, the first time its page is opened.
    /// Dayez's films already have theirs.</summary>
    public async void LookUpDetails(Work work)
    {
        if (!work.Mentions.All(m => m.Segment.Overview is null) || Core.WorkDetails.KeyFor(work) is not { } key
            || !WorkDetails.NeedsLookup(key) || _detailLookups.Contains(key) || work.Mentions.FirstOrDefault() is not { } latest) return;
        _detailLookups.Add(key);
        var slug = work.Mentions.Select(m => m.Segment.Slug).FirstOrDefault(s => s is not null);
        try
        {
            var found = slug is not null
                ? await _site.MovieDetailsAsync(slug)
                : await _tmdb.SeriesDetailsAsync(latest.Segment.DisplayTitle, latest.Episode.Date);
            WorkDetails.Record(found, key);
            try { WorkDetails.Save(); } catch (IOException) { }
            DetailsChanged?.Invoke();
        }
        catch (Exception) { /* offline, or the proxy not allowing series yet: asked again next time */ }
        finally { _detailLookups.Remove(key); }
    }

    // MARK: Where to watch

    /// <summary>Where each film or series streams in this country, by <see cref="Work.Id"/>: looked up when its page is
    /// first opened, kept until the app quits.</summary>
    public async void LookUpStreaming(Work work)
    {
        if (work.Kind is not (SegmentKind.Movie or SegmentKind.TvShow) || work.Mentions.FirstOrDefault() is not { } latest
            || !_streamingAsked.Add(work.Id)) return;
        var region = System.Globalization.RegionInfo.CurrentRegion.TwoLetterISORegionName;
        if (region.Length != 2) region = "BE";
        try
        {
            var segment = latest.Segment;
            var id = work.Kind == SegmentKind.Movie
                ? await _tmdb.MovieIdAsync(segment.DisplayTitle, segment.Year)
                : await _tmdb.SeriesIdAsync(segment.DisplayTitle, latest.Episode.Date);
            if (id is null || await _tmdb.StreamingAsync(id.Value, work.Kind == SegmentKind.TvShow, region) is not { } found) return;
            Streamings[work.Id] = found;
            DetailsChanged?.Invoke();
        }
        catch (Exception) { _streamingAsked.Remove(work.Id); }
    }
}
