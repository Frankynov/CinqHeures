using System.Runtime.InteropServices.WindowsRuntime;
using CinqHeures.Core;
using Windows.Foundation;
using Windows.Storage.Streams;

namespace CinqHeures;

/// <summary>Feeds the media player an MP3 through small, bounded range requests of our own.
///
/// 5heures.be's audio comes from a Rails app behind Cloudflare, and a file that hasn't been requested for a while is slow
/// the first time: a deep seek can wait a minute or more for the body of its answer, then everything is fast. Left to
/// itself the media player gives up (it never started playing a deep seek in the tests). Here every request is small and
/// is asked again patiently, what has been fetched is kept so jumping back is instant, and the app is told when the
/// server is slow.</summary>
public sealed class RangeSource
{
    private const long Chunk = 512 * 1024;
    /// <summary>How far past the playhead to read, so a long episode isn't downloaded whole.</summary>
    private const long ReadAhead = 12 * 1024 * 1024;
    private const int MaxChunks = 96;      // 48 MB

    private static readonly HttpClient Http = CreateHttp();

    private static HttpClient CreateHttp()
    {
        var http = new HttpClient(SiteClient.CreateHandler(4)) { Timeout = Timeout.InfiniteTimeSpan };
        http.DefaultRequestHeaders.UserAgent.ParseAdd(SiteClient.UserAgent);
        return http;
    }

    private readonly object _lock = new();
    private readonly Dictionary<long, byte[]> _cache = [];
    private readonly Dictionary<long, Task<byte[]>> _inFlight = [];
    private readonly HashSet<Guid> _slow = [];
    private long? _length;
    private long _playheadByte;
    /// <summary>Where the reader last jumped to: reads are only held back when they run far past both this and the playhead.</summary>
    private long _anchor;
    private long _nextExpected = -1;
    private double _bytesPerSecond = 16_000;

    public Uri Url { get; }

    /// <summary>Called (from any thread) when the server starts or stops being slow to answer.</summary>
    public event Action<bool>? SlowChanged;

    public RangeSource(Uri url) { Url = url; }

    /// <summary>Tells the source where playback is, so it reads only a little way ahead.</summary>
    public void Playhead(double seconds, double duration)
    {
        lock (_lock)
        {
            if (duration > 60 && _length is { } length) _bytesPerSecond = length / duration;
            _playheadByte = (long)(seconds * _bytesPerSecond);
        }
    }

    public async Task<long> LengthAsync(CancellationToken cancel)
    {
        lock (_lock) { if (_length is { } known) return known; }
        if (AudioCache.Shared.Length(Url) is { } cached)
        {
            lock (_lock) _length = cached;
            return cached;
        }
        long? found = null;
        await FetchAsync(0, 1, response => found = response.Content.Headers.ContentRange?.Length, cancel);
        if (found is not { } total) throw SiteException.Unreadable();
        lock (_lock) _length = total;
        return total;
    }

    /// <summary>The bytes from <paramref name="offset"/> to the end of its chunk (at most <paramref name="count"/>).</summary>
    public async Task<byte[]> ReadAsync(long offset, int count, CancellationToken cancel)
    {
        var total = await LengthAsync(cancel);
        if (offset >= total) return [];
        // Don't run far ahead of what's being listened to: but a read that jumped somewhere (a seek, or the player looking
        // at the end of the file) counts from there, as the Mac's loader counts from the start of the request.
        lock (_lock)
        {
            if (offset != _nextExpected) _anchor = offset;
        }
        while (true)
        {
            long head, anchor;
            lock (_lock) { head = _playheadByte; anchor = _anchor; }
            if (offset <= Math.Max(anchor, head) + ReadAhead) break;
            await Task.Delay(500, cancel);
        }
        var began = DateTime.UtcNow;
        var index = offset / Chunk;
        var skip = (int)(offset - index * Chunk);
        var chunk = await ChunkAsync(index, total, cancel);
        var length = Math.Min(count, chunk.Length - skip);
        if (length <= 0) return [];
        lock (_lock) _nextExpected = offset + length;
        if (DebugLog.On) DebugLog.Write($"read @{offset} +{length} answered in {(DateTime.UtcNow - began).TotalMilliseconds:F0} ms");
        // The next chunk, in the background, so the read after this one doesn't wait for the network.
        if ((index + 1) * Chunk < total) _ = ChunkAsync(index + 1, total, CancellationToken.None).ContinueWith(_ => { }, TaskScheduler.Default);
        return chunk.AsSpan(skip, length).ToArray();
    }

    private Task<byte[]> ChunkAsync(long index, long total, CancellationToken cancel)
    {
        lock (_lock)
        {
            if (_cache.TryGetValue(index, out var hit)) return Task.FromResult(hit);
            if (_inFlight.TryGetValue(index, out var running)) return running.WaitAsync(cancel);
            var task = Task.Run(() => LoadChunkAsync(index, total));
            _inFlight[index] = task;
            return task.WaitAsync(cancel);
        }
    }

    private async Task<byte[]> LoadChunkAsync(long index, long total)
    {
        try
        {
            var first = index * Chunk;
            var last = Math.Min(total, first + Chunk) - 1;
            // Already downloaded in the background (AudioCache): no need to ask the server.
            var data = AudioCache.Shared.Read(Url, first, last) ?? await FetchAsync(first, last, null, CancellationToken.None);
            if (DebugLog.On) DebugLog.Write($"chunk {index} loaded ({data.Length} bytes)");
            lock (_lock)
            {
                _cache[index] = data;
                if (_cache.Count > MaxChunks)
                {
                    var here = _playheadByte / Chunk;
                    foreach (var key in _cache.Keys.OrderByDescending(k => Math.Abs(k - here)).Take(_cache.Count - MaxChunks).ToList())
                        _cache.Remove(key);
                }
            }
            return data;
        }
        finally
        {
            lock (_lock) _inFlight.Remove(index);
        }
    }

