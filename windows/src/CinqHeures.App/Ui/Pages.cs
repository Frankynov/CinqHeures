using CinqHeures.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace CinqHeures;

/// <summary>A page as the window shows it: its content, its title in the bar, and the buttons beside the search field.</summary>
public sealed record PageView(UIElement Content, string Title, string? Subtitle = null, IReadOnlyList<UIElement>? Toolbar = null);

public static class Pages
{
    /// <summary>Room under the last row, so nothing stays hidden behind the floating player.</summary>
    public const double PlayerRoom = 96;

    private static AppModel Model => Shell.Model;

    public static Action Reload { get; set; } = () => { };

    /// <summary>The page a route leads to.</summary>
    public static PageView Build(Route route) => route switch
    {
        Route.Work w => WorkPage(w.Kind, w.Title),
        Route.EpisodePage e => EpisodePage(e.Id, e.Highlight),
        Route.ListingPage l => ListingPage(l.Listing),
        Route.ShowPage s => ShowPage(s.Series),
        Route.FavoritesPage => FavoritesPage(),
        _ => Message("Introuvable", Ui.G.Info),
    };

    public static PageView Root(SidebarItem item) => item.Kind switch
    {
        SidebarKind.Home => HomePage(),
        SidebarKind.Favorites => FavoritesPage(),
        SidebarKind.All => ShowPage(null),
        SidebarKind.Show => ShowPage(item.Show),
        SidebarKind.Score => ListingPage(Listing.OfStars(item.Score)),
        _ => ListingPage(Listing.Unrated),
    };

    // MARK: Shared pieces

    private static ScrollViewer Scroll(UIElement content, double pad = 28)
    {
        if (content is FrameworkElement fe) fe.Margin = new Thickness(pad, 20, pad, PlayerRoom);
        return new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    public static PageView Message(string title, string glyph, string? detail = null, UIElement? action = null)
    {
        var stack = new StackPanel { Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 460 };
        stack.Children.Add(new FontIcon { Glyph = glyph, FontSize = 40, Opacity = 0.45, HorizontalAlignment = HorizontalAlignment.Center });
        var t = Ui.Text(title, 20, Ui.SemiBold); t.HorizontalAlignment = HorizontalAlignment.Center; t.TextAlignment = TextAlignment.Center;
        stack.Children.Add(t);
        if (detail is not null)
        {
            var d = Ui.Secondary(detail, 14); d.TextAlignment = TextAlignment.Center; d.HorizontalAlignment = HorizontalAlignment.Center;
            stack.Children.Add(d);
        }
        if (action is FrameworkElement a) { a.HorizontalAlignment = HorizontalAlignment.Center; stack.Children.Add(a); }
        return new PageView(stack, title);
    }

    /// <summary>The "download the catalogue" page, shown while there's nothing else to show.</summary>
    public static PageView FirstLaunch()
    {
        var sync = Model.Sync;
        switch (sync.Kind)
        {
            case AppModel.SyncKind.Failed:
                return Message("Catalogue indisponible", Ui.G.Warning, sync.Message,
                    Ui.OrangeButton("Réessayer", Ui.G.Refresh, () => _ = Model.RefreshAsync(true)));
            default:
                var bar = new ProgressBar { Width = 260, Maximum = Math.Max(sync.Of, 1), Value = sync.Done, Foreground = Ui.OrangeBrush, IsIndeterminate = sync.Of <= 1 };
                var column = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center };
                column.Children.Add(bar);
                if (sync.Of > 1) column.Children.Add(Ui.Secondary($"{sync.Done} sur {sync.Of}", 12));
                return Message("Première ouverture", Ui.G.Refresh,
                    "Téléchargement des « 5 heures » depuis 5heures.be. Cela ne se fait qu'une fois.", column);
        }
    }

    /// <summary>Content that builds itself again when one of the model's events fires, while it's on screen.</summary>
    private static ContentPresenter Live(Func<UIElement> build, Action<Action> subscribe, Action<Action> unsubscribe)
    {
        var host = new ContentPresenter { Content = build() };
        void Rebuild() => host.DispatcherQueue.TryEnqueue(() => host.Content = build());
        host.Loaded += (_, _) => subscribe(Rebuild);
        host.Unloaded += (_, _) => unsubscribe(Rebuild);
        return host;
    }

