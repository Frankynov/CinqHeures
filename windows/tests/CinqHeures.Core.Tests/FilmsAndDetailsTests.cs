using System.Text;
using System.Text.Json;
using CinqHeures.Core;

namespace CinqHeures.Core.Tests;

/// <summary>Descriptions as 5heures.be writes them for its "Autre" specials.</summary>
public class AutreFilmsTests
{
    private static List<string> Names(string description) => AutreProgramme.Films(description).Select(f => f.Title).ToList();

    [Fact]
    public void ReadsTheFilmListAndStopsAtTheNextSection()
    {
        var monaco = "Thème : Monaco Cinéma : La Main au collet (Alfred Hitchcock), Le roman d’un tricheur (Sacha Guitry) et La fille de Monaco (Anne Fontaine) Musique : 28 degrés à l’ombre (Jean-François Maurice), Il faut naitre à Monaco (Joe Dassin)";
        var films = AutreProgramme.Films(monaco);
        Assert.Equal(["La Main au collet", "Le roman d’un tricheur", "La fille de Monaco"], films.Select(f => f.Title));
        Assert.Equal([["Alfred Hitchcock"], ["Sacha Guitry"], ["Anne Fontaine"]], films.Select(f => f.Directors.ToArray()));
        // Songs straight after the films, without a label: the film after "et" ends the list.
        var christmas = "Films : L’assassinat du Père Noël (Christian-Jacque), L’étrange Noël de Mister Jack (Henry Selick) et Le Père Noël est une ordure (Jean-Marie Poiré) La fille du Père Noël (Bijou), I Believe in Father Christmas (Greg Lake)";
        Assert.Equal(["L’assassinat du Père Noël", "L’étrange Noël de Mister Jack", "Le Père Noël est une ordure"], Names(christmas));
        // A section before the films, a colon inside a title, a second section after.
        Assert.Equal(["Da Vinci Code", "1492 : Christophe Colomb"],
            Names("BD : Little Nemo (Winsor McCay) Films : Da Vinci Code (Ron Howard) et 1492 : Christophe Colomb (Ridley Scott) Livre : Max et les Maximonstres (Maurice Sendak)"));
        Assert.Empty(Names("Rudy et Hugues te donnent rendez-vous sur la plage, coco !"));
    }

    [Fact]
    public void RemarksCommasAndSeveralDirectors()
    {
        var triporteur = AutreProgramme.Films("Films : Le Triporteur (Jacques Pinoteau) d'après le roman de René Fallet et René La Canne (Francis Girod) Musiques : Nous (Hervé Vilard)");
        Assert.Equal(["Le Triporteur", "René La Canne"], triporteur.Select(f => f.Title));
        var liege = AutreProgramme.Films("Films : Simenon au cinéma, Mon père ce Héros (Gérard Lauzier) et Je pense à vous (Luc et Jean-Pierre Dardenne)");
        Assert.Equal(["Mon père ce Héros"], liege[0].Alternatives);
        Assert.Equal(["Luc", "Jean-Pierre Dardenne"], liege[^1].Directors);
        Assert.Equal(["Blow up", "Cousin, cousine"], Names("Films : Blow up (Michelangelo Antonioni) et Cousin, cousine (Jean-Charles Tacchella)"));
        Assert.Equal(["Wedding Bells", "Un mariage"], Names("Films : Wedding Bells (Godley &amp;amp; Creme) et Un mariage (Robert Altman)"));
    }

    [Fact]
    public void DirectorsMatchDespiteTypos()
    {
        Assert.True(TMDBClient.SameDirector(["Michael Radofrd"], ["Michael Radford"]));
        Assert.True(TMDBClient.SameDirector(["Luc", "Jean-Pierre Dardenne"], ["Luc Dardenne", "Jean-Pierre Dardenne"]));
        Assert.False(TMDBClient.SameDirector(["Lewis Carroll"], ["Tim Burton"]));
        Assert.False(TMDBClient.SameDirector(["Paul King"], ["Paul Greengrass"]));
    }