    private void MarkSlow(Guid request, bool slow)
    {
        bool? change;
        lock (_lock)
        {
            var before = _slow.Count > 0;
            if (slow) _slow.Add(request); else _slow.Remove(request);
            var after = _slow.Count > 0;
            change = before == after ? null : after;
        }
        if (change is { } c) SlowChanged?.Invoke(c);
    }

    /// <summary>One range, asked for again for up to about three minutes while the server stalls or errors.</summary>
    private async Task<byte[]> FetchAsync(long first, long last, Action<HttpResponseMessage>? inspect, CancellationToken cancel)
    {
        Exception lastError = SiteException.Unreadable();
        var id = Guid.NewGuid();
        using var slowTimer = new CancellationTokenSource();
        _ = Task.Delay(TimeSpan.FromSeconds(3), slowTimer.Token).ContinueWith(t => { if (!t.IsCanceled) MarkSlow(id, true); });
        try
        {
            for (var attempt = 0; attempt < 9; attempt++)
            {
                cancel.ThrowIfCancellationRequested();
                if (attempt > 0) await Task.Delay(1000, cancel);
                try
                {
                    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
                    timeout.CancelAfter(TimeSpan.FromSeconds(20));
                    using var request = new HttpRequestMessage(HttpMethod.Get, Url);
                    request.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(first, last);
                    using var response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
                    var status = (int)response.StatusCode;
                    if (status is not (206 or 200)) throw SiteException.Http(status);
                    inspect?.Invoke(response);
                    var wanted = (int)(last - first + 1);
                    await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
                    // A 200 means the server ignored the range and sent the whole file from the start.
                    if (status == 200)
                    {
                        var skipped = new byte[64 * 1024];
                        for (long left = first; left > 0;)
                        {
                            var n = await stream.ReadAsync(skipped.AsMemory(0, (int)Math.Min(left, skipped.Length)), timeout.Token);
                            if (n == 0) throw SiteException.Unreadable();
                            left -= n;
                        }
                    }
                    var buffer = new byte[wanted];
                    var read = 0;
                    while (read < wanted)
                    {
                        var n = await stream.ReadAsync(buffer.AsMemory(read), timeout.Token);
                        if (n == 0) break;
                        read += n;
                    }
                    return read == wanted ? buffer : buffer.AsSpan(0, read).ToArray();
                }
                catch (OperationCanceledException) when (cancel.IsCancellationRequested) { throw; }
                catch (Exception e) { lastError = e; }
            }
            throw lastError;
        }
        finally
        {
            slowTimer.Cancel();
            MarkSlow(id, false);
        }
    }

    /// <summary>Asks 5heures.be for a piece of a file in the background, so that it's warm by the time it's played: the
    /// server takes a minute or two over a file it hasn't served lately, then it's fast. The answer isn't kept; each
    /// piece is warmed at most once every ten minutes.</summary>
    private static readonly Dictionary<string, DateTime> Warmed = [];

    public static void Warm(Uri url, long offset)
    {
        var first = offset / Chunk * Chunk;
        var key = $"{url.AbsoluteUri}#{first}";
        lock (Warmed)
        {
            if (Warmed.TryGetValue(key, out var last) && (DateTime.UtcNow - last).TotalSeconds < 600) return;
            Warmed[key] = DateTime.UtcNow;
        }
        _ = Task.Run(async () =>
        {
            try
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(180));
                using var request = new HttpRequestMessage(HttpMethod.Get, url);
                request.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(first, first + 64 * 1024 - 1);
                using var response = await Http.SendAsync(request, HttpCompletionOption.ResponseContentRead, timeout.Token);
            }
            catch (Exception) { }
        });
    }
}

/// <summary>A read-only <see cref="IRandomAccessStream"/> over a <see cref="RangeSource"/>, for the media player.</summary>
public sealed class RangeStream : IRandomAccessStream
{
    private readonly RangeSource _source;
    private readonly ulong _size;
    private ulong _position;

    public RangeStream(RangeSource source, long size, ulong position = 0)
    {
        _source = source; _size = (ulong)size; _position = position;
    }

    public bool CanRead => true;
    public bool CanWrite => false;
    public ulong Position => _position;
    public ulong Size { get => _size; set => throw new NotSupportedException(); }

    public IInputStream GetInputStreamAt(ulong position) => new RangeStream(_source, (long)_size, position);
    public IOutputStream GetOutputStreamAt(ulong position) => throw new NotSupportedException();
    public void Seek(ulong position) => _position = position;
    public IRandomAccessStream CloneStream() => new RangeStream(_source, (long)_size, _position);

    public IAsyncOperationWithProgress<IBuffer, uint> ReadAsync(IBuffer buffer, uint count, InputStreamOptions options) =>
        AsyncInfo.Run<IBuffer, uint>(async (cancel, progress) =>
        {
            var bytes = await _source.ReadAsync((long)_position, (int)Math.Min(count, buffer.Capacity), cancel);
            _position += (ulong)bytes.Length;
            bytes.CopyTo(0, buffer, 0, bytes.Length);
            buffer.Length = (uint)bytes.Length;
            return buffer;
        });

    public IAsyncOperationWithProgress<uint, uint> WriteAsync(IBuffer buffer) => throw new NotSupportedException();
    public IAsyncOperation<bool> FlushAsync() => Task.FromResult(true).AsAsyncOperation();
    public void Dispose() { }
}
