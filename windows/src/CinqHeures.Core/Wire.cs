using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace CinqHeures.Core;

/// <summary>The JSON as 5heures.be sends it, read into the app's own models. Only what the app uses is read, and every
/// field that has ever been missing is optional. Arrays are read leniently: one malformed episode (or part) is skipped
/// instead of failing the whole page, and with it the refresh.</summary>
public static class Wire
{
    public static (List<Episode> Episodes, int TotalPages) ParsePage(ReadOnlyMemory<byte> data)
    {
        using var document = JsonDocument.Parse(data);
        var root = document.RootElement;
        var totalPages = root.GetProperty("pagination").GetProperty("total_pages").GetInt32();
        var episodes = new List<Episode>();
        foreach (var element in root.GetProperty("podcasts").EnumerateArray())
        {
            try
            {
                if (EpisodeFrom(element) is { } episode) episodes.Add(episode);
            }
            catch (Exception e) when (e is InvalidOperationException or KeyNotFoundException or FormatException) { }
        }
        return (episodes, totalPages);
    }

    /// <summary>The years each show has episodes for.</summary>
    public static Dictionary<Series, List<int>> ParseYears(ReadOnlyMemory<byte> data)
    {
        using var document = JsonDocument.Parse(data);
        var result = new Dictionary<Series, List<int>>();
        foreach (var kind in document.RootElement.GetProperty("config").GetProperty("years_for_kinds").EnumerateObject())
        {
            if (SeriesInfo.FromRaw(kind.Name) is { } series)
                result[series] = kind.Value.EnumerateArray().Select(y => y.GetInt32()).ToList();
        }
        return result;
    }

    public static Episode? EpisodeFrom(string json)
    {
        using var document = JsonDocument.Parse(json);
        return EpisodeFrom(document.RootElement);
    }

    /// <summary>Null for an episode the app can't use: unknown show, no audio file, no readable date. Throws when a
    /// required field is missing or of the wrong type (the page then skips it).</summary>
    public static Episode? EpisodeFrom(JsonElement e)
    {
        var id = e.GetProperty("id").GetInt64();
        var kind = e.GetProperty("kind").GetString();
        var displayName = e.GetProperty("display_name").GetString() ?? throw new FormatException("display_name");
        var availableAt = OptionalString(e, "available_at");
        var description = OptionalString(e, "description");
        var audio = OptionalString(e, "audio_file_url");

        if (SeriesInfo.FromRaw(kind) is not { } series
            || audio is null || !Uri.TryCreate(audio, UriKind.Absolute, out var audioUri)
            || RecordingDate(displayName, availableAt) is not { } date)
            return null;

        var segments = new List<Segment>();
        if (e.TryGetProperty("parts", out var parts) && parts.ValueKind == JsonValueKind.Array)
        {
            foreach (var part in parts.EnumerateArray())
            {
                try
                {
                    if (SegmentFrom(part) is { } segment) segments.Add(segment);
                }
                catch (Exception ex) when (ex is InvalidOperationException or KeyNotFoundException or FormatException) { }
            }
        }
        return new Episode(id, series, date, description ?? "", audioUri, segments);
    }

    private static Segment? SegmentFrom(JsonElement part)
    {
        var id = part.GetProperty("id").GetInt64();
        _ = part.GetProperty("display_name").GetString() ?? throw new FormatException("display_name");
        var title = part.GetProperty("display_name").GetString()!;
        if (SegmentKindInfo.FromRaw(part.GetProperty("kind").GetString()) is not { } kind) return null;
        var start = OptionalNumber(part, "start_second");
        var verdict = OptionalString(part, "score_text");
        if (verdict is { Length: 0 }) verdict = null;
        var poster = OptionalString(part, "poster_url");
        var slug = OptionalString(part, "slug");
        return new Segment(id, title, kind, start, verdict, Segment.ParseScore(LooseString(part, "score")),
                           poster is not null && Uri.TryCreate(poster, UriKind.Absolute, out var posterUri) ? posterUri : null,
                           slug: kind == SegmentKind.Movie && !string.IsNullOrEmpty(slug) ? slug : null);
    }

    private static string? OptionalString(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static double? OptionalNumber(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : null;

    /// <summary>A field the API sends as a string, a number or null depending on the entry.</summary>
    private static string? LooseString(JsonElement e, string name)
    {
        if (!e.TryGetProperty(name, out var v)) return null;
        return v.ValueKind switch
        {
            JsonValueKind.String => v.GetString(),
            JsonValueKind.Number => v.GetDouble().ToString("R", CultureInfo.InvariantCulture),
            _ => null,
        };
    }

    private static readonly Regex DatePattern = new(@"[0-9]{2}/[0-9]{2}/[0-9]{4}", RegexOptions.Compiled);

    /// <summary>"Podcast du 27/06/2025" → that day. Falls back to the API's date, which is later than the recording by
    /// about a month but is the only date left.</summary>
    public static DateTime? RecordingDate(string displayName, string? availableAt)
    {
        var match = DatePattern.Match(displayName);
        if (match.Success && EpisodeDates.ParseShort(match.Value) is { } date) return date;
        return availableAt is null ? null : EpisodeDates.ParseIso(availableAt);
    }
}
