using CinqHeures.Core;
using Microsoft.UI.Dispatching;
using Windows.Media;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage;
using Windows.Storage.Streams;

namespace CinqHeures;

/// <summary>Plays an episode, starting exactly where a film's review begins.
///
/// The website starts the audio first and seeks afterwards, so on a slow connection it often plays from the start. Here
/// nothing plays until the file is ready *and* the seek has landed.</summary>
public sealed class PlayerModel
{
    public enum Phase { Idle, Loading, Ready, Failed }

    public static readonly double[] Speeds = [0.8, 1, 1.15, 1.25, 1.5, 1.75, 2];
    public const double Jump = 15;

    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    private readonly UserData _data;
    private readonly MediaPlayer _player = new() { AutoPlay = false };
    private readonly DispatcherQueueTimer _timer;
    private SystemMediaTransportControls? _transport;

    public Episode? Episode { get; private set; }
    /// <summary>The segment the user asked for, shown in the player bar until playback moves past it.</summary>
    public Segment? RequestedSegment { get; private set; }
    public Phase State { get; private set; } = Phase.Idle;
    public string? Error { get; private set; }
    public double CurrentTime { get; private set; }
    public double Duration { get; private set; }
    public bool IsPlaying { get; private set; }
    /// <summary>True while 5heures.be's server is slow to hand over the part being played (it can take a minute the first time).</summary>
    public bool ServerIsSlow { get; private set; }
    public DateTime? SlowSince { get; private set; }
    /// <summary>Changes only when playback crosses into another segment, so the lists can follow it without redrawing twice a second.</summary>
    public long? CurrentSegmentId { get; private set; }
    /// <summary>Bumped whenever "Continuer l'écoute" would show something else.</summary>
    public int ProgressRevision { get; private set; }

    /// <summary>Something other than the clock changed: the episode, the phase, play or pause, the segment.</summary>
    public event Action? Changed;
    /// <summary>The clock moved.</summary>
    public event Action? Ticked;

    private RangeSource? _range;
    private CancellationTokenSource? _load;
    private int _generation;
    private double _lastSaved;
    private double? _seekTarget;
    private double _lastPosition = -1;
    private DateTime _stalledSince = DateTime.MaxValue;
    private int _recoveries;
    private (long Id, bool Listed)? _shelfState;
    private Uri? _pictureUrl;

    public double Rate
    {
        get => _data.Rate;
        set
        {
            _data.Rate = value;
            if (IsPlaying) _player.PlaybackSession.PlaybackRate = value;
            _data.Save();
            Changed?.Invoke();
        }
    }

    public double Volume
    {
        get => _data.Volume;
        set
        {
            _data.Volume = Math.Clamp(value, 0, 1);
            _player.Volume = _data.Volume;
            _data.Save();
        }
    }

    public PlayerModel(UserData data)
    {
        _data = data;
        _player.Volume = Math.Clamp(data.Volume, 0, 1);
        _player.CommandManager.IsEnabled = false;
        _player.MediaEnded += (_, _) => _ui.TryEnqueue(Ended);
        _player.MediaFailed += (_, e) => _ui.TryEnqueue(() => OnFailed(e.ErrorMessage));
        _player.PlaybackSession.SeekCompleted += (_, _) => _ui.TryEnqueue(() =>
        {
            _seekTarget = null;
            Tick();
            UpdateTransport();
        });
        _timer = _ui.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(500);
        _timer.Tick += (_, _) => Tick();
        _timer.Start();
        SetUpTransport();
    }

    // MARK: Starting

    /// <summary>Plays <paramref name="episode"/> from <paramref name="segment"/> (or, with none, from where it was left, or the start).</summary>
    public void Play(Episode episode, Segment? segment = null)
    {
        var start = segment is null ? ResumePoint(episode) : segment.Start ?? 0;
        RequestedSegment = segment;
        _recoveries = 0;
        SetSlow(false);
        if (Episode?.Id == episode.Id && State == Phase.Ready)
        {
            _generation++;
            _ = JumpAndPlayAsync(start, _generation);
            Changed?.Invoke();
            return;
        }
        Load(episode, start);
    }

