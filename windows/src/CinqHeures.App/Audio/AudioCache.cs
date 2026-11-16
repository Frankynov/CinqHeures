using System.Security.Cryptography;
using System.Text;
using CinqHeures.Core;

namespace CinqHeures;

/// <summary>The episodes played lately, kept on disk: the one playing and the last few before it.
///
/// While an episode plays its whole file downloads in the background, from the start, one file at a time.
/// <see cref="RangeStream"/> reads from it whatever has arrived, so a jump into the part already fetched is instant, even
/// when 5heures.be's server would have taken a minute to answer; once complete, the episode plays from the file,
/// offline too. An interrupted file carries on where it stopped.</summary>
public sealed class AudioCache
{
    public static AudioCache Shared { get; } = new();

    /// <summary>The one playing and the five before it.</summary>
    public const int Kept = 6;

    public static string Folder => Path.Combine(AppPaths.Cache, "Episodes");

    private readonly object _lock = new();
    private readonly HttpClient _http = new(new SocketsHttpHandler { UseCookies = false }) { Timeout = Timeout.InfiniteTimeSpan };
    private Uri? _downloading;
    private long _written;
    private long? _total;
    private CancellationTokenSource? _cancel;

    private AudioCache()
    {
        _http.DefaultRequestHeaders.UserAgent.ParseAdd(SiteClient.UserAgent);
    }

    private static string NameOf(Uri url) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(url.AbsoluteUri)))[..24].ToLowerInvariant();

    private static string Complete(Uri url) => Path.Combine(Folder, NameOf(url) + ".mp3");
    private static string Partial(Uri url) => Path.Combine(Folder, NameOf(url) + ".part");

    /// <summary>The whole file on disk, if it has been downloaded.</summary>
    public string? File(Uri url) => !DebugLog.NoDisk && System.IO.File.Exists(Complete(url)) ? Complete(url) : null;

    /// <summary>The file's length, once known (from a complete file or the download's answer).</summary>
    public long? Length(Uri url)
    {
        if (File(url) is { } file) return new FileInfo(file).Length;
        lock (_lock) return _downloading == url ? _total : null;
    }

    /// <summary>The bytes in <c>[first, last]</c>, if they're on disk: in the complete file, or already in the part being fetched.</summary>
    public byte[]? Read(Uri url, long first, long last)
    {
        string source;
        if (File(url) is { } file) source = file;
        else
        {
            long available;
            lock (_lock) available = _downloading == url ? _written : 0;
            if (last >= available) return null;
            source = Partial(url);
        }
        try
        {
            using var stream = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            stream.Seek(first, SeekOrigin.Begin);
            var data = new byte[last - first + 1];
            var read = 0;
            while (read < data.Length)
            {
                var n = stream.Read(data, read, data.Length - read);
                if (n == 0) return null;
                read += n;
            }
            return data;
        }
        catch (IOException) { return null; }
    }

    /// <summary>The episode at <paramref name="url"/> is being played: keep it, and fetch the rest of it if it isn't all here.</summary>
    public void Playing(Uri url)
    {
        if (DebugLog.NoDisk) return;
        Directory.CreateDirectory(Folder);
        if (File(url) is { } file)
        {
            // Most recently played first, for Prune.
            try { System.IO.File.SetLastWriteTimeUtc(file, DateTime.UtcNow); } catch (IOException) { }
            Prune(url);
            return;
        }
        lock (_lock)
        {
            if (_downloading == url) return;
            _cancel?.Cancel();
            _cancel = new CancellationTokenSource();
            _downloading = url;
            _total = null;
            _written = 0;
            _ = DownloadAsync(url, _cancel.Token);
        }
        Prune(url);
    }

    private async Task DownloadAsync(Uri url, CancellationToken cancel)
    {
        try
        {
            var part = Partial(url);
            long written = System.IO.File.Exists(part) ? new FileInfo(part).Length : 0;
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            if (written > 0) request.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(written, null);
            using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancel);
            var status = (int)response.StatusCode;
            if (status is not (200 or 206)) return;
            long? total;
            if (status == 206) total = response.Content.Headers.ContentRange?.Length;
            else
            {
                // The whole file from the start (a first request, or a server that ignored the range).
                written = 0;
                total = response.Content.Headers.ContentLength;
            }
            lock (_lock) { if (_downloading == url) { _total = total; _written = written; } }
            await using var stream = await response.Content.ReadAsStreamAsync(cancel);
            await using var output = new FileStream(part, written > 0 ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
            var buffer = new byte[128 * 1024];
            while (true)
            {
                var n = await stream.ReadAsync(buffer, cancel);
                if (n == 0) break;
                await output.WriteAsync(buffer.AsMemory(0, n), cancel);
                await output.FlushAsync(cancel);
                written += n;
                lock (_lock) { if (_downloading == url) _written = written; }
            }
            await output.DisposeAsync();
            if (total is null ? written > 0 : written >= total)
                System.IO.File.Move(part, Complete(url), overwrite: true);
        }
        catch (Exception) { /* the part stays, and carries on next time it's played */ }
        finally
        {
            lock (_lock) { if (_downloading == url) _downloading = null; }
        }
    }

    /// <summary>Keeps the files of the <see cref="Kept"/> episodes played last (and the one playing); deletes the rest.</summary>
    private void Prune(Uri keeping)
    {
        try
        {
            var current = new[] { Complete(keeping), Partial(keeping) };
            Uri? active;
            lock (_lock) active = _downloading;
            var activePath = active is null ? null : Partial(active);
            var dated = new DirectoryInfo(Folder).GetFiles()
                .Where(f => !current.Contains(f.FullName) && f.FullName != activePath)
                .OrderByDescending(f => f.LastWriteTimeUtc).ToList();
            // Parts count as episodes too: one stopped half-way is resumed if it's played again soon.
            foreach (var file in dated.Skip(Kept - 1)) { try { file.Delete(); } catch (IOException) { } }
        }
        catch (IOException) { }
    }

    public long Size()
    {
        try { return new DirectoryInfo(Folder).GetFiles().Sum(f => f.Length); } catch (IOException) { return 0; }
    }

    /// <summary>Deletes every file (Réinitialiser › Cache).</summary>
    public void Clear()
    {
        lock (_lock) { _cancel?.Cancel(); _downloading = null; }
        try { Directory.Delete(Folder, true); } catch (IOException) { }
    }
}
