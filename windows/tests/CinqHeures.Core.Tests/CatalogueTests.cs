using System.Text;
using System.Text.RegularExpressions;
using CinqHeures.Core;

namespace CinqHeures.Core.Tests;

public class DecodingTests
{
    [Fact]
    public void EveryShowIsRecognised()
    {
        var episodes = Fixture.Episodes();
        Assert.Equal(6, episodes.Count);
        // The music podcast isn't on the site.
        Assert.Equal(SeriesInfo.All.Where(s => s.IsOnSite()).ToHashSet(), episodes.Select(e => e.Series).ToHashSet());
    }

    /// <summary>The API's available_at of the Substance episode is 2024-12-04; it was recorded on 4 November.</summary>
    [Fact]
    public void DateComesFromTheEpisodeTitleNotTheApiDate()
    {
        var substance = Fixture.Episodes().First(e => e.Id == 1449);
        Assert.Equal("04/11/2024", EpisodeDates.Short(substance.Date));
        Assert.Equal("Podcast du 04/11/2024", substance.Title);
    }

    [Fact]
    public void SegmentsKeepTheirTimecodeAndVerdict()
    {
        var review = Fixture.Episodes().First(e => e.Id == 1449).Segments.First(s => s.Title == "The Substance (2024)");
        Assert.Equal(SegmentKind.Movie, review.Kind);
        Assert.Equal(860, review.Start);
        Assert.Equal("4 bonnes doses", review.Verdict);
    }

    [Fact]
    public void IntroductionIsNotASubject()
    {
        var episode = Fixture.Episodes().First(e => e.Id == 1613);
        Assert.Equal(SegmentKind.Introduction, episode.Segments[0].Kind);
        Assert.Contains("KPop Demon Hunters (2025)", episode.Subjects.Select(s => s.Title));
        Assert.DoesNotContain(episode.Subjects, s => s.Kind is SegmentKind.Introduction or SegmentKind.Conclusion);
    }

    [Fact]
    public void AnEpisodeWithoutAudioIsSkipped()
    {
        var json = """{"id":1,"kind":"cinq_heures","display_name":"Podcast du 01/01/2020","available_at":"2020-02-01","parts":[]}""";
        Assert.Null(Wire.EpisodeFrom(json));
    }

    [Fact]
    public void DatesAreWrittenInFrench()
    {
        Assert.Equal("vendredi 27 juin 2025", EpisodeDates.Long(Fixture.Day("27/06/2025")));
    }
}

public class SearchTests
{
    private readonly Catalogue _catalogue = new(Fixture.Episodes());

    [Fact]
    public void FoldingIgnoresAccentsCaseAndPunctuation()
    {
        Assert.Equal("amelie et la metaphysique", Search.Fold("Amélie  et-la MÉTAPHYSIQUE"));
        Assert.Equal("", Search.Fold("  "));
    }

    [Fact]
    public void FindsAFilmWithoutItsYearOrAccents()
    {
        var works = Search.Works("substance", _catalogue);
        Assert.Equal("The Substance (2024)", works[0].Title);
        Assert.Equal(860, works[0].Mentions[0].Segment.Start);
        Assert.Equal("L'Accident de piano (2025)", Search.Works("ACCIDENT DE PIANO", _catalogue)[0].Title);
    }

    [Fact]
    public void EveryWordMustMatch()
    {
        Assert.Single(Search.Works("twin peaks fire", _catalogue));
        Assert.Empty(Search.Works("twin banana", _catalogue));
    }

    [Fact]
    public void SeriesAreFoundToo()
    {
        Assert.Equal(SegmentKind.TvShow, Search.Works("severance", _catalogue)[0].Kind);
        Assert.Single(Search.Works("severance", _catalogue, SearchScope.Shows));
        Assert.Empty(Search.Works("severance", _catalogue, SearchScope.Movies));
    }

    [Fact]
    public void CanBeLimitedToOneShow()
    {
        Assert.Single(Search.Works("twin peaks", _catalogue, series: new HashSet<Series> { Series.CodLive }));
        Assert.Empty(Search.Works("twin peaks", _catalogue, series: new HashSet<Series> { Series.Podcast }));
    }

