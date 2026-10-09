// Checks that gamepad/arrow navigation in the Journal mosaic is spatial.
//
// Builds a ListBox exactly like the theme's (horizontal VirtualizingStackPanel, per-index sizes and negative
// margins read from the generated block in themes/journal/Views/Main.xaml), shows it, then presses the arrow
// keys and asserts that focus always lands on the nearest tile that is really in that direction on screen,
// including tiles just past the right edge (virtualization).
//
//   dotnet run --project tests/MosaicNavigation [path/to/Main.xaml]
using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace MosaicNavigation;

internal static class Program
{
    private record Slot(double Width, double Height, Thickness Margin);

    private const int ItemCount = 400;
    private const double Eps = 0.5;
    private static readonly Key[] Directions = { Key.Right, Key.Left, Key.Down, Key.Up };

    [STAThread]
    private static int Main(string[] args)
    {
        var mainXaml = args.Length > 0 ? args[0] : FindMainXaml();
        var slots = ReadSlots(mainXaml);
        Console.WriteLine($"Pattern: {slots.Count} positions, from {mainXaml}");

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Startup += async (_, _) =>
        {
            var code = 2;
            try
            {
                code = await Run(slots);
            }
            catch (Exception e)
            {
                Console.WriteLine(e);
            }
            app.Shutdown(code);
        };
        return app.Run();
    }