    [Fact]
    public void TheProgrammeShowsFoundFilmsAndDropsTheRest()
    {
        var date = Fixture.Day("26/08/2022");
        var episode = new Episode(994, Series.Autre, date,
            "Films : Le Triporteur (Jacques Pinoteau) d'après le roman de René Fallet et René La Canne (Francis Girod)",
            new Uri("https://example.org/a.mp3"), []);
        var library = new FilmLibrary();
        // Before any lookup: both, untimed, under their own names.
        Assert.Equal(["Le Triporteur", "René La Canne"], episode.WithNamedFilms(library).Segments.Select(s => s.Title));
        Assert.All(episode.WithNamedFilms(library).Segments, s => { Assert.Null(s.Start); Assert.True(s.Id < 0); });
        library.Record(new FilmInfo { TmdbId = 1, Title = "Le Triporteur", OriginalTitle = "Le Triporteur", Year = 1957,
                                      Overview = "Un livreur.", PosterPath = "/t.jpg", Director = "Jacques Pinoteau" }, "Le Triporteur", date);
        library.Record(null, "René La Canne", date);
        var timed = episode.WithNamedFilms(library);
        Assert.Equal(["Le Triporteur (1957)"], timed.Segments.Select(s => s.Title));
        Assert.Equal("Un livreur.", timed.Segments[0].Overview);
        // Applying again changes nothing; other shows are left alone.
        Assert.Equal(timed, timed.WithNamedFilms(library));
        var podcast = new Episode(1, Series.Podcast, date, "Films : Rocky (John G. Avildsen)", episode.AudioUrl, []);
        Assert.Equal(podcast, podcast.WithNamedFilms(library));
    }
}

public class WorkDetailsTests
{
    /// <summary>The shape of /api/movies/slug, cut down.</summary>
    private static readonly byte[] Peacock = Encoding.UTF8.GetBytes("""
    {"movie":{"id":4518,"name":"Pfau - Bin ich echt?","name_fr":"Peacock","overview":" Besoin d’un petit ami cultivé ? ",
     "people":[{"name":"Albrecht Schuch","job":{"id":1,"name":"Actor"}},{"name":"Bernhard Wenger","job":{"id":4,"name":"Director"}},
               {"name":"Bernhard Wenger","job":{"id":21,"name":"Writer"}}],"critics":[]}}
    """);

    [Fact]
    public void AFilmPageGivesSynopsisFrenchTitleAndDirector()
    {
        var details = SiteClientDetailsExtensions.FromMoviePage(Peacock);
        Assert.Equal(new WorkDetails { Overview = "Besoin d’un petit ami cultivé ?", LocalTitle = "Peacock", Director = "Bernhard Wenger", Source = "site" }, details);
        var bare = Encoding.UTF8.GetBytes("""{"movie":{"name":"Les Pas perdus","name_fr":"Les Pas perdus","overview":"","people":[]}}""");
        Assert.Null(SiteClientDetailsExtensions.FromMoviePage(bare));
    }

    [Fact]
    public void ASeriesIsTheOneOfThatNameAlreadyOnTheAir()
    {
        var page = new TMDBClient.SeriesPage
        {
            Results =
            [
                new() { Id = 1, Name = "The Survivors", OriginalName = "The Survivors", FirstAirDate = "2030-01-01", Overview = "Pas encore.", Popularity = 90 },
                new() { Id = 2, Name = "Les Survivants", OriginalName = "The Survivors", FirstAirDate = "2025-06-06", Overview = "Un drame en Tasmanie.", Popularity = 20 },
                new() { Id = 3, Name = "Survivors", OriginalName = "Survivors", FirstAirDate = "2008-11-23", Overview = "Une épidémie.", Popularity = 50 },
            ],
        };
        var date = Fixture.Day("20/06/2025");
        Assert.Equal(new WorkDetails { Overview = "Un drame en Tasmanie.", LocalTitle = "Les Survivants", Source = "tmdb" },
                     TMDBClient.SeriesIn(page, "The Survivors", date));
        Assert.Null(TMDBClient.SeriesIn(page, "Olympo", date));
    }

    [Fact]
    public void KeysAndLookups()
    {
        var episode = new Episode(1, Series.Podcast, DateTime.UtcNow, "", new Uri("https://example.org/a.mp3"), []);
        var film = Fixture.Movie("Peacock (2025)", 1, "peacock");
        var series = new Segment(2, "The Survivors", SegmentKind.TvShow, 20, null);
        Assert.Equal("movie:peacock", WorkDetails.KeyFor(new Work(film.Title, SegmentKind.Movie, [new Work.Mention(episode, film)])));
        Assert.Equal("tv:the survivors", WorkDetails.KeyFor(new Work(series.Title, SegmentKind.TvShow, [new Work.Mention(episode, series)])));

        var now = Fixture.Unix(1_800_000_000);
        var library = new WorkDetailsLibrary();
        Assert.True(library.NeedsLookup("movie:peacock", now));
        library.Record(new WorkDetails { Overview = "…", Source = "site" }, "movie:peacock", now);
        library.Record(null, "tv:olympo", now);
        Assert.False(library.NeedsLookup("movie:peacock", now.AddDays(400)));
        Assert.False(library.NeedsLookup("tv:olympo", now.AddDays(6)));
        Assert.True(library.NeedsLookup("tv:olympo", now.AddDays(8)));
    }
}

