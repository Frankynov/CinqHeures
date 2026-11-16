using CinqHeures.Core;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using Windows.UI;

namespace CinqHeures;

/// <summary>The window: the sidebar, the page and what's pushed on it, the search field, and the player floating over the bottom.</summary>
public sealed class MainWindow : Window
{
    private readonly AppModel _model;
    private readonly Grid _root = new();
    private readonly Grid _titleBar = new() { Height = 48 };
    private readonly ColumnDefinition _leftInset = new() { Width = new GridLength(0) };
    private readonly ColumnDefinition _rightInset = new() { Width = new GridLength(0) };
    private readonly Button _back;
    private readonly TextBlock _title = Ui.Text("", 28, Ui.SemiBold, 1, 1);
    private readonly TextBlock _subtitle = Ui.Secondary("", 12, 1);
    private readonly StackPanel _toolbar = new() { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
    private readonly AutoSuggestBox _search = new() { PlaceholderText = "Film, série, réalisateur, acteur, artiste…", Width = 330, VerticalAlignment = VerticalAlignment.Center, QueryIcon = new SymbolIcon(Symbol.Find) };
    private readonly ContentPresenter _page = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly NavigationView _nav = new();
    private readonly StackPanel _sync = new() { Margin = new Thickness(12, 6, 12, 10), Spacing = 4 };
    private readonly Dictionary<SidebarItem, (NavigationViewItem Item, TextBlock Count)> _rows = [];
    private readonly Stack<Route> _path = new();
    private SidebarItem _selected = SidebarItem.Home;
    private bool _showingFirstLaunch;
    private PlayerBar _player = null!;

    public MainWindow()
    {
        Title = "5heures";
        _model = new AppModel();
        Shell.Model = _model;
        Shell.Open = Push;
        Pages.Reload = ShowCurrent;
        Cards.Window = this;

        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        try { AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico")); } catch (Exception) { }

        _back = Ui.IconButton(Ui.G.Back, "Retour (Alt+←)", Pop, 14, 9);
        BuildTitleBar();
        BuildBody();
        Content = _root;
        PlaceWindow();

        _model.CatalogueChanged += OnCatalogueChanged;
        _model.SyncChanged += OnSyncChanged;
        _model.SearchChanged += () => { if (_model.IsSearching) ShowCurrent(); };
        AppWindow.Changed += (_, e) => { if (e.DidPositionChange || e.DidSizeChange) RememberBounds(); };
        Closed += (_, _) => SavePlacement();
        AddShortcuts();
        _root.Loaded += (_, _) =>
        {
            _ = _model.StartAsync();
            // CINQHEURES_AUTOPLAY=<episode id>:<seconds> plays from there at launch: for testing the player.
            if (Environment.GetEnvironmentVariable("CINQHEURES_AUTOPLAY")?.Split(':') is { Length: 2 } a
                && long.TryParse(a[0], out var id) && double.TryParse(a[1], System.Globalization.CultureInfo.InvariantCulture, out var at)
                && _model.EpisodeById(id) is { } episode)
                _model.Play(episode, new Segment(0, "", SegmentKind.Other, at, null));
        };
        BuildSidebar();
        ShowCurrent();
        _titleBar.SizeChanged += (_, _) => UpdateInsets();
    }

    // MARK: Layout

    private void BuildTitleBar()
    {
        // Like the Microsoft Store: the app's name at the left, the search field in the middle, Windows' own caption buttons at the right.
        _titleBar.ColumnDefinitions.Add(_leftInset);
        _titleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _titleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _titleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _titleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(420) });
        _titleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _titleBar.ColumnDefinitions.Add(_rightInset);

        _back.Margin = new Thickness(4, 0, 0, 0);
        Grid.SetColumn(_back, 1);
        _titleBar.Children.Add(_back);

        var brand = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.png");
        if (File.Exists(iconPath))
            brand.Children.Add(new Image { Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(iconPath)) { DecodePixelWidth = 32 }, Width = 16, Height = 16 });
        brand.Children.Add(Ui.Text("5heures", 12));
        Grid.SetColumn(brand, 2);
        _titleBar.Children.Add(brand);

