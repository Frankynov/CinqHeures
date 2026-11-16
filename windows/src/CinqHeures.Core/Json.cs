using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CinqHeures.Core;

/// <summary>The saved files are the macOS app's own format, so the snapshots shipped with it load here as they are:
/// Swift's default date is a number of seconds since 1 January 2001, empty optionals are left out, and the shows
/// and kinds are written by their raw names.</summary>
public static class CoreJson
{
    public static readonly DateTime AppleEpoch = new(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    public static readonly JsonSerializerOptions Options = Build();

    private static JsonSerializerOptions Build()
    {
        var options = new JsonSerializerOptions
        {
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            PropertyNameCaseInsensitive = true,
        };
        options.Converters.Add(new AppleDateConverter());
        options.Converters.Add(new SeriesConverter());
        options.Converters.Add(new SegmentKindConverter());
        return options;
    }

    public static DateTime FromApple(double seconds) => AppleEpoch.AddSeconds(seconds);

    public static double ToApple(DateTime date) => (date.ToUniversalTime() - AppleEpoch).TotalSeconds;

    private sealed class AppleDateConverter : JsonConverter<DateTime>
    {
        public override DateTime Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options) =>
            FromApple(reader.GetDouble());

        public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions options) =>
            writer.WriteNumberValue(ToApple(value));
    }

    private sealed class SeriesConverter : JsonConverter<Series>
    {
        public override Series Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options) =>
            SeriesInfo.FromRaw(reader.GetString()) ?? throw new JsonException("Unknown show");

        public override void Write(Utf8JsonWriter writer, Series value, JsonSerializerOptions options) =>
            writer.WriteStringValue(value.Raw());
    }

    private sealed class SegmentKindConverter : JsonConverter<SegmentKind>
    {
        public override SegmentKind Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options) =>
            SegmentKindInfo.FromRaw(reader.GetString()) ?? throw new JsonException("Unknown kind");

        public override void Write(Utf8JsonWriter writer, SegmentKind value, JsonSerializerOptions options) =>
            writer.WriteStringValue(value.Raw());
    }

    /// <summary>Writes a file in one go, through a temporary file, so a crash never leaves half of one.</summary>
    public static void SaveAtomically(string path, Action<Stream> write)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + ".tmp";
        using (var stream = File.Create(temp)) write(stream);
        File.Move(temp, path, overwrite: true);
    }
}

/// <summary>Where the app keeps what it learns. <c>CINQHEURES_DATA</c> moves it, for tests and screenshots.</summary>
public static class AppPaths
{
    public static string Data { get; } = Environment.GetEnvironmentVariable("CINQHEURES_DATA") is { Length: > 0 } custom
        ? custom
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CinqHeures");

    public static string Cache => Path.Combine(Data, "Cache");
    public static string Catalogue => Path.Combine(Data, "catalogue.json");
    public static string Films => Path.Combine(Data, "films.json");
    public static string Chapters => Path.Combine(Data, "chapters.json");
    public static string Details => Path.Combine(Data, "details.json");
}

/// <summary>With <c>CINQHEURES_DEBUG=1</c>, a line per event in <c>debug.log</c> of the data folder: what the player and the
/// loader do. Off otherwise.</summary>
public static class DebugLog
{
    public static readonly bool On = Environment.GetEnvironmentVariable("CINQHEURES_DEBUG") is { Length: > 0 };
    /// <summary><c>CINQHEURES_NODISK=1</c>: neither play from the disk cache nor fill it, to test the stream alone.</summary>
    public static readonly bool NoDisk = Environment.GetEnvironmentVariable("CINQHEURES_NODISK") is { Length: > 0 };
    private static readonly DateTime Start = DateTime.UtcNow;
    private static readonly object Lock = new();

    public static void Write(string message)
    {
        if (!On) return;
        try
        {
            lock (Lock)
            {
                Directory.CreateDirectory(AppPaths.Data);
                File.AppendAllText(Path.Combine(AppPaths.Data, "debug.log"), $"[{(DateTime.UtcNow - Start).TotalSeconds,8:F2}] {message}{Environment.NewLine}");
            }
        }
        catch (IOException) { }
    }
}