public class StreamingTests
{
    /// <summary>The shape of movie/id/watch/providers, cut down.</summary>
    private static TMDBClient.ProvidersPage Page(string json) =>
        JsonSerializer.Deserialize<TMDBClient.ProvidersPage>(json, CoreJson.Options)!;

    [Fact]
    public void SubscriptionsComeFirstWithoutTheirAdVariants()
    {
        var providers = Page("""
        {"id":1,"results":{"BE":{"link":"https://www.themoviedb.org/movie/1/watch?locale=BE",
          "flatrate":[{"provider_name":"Netflix Standard with Ads","logo_path":"/a.jpg","display_priority":3},
                      {"provider_name":"Netflix","logo_path":"/n.jpg","display_priority":1},
                      {"provider_name":"Amazon Prime Video","logo_path":"/p.jpg","display_priority":2},
                      {"provider_name":"Cinemax Amazon Channel","logo_path":"/c.jpg","display_priority":4}],
          "rent":[{"provider_name":"Apple TV","logo_path":"/t.jpg","display_priority":1}]},
          "FR":{"flatrate":[{"provider_name":"Canal+","display_priority":1}]}}}
        """);
        var found = TMDBClient.StreamingIn(providers, "BE")!;
        Assert.Equal(StreamingKind.Subscription, found.Kind);
        Assert.Equal(["Netflix", "Amazon Prime Video"], found.Services.Select(s => s.Name));
        Assert.Equal(new Uri("https://image.tmdb.org/t/p/w92/n.jpg"), found.Services[0].LogoUrl);
        Assert.Equal(new Uri("https://www.themoviedb.org/movie/1/watch?locale=BE"), found.Link);
        Assert.Null(TMDBClient.StreamingIn(providers, "NL"));
    }

    [Fact]
    public void FreeThenRentWhenNoSubscription()
    {
        var free = Page("""{"results":{"BE":{"ads":[{"provider_name":"Auvio","display_priority":5}],"rent":[{"provider_name":"Apple TV"}]}}}""");
        Assert.Equal(StreamingKind.Free, TMDBClient.StreamingIn(free, "BE")!.Kind);
        var rent = Page("""{"results":{"BE":{"rent":[{"provider_name":"Apple TV"},{"provider_name":"Google Play Movies"}]}}}""");
        var found = TMDBClient.StreamingIn(rent, "BE")!;
        Assert.Equal(StreamingKind.Rent, found.Kind);
        Assert.Equal(["Apple TV", "Google Play Movies"], found.Services.Select(s => s.Name));
    }

    [Fact]
    public void AFilmIsTheOneOfThatTitleFromAboutThatYear()
    {
        var results = new TMDBClient.SearchPage
        {
            Results =
            [
                new() { Id = 10, Title = "Peacock", OriginalTitle = "Peacock", ReleaseDate = "2008-01-01", Popularity = 9 },
                new() { Id = 11, Title = "Peacock", OriginalTitle = "Pfau - Bin ich echt?", ReleaseDate = "2024-09-01", Popularity = 3 },
            ],
        };
        Assert.Equal(11, TMDBClient.MovieIdIn(results, "Pfau - Bin ich echt?", 2025));
        Assert.Equal(11, TMDBClient.MovieIdIn(results, "Peacock", 2025));
        Assert.Equal(10, TMDBClient.MovieIdIn(results, "Peacock", 2008));
        Assert.Null(TMDBClient.MovieIdIn(results, "Le Paon", 2025));
    }
}

/// <summary>The Windows app reads the very files the Mac app ships and saves: these tests pin the compatibility.</summary>
public class ShippedSnapshotTests
{
    private static readonly Lazy<Catalogue> Shipped = new(() => Catalogue.Load(Fixture.Path("Snapshot/snapshot-catalogue.json"))!);
    private static readonly Lazy<FilmLibrary> Films = new(() => FilmLibrary.Load(Fixture.Path("Snapshot/snapshot-films.json")));