        _search.TextChanged += (s, e) =>
        {
            if (e.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;
            var was = _model.IsSearching;
            _model.SetSearch(s.Text);
            if (_model.IsSearching) { _path.Clear(); if (!was) ShowCurrent(); }
            else ShowCurrent();
        };
        _search.QuerySubmitted += (_, _) => _model.SetSearch(_search.Text, typing: false);
        _search.Width = double.NaN;
        _search.Margin = new Thickness(8, 0, 8, 0);
        Grid.SetColumn(_search, 4);
        _titleBar.Children.Add(_search);

        SetTitleBar(_titleBar);
    }

    private void BuildBody()
    {
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(_titleBar, 0);
        _root.Children.Add(_titleBar);

        // The stock Windows sidebar: NavigationView, with its own selection pill, hover and focus visuals.
        _nav.PaneDisplayMode = NavigationViewPaneDisplayMode.Left;
        _nav.OpenPaneLength = 264;
        _nav.IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed;
        _nav.IsPaneToggleButtonVisible = false;
        _nav.IsSettingsVisible = false;
        _nav.IsTitleBarAutoPaddingEnabled = false;
        _nav.ItemInvoked += (sender, e) =>
        {
            if (e.InvokedItemContainer?.Tag is SidebarItem item) Select(item);
            else if (e.InvokedItemContainer?.Tag as string == "reset") _ = ShowResetAsync();
        };
        _nav.PaneFooter = _sync;
        Grid.SetRow(_nav, 1);
        _root.Children.Add(_nav);

        // The page: a header (title and the page's buttons), then the page itself, with the player floating over its bottom.
        var content = new Grid();
        content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var header = new Grid { Margin = new Thickness(28, 14, 28, 0), ColumnSpacing = 12 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(_title);
        titles.Children.Add(_subtitle);
        header.Children.Add(titles);
        Grid.SetColumn(_toolbar, 1);
        header.Children.Add(_toolbar);
        content.Children.Add(header);
        Grid.SetRow(_page, 1);
        content.Children.Add(_page);
        _player = new PlayerBar(_model);
        Grid.SetRow(_player, 1);
        content.Children.Add(_player);
        _nav.Content = content;

        _root.ActualThemeChanged += (_, _) => ApplyCaptionColors();
        _root.Loaded += (_, _) => ApplyCaptionColors();
    }

    /// <summary>Windows' own caption buttons, drawn in the foreground of the theme: light symbols on a dark window, dark ones on a
    /// light window (the defaults went pale grey on the pale Mica of the light theme).</summary>
    private void ApplyCaptionColors()
    {
        var dark = _root.ActualTheme == ElementTheme.Dark;
        var caption = AppWindow.TitleBar;
        var ink = dark ? Colors.White : Colors.Black;
        caption.ButtonBackgroundColor = Colors.Transparent;
        caption.ButtonInactiveBackgroundColor = Colors.Transparent;
        caption.ButtonForegroundColor = ink;
        caption.ButtonHoverForegroundColor = ink;
        caption.ButtonPressedForegroundColor = ink;
        caption.ButtonHoverBackgroundColor = Color.FromArgb(dark ? (byte)26 : (byte)20, ink.R, ink.G, ink.B);
        caption.ButtonPressedBackgroundColor = Color.FromArgb(dark ? (byte)15 : (byte)12, ink.R, ink.G, ink.B);
        caption.ButtonInactiveForegroundColor = Color.FromArgb(dark ? (byte)120 : (byte)110, ink.R, ink.G, ink.B);
    }

    private void UpdateInsets()
    {
        var scale = _titleBar.XamlRoot?.RasterizationScale ?? 1;
        _leftInset.Width = new GridLength(AppWindow.TitleBar.LeftInset / scale);
        _rightInset.Width = new GridLength(AppWindow.TitleBar.RightInset / scale);
    }

    // MARK: Sidebar

    private void AddRow(SidebarItem item, string glyph, UIElement label, bool counted)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ((FrameworkElement)label).VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(label);
        var count = Ui.Secondary("", 12, 1);
        count.VerticalAlignment = VerticalAlignment.Center;
        count.TextWrapping = TextWrapping.NoWrap;
        Grid.SetColumn(count, 1);
        if (counted) grid.Children.Add(count);
        var nav = new NavigationViewItem { Content = grid, Icon = Ui.Icon(glyph, 16), Tag = item };
        _rows[item] = (nav, count);
        _nav.MenuItems.Add(nav);
    }

