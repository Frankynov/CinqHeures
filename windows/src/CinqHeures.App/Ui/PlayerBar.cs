using CinqHeures.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace CinqHeures;

/// <summary>The player: one compact row floating over the bottom of the pages. Artwork and title, previous passage, ±15 s,
/// play, next passage, a scrubber with a mark at each film of the episode (hover to see which film and when, click or drag
/// to seek), volume, favourite and speed.</summary>
public sealed class PlayerBar : Grid
{
    private readonly PlayerModel _player;
    private readonly AppModel _model;
    private readonly ContentPresenter _art = new() { Width = 44, Height = 44 };
    private readonly TextBlock _title = Ui.Text("Rien en lecture", 14, null, 1, 1);
    private readonly StackPanel _subtitle = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    private readonly Button _play;
    private readonly FontIcon _playIcon = Ui.Icon(Ui.G.Play, 16);
    private readonly Button _prev, _next, _back, _forward;
    private readonly TextBlock _elapsed = Ui.Text("0:00", 12, null, 0.7, 1);
    private readonly TextBlock _remaining = Ui.Text("", 12, null, 0.7, 1);
    private readonly Slider _slider = new() { Minimum = 0, Maximum = 1, Value = 0, IsEnabled = false, VerticalAlignment = VerticalAlignment.Center };
    private readonly Canvas _marks = new() { IsHitTestVisible = false, Height = 22, VerticalAlignment = VerticalAlignment.Center };
    private readonly Slider _volume = new() { Minimum = 0, Maximum = 1, StepFrequency = 0.01, Width = 90, VerticalAlignment = VerticalAlignment.Center };
    private readonly ContentPresenter _heart = new();
    private readonly Button _speed;
    private readonly Grid _layout = new() { ColumnSpacing = 12 };
    private readonly Grid _volumeHost = new();
    private readonly Border _card = new();
    private readonly Microsoft.UI.Xaml.Controls.Primitives.Popup _hover = new() { ShouldConstrainToRootBounds = false };
    private readonly TextBlock _hoverText = Ui.Text("", 13, null, 1, 1, Colors.White);
    private bool _updating;
    private double? _pending;
    private Uri? _artFor;
    private long? _artEpisode;

    public PlayerBar(AppModel model)
    {
        _model = model;
        _player = model.Player;

        _prev = Ui.IconButton(Ui.G.Prev, "Passage précédent (Ctrl+Maj+←)", _player.PreviousPassageStart, 14, 8);
        _back = SkipButton("", "Reculer de 15 secondes", -PlayerModel.Jump);
        _forward = SkipButton("", "Avancer de 15 secondes", PlayerModel.Jump);
        _next = Ui.IconButton(Ui.G.Next, "Passage suivant (Ctrl+Maj+→)", _player.NextPassageStart, 14, 8);
        _play = new Button
        {
            Content = _playIcon, Width = 40, Height = 40, CornerRadius = new CornerRadius(20), Padding = new Thickness(0),
            Style = (Style)Application.Current.Resources["AccentButtonStyle"],
        };
        _play.Click += (_, _) => _player.TogglePlayPause();
        ToolTipService.SetToolTip(_play, "Lecture / pause (Espace)");

        _speed = new Button { Content = Ui.Text("1×", 13), Padding = new Thickness(8, 4, 8, 4), Background = Ui.Brush(Colors.Transparent), BorderThickness = new Thickness(0) };
        var menu = new MenuFlyout();
        foreach (var speed in PlayerModel.Speeds)
        {
            var item = new ToggleMenuFlyoutItem { Text = $"{speed.ToString("0.##").Replace('.', ',')}×" };
            var value = speed;
            item.Click += (_, _) => _player.Rate = value;
            menu.Items.Add(item);
        }
        menu.Opening += (_, _) =>
        {
            for (var i = 0; i < PlayerModel.Speeds.Length; i++) ((ToggleMenuFlyoutItem)menu.Items[i]).IsChecked = Math.Abs(PlayerModel.Speeds[i] - _player.Rate) < 0.01;
        };
        _speed.Flyout = menu;
        ToolTipService.SetToolTip(_speed, "Vitesse de lecture");

        _volume.Value = _player.Volume;
        _volume.ValueChanged += (_, e) => { if (!_updating) _player.Volume = e.NewValue; };
        ToolTipService.SetToolTip(_volume, "Volume");
        _volumeHost.Children.Add(_volume);

        // The scrubber: the slider, with the films' marks drawn over its track.
        _slider.ValueChanged += (_, e) =>
        {
            if (_updating) return;
            _pending = e.NewValue;
            _elapsed.Text = Ui.Clock(e.NewValue);
        };
        _slider.AddHandler(PointerReleasedEvent, new PointerEventHandler((_, _) => CommitSeek()), true);
        _slider.AddHandler(PointerCaptureLostEvent, new PointerEventHandler((_, _) => CommitSeek()), true);
        _slider.AddHandler(KeyUpEvent, new KeyEventHandler((_, _) => CommitSeek()), true);
        _slider.AddHandler(PointerMovedEvent, new PointerEventHandler(OnScrubberMoved), true);
        _slider.AddHandler(PointerExitedEvent, new PointerEventHandler((_, _) => CloseHover()), true);
        _hoverText.TextWrapping = TextWrapping.NoWrap;
        _hover.Child = new Border
        {
            Child = _hoverText, Padding = new Thickness(10, 6, 10, 7), CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1),
            Background = Ui.Brush(Windows.UI.Color.FromArgb(245, 38, 38, 38)), IsHitTestVisible = false,
            BorderBrush = Ui.Tint(80), RequestedTheme = ElementTheme.Dark,
        };
        Loaded += (_, _) => _hover.XamlRoot = XamlRoot;
        _slider.IsThumbToolTipEnabled = false;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_slider, "Position de lecture");
        var scrubber = new Grid { VerticalAlignment = VerticalAlignment.Center };
        scrubber.Children.Add(_marks);
        scrubber.Children.Add(_slider);
        scrubber.SizeChanged += (_, _) => DrawMarks();

