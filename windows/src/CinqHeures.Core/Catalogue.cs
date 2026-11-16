using System.Text.Json;
using System.Text.Json.Serialization;

namespace CinqHeures.Core;

/// <summary>Every episode and everything discussed in it, kept in memory for instant search and saved to disk so the
/// next launch starts with it. The episode list is replaced, never changed in place, so <see cref="Snapshot"/> is cheap
/// and a background thread can read a snapshot while the app goes on merging.</summary>
public sealed class Catalogue
{
    /// <summary>Bumped when the app starts keeping something new from each episode; a saved catalogue with an older
    /// number is downloaded again once (and stays usable until then). 3: each film's slug, for its synopsis.</summary>
    public const int CurrentSchema = 3;

    public IReadOnlyList<Episode> Episodes { get; private set; }
    public DateTime? UpdatedAt { get; private set; }
    public int Schema { get; private set; }

    public Catalogue() : this([], null) { }

    public Catalogue(IEnumerable<Episode> episodes, DateTime? updatedAt = null)
    {
        Episodes = Sorted(episodes);
        UpdatedAt = updatedAt;
        Schema = CurrentSchema;
    }

    private Catalogue(Catalogue other)
    {
        Episodes = other.Episodes;
        UpdatedAt = other.UpdatedAt;
        Schema = other.Schema;
    }

    /// <summary>A copy that later changes to this catalogue don't touch.</summary>
    public Catalogue Snapshot() => new(this);

    /// <summary>Newest first, and episodes recorded the same day always in the same order (by id): without that,
    /// each refresh listed same-day episodes in a new order, enough to change the home page's shelves with nothing new.</summary>
    private static List<Episode> Sorted(IEnumerable<Episode> episodes) =>
        episodes.OrderByDescending(e => e.Date).ThenByDescending(e => e.Id).ToList();

    public bool NeedsFullDownload => Schema < CurrentSchema;

    /// <summary>Records that every episode was downloaded with the current fields.</summary>
    public void MarkDownloadedInFull() => Schema = CurrentSchema;

    public bool IsEmpty => Episodes.Count == 0;

    /// <summary>Adds new episodes and replaces the ones already known, newest first.</summary>
    public void Merge(IEnumerable<Episode> fresh, DateTime? at = null)
    {
        var byId = new Dictionary<long, Episode>();
        foreach (var e in Episodes) byId[e.Id] = e;
        foreach (var e in fresh) byId[e.Id] = e;
        Episodes = Sorted(byId.Values);
        UpdatedAt = at ?? DateTime.UtcNow;
    }

    /// <summary>Puts a feed show's current episodes in place of the ones known before: an episode removed from the feed
    /// goes, and an id scheme that changed can't leave copies behind.</summary>
    public void ReplaceEpisodes(Series series, IEnumerable<Episode> fresh, DateTime? at = null)
    {
        Episodes = Episodes.Where(e => e.Series != series).ToList();
        Merge(fresh, at);
    }

    public Episode? Episode(long id) => Episodes.FirstOrDefault(e => e.Id == id);

    // MARK: Saving

    private sealed class Stored
    {
        [JsonPropertyName("episodes")] public List<Episode> Episodes { get; set; } = [];
        [JsonPropertyName("updatedAt")] public DateTime? UpdatedAt { get; set; }
        [JsonPropertyName("schema")] public int? Schema { get; set; }
    }

    public static Catalogue? Load(string path)
    {
        try
        {
            using var stream = File.OpenRead(path);
            return Load(stream);
        }
        catch (Exception) { return null; }
    }

    public static Catalogue? Load(Stream stream)
    {
        try
        {
            var stored = JsonSerializer.Deserialize<Stored>(stream, CoreJson.Options);
            if (stored is null) return null;
            return new Catalogue(stored.Episodes, stored.UpdatedAt) { Schema = stored.Schema ?? 1 };
        }
        catch (Exception) { return null; }
    }

    public void Save(string path) =>
        CoreJson.SaveAtomically(path, stream => JsonSerializer.Serialize(stream,
            new Stored { Episodes = Episodes.ToList(), UpdatedAt = UpdatedAt, Schema = Schema }, CoreJson.Options));
}