    private void BuildSidebar()
    {
        _nav.MenuItems.Clear();
        _nav.FooterMenuItems.Clear();
        _rows.Clear();
        AddRow(SidebarItem.Home, Ui.G.Home, Ui.Text("Accueil", 14), false);
        AddRow(SidebarItem.Favorites, Ui.G.Heart, Ui.Text("Favoris", 14), true);
        _nav.MenuItems.Add(new NavigationViewItemSeparator());
        _nav.MenuItems.Add(new NavigationViewItemHeader { Content = "Émissions" });
        AddRow(SidebarItem.All, Ui.G.Clock, Ui.Text("Récents", 14), true);
        foreach (var series in SeriesInfo.All)
            AddRow(SidebarItem.OfShow(series), series.Symbol(), Ui.Text(series.Title(), 14, null, 1, 2), true);
        _nav.MenuItems.Add(new NavigationViewItemSeparator());
        _nav.MenuItems.Add(new NavigationViewItemHeader { Content = "Notes des films" });
        foreach (var stars in new[] { 4, 3, 2, 1, 0 })
            AddRow(SidebarItem.OfScore(stars), "\uE734", Ui.Text(Segment.StarString(stars), 14, null, 1, 1, stars >= 3 ? Ui.Orange : null), true);
        AddRow(SidebarItem.Unrated, "\uE738", Ui.Text("Sans note", 14, null, 0.7), true);
        _nav.FooterMenuItems.Add(new NavigationViewItem { Content = "Réinitialiser…", Icon = Ui.Icon(Ui.G.Reset, 16), Tag = "reset", SelectsOnInvoked = false });
        UpdateCounts();
        UpdateSelection();
        UpdateSync();
    }

    private void UpdateCounts()
    {
        foreach (var (item, (_, count)) in _rows)
        {
            var n = item.Kind switch
            {
                SidebarKind.Favorites => _model.Data.Favorites.Count,
                SidebarKind.All => _model.CountOf(null),
                SidebarKind.Show => _model.CountOf(item.Show),
                SidebarKind.Score => _model.CountOfStars(item.Score),
                SidebarKind.Unrated => _model.UnratedCount,
                _ => 0,
            };
            count.Text = n.ToString("N0", EpisodeDates.Culture);
        }
    }

    private void UpdateSelection()
    {
        if (_rows.TryGetValue(_selected, out var row)) _nav.SelectedItem = row.Item;
    }

    private void UpdateSync()
    {
        _sync.Children.Clear();
        var state = _model.Sync;
        switch (state.Kind)
        {
            case AppModel.SyncKind.Running:
                _sync.Children.Add(Ui.Text("Téléchargement du catalogue…", 12));
                _sync.Children.Add(new ProgressBar { Maximum = Math.Max(state.Of, 1), Value = state.Done });
                break;
            case AppModel.SyncKind.Failed:
                _sync.Children.Add(Ui.Text("Hors ligne ou site indisponible", 12));
                _sync.Children.Add(Ui.Secondary(state.Message, 11, 3));
                _sync.Children.Add(Ui.TextButton("Réessayer", null, () => _ = _model.RefreshAsync(_model.Catalogue.IsEmpty || _model.Catalogue.NeedsFullDownload)));
                break;
            default:
                if (_model.Catalogue.UpdatedAt is { } date)
                    _sync.Children.Add(Ui.Secondary($"À jour au {EpisodeDates.Short(date)}", 12, 1));
                break;
        }
    }

    // MARK: Navigation