    /// <summary>The episode playing, with what was learnt about it since it started (where its films start, from the file's
    /// chapters; their TMDB details): the bar's marks and the film being discussed follow.</summary>
    public void Update(Episode episode)
    {
        if (Episode?.Id != episode.Id || Episode == episode) return;
        Episode = episode;
        RequestedSegment = RequestedSegment is null ? null : episode.Segments.FirstOrDefault(s => s.Id == RequestedSegment.Id);
        CurrentSegmentId = episode.Segments.LastOrDefault(s => (s.Start ?? double.PositiveInfinity) <= CurrentTime + 0.5)?.Id;
        UpdateTransport();
        Changed?.Invoke();
    }

    /// <summary>Stops and unloads whatever is playing (the player bar goes back to "Rien en lecture").</summary>
    public void Stop()
    {
        _load?.Cancel();
        _generation++;
        _player.Pause();
        _player.Source = null;
        _range = null;
        Episode = null; RequestedSegment = null; _seekTarget = null;
        State = Phase.Idle; IsPlaying = false; CurrentTime = 0; Duration = 0; CurrentSegmentId = null;
        SetSlow(false);
        if (_transport is not null) { _transport.PlaybackStatus = MediaPlaybackStatus.Closed; _transport.DisplayUpdater.ClearAll(); }
        Changed?.Invoke();
    }

    /// <summary>Gets 5heures.be's server ready for a passage that's likely to be played soon. Its position in the file is
    /// estimated from the usual bitrate (128 kb/s) until the file is known.</summary>
    public void Warm(Episode episode, Segment? segment)
    {
        if (!episode.Series.IsOnSite() || Episode?.Id == episode.Id) return;
        RangeSource.Warm(episode.AudioUrl, 0);
        if (segment?.Start is > 30 and var start) RangeSource.Warm(episode.AudioUrl, (long)(start * 16_000));
    }

    public void Retry()
    {
        if (Episode is { } episode) Load(episode, RequestedSegment is { } r ? r.Start ?? 0 : CurrentTime);
    }

    private void Load(Episode episode, double start)
    {
        _load?.Cancel();
        _load = new CancellationTokenSource();
        var generation = ++_generation;
        _player.Pause();
        Episode = episode;
        _seekTarget = null;
        State = Phase.Loading; Error = null;
        IsPlaying = false; CurrentTime = start; Duration = 0; CurrentSegmentId = null;
        _lastPosition = -1; _stalledSince = DateTime.MaxValue;
        // Kept on disk, and fetched whole in the background if it isn't yet (see AudioCache).
        AudioCache.Shared.Playing(episode.AudioUrl);
        Changed?.Invoke();
        _ = LoadAsync(episode, start, generation, _load.Token);
    }

    private async Task LoadAsync(Episode episode, double start, int generation, CancellationToken cancel)
    {
        var lastError = "Le fichier audio n'a pas pu être chargé.";
        for (var attempt = 0; attempt < 3; attempt++)
        {
            if (cancel.IsCancellationRequested) return;
            if (attempt > 0) await Task.Delay(TimeSpan.FromSeconds(attempt * 1.5));
            try
            {
                var opened = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
                void OnOpened(MediaPlayer p, object o) => opened.TrySetResult(null);
                void OnFailed(MediaPlayer p, MediaPlayerFailedEventArgs e) => opened.TrySetResult(e.ErrorMessage);
                _player.MediaOpened += OnOpened;
                _player.MediaFailed += OnFailed;
                try
                {
                    _player.Source = await SourceForAsync(episode, cancel);
                    DebugLog.Write($"attempt {attempt}: source set ({(_range is not null ? "stream" : AudioCache.Shared.File(episode.AudioUrl) is not null ? "disk" : "uri")})");
                    if (cancel.IsCancellationRequested) return;
                    var error = await WaitUntilOpenedAsync(opened.Task, cancel);
                    DebugLog.Write(error is null ? "MediaOpened" : "open failed: " + error);
                    if (error is not null) { lastError = error; continue; }
                }
                finally
                {
                    _player.MediaOpened -= OnOpened;
                    _player.MediaFailed -= OnFailed;
                }
            }
            catch (OperationCanceledException) { return; }
            catch (Exception e) { lastError = e.Message; continue; }
            if (cancel.IsCancellationRequested || generation != _generation) return;
            var length = _player.PlaybackSession.NaturalDuration.TotalSeconds;
            Duration = double.IsFinite(length) ? length : 0;
            State = Phase.Ready;
            Changed?.Invoke();
            await JumpAndPlayAsync(start, generation);
            return;
        }
        if (!cancel.IsCancellationRequested && generation == _generation)
        {
            State = Phase.Failed; Error = lastError;
            Changed?.Invoke();
        }
    }

