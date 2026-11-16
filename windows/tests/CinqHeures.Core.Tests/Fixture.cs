using CinqHeures.Core;

namespace CinqHeures.Core.Tests;

internal static class Fixture
{
    public static string Path(string name) => System.IO.Path.Combine(AppContext.BaseDirectory, name);

    /// <summary>The sample episodes, as 5heures.be sends them.</summary>
    public static List<Episode> Episodes() => Wire.ParsePage(File.ReadAllBytes(Path("Fixtures/episodes.json"))).Episodes;

    public static List<Episode> Dayez() => FeedClient.Parse(File.ReadAllBytes(Path("Fixtures/dayez.xml")), Series.Dayez);

    public static List<Episode> Feed() => FeedClient.Parse(File.ReadAllBytes(Path("Fixtures/feed.xml")));

    public static DateTime Day(string ddMMyyyy) => EpisodeDates.ParseShort(ddMMyyyy)!.Value;

    public static DateTime Unix(long seconds) => DateTimeOffset.FromUnixTimeSeconds(seconds).UtcDateTime;

    public static Segment Movie(string title, long id = 0, string? slug = null) =>
        new(id, title, SegmentKind.Movie, null, null, slug: slug);
}