    /// <summary>A film discussed twice gives one work with two mentions, newest first.</summary>
    [Fact]
    public void AFilmDiscussedTwiceIsOneWorkWithTwoMentions()
    {
        var original = _catalogue.Episodes.First(e => e.Id == 1449);
        var segment = original.Segments.First(s => s.Title == "The Substance (2024)");
        var later = new Episode(9999, Series.Soir, original.Date.AddSeconds(86_400 * 30), "", original.AudioUrl, [segment]);
        var catalogue = new Catalogue(_catalogue.Episodes);
        catalogue.Merge([later]);
        var work = Search.Works("the substance", catalogue)[0];
        Assert.Equal([9999L, 1449L], work.Mentions.Select(m => m.Episode.Id));
    }

    [Fact]
    public void ExactTitlesComeBeforePartialOnes()
    {
        var works = Search.Works("the", _catalogue);
        Assert.True(works.Count > 1);
        Assert.StartsWith("the", Search.Fold(works[0].Title));
    }
}

public class CatalogueTests
{
    [Fact]
    public void MergeReplacesKnownEpisodesAndSortsNewestFirst()
    {
        var catalogue = new Catalogue(Fixture.Episodes());
        var dates = catalogue.Episodes.Select(e => e.Date).ToList();
        Assert.Equal(dates.OrderByDescending(d => d), dates);
        var count = catalogue.Episodes.Count;
        catalogue.Merge(catalogue.Episodes.Take(2).ToList());
        Assert.Equal(count, catalogue.Episodes.Count);
    }

    /// <summary>The home page draws its shelves from the catalogue in order: episodes recorded the same day must keep
    /// one order whatever order they come in, or a refresh with nothing new reshuffles it.</summary>
    [Fact]
    public void SameDayEpisodesAlwaysComeInTheSameOrder()
    {
        var day = Fixture.Unix(1_700_000_000);
        var episodes = Enumerable.Range(1, 6).Select(id =>
            new Episode(id, Series.Podcast, id == 6 ? day.AddDays(1) : day, "", new Uri($"https://example.com/{id}.mp3"), [])).ToList();
        long[] expected = [6, 5, 4, 3, 2, 1];
        Assert.Equal(expected, new Catalogue(episodes).Episodes.Select(e => e.Id));
        Assert.Equal(expected, new Catalogue(Enumerable.Reverse(episodes)).Episodes.Select(e => e.Id));
        var merged = new Catalogue(episodes.Take(3));
        merged.Merge(episodes.OrderBy(_ => Guid.NewGuid()));
        Assert.Equal(expected, merged.Episodes.Select(e => e.Id));
        merged.ReplaceEpisodes(Series.Podcast, episodes.OrderBy(_ => Guid.NewGuid()));
        Assert.Equal(expected, merged.Episodes.Select(e => e.Id));
    }

