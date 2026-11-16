using System.Text.Json;
using System.Text.Json.Serialization;
using CinqHeures.Core;

namespace CinqHeures;

/// <summary>What the listener chose or did, kept between launches (the Mac keeps it in UserDefaults): favourites, where each
/// episode was left, the speed and volume, how listings are sorted. It survives a cache reset.</summary>
public sealed class UserData
{
    [JsonPropertyName("favorites")] public List<long> Favorites { get; set; } = [];
    [JsonPropertyName("positions")] public Dictionary<string, double> Positions { get; set; } = [];
    [JsonPropertyName("positionDates")] public Dictionary<string, double> Dates { get; set; } = [];
    [JsonPropertyName("episodeLengths")] public Dictionary<string, double> Lengths { get; set; } = [];
    [JsonPropertyName("rate")] public double Rate { get; set; } = 1;
    [JsonPropertyName("volume")] public double Volume { get; set; } = 1;
    [JsonPropertyName("listingOrder")] public string ListingOrder { get; set; } = "date";
    [JsonPropertyName("listingReversed")] public bool ListingReversed { get; set; }
    [JsonPropertyName("listingLayout")] public string ListingLayout { get; set; } = "grid";
    [JsonPropertyName("showLayout")] public string ShowLayout { get; set; } = "list";
    [JsonPropertyName("notify")] public bool Notify { get; set; } = true;
    [JsonPropertyName("seenEpisodes")] public List<long> SeenEpisodes { get; set; } = [];
    [JsonPropertyName("window")] public int[]? Window { get; set; }

    private static string Path => System.IO.Path.Combine(AppPaths.Data, "settings.json");

    public static UserData Load()
    {
        try
        {
            using var stream = File.OpenRead(Path);
            return JsonSerializer.Deserialize<UserData>(stream) ?? new UserData();
        }
        catch (Exception) { return new UserData(); }
    }

    public void Save()
    {
        try { CoreJson.SaveAtomically(Path, stream => JsonSerializer.Serialize(stream, this)); }
        catch (IOException) { }
    }
}