    private async Task<MediaSource> SourceForAsync(Episode episode, CancellationToken cancel)
    {
        _range = null;
        // From the disk when the whole file is there (offline too). Otherwise 5heures.be's own audio server needs the
        // patient loader, which reads what's already on disk itself; Ausha's and Audiobookshelf's don't.
        if (AudioCache.Shared.File(episode.AudioUrl) is { } path)
            return MediaSource.CreateFromStorageFile(await StorageFile.GetFileFromPathAsync(path));
        if (!episode.Series.IsOnSite()) return MediaSource.CreateFromUri(episode.AudioUrl);
        var range = new RangeSource(episode.AudioUrl);
        range.SlowChanged += slow => _ui.TryEnqueue(() => SetSlow(slow));
        var length = await range.LengthAsync(cancel);
        _range = range;
        return MediaSource.CreateFromStream(new RangeStream(range, length), "audio/mpeg");
    }

    /// <summary>Waits for the file to open. While the loader says 5heures.be's server is slow, it waits on: a file the
    /// server hasn't served lately can take a minute or more to start, and giving up early fails just before it arrives. It
    /// gives up after 15 seconds with nothing happening and no slow server to blame, or after 4 minutes in all.</summary>
    private async Task<string?> WaitUntilOpenedAsync(Task<string?> opened, CancellationToken cancel)
    {
        var started = DateTime.UtcNow;
        var quietSince = DateTime.UtcNow;
        while (true)
        {
            cancel.ThrowIfCancellationRequested();
            var done = await Task.WhenAny(opened, Task.Delay(100, cancel));
            if (done == opened) return await opened;
            if (ServerIsSlow) quietSince = DateTime.UtcNow;
            if ((DateTime.UtcNow - quietSince).TotalSeconds > 15 || (DateTime.UtcNow - started).TotalSeconds > 240)
                return "Le serveur ne répond pas.";
        }
    }

    /// <summary>Seeks, lets the seek settle, and only then plays, unless a newer request came in meanwhile.</summary>
    private async Task JumpAndPlayAsync(double seconds, int requested)
    {
        var session = _player.PlaybackSession;
        if (seconds > 0.5 || session.Position.TotalSeconds > 0.5)
        {
            _seekTarget = seconds;
            session.Position = TimeSpan.FromSeconds(Math.Max(0, seconds));
            // Playing at once after a deep seek could leave the pipeline waiting for ever: let it land first.
            for (var i = 0; i < 30 && _seekTarget is not null && requested == _generation; i++) await Task.Delay(100);
            await Task.Delay(300);
        }
        if (requested != _generation) return;
        _seekTarget = null;
        Tick();
        _player.PlaybackSession.PlaybackRate = Rate;
        _player.Play();
        DebugLog.Write($"Play() at {session.Position.TotalSeconds:F1}");
        IsPlaying = true;
        _lastPosition = CurrentTime; _stalledSince = DateTime.UtcNow;
        UpdateTransport();
        Changed?.Invoke();
    }

    // MARK: Controls

    public void TogglePlayPause()
    {
        if (State != Phase.Ready) return;
        if (IsPlaying)
        {
            _player.Pause();
            IsPlaying = false;
            Save();
        }
        else
        {
            // Finished: play again from the start rather than doing nothing.
            if (Duration > 0 && CurrentTime >= Duration - 1) Seek(0);
            _player.PlaybackSession.PlaybackRate = Rate;
            _player.Play();
            IsPlaying = true;
            _stalledSince = DateTime.UtcNow; _lastPosition = CurrentTime;
        }
        UpdateTransport();
        Changed?.Invoke();
    }

    public void SkipBy(double seconds) => Seek(CurrentTime + seconds);

    // MARK: Passages

    /// <summary>Where the episode's passages start (films, series, people, asides): the marks on the bar.</summary>
    public IReadOnlyList<double> Marks => (Episode?.Segments ?? []).Select(s => s.Start).OfType<double>().Where(s => s > 0).Order().ToList();

    public Segment? NextPassage
    {
        get
        {
            var marks = Marks;
            var start = marks.Cast<double?>().FirstOrDefault(m => m > CurrentTime + 1);
            return start is null ? null : Episode?.Segments.FirstOrDefault(s => s.Start == start);
        }
    }