    [Fact]
    public void SavesAndLoadsBack()
    {
        var catalogue = new Catalogue(Fixture.Episodes(), Fixture.Unix(1_700_000_000));
        var path = Path.Combine(Path.GetTempPath(), $"catalogue-{Guid.NewGuid()}.json");
        try
        {
            catalogue.Save(path);
            var loaded = Catalogue.Load(path)!;
            Assert.Equal(catalogue.Episodes, loaded.Episodes);
            Assert.Equal(catalogue.UpdatedAt, loaded.UpdatedAt);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void AnOldSavedCatalogueIsDownloadedAgain()
    {
        var path = Path.Combine(Path.GetTempPath(), $"old-{Guid.NewGuid()}.json");
        File.WriteAllText(path, """{"episodes":[]}""");
        try
        {
            var old = Catalogue.Load(path)!;
            Assert.True(old.NeedsFullDownload);
            Assert.False(new Catalogue().NeedsFullDownload);
            old.MarkDownloadedInFull();
            Assert.False(old.NeedsFullDownload);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void MergingKeepsTheNewerCopyOfAnEpisode()
    {
        var catalogue = new Catalogue(Fixture.Episodes());
        var original = catalogue.Episodes[0];
        var renamed = original with { Summary = "updated" };
        catalogue.Merge([renamed, renamed]);
        Assert.Equal(["updated"], catalogue.Episodes.Where(e => e.Id == original.Id).Select(e => e.Summary));
    }
}

public class SearchIndexTests
{
    [Fact]
    public void IndexAndDirectSearchAgree()
    {
        var catalogue = new Catalogue(Fixture.Episodes());
        var index = new SearchIndex(catalogue);
        foreach (var query in new[] { "the", "twin peaks", "Amélie", "severance", "zzz" })
            Assert.Equal(Search.Works(query, catalogue).Select(w => w.Id), index.Works(query).Select(w => w.Id));
    }

    [Fact]
    public void DescriptionsAreSearchedToo()
    {
        var index = new SearchIndex(new Catalogue(Fixture.Episodes()));
        Assert.Equal([1613L], index.Episodes("dupieux").Select(e => e.Id));
    }
}

public class ScoreTests
{
    [Fact]
    public void TheNumberIsReadFromWhateverTheHostsWrote()
    {
        Assert.Equal(4, Segment.ParseScore("4"));
        Assert.Equal(2, Segment.ParseScore("2 "));
        Assert.Equal(1.5, Segment.ParseScore("1,5"));
        Assert.Equal(3, Segment.ParseScore("3 porte-avions"));
        Assert.Null(Segment.ParseScore("Pas de cotation"));
        Assert.Null(Segment.ParseScore("Pas rattrapé"));
        Assert.Null(Segment.ParseScore(""));
        Assert.Null(Segment.ParseScore(null));
    }

    [Fact]
    public void StarsAreWholeAndClampedToFour()
    {
        static int? Stars(double? score) => new Segment(0, "", SegmentKind.Movie, null, null, score).Stars;
        Assert.Equal(1, Stars(1.5));
        Assert.Equal(4, Stars(4));
        Assert.Equal(4, Stars(5));
        Assert.Equal(0, Stars(0));
        Assert.Null(Stars(null));
        Assert.Equal("★★★☆", Segment.StarString(3));
    }

    [Fact]
    public void ScoreComesFromTheEpisodeData()
    {
        var review = Fixture.Episodes().First(e => e.Id == 1449).Segments.First(s => s.Title == "The Substance (2024)");
        Assert.Equal(4, review.Score);
        Assert.Equal(4, review.Stars);
        Assert.Equal("4 bonnes doses", review.SpokenVerdict);
    }

    [Fact]
    public void ListsEveryPassageWithAScoreNewestFirstWithoutAQuery()
    {
        var index = new SearchIndex(new Catalogue(Fixture.Episodes()));
        var four = index.Works("", stars: 4);
        Assert.Contains("The Substance (2024)", four.Select(w => w.Title));
        Assert.All(four, w => Assert.All(w.Mentions, m => Assert.Equal(4, m.Segment.Stars)));
        Assert.Empty(index.Works(""));                       // no query and no score: nothing
        Assert.Empty(index.Works("substance", stars: 1));
        Assert.Single(index.Works("substance", stars: 4));
    }
}

public class FeedTests
{
    [Fact]
    public void ReadsEpisodesNewestFirstAndSkipsOnesWithoutAudio()
    {
        var episodes = Fixture.Feed();
        Assert.Equal(6, episodes.Count);                                  // the 7th has no audio file
        Assert.Equal(episodes.Select(e => e.Date).OrderByDescending(d => d), episodes.Select(e => e.Date));
        Assert.All(episodes, e => { Assert.Equal(Series.QuelquePart, e.Series); Assert.Empty(e.Segments); });
        Assert.Equal("Halloween Mixtape", episodes[0].Name);
        Assert.Equal("audio.ausha.co", episodes[0].AudioUrl.Host);
        Assert.Equal(4987, episodes[0].Duration);                         // 1:23:07
    }

    [Fact]
    public void IdsAreStableAndNeverClashWithTheSitesOwn()
    {
        var first = Fixture.Feed();
        var second = Fixture.Feed();
        Assert.Equal(first.Select(e => e.Id), second.Select(e => e.Id));
        Assert.All(first, e => Assert.True(e.Id < 0));
        Assert.Equal(first.Count, first.Select(e => e.Id).Distinct().Count());
    }

    [Fact]
    public void CoversUseTheSmallVersion() =>
        Assert.Contains("_400x400", Fixture.Feed()[0].Artwork!.AbsoluteUri);

    [Fact]
    public void DurationsAreReadInEveryFormat()
    {
        Assert.Equal(4987, FeedClient.ParseDuration("1:23:07"));
        Assert.Equal(262, FeedClient.ParseDuration("04:22"));
        Assert.Equal(3600, FeedClient.ParseDuration("3600"));
        Assert.Null(FeedClient.ParseDuration("n/a"));
    }

    [Fact]
    public void TheTitleIsSearchable()
    {
        var index = new SearchIndex(new Catalogue(Fixture.Feed()));
        Assert.Single(index.Episodes("halloween"));
        Assert.Single(index.Episodes("episode 44"));
    }

    [Fact]
    public void TheShowDoesNotUseTheSitesSlowServerWorkaround()
    {
        Assert.False(Series.QuelquePart.IsOnSite());
        Assert.True(Series.Podcast.IsOnSite());
    }

    [Fact]
    public void TheMusicPodcastKeepsItsIds() =>
        Assert.Equal(FeedClient.StableId("d32384faf19616ab609832fbda64a126f80f4cc0"), Fixture.Feed()[0].Id);
}

public class DiscoveryTests
{
    private readonly Catalogue _catalogue = new(Fixture.Episodes());

    private static Segment Movie(string title) => Fixture.Movie(title);

    [Fact]
    public void TheYearIsReadFromTheTitle()
    {
        Assert.Equal(2013, Movie("Oblivion (2013)").Year);
        Assert.Equal("Oblivion", Movie("Oblivion (2013)").DisplayTitle);
        Assert.Null(Movie("Black Mirror").Year);
        Assert.Equal("Black Mirror", Movie("Black Mirror").DisplayTitle);
        Assert.Equal(2009, Movie("(500) jours ensemble (2009)").Year);
        Assert.Equal("(500) jours ensemble", Movie("(500) jours ensemble (2009)").DisplayTitle);
        Assert.Null(Movie("Blade Runner 2049").Year);
        Assert.Equal("Oblivion", Movie("Oblivion (2013) ").DisplayTitle);
        Assert.Null(Movie("Film (20133)").Year);
    }

    /// <summary>The year is read by hand for speed: it must say exactly what the regular expressions it replaced said.</summary>
    [Fact]
    public void TheYearReaderAgreesWithTheRegularExpressions()
    {
        static int? RegexYear(string title) =>
            Regex.Match(title, @"\(([0-9]{4})\)\s*$") is { Success: true } m ? int.Parse(m.Groups[1].Value) : null;
        static string RegexDisplayTitle(string title) =>
            RegexYear(title) is null ? title : Regex.Replace(title, @"\s*\([0-9]{4}\)\s*$", "");
        string[] odd = ["Oblivion (2013)", "Oblivion(2013)", "Oblivion  (2013)  ", "Oblivion (2013)\n", "(2013)", "Film (13)",
            "Film (20133)", "Film 2013)", "Film (2013", "Film (2013) suite", "Amélie (2001)", "Été 85 (2020)",
            "Film (2013)", "Film (٢٠١٣)", "", " ", "()", "Film (2O13)", "M (1931)", "Film (1999) (2000)"];
        foreach (var title in odd.Concat(_catalogue.Episodes.SelectMany(e => e.Segments).Select(s => s.Title)))
        {
            Assert.Equal(RegexYear(title), Movie(title).Year);
            Assert.Equal(RegexDisplayTitle(title), Movie(title).DisplayTitle);
        }
    }

    [Fact]
    public void DecadesGroupFilmsByTheirReleaseYear()
    {
        Assert.Equal(0, Decades.Of(1959));
        Assert.Equal(1980, Decades.Of(1986));
        Assert.Equal(2020, Decades.Of(2024));
        Assert.Equal("Années 80", Decades.Title(1980));
        Assert.Equal("Années 2000", Decades.Title(2000));
        Assert.Equal("Avant 1960", Decades.Title(0));
    }

    private static string? PassageTitle(ShelfItem item) => item is ShelfItem.Passage p ? p.Mention.Segment.Title : null;

    [Fact]
    public void AListingHoldsOnePassagePerFilm()
    {
        var titles = new Discovery(_catalogue).Items(Listing.Latest).Select(PassageTitle).ToList();
        Assert.NotEmpty(titles);
        Assert.Equal(titles.Count, titles.Distinct().Count());
    }

    [Fact]
    public void StarListingsOnlyHoldThatScore()
    {
        var fours = new Discovery(_catalogue).Items(Listing.OfStars(4));
        Assert.NotEmpty(fours);
        Assert.All(fours, i => Assert.Equal(4, ((ShelfItem.Passage)i).Mention.Segment.Stars));
    }

    [Fact]
    public void UnratedHoldsOnlyFilmsWithoutAScore()
    {
        var unrated = new Discovery(_catalogue).Items(Listing.Unrated);
        Assert.NotEmpty(unrated);
        Assert.All(unrated, i =>
        {
            var segment = ((ShelfItem.Passage)i).Mention.Segment;
            Assert.Null(segment.Stars);
            Assert.Equal(SegmentKind.Movie, segment.Kind);
        });
    }

    [Fact]
    public void TheSameSeedGivesTheSameShelves()
    {
        var discovery = new Discovery(_catalogue);
        var a = discovery.Shelves(42).Select(s => s.Items.Select(i => i.Id).ToList()).ToList();
        var b = discovery.Shelves(42).Select(s => s.Items.Select(i => i.Id).ToList()).ToList();
        Assert.Equal(a, b);
        Assert.All(discovery.Shelves(42), s => Assert.NotEmpty(s.Items));
        Assert.DoesNotContain(discovery.Shelves(42), s => s.Id == "latest");     // the archive is frozen: no "latest" shelf
    }

    [Fact]
    public void DecadeTilesCountTheirFilms()
    {
        var discovery = new Discovery(_catalogue);
        var tiles = discovery.DecadeTiles(1);
        Assert.NotEmpty(tiles);
        Assert.All(tiles, t => Assert.True(t.Count > 0));
        Assert.True(tiles.Sum(t => t.Count) <= discovery.Items(Listing.Latest).Count);
    }

    [Fact]
    public void TheHeroIsAWellRatedFilmWithAPoster()
    {
        var hero = new Discovery(_catalogue).Hero(3)!;
        Assert.True((hero.Segment.Stars ?? 0) >= 3);
        Assert.NotNull(hero.Segment.PosterUrl);
    }

    [Fact]
    public void AWorkIsFoundByKindAndTitle()
    {
        var index = new SearchIndex(_catalogue);
        var work = index.FindWork(SegmentKind.Movie, "The Substance (2024)")!;
        Assert.Single(work.Mentions);
        Assert.Null(index.FindWork(SegmentKind.TvShow, "The Substance (2024)"));
    }
}

public class RobustDecodingTests
{
    /// <summary>One broken episode (and one broken segment, and some junk values) must not sink the whole page.</summary>
    [Fact]
    public void BadEntriesAreSkippedNotFatal()
    {
        var json = """
        {"pagination": {"total_pages": 1}, "podcasts": [
          {"id": 1, "kind": "cinq_heures", "display_name": "Podcast du 01/02/2020",
           "audio_file_url": "https://example.com/a.mp3",
           "parts": [
             {"id": 10, "display_name": "Good (2019)", "kind": "movie", "start_second": 120, "score": "3", "score_text": "3 étoiles"},
             {"id": "not a number", "kind": "movie"},
             42,
             {"id": 11, "display_name": "Also good", "kind": "tv_show", "start_second": null, "score": 2}
           ]},
          {"id": "broken episode"},
          null,
          "junk",
          {"id": 2, "kind": "cod_live", "display_name": "Podcast du 03/04/2018",
           "audio_file_url": "https://example.com/b.mp3", "parts": []}
        ]}
        """;
        var episodes = Wire.ParsePage(Encoding.UTF8.GetBytes(json)).Episodes;
        Assert.Equal([1L, 2L], episodes.Select(e => e.Id));
        Assert.Equal([10L, 11L], episodes[0].Segments.Select(s => s.Id));
        Assert.Equal(2, episodes[0].Segments[1].Score);                    // a number, not a string
    }

    [Fact]
    public void TheSiteGivesEachFilmItsSlug()
    {
        var json = """
        {"podcasts":[{"id":1613,"kind":"cinq_heures","display_name":"Podcast du 27/06/2025","available_at":"2025-07-27",
          "description":"","audio_file_url":"https://example.org/a.mp3","parts":[
          {"id":8167,"display_name":"Pfau - Bin ich echt? (2025)","kind":"movie","start_second":252,"score":"","score_text":"","poster_url":null,"slug":"peacock"},
          {"id":8168,"display_name":"Olympo","kind":"tv_show","start_second":900,"score":"","score_text":"","poster_url":null,"slug":null}]}],
         "pagination":{"total_pages":1}}
        """;
        var episodes = Wire.ParsePage(Encoding.UTF8.GetBytes(json)).Episodes;
        Assert.Equal(["peacock", null], episodes[0].Segments.Select(s => s.Slug));
    }
}

public class DayezFeedTests
{
    private static void Is(string raw, params string[] expected) => Assert.Equal(expected, FeedClient.FilmTitles(raw));

    [Fact]
    public void FilmTitlesAreReadWhicheverWayTheTitleIsWritten()
    {
        Is("Coward - Wicker - Karma", "Coward", "Wicker", "Karma");
        Is("\"Les Misérables\", \"Le Corset\", \"Franz\"", "Les Misérables", "Le Corset", "Franz");
        Is("\"The Social Reckoning\" - \"Ni vue, ni connue\" - \"Fausse Note\"", "The Social Reckoning", "Ni vue, ni connue", "Fausse Note");
        Is("Digger, Notre Salut et Verity", "Digger", "Notre Salut", "Verity");
        Is("\"Downton Abbey, le grand final\" ; \"Sirat\"  et  \" Miroirs n°3 \"", "Downton Abbey, le grand final", "Sirat", "Miroirs n°3");
        Is("Cinéma, avec Hugues Dayez - \"Un simple accident\"-\"Rembrandt\"-\"LHomme qui a vu l'ours qui a vu l'homme\" - 01/10/2025",
           "Un simple accident", "Rembrandt", "LHomme qui a vu l'ours qui a vu l'homme");
        Is("Cinéma : Moulin - La Gradiva - The only living pickpocket in New York", "Moulin", "La Gradiva", "The only living pickpocket in New York");
        // The odd ones in the real feed.
        Is("Les chroniques de la Grande matinée, avec Hugues Dayez - Cinéma : Raisons et Sentiments-Garance-Chopin, Chopin! - 23/09/2026",
           "Raisons et Sentiments", "Garance", "Chopin, Chopin!");
        Is("\"Le chant des Forêts\", 'A pied d'oeuvre\", 'L'enfant bélier\"", "Le chant des Forêts", "A pied d'oeuvre", "L'enfant bélier");
        Is("Tron: Arès / Mary Anning, film d'animation / The end avec Tilda Swinton", "Tron: Arès", "Mary Anning", "The end");
        Is("The Death of Robin Hood de Michael Sarnoski", "The Death of Robin Hood");
        Is("La voix de Hind Rajab - Misérables - Running man", "La voix de Hind Rajab", "Misérables", "Running man");
        Is("l'homme qui rétrécit - Interview jean dujardin-mp3", "l'homme qui rétrécit");
        Is("Linterview de Sophie Marceau pour LOL 2.0");
        Is("\"Marsupilami\", et si le cinéma arrêtait de massacrer Franquin ?", "Marsupilami");
    }

    [Fact]
    public void EpisodesCarryTheirFilmsAndPlayFromTheStart()
    {
        var episodes = Fixture.Dayez();
        Assert.Equal(8, episodes.Count);
        Assert.All(episodes, e => { Assert.Equal(Series.Dayez, e.Series); Assert.False(e.Series.IsOnSite()); });
        var coward = episodes.First(e => e.Segments.Select(s => s.Title).Contains("Coward"));
        Assert.Equal(3, coward.Subjects.Count());
        Assert.All(coward.Segments, s => { Assert.Null(s.Start); Assert.Equal(SegmentKind.Movie, s.Kind); });
        Assert.Equal("Coward · Wicker · Karma", coward.Name);
        Assert.Contains("Lucas Dont", coward.Summary);                       // the director, from the description
        Assert.All(episodes, e => Assert.False(e.Summary.StartsWith("cinema-sorties")));
        // The title's own date wins over a wrong publication date (01/01/2025 in the feed).
        var accident = episodes.First(e => e.Segments.Select(s => s.Title).Contains("Rembrandt"));
        Assert.Equal("01/10/2025", EpisodeDates.Short(accident.Date));
        // Searchable alongside everything else.
        var index = new SearchIndex(new Catalogue(episodes));
        Assert.Equal(Series.Dayez, index.Works("wicker")[0].Mentions[0].Episode.Series);
        var ids = episodes.SelectMany(e => e.Segments).Select(s => s.Id).ToList();
        Assert.Equal(ids.Count, ids.Distinct().Count());
    }

    [Fact]
    public void AFeedRefreshReplacesThatShowOnly()
    {
        var site = Fixture.Episodes();
        var dayez = Fixture.Dayez();
        var catalogue = new Catalogue(site.Concat(dayez));
        // A stale copy under another id, as an id-scheme change would leave behind.
        catalogue.Merge([new Episode(-42, Series.Dayez, DateTime.UtcNow, "", dayez[0].AudioUrl, [])]);
        catalogue.ReplaceEpisodes(Series.Dayez, dayez);
        Assert.Equal(dayez.Count, catalogue.Episodes.Count(e => e.Series == Series.Dayez));
        Assert.Equal(site.Count(e => e.Series.IsOnSite()), catalogue.Episodes.Count(e => e.Series.IsOnSite()));
    }
}

public class TmdbMatchingTests
{
    [Fact]
    public void TitlesAreComparedGenerously()
    {
        Assert.Equal(10, TMDBClient.Similarity("Fausse Note", ["Fausse note"]));
        Assert.Equal(10, TMDBClient.Similarity("LHomme qui a vu l'ours qui a vu l'homme", ["L'Homme qui a vu l'ours qui a vu l'homme"]));
        Assert.Equal(6, TMDBClient.Similarity("Miroirs n°3", ["Miroirs No. 3"]));
        Assert.Equal(6, TMDBClient.Similarity("Downton Abbey, le grand final", ["Downton Abbey III : Le Grand Final"]));
        Assert.Equal(6, TMDBClient.Similarity("Beginnings", ["Transformers: Beginnings"]));
        Assert.Equal(0, TMDBClient.Similarity("Karma", ["Garance"]));
    }

    [Fact]
    public void FilmsInAnotherScriptKeepTheirFrenchTitle()
    {
        Assert.Equal("Résurrection (2025)", new FilmInfo { TmdbId = 1, Title = "Résurrection", OriginalTitle = "狂野时代", Year = 2025 }.ArchiveTitle);
        Assert.Equal("Sirāt (2025)", new FilmInfo { TmdbId = 2, Title = "Sirat", OriginalTitle = "Sirāt", Year = 2025 }.ArchiveTitle);
    }

    [Fact]
    public void ADayezEpisodeTakesTmdbsTitlePosterAndSynopsis()
    {
        var episode = Fixture.Dayez().First(e => e.SpokenFilms.Contains("Coward"));
        var library = new FilmLibrary();
        library.Record(new FilmInfo { TmdbId = 9, Title = "Les Braves", OriginalTitle = "Coward", Year = 2026, Overview = "1916…",
                                      PosterPath = "/x.jpg", Director = "Lukas Dhont" }, "Coward", episode.Date);
        library.Record(null, "Wicker", episode.Date);
        var enriched = library.Enrich(episode);
        Assert.Equal("Coward (2026)", enriched.Segments[0].Title);
        Assert.Equal("Les Braves", enriched.Segments[0].LocalTitle);
        Assert.Equal("https://image.tmdb.org/t/p/w500/x.jpg", enriched.Segments[0].PosterUrl!.AbsoluteUri);
        Assert.Equal("Lukas Dhont", enriched.Segments[0].Director);
        Assert.Equal("Wicker", enriched.Segments[1].Title);                         // not found: left as it was
        Assert.Equal("Coward (2026)", library.Enrich(enriched).Segments[0].Title);   // enriching twice changes nothing
        Assert.False(library.NeedsLookup("Wicker", episode.Date));                   // tried this week
        Assert.True(library.NeedsLookup("Wicker", episode.Date, DateTime.UtcNow.AddDays(8)));

        // A new release not found yet is asked about again within the day; an old film, a week later.
        var thisWeek = DateTime.UtcNow;
        var fresh = new FilmLibrary();
        fresh.Record(null, "Moulin", thisWeek, thisWeek);
        Assert.False(fresh.NeedsLookup("Moulin", thisWeek, thisWeek.AddHours(1)));
        Assert.True(fresh.NeedsLookup("Moulin", thisWeek, thisWeek.AddHours(7)));
        var longAgo = thisWeek.AddDays(-400);
        fresh.Record(null, "Old", longAgo, thisWeek);
        Assert.False(fresh.NeedsLookup("Old", longAgo, thisWeek.AddHours(7)));
    }
}