    private void Select(SidebarItem item)
    {
        _selected = item;
        _path.Clear();
        if (_model.IsSearching) { _search.Text = ""; _model.SetSearch("", typing: false); }
        UpdateSelection();
        ShowCurrent();
    }

    private void Push(Route route)
    {
        if (_path.Count > 0 && _path.Peek() == route) return;
        _path.Push(route);
        ShowCurrent();
    }

    private void Pop()
    {
        if (_path.Count == 0) return;
        _path.Pop();
        ShowCurrent();
    }

    private void ShowCurrent()
    {
        PageView view;
        _showingFirstLaunch = false;
        if (_path.Count > 0) view = Pages.Build(_path.Peek());
        else if (_model.IsSearching) view = Pages.SearchPage();
        else
        {
            view = Pages.Root(_selected);
            _showingFirstLaunch = _model.Catalogue.IsEmpty;
        }
        _page.Content = view.Content;
        _title.Text = view.Title;
        _subtitle.Text = view.Subtitle ?? "";
        _subtitle.Visibility = view.Subtitle is null ? Visibility.Collapsed : Visibility.Visible;
        _toolbar.Children.Clear();
        foreach (var item in view.Toolbar ?? []) _toolbar.Children.Add(item);
        _back.Visibility = _path.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        Title = view.Title == "Accueil" ? "5heures" : $"{view.Title} – 5heures";
    }

    private void OnCatalogueChanged()
    {
        UpdateCounts();
        UpdateSync();
        // The home page is built the first time the catalogue is indexed (and when it was empty); after that, what
        // arrives in the background shows on the next visit rather than moving the page under the listener's eyes.
        if (_path.Count == 0 && !_model.IsSearching && (_showingFirstLaunch || (_selected == SidebarItem.Home && _homeBuilt == false)))
        {
            _homeBuilt = true;
            ShowCurrent();
        }
    }

    private bool _homeBuilt;

    private void OnSyncChanged()
    {
        UpdateSync();
        if (_showingFirstLaunch) ShowCurrent();
    }

    // MARK: Reset