    /// <summary>Where "previous" goes: the start of the passage playing when it's more than a few seconds in (like a
    /// previous-track button), else the one before it, else the start of the episode.</summary>
    private double PreviousTarget
    {
        get
        {
            var marks = Marks;
            var current = marks.Cast<double?>().LastOrDefault(m => m <= CurrentTime + 0.5);
            if (current is { } c && CurrentTime - c > 3) return c;
            return marks.Cast<double?>().LastOrDefault(m => m < (current ?? CurrentTime) - 0.5) ?? 0;
        }
    }

    public void NextPassageStart()
    {
        if (State == Phase.Ready && NextPassage?.Start is { } start) Seek(start);
    }

    public void PreviousPassageStart()
    {
        if (State == Phase.Ready) Seek(PreviousTarget);
    }

    public void Seek(double seconds)
    {
        if (State != Phase.Ready) return;
        var target = Math.Max(0, Duration > 0 ? Math.Min(seconds, Duration) : seconds);
        CurrentTime = target;
        _seekTarget = target;
        _player.PlaybackSession.Position = TimeSpan.FromSeconds(target);
        _lastPosition = target; _stalledSince = DateTime.UtcNow;
        Ticked?.Invoke();
    }

    // MARK: Following playback

    private void Tick()
    {
        if (State != Phase.Ready) return;
        var reported = _player.PlaybackSession.Position.TotalSeconds;
        if (!double.IsFinite(reported)) return;
        if (DebugLog.On && IsPlaying && (int)(reported * 2) % 10 == 0) DebugLog.Write($"tick {reported:F1} state={_player.PlaybackSession.PlaybackState}");
        var seconds = _seekTarget ?? reported;
        WatchForStall(reported);
        _range?.Playhead(seconds, Duration);
        CurrentTime = seconds;
        var length = _player.PlaybackSession.NaturalDuration.TotalSeconds;
        if (double.IsFinite(length) && length > 0 && Math.Abs(length - Duration) > 0.5) Duration = length;
        var segment = Episode?.Segments.LastOrDefault(s => (s.Start ?? double.PositiveInfinity) <= seconds + 0.5);
        var segmentChanged = segment?.Id != CurrentSegmentId;
        if (segmentChanged)
        {
            CurrentSegmentId = segment?.Id;
            UpdateTransport();      // the title in the media overlay follows the film being discussed
        }
        if (RequestedSegment is { } requested && segment is not null && segment.Id != requested.Id && seconds > (requested.Start ?? 0) + 5)
        {
            RequestedSegment = null;
            segmentChanged = true;
        }
        if (IsPlaying && (seconds - _lastSaved > 5 || seconds < _lastSaved)) Save();
        Ticked?.Invoke();
        if (segmentChanged) Changed?.Invoke();
    }

    /// <summary>If playback is stuck for no reason the loader knows about (it reports a slow server itself), load the file
    /// again and carry on from here.</summary>
    private void WatchForStall(double reported)
    {
        if (!IsPlaying || State != Phase.Ready || _seekTarget is not null) { _stalledSince = DateTime.MaxValue; return; }
        var moved = Math.Abs(reported - _lastPosition) > 0.05;
        if (moved || ServerIsSlow)
        {
            _lastPosition = reported;
            _stalledSince = DateTime.UtcNow;
            if (moved) _recoveries = 0;
            return;
        }
        if ((DateTime.UtcNow - _stalledSince).TotalSeconds < 20 || Episode is not { } episode) return;
        _stalledSince = DateTime.UtcNow;
        if (_recoveries >= 3)
        {
            State = Phase.Failed; Error = "La lecture est bloquée : le serveur ne répond pas.";
            IsPlaying = false;
            _player.Pause();
            Changed?.Invoke();
            return;
        }
        _recoveries++;
        Load(episode, reported);
    }

    public Segment? CurrentSegment => CurrentSegmentId is { } id ? Episode?.Segments.FirstOrDefault(s => s.Id == id) : null;

    private void Ended()
    {
        IsPlaying = false;
        Forget();
        UpdateTransport();
        Changed?.Invoke();
    }

    private void OnFailed(string message)
    {
        if (State != Phase.Ready) return;       // while loading, the load itself retries
        State = Phase.Failed; Error = message; IsPlaying = false;
        Changed?.Invoke();
    }

    private void SetSlow(bool slow)
    {
        if (ServerIsSlow == slow) return;
        ServerIsSlow = slow;
        SlowSince = slow ? SlowSince ?? DateTime.UtcNow : null;
        Changed?.Invoke();
    }

    // MARK: Remembering where you were

    private ReadOnlySpan<char> Key(Episode e) => e.Id.ToString();