    private static UIElement Section(string title, UIElement body, string? suffix = null)
    {
        var column = new StackPanel { Spacing = 12 };
        var t = Ui.Text(suffix is null ? title : $"{title} · {suffix}", 20, Ui.Bold);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHeadingLevel(t, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        column.Children.Add(t);
        column.Children.Add(body);
        return column;
    }

    private static ItemsRepeater PosterGrid<T>(IReadOnlyList<T> items, Func<T, UIElement> card) => new()
    {
        ItemsSource = items,
        ItemTemplate = new CodeFactory<T>((item, _) => card(item)),
        Layout = new UniformGridLayout { MinItemWidth = 172, MinItemHeight = 312, MinColumnSpacing = 14, MinRowSpacing = 14, ItemsStretch = UniformGridLayoutItemsStretch.None },
    };

    private static ItemsRepeater RowList<T>(IReadOnlyList<T> items, Func<T, UIElement> row, double spacing = 0) => new()
    {
        ItemsSource = items,
        ItemTemplate = new CodeFactory<T>((item, _) => row(item)),
        Layout = new StackLayout { Orientation = Orientation.Vertical, Spacing = spacing },
    };

    private static Button Toggle(string glyph, string tip, Action click) => Ui.IconButton(glyph, tip, click, 15, 8);

    // MARK: Home

    public static PageView HomePage()
    {
        if (Model.Catalogue.IsEmpty || (Model.IsSyncing && Model.HomeSections.Count == 0)) return FirstLaunch();
        var column = new StackPanel { Spacing = 34 };
        if (Model.Hero is { } hero) column.Children.Add(HeroView(hero));
        var resuming = Model.ContinueListening.Take(12).Select(p => (ShelfItem)new ShelfItem.EpisodeItem(p.Episode, p.Seconds)).ToList();
        if (resuming.Count > 0) column.Children.Add(Cards.ShelfRow("Continuer l'écoute", resuming, null));
        var favorites = Model.FavoriteEpisodes.Take(12).Select(e => (ShelfItem)new ShelfItem.EpisodeItem(e, null)).ToList();
        if (favorites.Count > 0) column.Children.Add(Cards.ShelfRow("Favoris", favorites, new Route.FavoritesPage()));
        foreach (var section in Model.HomeSections)
        {
            switch (section)
            {
                case Shelf shelf:
                    Route? route = shelf.Listing is { } l ? new Route.ListingPage(l) : shelf.Show is { } s ? new Route.ShowPage(s) : null;
                    column.Children.Add(Cards.ShelfRow(shelf.Title, shelf.Items, route));
                    break;
                case List<DecadeTile> tiles:
                    column.Children.Add(DecadeRow(tiles));
                    break;
            }
        }
        var surprise = SurpriseButton();
        return new PageView(Scroll(column), "Accueil", Ui.Plural(Model.Catalogue.Episodes.Count, "épisode", "épisodes"), [surprise]);
    }

    private static Button SurpriseButton()
    {
        var button = Ui.OrangeButton("Surprenez-moi", "🐐", () => { Model.Shuffle(); Reload(); });
        ToolTipService.SetToolTip(button, "D'autres films au hasard, partout sur cette page");
        return button;
    }

    /// <summary>A well-rated review, big, with its poster behind it: play it or open the film.</summary>
    private static UIElement HeroView(Work.Mention mention)
    {
        var segment = mention.Segment;
        var grid = new Grid { Height = 270 };
        if (segment.PosterUrl is { } url)
        {
            var image = Ui.Blurred(url, 400);
            image.Opacity = 0.9;
            grid.Children.Add(image);
        }
        else grid.Background = Ui.Brush(Windows.UI.Color.FromArgb(255, 13, 51, 110));
        grid.Children.Add(new Border
        {
            Background = new LinearGradientBrush
            {
                StartPoint = new Windows.Foundation.Point(0, 0), EndPoint = new Windows.Foundation.Point(1, 0),
                GradientStops = { new GradientStop { Color = Windows.UI.Color.FromArgb(222, 0, 0, 0), Offset = 0 }, new GradientStop { Color = Windows.UI.Color.FromArgb(120, 0, 0, 0), Offset = 1 } },
            },
        });

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 26, Padding = new Thickness(28, 26, 28, 26) };
        var poster = Ui.Poster(segment.PosterUrl, 138, 10);
        row.Children.Add(poster);
        var text = new StackPanel { Spacing = 9, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 640 };
        var white = Colors.White;
        var kicker = Ui.Text("À la une · Une critique au hasard", 12, Ui.SemiBold, 0.75, 1, white);
        text.Children.Add(kicker);
        text.Children.Add(Ui.Text(segment.DisplayTitle, 28, Ui.SemiBold, 1, 2, white));
        var facts = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (segment.Year is { } y) facts.Children.Add(Ui.Text(y.ToString(), 14, null, 0.85, 1, white));
        if (segment.Stars is { } stars) facts.Children.Add(Ui.Text(Segment.StarString(stars), 14, null, 1, 1, Ui.OrangeLight));
        if (segment.SpokenVerdict is { } verdict) facts.Children.Add(Ui.Text("· " + verdict, 14, null, 0.85, 1, white));
        text.Children.Add(facts);
        text.Children.Add(Ui.Text($"{EpisodeDates.Long(mention.Episode.Date)} · {mention.Episode.Series.Title()}", 14, null, 0.65, 2, white));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Margin = new Thickness(0, 6, 0, 0) };
        buttons.Children.Add(Ui.OrangeButton("Écouter la critique", Ui.G.Play, () => Model.Play(mention.Episode, segment), true));
        buttons.Children.Add(WhiteButton(segment.Kind == SegmentKind.Movie ? "Voir le film" : "Voir la page", Ui.G.Info,
            () => Shell.Open(new Route.Work(segment.Kind, segment.Title))));
        buttons.Children.Add(WhiteButton("Une autre", Ui.G.Dice, () => { Model.AnotherHero(); Reload(); }));
        text.Children.Add(buttons);
        row.Children.Add(text);
        grid.Children.Add(row);
        Model.Warm(mention.Episode, segment);
        return new Border { Child = grid, CornerRadius = new CornerRadius(8), HorizontalAlignment = HorizontalAlignment.Stretch };
    }

    private static Button WhiteButton(string label, string glyph, Action click)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(Ui.Icon(glyph, 14));
        row.Children.Add(Ui.Text(label, 14));
        var b = new Button { Content = row, RequestedTheme = ElementTheme.Dark, Padding = new Thickness(14, 8, 14, 8) };
        b.Click += (_, _) => click();
        return b;
    }

    private static readonly Windows.UI.Color[][] DecadePalette =
    [
        [Rgb(.35, .30, .28), Rgb(.62, .50, .36)], [Rgb(.75, .30, .25), Rgb(.95, .62, .20)],
        [Rgb(.55, .25, .60), Rgb(.90, .40, .55)], [Rgb(.15, .40, .75), Rgb(.45, .30, .80)],
        [Rgb(.10, .50, .55), Rgb(.25, .70, .45)], [Rgb(.20, .25, .60), Rgb(.55, .30, .70)],
        [Rgb(.80, .35, .20), Rgb(.55, .15, .40)], [Rgb(.05, .35, .55), Rgb(.10, .60, .70)],
    ];

    private static Windows.UI.Color Rgb(double r, double g, double b) =>
        Windows.UI.Color.FromArgb(255, (byte)(r * 255), (byte)(g * 255), (byte)(b * 255));

    /// <summary>Decades as colourful tiles: the archive's way of "Genres".</summary>
    private static UIElement DecadeRow(List<DecadeTile> tiles)
    {
        var column = new StackPanel { Spacing = 14 };
        var title = Ui.Text("Explorer par époque", 22, Ui.Bold);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHeadingLevel(title, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        column.Children.Add(title);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 18, Padding = new Thickness(0, 4, 0, 14) };
        for (var i = 0; i < tiles.Count; i++)
        {
            var tile = tiles[i];
            var colors = DecadePalette[i % DecadePalette.Length];
            var grid = new Grid { Width = 250, Height = 128 };
            grid.Background = new LinearGradientBrush
            {
                StartPoint = new Windows.Foundation.Point(0, 0), EndPoint = new Windows.Foundation.Point(1, 1),
                GradientStops = { new GradientStop { Color = colors[0], Offset = 0 }, new GradientStop { Color = colors[1], Offset = 1 } },
            };
            var fan = new Grid { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 22, 0), Opacity = 0.95 };
            for (var p = 0; p < tile.Posters.Count; p++)
            {
                var poster = Ui.Poster(tile.Posters[p], 62, 5);
                poster.HorizontalAlignment = HorizontalAlignment.Right;
                poster.Margin = new Thickness(0, 0, p * 28, 0);
                poster.RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5);
                poster.RenderTransform = new RotateTransform { Angle = (tile.Posters.Count - 1 - p - 1) * 7 };
                fan.Children.Insert(0, poster);
            }
            grid.Children.Add(fan);
            var label = new StackPanel { Spacing = 2, Margin = new Thickness(16), VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Left };
            label.Children.Add(Ui.Text(tile.Title, 18, Ui.Bold, 1, 1, Colors.White));
            label.Children.Add(Ui.Text($"{tile.Count} films", 12, null, 0.8, 1, Colors.White));
            grid.Children.Add(label);
            var host = new Border { Child = grid, CornerRadius = new CornerRadius(8) };
            host.Clickable(() => Shell.Open(new Route.ListingPage(Listing.OfDecade(tile.Decade))), $"{tile.Title}, {tile.Count} films");
            row.Children.Add(host);
        }
        column.Children.Add(new ScrollViewer { Content = row, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Enabled, VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
        return column;
    }

    // MARK: Listings

    private static ListingOrder OrderOf(string raw) => raw == "name" ? ListingOrder.Name : ListingOrder.Date;

    /// <summary>A film or episode as a row: the dense alternative to the poster grid.</summary>
    private static UIElement ItemRow(ShelfItem item)
    {
        if (item is ShelfItem.EpisodeItem e) return Cards.EpisodeRow(e.Episode);
        var mention = ((ShelfItem.Passage)item).Mention;
        var segment = mention.Segment;
        var grid = new Grid { ColumnSpacing = 12, Padding = new Thickness(8, 6, 8, 6) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Ui.Poster(segment.PosterUrl, 40, 4));
        var text = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(Ui.Text(segment.DisplayTitle, 15, Ui.SemiBold, 1, 1));
        var facts = new List<string>();
        if (segment.Year is { } y) facts.Add(y.ToString());
        if (segment.SpokenVerdict is { } v) facts.Add(v);
        if (facts.Count > 0) text.Children.Add(Ui.Secondary(string.Join(" · ", facts), 12, 1));
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, VerticalAlignment = VerticalAlignment.Center };
        if (segment.Stars is { } stars) right.Children.Add(Ui.Text(Segment.StarString(stars), 13, null, 1, 1, Ui.Orange));
        right.Children.Add(Ui.Badge(mention.Episode.Series));
        right.Children.Add(Ui.Secondary(EpisodeDates.Short(mention.Episode.Date), 12, 1));
        Grid.SetColumn(right, 2);
        grid.Children.Add(right);
        var host = new Border { Child = grid, CornerRadius = new CornerRadius(10), Background = Ui.Brush(Colors.Transparent) };
        host.Hover(on => host.Background = on ? Ui.Tint(30) : Ui.Brush(Colors.Transparent));
        host.Clickable(() => Shell.Open(new Route.Work(segment.Kind, segment.Title)), segment.DisplayTitle);
        return host;
    }

    /// <summary>A shelf's "Tout voir", a score, a decade: a grid of everything in it.</summary>
    public static PageView ListingPage(Listing listing)
    {
        var data = Model.Data;
        var order = OrderOf(data.ListingOrder);
        var items = Model.Items(listing, order);
        var shown = data.ListingReversed ? Enumerable.Reverse(items).ToList() : items;
        var subtitle = Ui.Plural(items.Count, "titre", "titres");
        if (items.Count == 0) return Message("Rien ici", Ui.G.Film) with { Title = listing.Title, Subtitle = subtitle };

        var list = data.ListingLayout == "list";
        UIElement body = list
            ? RowList(shown, ItemRow)
            : PosterGrid(shown, i => Cards.ItemCard(i));
        var sort = SortMenu();
        var layout = Toggle(list ? Ui.G.Grid : Ui.G.List, list ? "Afficher en grille d'affiches" : "Afficher en liste",
            () => { data.ListingLayout = list ? "grid" : "list"; data.Save(); Reload(); });
        return new PageView(Scroll((FrameworkElement)body), listing.Title, subtitle, [layout, sort]);
    }

    private static Button SortMenu()
    {
        var data = Model.Data;
        var order = OrderOf(data.ListingOrder);
        var menu = new MenuFlyout();
        foreach (var choice in new[] { ListingOrder.Date, ListingOrder.Name })
        {
            var current = choice == order;
            var item = new MenuFlyoutItem
            {
                Text = current ? $"{choice.Title()} · {choice.Direction(data.ListingReversed)}" : choice.Title(),
                Icon = Ui.Icon(current ? (data.ListingReversed ? "" : "") : (choice == ListingOrder.Date ? "" : ""), 14),
            };
            item.Click += (_, _) =>
            {
                // Choosing the current order again flips it.
                if (current) data.ListingReversed = !data.ListingReversed;
                else { data.ListingOrder = choice == ListingOrder.Name ? "name" : "date"; data.ListingReversed = false; }
                data.Save();
                Reload();
            };
            menu.Items.Add(item);
        }
        var button = new Button { Content = Ui.Icon(Ui.G.Sort, 15), Flyout = menu, Padding = new Thickness(8), Background = Ui.Brush(Colors.Transparent), BorderThickness = new Thickness(0), CornerRadius = new CornerRadius(8) };
        ToolTipService.SetToolTip(button, "Trier par date ou par nom ; choisir à nouveau inverse l'ordre");
        return button;
    }

    // MARK: Shows and favourites

    /// <summary>A show's episodes, by year; or, for the shows that discuss films, its films' posters in a grid.</summary>
    public static PageView ShowPage(Series? series)
    {
        var episodes = Model.Catalogue.Episodes.Where(e => series is null || e.Series == series).ToList();
        var host = series?.Host() is { } h ? $"par {h} · " : "";
        var title = series?.FullTitle() ?? "Récents";
        var offersGrid = series is { } s && s != Series.QuelquePart;
        var grid = offersGrid && Model.Data.ShowLayout == "grid";
        var toolbar = new List<UIElement>();
        if (offersGrid)
            toolbar.Add(Toggle(grid ? Ui.G.List : Ui.G.Grid, grid ? "Afficher la liste des épisodes" : "Afficher les affiches des films",
                () => { Model.Data.ShowLayout = grid ? "list" : "grid"; Model.Data.Save(); Reload(); }));
        if (grid)
        {
            var films = Model.Items(Listing.OfShow(series!.Value), ListingOrder.Date);
            return new PageView(Scroll(PosterGrid(films, i => Cards.ItemCard(i))), title, host + Ui.Plural(films.Count, "titre", "titres"), toolbar);
        }
        // Year headings and episodes in one virtualised list: 1,160 rows scroll smoothly.
        var rows = new List<object>();
        foreach (var group in episodes.GroupBy(e => e.Year).OrderByDescending(g => g.Key))
        {
            rows.Add(group.Key);
            rows.AddRange(group);
        }
        var list = RowList(rows, row => row is int year
            ? Pad(Ui.Text(year.ToString(), 18, Ui.Bold), new Thickness(8, 18, 0, 6))
            : Cards.EpisodeRow((Episode)row, series is null));
        return new PageView(Scroll(list), title, host + Ui.Plural(episodes.Count, "épisode", "épisodes"), toolbar);
    }

    private static UIElement Pad(FrameworkElement element, Thickness margin)
    {
        element.Margin = margin;
        return element;
    }

    /// <summary>The favourite episodes, the last one added first.</summary>
    public static PageView FavoritesPage()
    {
        var episodes = Model.FavoriteEpisodes;
        var subtitle = Ui.Plural(episodes.Count, "épisode", "épisodes");
        if (episodes.Count == 0)
            return Message("Aucun favori", Ui.G.Heart, "Cliquez sur le cœur d'un épisode pour le retrouver ici.") with { Title = "Favoris", Subtitle = subtitle };
        return new PageView(Scroll(RowList(episodes, e => Cards.EpisodeRow(e))), "Favoris", subtitle);
    }

    // MARK: Search

    private const int SearchLimit = 120;

    /// <summary>What a search found: posters by kind, then the episodes whose title or summary matched.</summary>
    public static PageView SearchPage()
    {
        var results = new ContentPresenter();
        var scopes = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(28, 14, 28, 0) };
        void Fill()
        {
            results.Content = SearchResults();
            foreach (var (b, scope) in scopes.Children.OfType<ToggleButton>().Zip(Enum.GetValues<SearchScope>()))
                b.IsChecked = Model.Scope == scope;
        }
        foreach (var scope in Enum.GetValues<SearchScope>())
        {
            var button = new ToggleButton { Content = scope.Title(), Padding = new Thickness(14, 5, 14, 6) };
            button.Click += (_, _) => Model.SetSearch(Model.SearchText, scope, false);
            scopes.Children.Add(button);
        }
        var page = new Grid();
        page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        page.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        page.Children.Add(scopes);
        Grid.SetRow(results, 1);
        page.Children.Add(results);
        Action handler = Fill;
        page.Loaded += (_, _) => { Model.SearchChanged += handler; };
        page.Unloaded += (_, _) => { Model.SearchChanged -= handler; };
        Fill();
        return new PageView(page, "Recherche", Model.SearchText);
    }

    private static UIElement SearchResults()
    {
        var found = Model.Results;
        if (found.IsEmpty)
            return Message(Model.SearchIsSettled ? $"Aucun résultat pour « {Model.SearchText} »" : "Recherche…", Ui.G.Search).Content;
        var column = new StackPanel { Spacing = 28 };
        foreach (var (title, kind) in new[] { ("Films", SegmentKind.Movie), ("Séries", SegmentKind.TvShow), ("Personnalités", SegmentKind.Person) })
        {
            var matching = found.Works.Where(w => w.Kind == kind).ToList();
            if (matching.Count == 0) continue;
            var body = new StackPanel { Spacing = 10 };
            body.Children.Add(new ItemsRepeater
            {
                ItemsSource = matching.Take(SearchLimit).ToList(),
                ItemTemplate = new CodeFactory<Work>((w, _) => Cards.FilmCard(w.Mentions[0], 150, w.Mentions.Count)),
                Layout = new UniformGridLayout { MinItemWidth = 172, MinItemHeight = 312, MinColumnSpacing = 14, MinRowSpacing = 14, ItemsStretch = UniformGridLayoutItemsStretch.None },
            });
            if (matching.Count > SearchLimit) body.Children.Add(Ui.Secondary($"… et {matching.Count - SearchLimit} autres : précisez la recherche.", 14));
            column.Children.Add(Section(title, body, matching.Count.ToString()));
        }
        if (found.Described.Count > 0)
            column.Children.Add(Section("Dans le titre ou le résumé d'un épisode", RowList(found.Described.Take(40).ToList(), e => Cards.EpisodeRow(e))));
        return Scroll(column);
    }

    // MARK: A film, series or person

    public static PageView WorkPage(SegmentKind kind, string title)
    {
        if (Model.FindWork(kind, title) is not { } work
            || (work.Mentions.FirstOrDefault(m => m.Segment.Start is not null) ?? work.Mentions[0]) is not { } latest)
            return Message("Introuvable", Ui.G.Info);
        // "Écouter la critique" plays the newest passage with a time: an "Autre" special only mentions a film, from the
        // start of an untimed episode, when a review of it may be elsewhere.
        Model.Warm(latest.Episode, latest.Segment);
        Model.LookUpDetails(work);
        Model.LookUpStreaming(work);
        var content = Live(() => WorkContent(work, latest), h => Model.DetailsChanged += h, h => Model.DetailsChanged -= h);
        return new PageView(content, latest.Segment.DisplayTitle, kind.Label());
    }

    private static UIElement WorkContent(Work work, Work.Mention latest)
    {
        var segment = latest.Segment;
        var kind = work.Kind;
        // Dayez's films have them from TMDB; 5heures.be's from the film's page on the site, once looked up.
        var fetched = Model.DetailsOf(work);
        var local = work.Mentions.Select(m => m.Segment.LocalTitle).FirstOrDefault(s => s is not null) ?? fetched?.LocalTitle;
        var director = work.Mentions.Select(m => m.Segment.Director).FirstOrDefault(s => s is not null) ?? fetched?.Director;
        var own = work.Mentions.Select(m => m.Segment.Overview).FirstOrDefault(s => s is not null);
        var overview = own ?? fetched?.Overview;

        var header = new Grid { ColumnSpacing = 28 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var poster = Ui.Poster(work.PosterUrl, 210, 12);
        header.Children.Add(poster);

        var info = new StackPanel { Spacing = 10, MaxWidth = 700, HorizontalAlignment = HorizontalAlignment.Left };
        info.Children.Add(Ui.Text(segment.DisplayTitle, 34, Ui.Bold));
        if (local is not null && local != segment.DisplayTitle) info.Children.Add(Ui.Text(local, 18, null, 0.65));
        var facts = new[] { kind.Label(), segment.Year?.ToString(), director is null ? null : $"de {director}", Ui.Plural(work.Mentions.Count, "passage", "passages") }.OfType<string>();
        info.Children.Add(Ui.Secondary(string.Join(" · ", facts), 14));
        if (work.Mentions.Select(m => m.Segment.Stars).OfType<int>().DefaultIfEmpty(-1).Max() is var best and >= 0)
            info.Children.Add(Ui.Text(Segment.StarString(best), 18, null, 1, 1, Ui.Orange));
        if (Model.Streamings.TryGetValue(work.Id, out var streaming)) info.Children.Add(StreamingLine(streaming));
        if (overview is not null)
        {
            var o = Ui.Text(overview, 14, null, 0.7, 8); o.IsTextSelectionEnabled = true;
            info.Children.Add(o);
            var source = own is not null ? "Synopsis et affiche : TMDB" : fetched?.FromTmdb == true ? "Synopsis : TMDB" : "Synopsis : 5heures.be";
            // JustWatch, where TMDB's "where to watch" comes from, asks to be named wherever it's shown.
            info.Children.Add(Ui.Text(streaming is null ? source : source + " · Plateformes : JustWatch", 11, null, 0.5));
        }
        var play = Ui.OrangeButton("Écouter la critique", Ui.G.Play, () => Model.Play(latest.Episode, segment), true);
        play.Margin = new Thickness(0, 8, 0, 0);
        info.Children.Add(play);
        Grid.SetColumn(info, 1);
        header.Children.Add(info);

        var column = new StackPanel { Spacing = 30 };
        column.Children.Add(header);
        var passages = new StackPanel { Spacing = 10 };
        var heading = Ui.Text(work.Mentions.Count > 1 ? "Les passages" : "Le passage", 22, Ui.Bold);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHeadingLevel(heading, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        passages.Children.Add(heading);
        foreach (var mention in work.Mentions) passages.Children.Add(PassageRow(mention));
        column.Children.Add(passages);
        return Scroll(column);
    }

    /// <summary>"Sur Netflix, Prime Video" with the services' small logos, under the title's facts: one quiet line, a link
    /// to TMDB's page for the title, which leads on to each service.</summary>
    private static UIElement StreamingLine(Streaming streaming)
    {
        var lead = streaming.Kind switch { StreamingKind.Subscription => "Sur", StreamingKind.Free => "Gratuit sur", _ => "À louer sur" };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var logos = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3 };
        foreach (var service in streaming.Services) logos.Children.Add(Ui.Cover(service.LogoUrl, 18, 4, Ui.G.Tv));
        row.Children.Add(logos);
        row.Children.Add(Ui.Text($"{lead} {string.Join(", ", streaming.Services.Select(s => s.Name))}", 14, null, 0.65, 1));
        if (streaming.Link is { } link)
        {
            row.Clickable(() => _ = Windows.System.Launcher.LaunchUriAsync(link));
            ToolTipService.SetToolTip(row, "Où le regarder (TMDB, données JustWatch)");
        }
        return row;
    }

    private static UIElement PassageRow(Work.Mention mention)
    {
        var segment = mention.Segment;
        var grid = new Grid { ColumnSpacing = 14 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Ui.EpisodeArt(mention.Episode, 52));
        var text = new StackPanel { Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        head.Children.Add(Ui.Text(EpisodeDates.Long(mention.Episode.Date), 15, Ui.SemiBold, 1, 1));
        head.Children.Add(Ui.Badge(mention.Episode.Series));
        text.Children.Add(head);
        var facts = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        // Dayez's episodes have no per-film timecode: the whole (short) episode plays.
        facts.Children.Add(Ui.Secondary(segment.Start is { } start ? Ui.Clock(start)
            : "Épisode entier" + (mention.Episode.Duration is { } d ? $" · {(int)(d / 60)} min" : ""), 13, 1));
        if (segment.Stars is { } stars) facts.Children.Add(Ui.Text(Segment.StarString(stars), 13, null, 1, 1, Ui.Orange));
        if (segment.SpokenVerdict is { } verdict) facts.Children.Add(Ui.Secondary(verdict, 13, 1));
        text.Children.Add(facts);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        buttons.Children.Add(Ui.TextButton("Épisode", Ui.G.List, () => Shell.Open(new Route.EpisodePage(mention.Episode.Id, segment.Id))));
        buttons.Children.Add(Ui.OrangeButton("Écouter", Ui.G.Play, () => Model.Play(mention.Episode, segment)));
        Grid.SetColumn(buttons, 2);
        grid.Children.Add(buttons);
        return Ui.Card(grid, 12, 12);
    }

    // MARK: An episode

    public static PageView EpisodePage(long id, long? highlight)
    {
        if (Model.EpisodeById(id) is not { } episode) return Message("Introuvable", Ui.G.Info);
        Model.Warm(episode, episode.Segments.FirstOrDefault(s => s.Id == highlight) ?? episode.Subjects.FirstOrDefault());
        return new PageView(EpisodeContent(episode, highlight), episode.Title, EpisodeDates.Long(episode.Date));
    }

    private static UIElement EpisodeContent(Episode episode, long? highlighted)
    {
        var player = Model.Player;
        var column = new StackPanel { Spacing = 22 };
        var top = new StackPanel { Spacing = 12 };
        if (episode.Artwork is not null)
        {
            var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14 };
            head.Children.Add(Ui.Cover(episode.Artwork, 110, 12));
            var t = new StackPanel { Spacing = 4 };
            t.Children.Add(Ui.Text(episode.Title, 20, Ui.SemiBold));
            if (episode.Series.Host() is { } host) t.Children.Add(Ui.Text($"{episode.Series.FullTitle()}, par {host}", 14, Ui.Medium, 0.65));
            t.Children.Add(Ui.Secondary(EpisodeDates.Long(episode.Date), 14));
            if (episode.Duration is { } duration) t.Children.Add(Ui.Secondary(Ui.Clock(duration), 14));
            head.Children.Add(t);
            top.Children.Add(head);
        }
        var bar = new Grid { ColumnSpacing = 8 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.Children.Add(Ui.Badge(episode.Series));
        var heart = Cards.FavoriteButton(episode);
        Grid.SetColumn(heart, 1);
        bar.Children.Add(heart);
        var playLabel = Ui.Text("", 14);
        var play = new Button
        {
            Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { Ui.Icon(Ui.G.Play, 14), playLabel } },
            Style = (Style)Application.Current.Resources["AccentButtonStyle"], Padding = new Thickness(14, 7, 14, 7),
        };
        play.Click += (_, _) => Model.Play(episode);
        Grid.SetColumn(play, 2);
        bar.Children.Add(play);
        top.Children.Add(bar);
        if (episode.Summary.Length > 0)
        {
            var summary = Ui.Text(episode.Summary, 14, null, 0.7); summary.IsTextSelectionEnabled = true;
            top.Children.Add(summary);
        }
        column.Children.Add(top);

        var updaters = new List<Action>();
        if (episode.Segments.Count > 0)
        {
            var timed = episode.Segments.Any(s => s.Start is not null);
            var list = new StackPanel();
            var heading = Ui.Text($"Au programme · {episode.Subjects.Count()}", 20, Ui.Bold);
            heading.Margin = new Thickness(0, 0, 0, 10);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetHeadingLevel(heading, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
            list.Children.Add(heading);
            FrameworkElement? target = null;
            foreach (var segment in episode.Segments)
            {
                var (row, update) = SegmentRow(segment, episode, timed, segment.Id == highlighted);
                updaters.Add(update);
                list.Children.Add(row);
                if (segment.Id == highlighted) target = row;
            }
            column.Children.Add(list);
            if (target is not null) target.Loaded += (_, _) => target.DispatcherQueue.TryEnqueue(() => target.StartBringIntoView(new BringIntoViewOptions { VerticalAlignmentRatio = 0.4, AnimationDesired = true }));
        }

        void Refresh()
        {
            var current = player.Episode?.Id == episode.Id;
            playLabel.Text = current ? "Reprendre" : player.HasProgress(episode) ? "Reprendre l'épisode" : "Écouter l'épisode";
            foreach (var update in updaters) update();
        }
        Refresh();
        Action handler = () => column.DispatcherQueue.TryEnqueue(Refresh);
        column.Loaded += (_, _) => player.Changed += handler;
        column.Unloaded += (_, _) => player.Changed -= handler;
        return Scroll(column);
    }

    private static (FrameworkElement Row, Action Update) SegmentRow(Segment segment, Episode episode, bool timed, bool highlighted)
    {
        var isSubject = segment.Kind.IsSubject();
        var grid = new Grid { ColumnSpacing = 10, Padding = new Thickness(10, 7, 10, 7) };
        var columns = new[] { timed ? 52.0 : 0, 26, -1, 20, timed ? 40 : 0 };
        foreach (var w in columns)
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = w < 0 ? new GridLength(1, GridUnitType.Star) : w == 0 ? new GridLength(0) : GridLength.Auto });
        if (timed)
        {
            var clock = Ui.Secondary(segment.Start is { } s ? Ui.Clock(s) : "–", 12, 1);
            clock.HorizontalAlignment = HorizontalAlignment.Right; clock.VerticalAlignment = VerticalAlignment.Center;
            clock.Width = 52; clock.TextAlignment = TextAlignment.Right;
            grid.Children.Add(clock);
        }
        FrameworkElement lead = isSubject ? Ui.Poster(segment.PosterUrl, 26, 3) : new FontIcon { Glyph = segment.Kind.Symbol(), FontSize = 14, Opacity = 0.4 };
        Grid.SetColumn(lead, 1);
        grid.Children.Add(lead);
        var text = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(Ui.Text(segment.Title, 15, isSubject ? Ui.Medium : null, isSubject ? 1 : 0.65));
        var facts = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (segment.Kind != SegmentKind.Movie && isSubject) facts.Children.Add(Ui.Secondary(segment.Kind.Label(), 12, 1));
        if (segment.Stars is { } stars) facts.Children.Add(Ui.Text(Segment.StarString(stars), 12, null, 1, 1, Ui.Orange));
        if (segment.SpokenVerdict is { } verdict) facts.Children.Add(Ui.Secondary(verdict, 12, 1));
        if (facts.Children.Count > 0) text.Children.Add(facts);
        Grid.SetColumn(text, 2);
        grid.Children.Add(text);
        var speaker = new FontIcon { Glyph = Ui.G.Speaker, FontSize = 14, Foreground = Ui.OrangeBrush, Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(speaker, 3);
        grid.Children.Add(speaker);
        // The "Autre" specials have no timecodes at all: no buttons all playing from the start (the episode's own does that).
        if (timed)
        {
            var play = Ui.IconButton(Ui.G.Play, $"Écouter à partir de {Ui.Clock(segment.Start ?? 0)}", () => Model.Play(episode, segment), 12, 7);
            play.Background = Ui.Tint(30);
            Grid.SetColumn(play, 4);
            grid.Children.Add(play);
        }
        var host = new Border { Child = grid, CornerRadius = new CornerRadius(10), Background = highlighted ? Ui.Brush(Windows.UI.Color.FromArgb(40, 0xEE, 0x8C, 0x0D)) : Ui.Brush(Colors.Transparent) };
        if (!highlighted) host.Hover(on => host.Background = on ? Ui.Tint(24) : Ui.Brush(Colors.Transparent));
        // The whole block opens the film, series or person; an aside plays instead.
        host.Clickable(() => { if (isSubject) Shell.Open(new Route.Work(segment.Kind, segment.Title)); else Model.Play(episode, segment); }, segment.Title);
        void Update() => speaker.Visibility = Model.Player.Episode?.Id == episode.Id && Model.Player.CurrentSegmentId == segment.Id ? Visibility.Visible : Visibility.Collapsed;
        Update();
        return (host, Update);
    }
}
