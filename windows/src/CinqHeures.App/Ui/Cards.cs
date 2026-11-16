using CinqHeures.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace CinqHeures;

/// <summary>What the pages need from the window: the model, and a way to go to another page.</summary>
public static class Shell
{
    public static AppModel Model { get; set; } = null!;
    public static Action<Route> Open { get; set; } = _ => { };
}

/// <summary>Posters, cards and rows.</summary>
public static class Cards
{
    public static Window? Window { get; set; }

    /// <summary>"Série", "2019 · 3 passages", "2024 · 3 skalextric".</summary>
    private static string FilmSubtitle(Segment segment, int passages)
    {
        var parts = new List<string>();
        switch (segment.Kind)
        {
            case SegmentKind.TvShow: parts.Add("Série"); break;
            case SegmentKind.Person: parts.Add("Personnalité"); break;
            default: if (segment.Year is { } y) parts.Add(y.ToString()); break;
        }
        if (passages > 1) parts.Add($"{passages} passages");
        else if (segment.Kind == SegmentKind.Movie && segment.SpokenVerdict is { } verdict) parts.Add(verdict);
        return string.Join(" · ", parts);
    }

    public static string Stars(int stars) => Segment.StarString(stars);

    /// <summary>One film, series or person as a poster with its title: click to open its page, hover to play.</summary>
    public static UIElement FilmCard(Work.Mention mention, double width = 150, int passages = 1)
    {
        var segment = mention.Segment;
        var poster = Ui.Poster(segment.PosterUrl, width, 8);
        var overlay = new Grid { Width = width, Height = width * 1.5 };
        overlay.Children.Add(poster);
        if (segment.Stars is { } stars)
        {
            var star = new Border
            {
                Background = Ui.Brush(Windows.UI.Color.FromArgb(158, 0, 0, 0)), CornerRadius = new CornerRadius(20),
                Padding = new Thickness(6, 2, 6, 3), Margin = new Thickness(7), HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Bottom,
                Child = Ui.Text(Stars(stars), 11, null, 1, 1, Ui.OrangeLight),
            };
            overlay.Children.Add(star);
        }
        var play = new Button
        {
            Content = Ui.Icon(Ui.G.Play, 20), Width = 48, Height = 48, CornerRadius = new CornerRadius(24),
            Background = Ui.Brush(Windows.UI.Color.FromArgb(140, 0, 0, 0)), Foreground = Ui.Brush(Colors.White),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed,
            BorderBrush = Ui.Brush(Windows.UI.Color.FromArgb(180, 255, 255, 255)), BorderThickness = new Thickness(1.5),
        };
        play.Resources["ButtonBackgroundPointerOver"] = Ui.Brush(Windows.UI.Color.FromArgb(190, 0, 0, 0));
        ToolTipService.SetToolTip(play, segment.Start is { } s ? $"Écouter la critique à {Ui.Clock(s)}" : "Écouter");
        play.Click += (_, _) => Shell.Model.Play(mention.Episode, segment);
        overlay.Children.Add(play);

        var stack = new StackPanel { Width = width, Spacing = 7 };
        stack.Children.Add(overlay);
        stack.Children.Add(Ui.Text(segment.DisplayTitle, 14, Ui.SemiBold, 1, 2));
        stack.Children.Add(Ui.Secondary(FilmSubtitle(segment, passages), 12, 1));
        stack.Hover(on => play.Visibility = on ? Visibility.Visible : Visibility.Collapsed);
        stack.Clickable(() => Shell.Open(new Route.Work(segment.Kind, segment.Title)), segment.DisplayTitle);
        return stack;
    }

    public static UIElement EpisodeCard(Episode episode, double? resume, double side = 150)
    {
        var art = Ui.EpisodeArt(episode, side);
        var host = new Grid { Width = side, Height = side };
        host.Children.Add(art);
        if (resume is { } seconds && Shell.Model.Player.LengthOf(episode) is { } length && length > 0)
        {
            host.Children.Add(new ProgressBar
            {
                Value = Math.Min(1, seconds / length), Maximum = 1, Height = 4, VerticalAlignment = VerticalAlignment.Bottom,
                Margin = new Thickness(8, 0, 8, 8), Foreground = Ui.OrangeBrush,
            });
        }
        var stack = new StackPanel { Width = side, Spacing = 7 };
        stack.Children.Add(host);
        stack.Children.Add(Ui.Text(episode.Name ?? episode.Title, 14, Ui.SemiBold, 1, 2));
        stack.Children.Add(Ui.Secondary(resume is { } r ? $"Reprendre à {Ui.Clock(r)}" : EpisodeDates.Short(episode.Date), 12, 1));
        stack.Clickable(() => Shell.Open(new Route.EpisodePage(episode.Id, null)), episode.Title);
        return stack;
    }

    public static UIElement ItemCard(ShelfItem item, double width = 150) => item switch
    {
        ShelfItem.Passage p => FilmCard(p.Mention, width),
        ShelfItem.EpisodeItem e => EpisodeCard(e.Episode, e.Resume, width),
        _ => new Grid(),
    };

