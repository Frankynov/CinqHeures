using CinqHeures.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.UI;

namespace CinqHeures;

/// <summary>Shorthand for building the pages in code. Text takes the theme's own foreground (and fades it for secondary
/// text), so every page follows Windows' light or dark mode without a palette of its own.</summary>
public static class Ui
{
    /// <summary>The Podcast orange, used for "Tout voir", the stars and the play buttons.</summary>
    public static readonly Color Orange = Color.FromArgb(255, 0xF2, 0x9A, 0x00);
    public static readonly Color OrangeLight = Color.FromArgb(255, 0xFA, 0x9E, 0x1F);
    public static SolidColorBrush Brush(Color c) => new(c);
    public static SolidColorBrush OrangeBrush => Brush(Orange);
    /// <summary>A neutral tint that reads as a card on a light page and on a dark one.</summary>
    public static SolidColorBrush Tint(byte alpha = 22) => Brush(Color.FromArgb(alpha, 128, 128, 128));

    public static readonly FontWeight Medium = new() { Weight = 500 };
    public static readonly FontWeight SemiBold = new() { Weight = 600 };
    public static readonly FontWeight Bold = new() { Weight = 600 };   // Windows type ramp: SemiBold, never heavier

    public static TextBlock Text(string text, double size = 14, FontWeight? weight = null, double opacity = 1,
                                 int lines = 0, Color? color = null)
    {
        var t = new TextBlock
        {
            Text = text, FontSize = size, FontWeight = weight ?? FontWeights.Normal, Opacity = opacity,
            TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis,
        };
        if (lines > 0) t.MaxLines = lines;
        if (color is { } c) t.Foreground = Brush(c);
        return t;
    }

    public static TextBlock Secondary(string text, double size = 12, int lines = 0) => Text(text, size, null, 0.65, lines);

    public static FontIcon Icon(string glyph, double size = 16) => new() { Glyph = glyph, FontSize = size };

    /// <summary>Segoe Fluent Icons code points used here.</summary>
    public static class G
    {
        public const string Play = "", Pause = "", Back = "", Home = "", Heart = "", HeartFill = "",
            Clock = "", Mic = "", Moon = "", Theater = "", Sparkle = "", Music = "",
            Film = "", Info = "", Dice = "", Sort = "", List = "", Grid = "", Person = "",
            Tv = "", Search = "", Prev = "", Next = "", Back15 = "", Fwd15 = "",
            Volume = "", Mute = "", Speaker = "", Reset = "", Chevron = "", ChevronLeft = "",
            Headphones = "", Popcorn = "", Warning = "", Refresh = "";
    }

    public static Button IconButton(string glyph, string tip, Action click, double size = 16, double pad = 9)
    {
        var b = new Button
        {
            Content = Icon(glyph, size), Padding = new Thickness(pad), Background = Brush(Colors.Transparent),
            BorderThickness = new Thickness(0),
        };
        ToolTipService.SetToolTip(b, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, tip);
        b.Click += (_, _) => click();
        return b;
    }