        // Left: what's playing.
        var left = new Grid { ColumnSpacing = 10, MinWidth = 150, MaxWidth = 250 };
        left.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        left.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        left.Children.Add(_art);
        var names = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        names.Children.Add(_title);
        names.Children.Add(_subtitle);
        Grid.SetColumn(names, 1);
        left.Children.Add(names);
        left.Clickable(() => _model.OpenCurrentEpisode(), "Ouvrir l'épisode en cours");
        ToolTipService.SetToolTip(left, "Ouvrir l'épisode");

        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        foreach (var c in new UIElement[] { _prev, _back, _play, _forward, _next }) controls.Children.Add(c);

        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        right.Children.Add(_volumeHost);
        right.Children.Add(_heart);
        right.Children.Add(_speed);

        _layout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(240) });
        _layout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _layout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _layout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 120 });
        _layout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _layout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        void Put(UIElement e, int col) { Grid.SetColumn((FrameworkElement)e, col); _layout.Children.Add(e); }
        Put(left, 0); Put(controls, 1); Put(_elapsed, 2); Put(scrubber, 3); Put(_remaining, 4); Put(right, 5);
        _elapsed.VerticalAlignment = _remaining.VerticalAlignment = VerticalAlignment.Center;
        // Fixed-width, tabular digits: the times changing every second must not move the scrubber between them.
        foreach (var clock in new[] { _elapsed, _remaining })
        {
            Microsoft.UI.Xaml.Documents.Typography.SetNumeralAlignment(clock, FontNumeralAlignment.Tabular);
            clock.Width = 58;
        }
        _elapsed.TextAlignment = TextAlignment.Right;
        _remaining.TextAlignment = TextAlignment.Left;
        _elapsed.TextWrapping = _remaining.TextWrapping = TextWrapping.NoWrap;

        _card.Child = _layout;
        _card.Padding = new Thickness(14, 10, 14, 10);
        _card.CornerRadius = new CornerRadius(8);
        _card.BorderThickness = new Thickness(1);
        _card.BorderBrush = Ui.Tint(60);
        Children.Add(_card);
        Margin = new Thickness(16, 0, 16, 12);
        VerticalAlignment = VerticalAlignment.Bottom;
        MaxWidth = 1400;
        SizeChanged += (_, e) => _volumeHost.Visibility = e.NewSize.Width < 900 ? Visibility.Collapsed : Visibility.Visible;

        _player.Changed += () => DispatcherQueue.TryEnqueue(Render);
        _player.Ticked += () => DispatcherQueue.TryEnqueue(RenderClock);
        model.FavoritesChanged += () => DispatcherQueue.TryEnqueue(Render);
        ActualThemeChanged += (_, _) => UpdateBackground();
        Loaded += (_, _) => UpdateBackground();
        Render();
    }

    /// <summary>A circular arrow with "15" inside it: turning back for rewind, forward for the other.</summary>
    private Button SkipButton(string glyph, string tip, double seconds)
    {
        var grid = new Grid { Width = 30, Height = 30 };
        var arrow = Ui.Icon("", 28);
        arrow.HorizontalAlignment = HorizontalAlignment.Center; arrow.VerticalAlignment = VerticalAlignment.Center;
        arrow.Opacity = 0.9;
        if (seconds < 0)
        {
            arrow.RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5);
            arrow.RenderTransform = new ScaleTransform { ScaleX = -1 };
        }
        grid.Children.Add(arrow);
        var label = Ui.Text("15", 10, Ui.Bold);
        label.TextWrapping = TextWrapping.NoWrap;
        label.HorizontalAlignment = HorizontalAlignment.Center; label.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(label);
        var button = Ui.IconButton(glyph, tip, () => _player.SkipBy(seconds), 18, 6);
        button.Content = grid;
        return button;
    }

    private void UpdateBackground()
    {
        var dark = ActualTheme == ElementTheme.Dark;
        _card.Background = new AcrylicBrush
        {
            TintColor = dark ? Windows.UI.Color.FromArgb(255, 32, 32, 32) : Windows.UI.Color.FromArgb(255, 248, 248, 248),
            TintOpacity = 0.6, FallbackColor = dark ? Windows.UI.Color.FromArgb(255, 44, 44, 44) : Windows.UI.Color.FromArgb(255, 240, 240, 240),
        };
    }

    private void CommitSeek()
    {
        if (_pending is not { } target) return;
        _pending = null;
        _player.Seek(target);
    }

    private string _hoverShown = "";

    /// <summary>Hovering the bar names the film being discussed at that point, with its time, in a label above the pointer (as on the Mac).
    /// Cheap on purpose: it runs at every mouse move, so nothing is touched unless it changed.</summary>
    private void OnScrubberMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_player.Episode is not { } episode || _player.Duration <= 0 || _slider.ActualWidth <= 0 || XamlRoot is null) { CloseHover(); return; }
        var point = e.GetCurrentPoint(_slider).Position;
        const double inset = 10;
        var time = Math.Clamp((point.X - inset) / Math.Max(1, _slider.ActualWidth - 2 * inset), 0, 1) * _player.Duration;
        // The segment under the pointer: the last one that has started by then (a film, a series, a person, or the intro).
        Segment? segment = null;
        foreach (var s in episode.Segments)
            if (s.Start is { } st && st <= time + 0.5 && (segment is null || st >= segment.Start)) segment = s;
        var text = segment is null ? Ui.Clock(time) : $"{(segment.Kind.IsSubject() ? segment.DisplayTitle : segment.Kind.Label())} · {Ui.Clock(time)}";
        if (text != _hoverShown)
        {
            _hoverShown = text;
            _hoverText.Text = text;
            _hover.Child.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        }
        var origin = _slider.TransformToVisual(null).TransformPoint(new Windows.Foundation.Point(point.X, 0));
        var width = ((FrameworkElement)_hover.Child).DesiredSize.Width;
        var x = Math.Max(8, Math.Round(origin.X - width / 2));
        var y = Math.Round(origin.Y - 46);
        if (Math.Abs(_hover.HorizontalOffset - x) >= 1) _hover.HorizontalOffset = x;
        if (Math.Abs(_hover.VerticalOffset - y) >= 1) _hover.VerticalOffset = y;
        if (!_hover.IsOpen) _hover.IsOpen = true;
    }

    private void CloseHover()
    {
        if (_hover.IsOpen) _hover.IsOpen = false;
    }

    private void DrawMarks()
    {
        _marks.Children.Clear();
        var width = _slider.ActualWidth;
        if (_player.Duration <= 0 || width <= 0) return;
        // The slider's track runs between its end caps, a few pixels in from its edges.
        const double inset = 10;
        foreach (var mark in _player.Marks)
        {
            var x = inset + mark / _player.Duration * (width - 2 * inset);
            var line = new Rectangle { Width = 2, Height = 10, RadiusX = 1, RadiusY = 1, Fill = Ui.Tint(150) };
            Canvas.SetLeft(line, x - 1);
            Canvas.SetTop(line, 1);
            _marks.Children.Add(line);
        }
    }

    private void RenderClock()
    {
        _updating = true;
        try
        {
            if (_pending is null)
            {
                var ready = _player.State == PlayerModel.Phase.Ready && _player.Duration > 0;
                _slider.Value = ready ? Math.Min(_player.CurrentTime, _slider.Maximum) : 0;
                _elapsed.Text = _player.Episode is null ? "0:00" : Ui.Clock(_player.CurrentTime);
            }
            _remaining.Text = _player.Duration > 0 ? "−" + Ui.Clock(Math.Max(0, _player.Duration - _player.CurrentTime)) : "";
        }
        finally { _updating = false; }
    }

    /// <summary>Everything but the clock: what's playing, the buttons, the marks.</summary>
    private void Render()
    {
        var episode = _player.Episode;
        var ready = _player.State == PlayerModel.Phase.Ready;
        _updating = true;
        try
        {
            _slider.IsEnabled = ready && _player.Duration > 0;
            _slider.Maximum = Math.Max(_player.Duration, 1);
            _volume.Value = _player.Volume;
        }
        finally { _updating = false; }
        _playIcon.Glyph = _player.IsPlaying ? Ui.G.Pause : Ui.G.Play;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_play, _player.IsPlaying ? "Pause" : "Lecture");
        var hasMarks = _player.Marks.Count > 0;
        _prev.IsEnabled = _next.IsEnabled = ready && hasMarks;
        _back.IsEnabled = _forward.IsEnabled = _play.IsEnabled = ready;
        _speed.Content = Ui.Text($"{_player.Rate.ToString("0.##").Replace('.', ',')}×", 13);

        _subtitle.Children.Clear();
        if (episode is null)
        {
            _title.Text = "Rien en lecture";
            _art.Content = null; _artFor = null; _artEpisode = null;
            _heart.Content = null;
        }
        else
        {
            var shown = _player.CurrentSegment ?? _player.RequestedSegment;
            _title.Text = shown?.DisplayTitle ?? episode.Title;
            var picture = shown?.PosterUrl ?? episode.Artwork;
            if (picture != _artFor || _artEpisode != episode.Id)
            {
                _artFor = picture; _artEpisode = episode.Id;
                _art.Content = picture is null ? Ui.EpisodeArt(episode, 44) : shown?.PosterUrl is not null ? Ui.Poster(picture, 29, 4) : Ui.Cover(picture, 44, 6);
                if (picture is not null && shown?.PosterUrl is not null) _art.HorizontalContentAlignment = HorizontalAlignment.Center;
            }
            switch (_player.State)
            {
                case PlayerModel.Phase.Loading:
                    _subtitle.Children.Add(Ui.Secondary(_player.ServerIsSlow ? "Le serveur de 5heures.be est lent… la suite sera instantanée" : "Préparation du passage…", 12, 1));
                    break;
                case PlayerModel.Phase.Failed:
                    _subtitle.Children.Add(Ui.Text(_player.Error ?? "Lecture impossible", 12, null, 1, 1, Windows.UI.Color.FromArgb(255, 232, 80, 60)));
                    _subtitle.Children.Add(Ui.TextButton("Réessayer", null, _player.Retry));
                    break;
                default:
                    _subtitle.Children.Add(Ui.Badge(episode.Series, true));
                    _subtitle.Children.Add(Ui.Secondary(EpisodeDates.Short(episode.Date), 12, 1));
                    if (_player.ServerIsSlow) _subtitle.Children.Add(Ui.Secondary("· serveur lent…", 12, 1));
                    break;
            }
            _heart.Content = Cards.FavoriteButton(episode, 16, false);
        }
        DrawMarks();
        RenderClock();
    }
}