    /// <summary>The films and series for a review show; date and length for a plain recording.</summary>
    private static string EpisodeDetail(Episode episode)
    {
        // A review show lists its films, unless they're already the episode's title (feed shows).
        var subjects = episode.Subjects.ToList();
        if (subjects.Count > 0 && episode.Name is null) return string.Join(" · ", subjects.Select(s => s.DisplayTitle));
        var parts = new List<string> { EpisodeDates.Long(episode.Date) };
        if (episode.Duration is { } d) parts.Add(Ui.Clock(d));
        if (episode.Summary.Length > 0 && subjects.Count == 0) parts.Add(episode.Summary);
        return string.Join(" · ", parts);
    }

    /// <summary>An episode as a row of a list: its picture, its title, the films in it.</summary>
    public static UIElement EpisodeRow(Episode episode, bool showSeries = true)
    {
        var grid = new Grid { ColumnSpacing = 12, Padding = new Thickness(8, 6, 8, 6) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(Ui.EpisodeArt(episode, 56));
        var text = new StackPanel { Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
        var head = new Grid { ColumnSpacing = 10 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.Children.Add(Ui.Text(episode.Name ?? EpisodeDates.Long(episode.Date), 15, Ui.SemiBold, 1, 2));
        if (showSeries) { var badge = Ui.Badge(episode.Series); Grid.SetColumn(badge, 1); head.Children.Add(badge); }
        text.Children.Add(head);
        text.Children.Add(Ui.Secondary(EpisodeDetail(episode), 12, 2));
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        var host = new Border { Child = grid, CornerRadius = new CornerRadius(10), Background = Ui.Brush(Colors.Transparent) };
        host.Hover(on => host.Background = on ? Ui.Tint(30) : Ui.Brush(Colors.Transparent));
        host.Clickable(() => Shell.Open(new Route.EpisodePage(episode.Id, null)), episode.Title);
        host.ContextFlyout = FavoriteMenu(episode);
        return host;
    }

    public static MenuFlyout FavoriteMenu(Episode episode)
    {
        var menu = new MenuFlyout();
        var item = new MenuFlyoutItem();
        void Refresh() { item.Text = Shell.Model.IsFavorite(episode) ? "Retirer des favoris" : "Ajouter aux favoris"; item.Icon = Ui.Icon(Shell.Model.IsFavorite(episode) ? Ui.G.Heart : Ui.G.HeartFill, 14); }
        Refresh();
        item.Click += (_, _) => Shell.Model.ToggleFavorite(episode);
        menu.Opening += (_, _) => Refresh();
        menu.Items.Add(item);
        return menu;
    }

    /// <summary>A heart that adds the episode to the favourites, or takes it out.</summary>
    public static Button FavoriteButton(Episode episode, double size = 16, bool bordered = true)
    {
        var button = new Button { Padding = new Thickness(bordered ? 10 : 8), CornerRadius = new CornerRadius(8) };
        if (!bordered) { button.Background = Ui.Brush(Colors.Transparent); button.BorderThickness = new Thickness(0); }
        void Refresh()
        {
            var on = Shell.Model.IsFavorite(episode);
            var icon = Ui.Icon(on ? Ui.G.HeartFill : Ui.G.Heart, size);
            if (on) icon.Foreground = Ui.Brush(Windows.UI.Color.FromArgb(255, 255, 45, 85));
            button.Content = icon;
            ToolTipService.SetToolTip(button, on ? "Retirer des favoris" : "Ajouter aux favoris");
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, on ? "Retirer des favoris" : "Ajouter aux favoris");
        }
        Refresh();
        button.Click += (_, _) => { Shell.Model.ToggleFavorite(episode); Refresh(); };
        Action handler = Refresh;
        Shell.Model.FavoritesChanged += handler;
        button.Unloaded += (_, _) => Shell.Model.FavoritesChanged -= handler;
        return button;
    }

    /// <summary>A titled row of cards that scrolls sideways, with "Tout voir".</summary>
    public static UIElement ShelfRow(string title, IReadOnlyList<ShelfItem> items, Route? seeAll)
    {
        var head = new Grid { Margin = new Thickness(0, 0, 0, 12) };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var t = Ui.Text(title, 20, Ui.SemiBold);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHeadingLevel(t, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        head.Children.Add(t);
        if (seeAll is not null)
        {
            var link = new HyperlinkButton { Content = "Tout voir", Padding = new Thickness(8, 4, 8, 4) };
            link.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(link, 1);
            link.Click += (_, _) => Shell.Open(seeAll);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(link, $"Tout voir : {title}");
            head.Children.Add(link);
        }
        var repeater = new ItemsRepeater
        {
            ItemsSource = items.ToList(),
            Layout = new StackLayout { Orientation = Orientation.Horizontal, Spacing = 20 },
            ItemTemplate = new CodeFactory<ShelfItem>((item, _) => ItemCard(item)),
        };
        var scroll = new ScrollViewer
        {
            Content = repeater, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollMode = ScrollMode.Enabled, VerticalScrollMode = ScrollMode.Disabled, Padding = new Thickness(0, 4, 0, 14),
        };
        var column = new StackPanel();
        column.Children.Add(head);
        column.Children.Add(scroll);
        return column;
    }
}