    private static string FindMainXaml()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "themes", "journal", "Views", "Main.xaml");
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }
        throw new FileNotFoundException("themes/journal/Views/Main.xaml not found above the test binary");
    }

    private static List<Slot> ReadSlots(string path)
    {
        var text = File.ReadAllText(path);
        var trigger = new Regex(
            "AlternationIndex\" Value=\"(\\d+)\">\\s*" +
            "<Setter Property=\"Width\" Value=\"([\\d.]+)\" />\\s*" +
            "<Setter Property=\"Height\" Value=\"([\\d.]+)\" />\\s*" +
            "<Setter Property=\"Margin\" Value=\"([-\\d.,]+)\" />");
        var slots = new List<Slot>();
        foreach (Match m in trigger.Matches(text))
        {
            if (int.Parse(m.Groups[1].Value) != slots.Count)
            {
                throw new InvalidDataException("Mosaic triggers are not in index order");
            }
            var t = m.Groups[4].Value.Split(',').Select(v => double.Parse(v, CultureInfo.InvariantCulture)).ToArray();
            slots.Add(new Slot(Num(m.Groups[2].Value), Num(m.Groups[3].Value), new Thickness(t[0], t[1], t[2], t[3])));
        }
        if (slots.Count == 0)
        {
            throw new InvalidDataException("No mosaic triggers found");
        }
        return slots;
    }

    private static double Num(string s) => double.Parse(s, CultureInfo.InvariantCulture);

    private static Style BuildItemStyle(List<Slot> slots)
    {
        var style = new Style(typeof(ListBoxItem));
        style.Setters.Add(new Setter(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Top));
        style.Setters.Add(new Setter(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Left));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(0)));
        style.Setters.Add(new Setter(FrameworkElement.FocusVisualStyleProperty, null));
        var border = new FrameworkElementFactory(typeof(Border));
        border.SetValue(Border.BackgroundProperty, Brushes.DimGray);
        style.Setters.Add(new Setter(Control.TemplateProperty, new ControlTemplate(typeof(ListBoxItem)) { VisualTree = border }));
        for (var i = 0; i < slots.Count; i++)
        {
            var trigger = new Trigger { Property = ItemsControl.AlternationIndexProperty, Value = i };
            trigger.Setters.Add(new Setter(FrameworkElement.WidthProperty, slots[i].Width));
            trigger.Setters.Add(new Setter(FrameworkElement.HeightProperty, slots[i].Height));
            trigger.Setters.Add(new Setter(FrameworkElement.MarginProperty, slots[i].Margin));
            style.Triggers.Add(trigger);
        }
        return style;
    }

    private static ListBox BuildList(List<Slot> slots)
    {
        var list = new ListBox
        {
            Height = slots.Max(s => s.Margin.Top + s.Height),
            AlternationCount = slots.Count,
            Background = Brushes.Black,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            Margin = new Thickness(70, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center,
            ItemContainerStyle = BuildItemStyle(slots),
            ItemsSource = Enumerable.Range(0, ItemCount).Select(i => $"Game {i:000}").ToList(),
        };
        ScrollViewer.SetHorizontalScrollBarVisibility(list, ScrollBarVisibility.Hidden);
        ScrollViewer.SetVerticalScrollBarVisibility(list, ScrollBarVisibility.Disabled);
        ScrollViewer.SetCanContentScroll(list, true);
        VirtualizingPanel.SetIsVirtualizing(list, true);
        VirtualizingPanel.SetVirtualizationMode(list, VirtualizationMode.Standard);
        VirtualizingPanel.SetScrollUnit(list, ScrollUnit.Pixel);
        VirtualizingPanel.SetCacheLength(list, new VirtualizationCacheLength(1));
        VirtualizingPanel.SetCacheLengthUnit(list, VirtualizationCacheLengthUnit.Page);
        KeyboardNavigation.SetDirectionalNavigation(list, KeyboardNavigationMode.Once);
        var panel = new FrameworkElementFactory(typeof(VirtualizingStackPanel));
        panel.SetValue(StackPanel.OrientationProperty, Orientation.Horizontal);
        list.ItemsPanel = new ItemsPanelTemplate(panel);
        return list;
    }

    private static async Task<int> Run(List<Slot> slots)
    {
        var list = BuildList(slots);
        var window = new Window
        {
            Width = 1920,
            Height = 1080,
            Left = 0,
            Top = 0,
            WindowStyle = WindowStyle.None,
            ResizeMode = ResizeMode.NoResize,
            Topmost = true,
            Background = Brushes.Black,
            Content = new Grid { Children = { list } },
        };
        window.Show();
        window.Activate();
        await Idle();

        var failures = 0;

        // 1. Every tile of the first three periods, every direction.
        var checkedMoves = 0;
        for (var i = 0; i < slots.Count * 3; i++)
        {
            foreach (var key in Directions)
            {
                if (!await FocusIndex(list, i))
                {
                    Console.WriteLine($"FAIL could not focus tile {i}");
                    failures++;
                    continue;
                }
                var from = RectOf(list, i);
                var candidates = Neighbours(list, i, from, key);
                var to = await Press(key);
                checkedMoves++;
                if (candidates.Count == 0)
                {
                    // Nothing in that direction: focus may stay or leave the list (to the top bar), never jump.
                    if (to != i && to != -1)
                    {
                        Console.WriteLine($"FAIL {i} {key}: nothing there, but focus jumped to {to}");
                        failures++;
                    }
                    continue;
                }
                var best = candidates.Min(c => c.Distance);
                var nearest = candidates.Where(c => c.Distance <= best + Eps).Select(c => c.Index).ToHashSet();
                if (!nearest.Contains(to))
                {
                    Console.WriteLine($"FAIL {i} {key}: went to {to}, expected one of [{string.Join(", ", nearest)}]");
                    failures++;
                }
            }
        }
        Console.WriteLine($"Spatial moves checked: {checkedMoves}");

        // 2. Holding right walks the whole library without getting stuck (scrolling + virtualization).
        await FocusIndex(list, 0);
        var last = 0;
        for (var step = 0; step < ItemCount; step++)
        {
            var next = await Press(Key.Right);
            if (next == last || next < 0)
            {
                break;
            }
            last = next;
        }
        var lastColumnStart = ItemCount - 3;
        if (last < lastColumnStart)
        {
            Console.WriteLine($"FAIL walking right stopped at tile {last} of {ItemCount}");
            failures++;
        }
        else
        {
            Console.WriteLine($"Walk right reached tile {last} of {ItemCount - 1}");
        }

        Console.WriteLine(failures == 0 ? "PASS mosaic navigation is spatial" : $"{failures} failure(s)");
        window.Close();
        return failures == 0 ? 0 : 1;
    }

    private record Candidate(int Index, double Distance);

    private static List<Candidate> Neighbours(ListBox list, int index, Rect from, Key key)
    {
        var result = new List<Candidate>();
        for (var j = Math.Max(0, index - 40); j < Math.Min(ItemCount, index + 40); j++)
        {
            if (j == index)
            {
                continue;
            }
            var r = RectOf(list, j);
            if (r.IsEmpty)
            {
                continue;
            }
            var overlapV = Math.Min(r.Bottom, from.Bottom) - Math.Max(r.Top, from.Top);
            var overlapH = Math.Min(r.Right, from.Right) - Math.Max(r.Left, from.Left);
            double? distance = key switch
            {
                Key.Right when r.Left >= from.Right - Eps && overlapV > Eps => r.Left - from.Right,
                Key.Left when r.Right <= from.Left + Eps && overlapV > Eps => from.Left - r.Right,
                Key.Down when r.Top >= from.Bottom - Eps && overlapH > Eps => r.Top - from.Bottom,
                Key.Up when r.Bottom <= from.Top + Eps && overlapH > Eps => from.Top - r.Bottom,
                _ => null,
            };
            if (distance is double d)
            {
                result.Add(new Candidate(j, d));
            }
        }
        return result;
    }

    private static Rect RectOf(ListBox list, int index)
    {
        if (list.ItemContainerGenerator.ContainerFromIndex(index) is not ListBoxItem item || !item.IsVisible)
        {
            return Rect.Empty;
        }
        return item.TransformToAncestor(list).TransformBounds(new Rect(item.RenderSize));
    }

    private static async Task<bool> FocusIndex(ListBox list, int index)
    {
        list.ScrollIntoView(list.Items[index]);
        await Idle();
        if (list.ItemContainerGenerator.ContainerFromIndex(index) is not ListBoxItem item)
        {
            return false;
        }
        list.SelectedIndex = index;
        item.Focus();
        Keyboard.Focus(item);
        await Idle();
        return ReferenceEquals(Keyboard.FocusedElement, item);
    }

    private static async Task<int> Press(Key key)
    {
        if (Keyboard.FocusedElement is not UIElement target || PresentationSource.FromVisual(target) is not PresentationSource source)
        {
            return -1;
        }
        var preview = new KeyEventArgs(Keyboard.PrimaryDevice, source, Environment.TickCount, key) { RoutedEvent = Keyboard.PreviewKeyDownEvent };
        target.RaiseEvent(preview);
        if (!preview.Handled)
        {
            target.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, source, Environment.TickCount, key) { RoutedEvent = Keyboard.KeyDownEvent });
        }
        await Idle();
        return FocusedIndex();
    }

    private static int FocusedIndex()
    {
        if (Keyboard.FocusedElement is ListBoxItem item && ItemsControl.ItemsControlFromItemContainer(item) is ListBox owner)
        {
            return owner.ItemContainerGenerator.IndexFromContainer(item);
        }
        return -1;
    }

    private static async Task Idle()
    {
        await Dispatcher.CurrentDispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        await Dispatcher.CurrentDispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
    }
}