    [Fact]
    public void TheShippedCatalogueIsCurrentAndComplete()
    {
        var catalogue = Shipped.Value;
        Assert.NotNull(catalogue);
        Assert.False(catalogue.NeedsFullDownload);
        Assert.Equal(SeriesInfo.All.ToHashSet(), catalogue.Episodes.Select(e => e.Series).ToHashSet());
        Assert.Contains(catalogue.Episodes.SelectMany(e => e.Segments), s => s.Slug is not null);
        Assert.True(catalogue.Episodes.Count > 1500);
        // The Mac wrote its dates as seconds since 2001: they must land on real days.
        Assert.All(catalogue.Episodes, e => Assert.InRange(e.Date.Year, 2000, 2030));
        Assert.True(Films.Value.Entries.Values.Count(e => e.Info is not null) > 300);
        var mine = new FilmLibrary();
        Assert.True(mine.Adopt(Films.Value));
        Assert.False(mine.Adopt(Films.Value));
    }

    [Fact]
    public void ASavedCatalogueIsReadBackExactly()
    {
        var path = Path.Combine(Path.GetTempPath(), $"roundtrip-{Guid.NewGuid()}.json");
        try
        {
            Shipped.Value.Save(path);
            var again = Catalogue.Load(path)!;
            Assert.Equal(Shipped.Value.Episodes.Count, again.Episodes.Count);
            Assert.Equal(Shipped.Value.Episodes, again.Episodes);
            Assert.Equal(Shipped.Value.UpdatedAt, again.UpdatedAt);
        }
        finally { File.Delete(path); }
    }

    /// <summary>The ids of the feeds' episodes come from a hash of their guid, and the shipped catalogue carries the Mac's.
    /// If this hash differed, the first refresh would add every feed episode a second time.</summary>
    [Fact]
    public void FeedIdsAreTheOnesTheMacComputed()
    {
        var known = Shipped.Value.Episodes.Select(e => e.Id).ToHashSet();
        Assert.True(Fixture.Feed().Count(e => known.Contains(e.Id)) >= 3, "the music podcast's ids");
        Assert.True(Fixture.Dayez().Count(e => known.Contains(e.Id)) >= 3, "Dayez's ids");
        var segments = Shipped.Value.Episodes.SelectMany(e => e.Segments).Select(s => s.Id).ToHashSet();
        Assert.True(Fixture.Dayez().SelectMany(e => e.Segments).Count(s => segments.Contains(s.Id)) >= 3, "Dayez's film ids");
    }

    /// <summary>The films the Mac already matched are found under the same keys: otherwise some 270 would be asked
    /// about again through the proxy at the first launch.</summary>
    [Fact]
    public void TheShippedFilmsAreFoundUnderTheKeysThisCodeComputes()
    {
        var dayez = Shipped.Value.Episodes.Where(e => e.Series == Series.Dayez)
            .SelectMany(e => e.SpokenFilms.Select(f => (Title: f, e.Date))).ToList();
        var autre = Shipped.Value.Episodes.Where(e => e.Series == Series.Autre)
            .SelectMany(e => AutreProgramme.Films(e.Summary).Select(f => (Title: f.Title, e.Date))).ToList();
        Assert.NotEmpty(dayez);
        Assert.True(autre.Count > 200);
        foreach (var (name, films) in new[] { ("Dayez", dayez), ("Autre", autre) })
        {
            var missing = films.Where(f => !Films.Value.Knows(f.Title, f.Date)).Select(f => f.Title).ToList();
            var rate = 1 - missing.Count / (double)films.Count;
            Assert.True(rate > 0.97, $"{name}: {missing.Count} of {films.Count} not found, e.g. {string.Join(" | ", missing.Take(8))}");
        }
    }

    [Fact]
    public void SearchingAndBrowsingTheRealCatalogueIsFast()
    {
        var catalogue = Shipped.Value;
        var built = System.Diagnostics.Stopwatch.StartNew();
        var index = new SearchIndex(catalogue);
        var discovery = new Discovery(catalogue);
        built.Stop();
        var queries = System.Diagnostics.Stopwatch.StartNew();
        foreach (var query in new[] { "t", "the", "twin peaks", "amélie", "black mirror", "dupieux" })
        {
            Assert.NotNull(index.Works(query));
            Assert.NotNull(index.Episodes(query));
        }
        queries.Stop();
        var home = System.Diagnostics.Stopwatch.StartNew();
        discovery.Shelves(1);
        discovery.DecadeTiles(1);
        Assert.NotNull(discovery.Hero(1));
        home.Stop();
        Assert.True(built.ElapsedMilliseconds < 3000, $"index and discovery built in {built.ElapsedMilliseconds} ms");
        Assert.True(queries.ElapsedMilliseconds < 1500, $"six searches in {queries.ElapsedMilliseconds} ms");
        Assert.True(home.ElapsedMilliseconds < 1000, $"home built in {home.ElapsedMilliseconds} ms");
    }
}
