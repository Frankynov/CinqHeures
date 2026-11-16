using System.Net;
using System.Net.Sockets;
using System.Text.Json;

namespace CinqHeures.Core;

public sealed class SiteException(int status, string message) : Exception(message)
{
    public int Status { get; } = status;

    public static SiteException Http(int status) => new(status, $"5heures.be a répondu {status}.");
    public static SiteException Unreadable() => new(0, "La réponse de 5heures.be n'a pas pu être lue.");
}

/// <summary>Reads the episode list from 5heures.be's own JSON API, the one the website itself uses.</summary>
public sealed class SiteClient
{
    public const string UserAgent = "CinqHeures/1.0 (personal podcast player)";

    /// <summary>One client for the whole app: no cookies, no cache, a generous timeout.</summary>
    public static HttpClient Http { get; } = CreateHttp();

    /// <summary>A handler that connects to IPv4 addresses first, giving each address a few seconds: where IPv6 is advertised but
    /// goes nowhere, the default waits for Windows' own 21-second connect timeout before trying the next address, and the
    /// first request of every connection stalled for that long.</summary>
    public static SocketsHttpHandler CreateHandler(int maxConnections = int.MaxValue) => new()
    {
        UseCookies = false,
        AutomaticDecompression = DecompressionMethods.All,
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        MaxConnectionsPerServer = maxConnections,
        ConnectCallback = async (context, cancel) =>
        {
            var addresses = await Dns.GetHostAddressesAsync(context.DnsEndPoint.Host, cancel);
            Exception? last = null;
            foreach (var address in addresses.OrderBy(a => a.AddressFamily == AddressFamily.InterNetwork ? 0 : 1))
            {
                var socket = new Socket(address.AddressFamily, SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
                try
                {
                    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
                    timeout.CancelAfter(TimeSpan.FromSeconds(4));
                    await socket.ConnectAsync(new IPEndPoint(address, context.DnsEndPoint.Port), timeout.Token);
                    return new NetworkStream(socket, ownsSocket: true);
                }
                catch (Exception e) when (e is SocketException or OperationCanceledException && !cancel.IsCancellationRequested)
                {
                    socket.Dispose();
                    last = e;
                }
            }
            throw last ?? new SocketException((int)SocketError.HostNotFound);
        },
    };

    private static HttpClient CreateHttp()
    {
        var handler = CreateHandler();
        var http = new HttpClient(handler, disposeHandler: true) { Timeout = TimeSpan.FromSeconds(60) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd(UserAgent);
        return http;
    }

    private readonly HttpClient _http;
    private readonly Uri _base;

    public SiteClient(Uri? baseUri = null, HttpClient? http = null)
    {
        _base = baseUri ?? new Uri("https://5heures.be");
        _http = http ?? Http;
    }

    /// <summary>The years each show has episodes for.</summary>
    public async Task<Dictionary<Series, List<int>>> YearsPerSeriesAsync(CancellationToken cancel = default) =>
        Wire.ParseYears(await GetAsync("api/config", [], cancel));

    /// <summary>Every episode of one show in one year, across however many pages that takes.</summary>
    public async Task<List<Episode>> EpisodesAsync(Series series, int year, CancellationToken cancel = default)
    {
        var result = new List<Episode>();
        for (var page = 1; ; page++)
        {
            var data = await GetAsync("api/podcasts", [("per_page", "100"), ("year", year.ToString()),
                ("kind", series.Raw()), ("page", page.ToString())], cancel);
            var (episodes, total) = Wire.ParsePage(data);
            result.AddRange(episodes);
            if (page >= total) return result;
        }
    }

    /// <summary>The site's CDN answers 503 now and then; asking again a moment later works.</summary>
    internal async Task<byte[]> GetAsync(string path, (string Key, string Value)[] query, CancellationToken cancel)
    {
        var url = new UriBuilder(new Uri(_base, path))
        {
            Query = string.Join("&", query.Select(q => $"{Uri.EscapeDataString(q.Key)}={Uri.EscapeDataString(q.Value)}")),
        }.Uri;
        Exception last = SiteException.Unreadable();
        for (var attempt = 0; attempt < 4; attempt++)
        {
            if (attempt > 0) await Task.Delay(TimeSpan.FromSeconds(attempt), cancel);
            try
            {
                using var response = await _http.GetAsync(url, cancel);
                var status = (int)response.StatusCode;
                if (status == 200) return await response.Content.ReadAsByteArrayAsync(cancel);
                last = SiteException.Http(status);
                if (status is not (502 or 503 or 504)) throw last;
            }
            catch (SiteException) { throw; }
            catch (OperationCanceledException) when (cancel.IsCancellationRequested) { throw; }
            catch (Exception e) { last = e; }
        }
        throw last;
    }
}