    /// <summary>The stock accent button (the system accent colour), with an icon and a label.</summary>
    public static Button OrangeButton(string label, string? glyph, Action click, bool large = false)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        // A glyph of "🐐" is the show's goat, an emoji rather than an icon.
        if (glyph == "🐐") row.Children.Add(new TextBlock { Text = "🐐", FontSize = 16, FontFamily = new FontFamily("Segoe UI Emoji"), VerticalAlignment = VerticalAlignment.Center });
        else if (glyph is not null) row.Children.Add(Icon(glyph, 14));
        row.Children.Add(Text(label, 14));
        var b = new Button { Content = row, Style = (Style)Application.Current.Resources["AccentButtonStyle"], Padding = new Thickness(large ? 16 : 12, large ? 8 : 5, large ? 16 : 12, large ? 8 : 5) };
        b.Click += (_, _) => click();
        return b;
    }

    public static Button TextButton(string label, string? glyph, Action click, string? tip = null)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7 };
        if (glyph is not null) row.Children.Add(Icon(glyph, 13));
        row.Children.Add(Text(label, 13));
        var b = new Button { Content = row, Padding = new Thickness(11, 5, 11, 5) };
        if (tip is not null) ToolTipService.SetToolTip(b, tip);
        b.Click += (_, _) => click();
        return b;
    }

    /// <summary>A small coloured capsule with the show's name.</summary>
    public static Border Badge(Series series, bool subtle = true)
    {
        var tint = series.Tint();
        var t = Text(series.Badge(), subtle ? 10.5 : 11, SemiBold, 1, 1, subtle ? (Application.Current.RequestedTheme == ApplicationTheme.Dark ? Lift(tint) : Deepen(tint)) : Colors.White);
        t.TextWrapping = TextWrapping.NoWrap;
        var border = new Border
        {
            Child = t, Background = subtle ? Brush(Color.FromArgb(48, tint.R, tint.G, tint.B)) : Brush(tint),
            CornerRadius = new CornerRadius(20), Padding = subtle ? new Thickness(7, 1, 7, 2) : new Thickness(7, 2, 7, 3),
            VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Left,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(border, series.Title());
        return border;
    }

    /// <summary>A lighter shade of a colour, to read on a tinted background in dark and light themes.</summary>
    private static Color Deepen(Color c) => Color.FromArgb(255, (byte)(c.R * 0.62), (byte)(c.G * 0.62), (byte)(c.B * 0.62));

    private static Color Lift(Color c) => Color.FromArgb(255, (byte)(c.R + (255 - c.R) / 4), (byte)(c.G + (255 - c.G) / 4), (byte)(c.B + (255 - c.B) / 4));

    public static Color Tint(this Series s) => s switch
    {
        Series.Podcast => Color.FromArgb(255, 237, 140, 13),
        Series.Soir => Color.FromArgb(255, 92, 102, 217),
        Series.CodLive => Color.FromArgb(255, 204, 56, 64),
        Series.Autre => Color.FromArgb(255, 115, 128, 140),
        Series.QuelquePart => Color.FromArgb(255, 13, 140, 148),
        _ => Color.FromArgb(255, 199, 64, 122),
    };

    public static string Symbol(this Series s) => s switch
    {
        Series.Podcast => G.Mic,
        Series.Soir => G.Moon,
        Series.CodLive => G.Theater,
        Series.Autre => G.Sparkle,
        Series.QuelquePart => G.Music,
        _ => G.Film,
    };

    public static string Symbol(this SegmentKind k) => k switch
    {
        SegmentKind.Movie => G.Film,
        SegmentKind.TvShow => G.Tv,
        SegmentKind.Person => G.Person,
        _ => G.Chevron,
    };

    /// <summary>"1:23:07" or "4:12".</summary>
    public static string Clock(double seconds)
    {
        if (!double.IsFinite(seconds)) return "0:00";
        var total = (int)Math.Floor(seconds);
        var (h, m, s) = (total / 3600, total / 60 % 60, total % 60);
        return h > 0 ? $"{h}:{m:00}:{s:00}" : $"{m}:{s:00}";
    }

    public static string Plural(int n, string one, string many) => $"{n} {(n > 1 ? many : one)}";

    private static Brush Resource(string key, Brush fallback) =>
        Application.Current.Resources.TryGetValue(key, out var v) && v is Brush b ? b : fallback;

    /// <summary>A Fluent card: the theme's card fill and hairline stroke, 8 px corners.</summary>
    public static Border Card(UIElement child, double radius = 8, double pad = 12) =>
        new()
        {
            Child = child, Background = Resource("CardBackgroundFillColorDefaultBrush", Tint()),
            BorderBrush = Resource("CardStrokeColorDefaultBrush", Tint(40)), BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(radius), Padding = new Thickness(pad),
        };

    // MARK: Images

    private static BitmapImage Bitmap(Uri url, int pixels) =>
        new() { UriSource = url, DecodePixelWidth = pixels, CreateOptions = BitmapCreateOptions.None };

    /// <summary>A poster at the width given, always 2:3, with a film glyph until it arrives.</summary>
    public static Border Poster(Uri? url, double width, double corner = 6)
    {
        var host = new Grid();
        host.Children.Add(new FontIcon { Glyph = G.Film, FontSize = Math.Max(14, width / 4), Opacity = 0.3 });
        if (url is not null)
            host.Children.Add(new Image { Source = Bitmap(url, (int)(width * 2)), Stretch = Stretch.UniformToFill });
        return new Border
        {
            Width = width, Height = width * 1.5, CornerRadius = new CornerRadius(corner), Background = Tint(),
            Child = host, HorizontalAlignment = HorizontalAlignment.Left,
        };
    }

    public static UIElement Cover(Uri? url, double side, double corner = 6, string glyph = G.Music)
    {
        var host = new Grid();
        host.Children.Add(new FontIcon { Glyph = glyph, FontSize = Math.Max(14, side / 3), Opacity = 0.3 });
        if (url is not null) host.Children.Add(new Image { Source = Bitmap(url, (int)(side * 2)), Stretch = Stretch.UniformToFill });
        return new Border { Width = side, Height = side, CornerRadius = new CornerRadius(corner), Background = Tint(), Child = host };
    }

    /// <summary>A square picture for an episode: its cover when it has one, else the posters of its films.</summary>
    public static UIElement EpisodeArt(Episode episode, double side)
    {
        if (episode.Artwork is not null) return Cover(episode.Artwork, side, side * 0.12);
        var urls = episode.Subjects.Select(s => s.PosterUrl).OfType<Uri>().Take(4).ToList();
        var half = side / 2;
        Border Tile(Uri u, double w, double h, int col = 0, int row = 0, int colSpan = 1)
        {
            var b = new Border { Width = w, Height = h, Background = Tint(), Child = new Image { Source = Bitmap(u, (int)(Math.Max(w, h) * 2)), Stretch = Stretch.UniformToFill } };
            Grid.SetColumn(b, col); Grid.SetRow(b, row); Grid.SetColumnSpan(b, colSpan);
            return b;
        }
        UIElement content;
        if (urls.Count == 0) content = new Grid { Background = Tint(), Children = { new FontIcon { Glyph = G.Headphones, FontSize = side / 3, Opacity = 0.3 } } };
        else if (urls.Count == 1) content = Tile(urls[0], side, side);
        else
        {
            var g = new Grid { Width = side, Height = side, ColumnSpacing = 1, RowSpacing = 1 };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(half - 0.5) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(half - 0.5) });
            if (urls.Count == 2)
            {
                g.Children.Add(Tile(urls[0], half - 0.5, side, 0));
                g.Children.Add(Tile(urls[1], half - 0.5, side, 1));
            }
            else
            {
                g.RowDefinitions.Add(new RowDefinition { Height = new GridLength(half - 0.5) });
                g.RowDefinitions.Add(new RowDefinition { Height = new GridLength(half - 0.5) });
                g.Children.Add(Tile(urls[0], half - 0.5, half - 0.5, 0, 0));
                g.Children.Add(Tile(urls[1], half - 0.5, half - 0.5, 1, 0));
                if (urls.Count > 3)
                {
                    g.Children.Add(Tile(urls[2], half - 0.5, half - 0.5, 0, 1));
                    g.Children.Add(Tile(urls[3], half - 0.5, half - 0.5, 1, 1));
                }
                else g.Children.Add(Tile(urls[2], side, half - 0.5, 0, 1, 2));      // three posters: the last takes the bottom row
            }
            content = g;
        }
        return new Border { Width = side, Height = side, CornerRadius = new CornerRadius(side * 0.1), Child = content, Background = Tint() };
    }

    public static Image Blurred(Uri url, int pixels = 300) =>
        new() { Source = Bitmap(url, pixels), Stretch = Stretch.UniformToFill };

    /// <summary>Makes any element clickable, with a hand cursor and keyboard activation.</summary>
    public static T Clickable<T>(this T element, Action click, string? name = null) where T : FrameworkElement
    {
        element.Tapped += (_, e) => { click(); e.Handled = true; };
        element.IsTabStop = true;
        element.KeyDown += (_, e) =>
        {
            if (e.Key is Windows.System.VirtualKey.Enter or Windows.System.VirtualKey.Space) { click(); e.Handled = true; }
        };
        if (name is not null) Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(element, name);
        ProtectedCursor(element, Microsoft.UI.Input.InputSystemCursorShape.Hand);
        return element;
    }

    private static void ProtectedCursor(FrameworkElement element, Microsoft.UI.Input.InputSystemCursorShape shape)
    {
        // UIElement.ProtectedCursor is protected: a tiny shim sets it through reflection once the element exists.
        var property = typeof(UIElement).GetProperty("ProtectedCursor", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
        property?.SetValue(element, Microsoft.UI.Input.InputSystemCursor.Create(shape));
    }

    public static T Hover<T>(this T element, Action<bool> changed) where T : UIElement
    {
        element.PointerEntered += (_, _) => changed(true);
        element.PointerExited += (_, _) => changed(false);
        return element;
    }
}

/// <summary>An <see cref="IElementFactory"/> that builds an item's UI in code and fills it in, for virtualised lists.</summary>
public sealed class CodeFactory<T> : IElementFactory
{
    private readonly Func<T, int, UIElement> _build;
    private readonly Stack<UIElement> _pool = new();

    public CodeFactory(Func<T, int, UIElement> build) { _build = build; }

    public UIElement GetElement(ElementFactoryGetArgs args)
    {
        var item = (T)args.Data;
        return _build(item, 0);
    }

    public void RecycleElement(ElementFactoryRecycleArgs args) { }
}