    private async Task ShowResetAsync()
    {
        var usage = _model.MeasureCache();
        var inProgress = _model.ContinueListening.Count;
        var cache = new CheckBox { IsChecked = !_model.IsSyncing, IsEnabled = !_model.IsSyncing };
        var progress = new CheckBox { IsChecked = false };
        UIElement Choice(CheckBox box, string title, string detail)
        {
            var stack = new StackPanel { Spacing = 3 };
            stack.Children.Add(Ui.Text(title, 14, Ui.SemiBold));
            stack.Children.Add(Ui.Secondary(detail, 13));
            box.Content = stack;
            return box;
        }
        var panel = new StackPanel { Spacing = 14, MaxWidth = 420 };
        panel.Children.Add(Choice(cache, $"Cache · {AppModel.CacheUsage.Text(usage.Total)}",
            $"Catalogue ({AppModel.CacheUsage.Text(usage.Catalogue)}) et épisodes écoutés récemment ({AppModel.CacheUsage.Text(usage.Episodes)}). "
            + "L'app retélécharge ensuite le catalogue depuis 5heures.be, comme à la première ouverture."));
        panel.Children.Add(Choice(progress, $"Progression d'écoute · {Ui.Plural(inProgress, "épisode", "épisodes")} en cours",
            "Les positions de reprise et la rangée « Continuer l'écoute ». Le cache n'est pas touché."));
        var dialog = new ContentDialog
        {
            Title = "Réinitialiser", Content = panel, PrimaryButtonText = "Effacer", CloseButtonText = "Annuler",
            DefaultButton = ContentDialogButton.Close, XamlRoot = _root.XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        if (cache.IsChecked != true && progress.IsChecked != true) return;
        _path.Clear();
        _selected = SidebarItem.Home;
        UpdateSelection();
        await _model.ResetAsync(cache.IsChecked == true, progress.IsChecked == true);
        _homeBuilt = false;
        ShowCurrent();
    }

    // MARK: Keyboard

    private void AddShortcuts()
    {
        _root.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        void Add(VirtualKey key, Action action, VirtualKeyModifiers modifiers = VirtualKeyModifiers.Control)
        {
            var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
            accelerator.Invoked += (_, e) => { action(); e.Handled = true; };
            _root.KeyboardAccelerators.Add(accelerator);
        }
        Add(VirtualKey.F, () => _search.Focus(FocusState.Keyboard));
        Add(VirtualKey.L, () => _model.OpenCurrentEpisode());
        Add(VirtualKey.D, () => { if (_model.Player.Episode is { } e) _model.ToggleFavorite(e); });
        Add(VirtualKey.Left, _model.Player.PreviousPassageStart, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift);
        Add(VirtualKey.Right, _model.Player.NextPassageStart, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift);
        Add(VirtualKey.Left, () => _model.Player.SkipBy(-PlayerModel.Jump), VirtualKeyModifiers.Control);
        Add(VirtualKey.Right, () => _model.Player.SkipBy(PlayerModel.Jump), VirtualKeyModifiers.Control);
        Add(VirtualKey.Left, Pop, VirtualKeyModifiers.Menu);
        Add(VirtualKey.Escape, () => { if (_search.Text.Length > 0) { _search.Text = ""; _model.SetSearch("", typing: false); ShowCurrent(); } else Pop(); }, VirtualKeyModifiers.None);
        var items = new[] { SidebarItem.Home, SidebarItem.Favorites, SidebarItem.All }
            .Concat(SeriesInfo.All.Select(SidebarItem.OfShow)).ToList();
        for (var i = 0; i < Math.Min(9, items.Count); i++)
        {
            var item = items[i];
            Add((VirtualKey)((int)VirtualKey.Number1 + i), () => Select(item));
        }
        // Space plays and pauses, unless a text field has the keyboard.
        _root.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Space && FocusManager.GetFocusedElement(_root.XamlRoot) is not (TextBox or AutoSuggestBox or Button or ToggleButton or CheckBox))
            {
                _model.Player.TogglePlayPause();
                e.Handled = true;
            }
        };
        // The mouse's back button.
        _root.PointerPressed += (_, e) =>
        {
            if (e.GetCurrentPoint(_root).Properties.IsXButton1Pressed) { Pop(); e.Handled = true; }
        };
    }

    // MARK: Window size and position

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    private Windows.Graphics.RectInt32 _normal;
    private bool _wasMaximized;

    /// <summary>The window opens where it was, or else at a comfortable size centred on the screen it opens on. Sizes are
    /// in physical pixels, so they are scaled for the display.</summary>
    private void PlaceWindow()
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var scale = GetDpiForWindow(hwnd) / 96.0;
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = (int)Math.Min(1000 * scale, area.Width);
            presenter.PreferredMinimumHeight = (int)Math.Min(640 * scale, area.Height);
        }
        int width = (int)Math.Min(1440 * scale, area.Width), height = (int)Math.Min(900 * scale, area.Height);
        int x = area.X + (area.Width - width) / 2, y = area.Y + (area.Height - height) / 2;
        if (_model.Data.Window is { Length: 5 } w && w[2] >= 400 && w[3] >= 300
            && DisplayArea.GetFromRect(new Windows.Graphics.RectInt32(w[0], w[1], w[2], w[3]), DisplayAreaFallback.None) is not null)
        {
            (x, y, width, height) = (w[0], w[1], w[2], w[3]);
            _wasMaximized = w[4] == 1;
        }
        _normal = new Windows.Graphics.RectInt32(x, y, width, height);
        AppWindow.MoveAndResize(_normal);
        if (_wasMaximized && AppWindow.Presenter is OverlappedPresenter p) p.Maximize();
    }

    private void RememberBounds()
    {
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Restored })
            _normal = new Windows.Graphics.RectInt32(AppWindow.Position.X, AppWindow.Position.Y, AppWindow.Size.Width, AppWindow.Size.Height);
    }

    private void SavePlacement()
    {
        var maximised = AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Maximized };
        _model.Data.Window = [_normal.X, _normal.Y, _normal.Width, _normal.Height, maximised ? 1 : 0];
        _model.Data.Save();
    }
}