    private double ResumePoint(Episode episode) =>
        _data.Positions.TryGetValue(episode.Id.ToString(), out var saved) && saved > 10 ? saved : 0;

    public bool HasProgress(Episode episode) => ResumePoint(episode) > 0;

    private void Save()
    {
        if (Episode is not { } episode || State != Phase.Ready) return;
        _lastSaved = CurrentTime;
        var key = episode.Id.ToString();
        _data.Positions[key] = CurrentTime;
        _data.Dates[key] = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        if (Duration > 0) _data.Lengths[key] = Duration;
        _data.Save();
        // "Continuer l'écoute" lists an episode once it's a minute in, newest first.
        var listed = CurrentTime > 60;
        if (!IsPlaying || _shelfState?.Id != episode.Id || _shelfState?.Listed != listed)
        {
            _shelfState = (episode.Id, listed);
            ProgressRevision++;
        }
    }

    /// <summary>The length of an episode that has been played here (the site doesn't say how long they are).</summary>
    public double? LengthOf(Episode episode) => _data.Lengths.TryGetValue(episode.Id.ToString(), out var l) ? l : episode.Duration;

    /// <summary>Episodes started and not finished: (episode id, seconds in), most recently listened first.</summary>
    public List<(long Id, double Seconds)> Unfinished() =>
        _data.Positions.Where(p => p.Value > 60 && long.TryParse(p.Key, out _))
            .OrderByDescending(p => _data.Dates.GetValueOrDefault(p.Key))
            .Select(p => (long.Parse(p.Key), p.Value)).ToList();

    /// <summary>Forgets where every episode was left: "Continuer l'écoute" empties.</summary>
    public void ForgetAllProgress()
    {
        _data.Positions.Clear(); _data.Dates.Clear(); _data.Lengths.Clear();
        _data.Save();
        _lastSaved = 0; _shelfState = null;
        ProgressRevision++;
        Changed?.Invoke();
    }

    private void Forget()
    {
        if (Episode is not { } episode) return;
        _data.Positions.Remove(episode.Id.ToString());
        _data.Save();
        _shelfState = null;
        ProgressRevision++;
    }

    // MARK: Media keys and the system media overlay

    private void SetUpTransport()
    {
        try
        {
            _transport = _player.SystemMediaTransportControls;
            _transport.IsEnabled = true;
            _transport.IsPlayEnabled = _transport.IsPauseEnabled = true;
            _transport.IsNextEnabled = _transport.IsPreviousEnabled = false;
            _transport.IsFastForwardEnabled = _transport.IsRewindEnabled = true;
            _transport.ButtonPressed += (_, e) => _ui.TryEnqueue(() =>
            {
                switch (e.Button)
                {
                    case SystemMediaTransportControlsButton.Play: if (!IsPlaying) TogglePlayPause(); break;
                    case SystemMediaTransportControlsButton.Pause: if (IsPlaying) TogglePlayPause(); break;
                    case SystemMediaTransportControlsButton.FastForward: SkipBy(Jump); break;
                    case SystemMediaTransportControlsButton.Rewind: SkipBy(-Jump); break;
                    case SystemMediaTransportControlsButton.Next: NextPassageStart(); break;
                    case SystemMediaTransportControlsButton.Previous: PreviousPassageStart(); break;
                }
            });
        }
        catch (Exception) { _transport = null; }
    }

    private void UpdateTransport()
    {
        if (_transport is null || Episode is not { } episode) return;
        try
        {
            // Next and previous passage: the media keys, only for an episode with marks.
            var has = Marks.Count > 0;
            _transport.IsNextEnabled = _transport.IsPreviousEnabled = has;
            _transport.PlaybackStatus = State != Phase.Ready ? MediaPlaybackStatus.Changing
                : IsPlaying ? MediaPlaybackStatus.Playing : MediaPlaybackStatus.Paused;
            var updater = _transport.DisplayUpdater;
            updater.Type = MediaPlaybackType.Music;
            updater.MusicProperties.Title = CurrentSegment?.DisplayTitle ?? episode.Title;
            updater.MusicProperties.Artist = episode.Title;
            var picture = (CurrentSegment ?? RequestedSegment)?.PosterUrl ?? episode.Artwork;
            if (picture != _pictureUrl)
            {
                _pictureUrl = picture;
                updater.Thumbnail = picture is null ? null : RandomAccessStreamReference.CreateFromUri(picture);
            }
            updater.Update();
        }
        catch (Exception) { }
    }
}
