using System.IO;
using System.Net.Http;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ClaudePet;

static class WindowsTests
{
    [STAThread]
    static int Main(string[] args)
    {
        string temporary = Path.Combine(Path.GetTempPath(), "claude-pet-wpf-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temporary);
        Environment.SetEnvironmentVariable("CLAUDE_PET_DATA_DIRECTORY", temporary);
        int checks = 0;
        void Check(bool value, string message) { checks++; if (!value) throw new Exception(message); }
        try
        {
            var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(45) };
            int missing = SpriteDownloads.Fetch(http, Paths.Sprites, Roster.Names).GetAwaiter().GetResult();
            Check(missing == 0, $"Missing {missing} upstream sprite assets");
            Check(Roster.Names.Length == 649, "Embedded full roster");
            Check(Look.CodexBadge.PixelWidth > 0, "Codex logo is packaged in the application");
            foreach (var name in Roster.Names)
            {
                var normal = SpriteSheet.Named(name);
                var shiny = SpriteSheet.Named(name, true);
                Check(normal != null && shiny != null, $"Normal and shiny decode: {name}");
                Check(normal!.Size == shiny!.Size && normal.Top == shiny.Top && normal.HalfWidth == shiny.HalfWidth,
                    $"Shiny geometry: {name}");
                Check(normal.Frames.Length == shiny.Frames.Length, $"Animation frames: {name}");
                for (int frame = 0; frame < normal.Pixels.Length; frame++)
                    for (int i = 3; i < normal.Pixels[frame].Length; i += 4)
                        if (normal.Pixels[frame][i] != shiny.Pixels[frame][i]) throw new Exception($"Shiny silhouette: {name}");
            }
            foreach (var name in new[] { "charmander", "squirtle" })
            {
                var fronts = SpriteSheet.Load(Path.Combine(Paths.Sprites, "front", name + ".png"), 2, frameSize: 32)!;
                Check(fronts.Frames.Length == 2, $"Two vertical front poses: {name}");
                foreach (bool shiny in new[] { false, true })
                {
                    string palettePath = Path.Combine(Paths.Sprites, "palettes", name + (shiny ? "_shiny.pal" : "_normal.pal"));
                    var original = SpriteSheet.Load(Path.Combine(Paths.Sprites, name + ".png"), 6, palettePath)!;
                    var updated = SpriteSheet.Named(name, shiny)!;
                    for (int i = 0; i < original.Pixels.Length; i++)
                    {
                        if (i < 2)
                        {
                            int Bottom(byte[] frame) => Enumerable.Range(0, frame.Length / 4).Where(p => frame[p * 4 + 3] > 0).Max(p => p / 32);
                            Check(!original.Pixels[i].SequenceEqual(updated.Pixels[i]), $"Front pose replaced: {name}, {shiny}, {i}");
                            Check(Bottom(original.Pixels[i]) == Bottom(updated.Pixels[i]), $"Front ground alignment: {name}, {shiny}, {i}");
                            Check(fronts.Pixels[i].Where((_, p) => p % 4 == 3).Count(a => a > 0) ==
                                updated.Pixels[i].Where((_, p) => p % 4 == 3).Count(a => a > 0), $"Front art is not clipped: {name}, {shiny}, {i}");
                        }
                        else Check(original.Pixels[i].SequenceEqual(updated.Pixels[i]), $"Side and back remain identical: {name}, {shiny}, {i}");
                    }
                }
                Check(!SpriteSheet.Named(name)!.Pixels[0].SequenceEqual(SpriteSheet.Named(name, true)!.Pixels[0]), $"Front supports shiny colours: {name}");
            }
            var allPicker = new PickerWindow("gengar", new HashSet<string>(), _ => { });
            Check(allPicker.VisiblePokemon.Length == 649 && allPicker.GenerationSelector.SelectedIndex == 0,
                "The default picker opens all Pokemon directly");
            Check(allPicker.GenerationSelector.Items.Count == 6, "All and five regions remain available as header tabs");
            allPicker.Close();
            var searchPicker = new PickerWindow("gengar", new HashSet<string> { "pikachu" }, _ => { }, 1, 151);
            Check(searchPicker.VisiblePokemon.Length == 151, "Picker starts in the selected generation");
            searchPicker.SearchField.Text = "ZOR";
            Check(searchPicker.VisiblePokemon.SequenceEqual(new[] { "scizor", "bronzor", "zorua", "zoroark" }), "Typing searches across generations immediately");
            Check(searchPicker.GenerationSelector.SelectedIndex == 0, "Global results identify their scope");
            searchPicker.SearchField.Text = "zzzzzz";
            Check(searchPicker.VisiblePokemon.Length == 0, "No stale cells remain for an unmatched search");
            searchPicker.SearchField.Clear();
            Check(searchPicker.VisiblePokemon.Length == 151 && searchPicker.GenerationSelector.SelectedIndex == 1, "Clearing restores the selected region");
            searchPicker.SearchField.Text = "char";
            searchPicker.GenerationSelector.SelectedIndex = 5;
            Check(searchPicker.SearchField.Text.Length == 0 && searchPicker.VisiblePokemon.Length == 156, "Changing regions clears search");
            searchPicker.Close();
            int Greens(SpriteSheet sheet) => Enumerable.Range(0, sheet.Size * sheet.Size).Count(i =>
                sheet.Pixels[0][i * 4 + 3] > 0 && sheet.Pixels[0][i * 4 + 1] > sheet.Pixels[0][i * 4 + 2] + 15 &&
                sheet.Pixels[0][i * 4 + 1] > sheet.Pixels[0][i * 4] + 15);
            Check(Greens(SpriteSheet.Named("virizion")!) > 30 &&
                Greens(SpriteSheet.Named("virizion")!) > Greens(SpriteSheet.Named("virizion", true)!), "Normal Virizion is green");
            var names = new[] { "snorunt", "groudon", "kyogre", "regirock", "regice", "registeel" };
            foreach (double scale in new[] { PetSize.Small, PetSize.Medium, PetSize.Large })
            {
                Look.BaseScale = scale;
                var pets = names.Select(name => new PetView(new Agent("test:" + name, "idle", "", "test"), name, SpriteSheet.Named(name)!)).ToList();
                foreach (var corner in Enum.GetValues<Corner>())
                {
                    var origins = Stacking.Origins(pets, new Rect(-1600, 80, 1440, 1800), new Arrangement { Vertical = true, Corner = corner });
                    var centers = pets.Zip(origins).Select(pair => pair.Second.X + pair.First.HomeX + pair.First.SpriteSize / 2).ToArray();
                    Check(centers.All(c => Math.Abs(c - centers[0]) < 0.001), $"Column alignment: {corner}, {scale}");
                    var row = Stacking.Origins(pets, new Rect(0, 0, 1440, 1800), new Arrangement { Vertical = false, Corner = corner });
                    var grounds = pets.Zip(row).Select(pair => pair.Second.Y + pair.First.Ground).ToArray();
                    Check(grounds.All(g => Math.Abs(g - grounds[0]) < 0.001), $"Row ground: {corner}, {scale}");
                }
            }
            Look.BaseScale = PetSize.Medium;
            double retentionStart = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
            double retentionEnd = retentionStart + StoredPetHistory.Lifetime;
            const string retainedPane = "test:stored-expiry";
            var storedAgent = new Agent(retainedPane, "idle", "", "test") { ActivityAt = retentionStart - 10 };
            Prefs.Set("assignments", retainedPane, "gengar");
            Prefs.Set("positions", "gengar", "0,0");
            var retained = new PetsController();
            retained.Sync(new() { storedAgent }, retentionStart);
            var originalPet = retained.PetFor(retainedPane)!;
            originalPet.ReturnToBall();
            for (int i = 0; i < 8; i++) originalPet.Animate();
            retained.Sync(new() { storedAgent }, retentionStart);
            retained.Sync(new() { storedAgent }, retentionEnd - 0.001);
            Check(retained.PetFor(retainedPane)?.IsGone == true, "Stored pet is available for the full two weeks");
            retained.Sync(new() { storedAgent }, retentionEnd);
            Check(retained.PetFor(retainedPane) == null && Prefs.Get("assignments", retainedPane) == null, "Expiry removes the pet and assignment");
            Check(Prefs.Get("appearances", retainedPane) == null && Prefs.Get("lastActive", retainedPane) == null &&
                Prefs.Get("positions", "gengar") == null, "Expiry clears appearance, activity and unshared position");
            var restartedRetention = new PetsController();
            restartedRetention.Sync(new() { storedAgent }, retentionEnd + 1);
            Check(restartedRetention.PetFor(retainedPane) == null, "Restart and stale status cannot resurrect a stored pet");
            var newActivity = storedAgent with { ActivityAt = retentionEnd + 2 };
            restartedRetention.Sync(new() { newActivity }, retentionEnd + 3);
            Check(restartedRetention.PetFor(retainedPane) is PetView freshPet && freshPet != originalPet &&
                Prefs.Get("assignments", retainedPane) != null, "New user activity creates a fresh random encounter");
            restartedRetention.Sync(new());
            var readyStored = new Agent("test:stored-ready-restart", "done", "", "test") { ActivityAt = retentionStart - 1 };
            var beforeRestart = new PetsController();
            beforeRestart.Sync(new() { readyStored }, retentionStart);
            var readyPet = beforeRestart.PetFor(readyStored.Pane)!;
            readyPet.ReturnToBall();
            for (int i = 0; i < 8; i++) readyPet.Animate();
            beforeRestart.Sync(new() { readyStored }, retentionStart);
            var afterRestart = new PetsController();
            afterRestart.Sync(new() { readyStored }, retentionStart + 60);
            Check(afterRestart.PetFor(readyStored.Pane)?.IsGone == true, "A ready pet remains stored across restart");
            var afterOfflineExpiry = new PetsController();
            afterOfflineExpiry.Sync(new() { readyStored with { ActivityAt = retentionEnd + 5 } }, retentionEnd + 10);
            Check(afterOfflineExpiry.PetFor(readyStored.Pane) is PetView offlineFresh && offlineFresh != readyPet,
                "Expiry while closed precedes reactivation by new activity");
            beforeRestart.Sync(new());
            afterRestart.Sync(new());
            afterOfflineExpiry.Sync(new());
            foreach (var kind in new[] { AgentKind.Claude, AgentKind.Codex })
            {
                var recallAgent = new Agent("test:recall:" + kind, "done", "", "test") { Kind = kind };
                var recalled = new PetView(recallAgent, "gengar", SpriteSheet.Named("gengar")!);
                recalled.Update(recallAgent);
                Check(recalled.CurrentMood == Mood.Done, "Unacknowledged completion is visible");
                recalled.ReturnToBall();
                for (int i = 0; i < 12; i++)
                {
                    recalled.Update(recallAgent);
                    recalled.Animate();
                }
                Check(recalled.IsGone, "Ready recall survives repeated done polls and finishes its animation");
                recalled.Wake();
                recalled.Land();
                recalled.Update(recallAgent);
                Check(recalled.CurrentMood == Mood.Idle, "Let Out does not replay a consumed completion");
                recallAgent = recallAgent with { Status = "working" };
                recalled.Update(recallAgent);
                recalled.ReturnToBall();
                for (int i = 0; i < 12; i++)
                {
                    recalled.Update(recallAgent);
                    recalled.Animate();
                }
                Check(recalled.IsGone, "Busy recall stays hidden through working polls");
                int summons = 0;
                recalled.OnSummon = _ => summons++;
                recalled.Update(recallAgent with { Status = "done" });
                Check(recalled.CurrentMood == Mood.Done && summons == 1, "Hidden work completing summons its pet");
                recalled.Land();
                recalled.ReturnToBall();
                for (int i = 0; i < 8; i++) recalled.Animate();
                recalled.Update(recallAgent with { Status = "done" });
                Check(recalled.IsGone, "A new completion can also be consumed by recall");

                var attentionPet = new PetView(recallAgent, "gengar", SpriteSheet.Named("gengar")!);
                attentionPet.Update(recallAgent);
                attentionPet.ReturnToBall();
                for (int i = 0; i < 8; i++) attentionPet.Animate();
                attentionPet.Update(recallAgent with { Status = "blocked" });
                Check(attentionPet.CurrentMood == Mood.Alert, "Hidden work needing attention comes back out");
            }
            var agent = new Agent("test:attention", "blocked", "a chat", "project") { Kind = AgentKind.Codex, ContextUsed = 0.9 };
            var gengar = new PetView(agent, "gengar", SpriteSheet.Named("gengar")!);
            gengar.Update(agent);
            Check(gengar.CurrentMood == Mood.Alert, "Questions select the red attention animation");
            int flashingRed = 0;
            for (int i = 0; i < 8; i++)
            {
                gengar.Animate();
                flashingRed = Math.Max(flashingRed, RedPixels(Render(gengar, (int)gengar.Width, (int)gengar.Height)));
            }
            gengar.Update(agent with { Status = "working" });
            Check(gengar.CurrentMood == Mood.Working, "Answering stops the red animation");
            int workingRed = RedPixels(Render(gengar, (int)gengar.Width, (int)gengar.Height));
            Check(flashingRed > workingRed + 100,
                $"The attention state visibly renders red, not just a changed status value (alert {flashingRed}, working {workingRed})");
            gengar.CaptionAbove = true;
            double caption = gengar.CaptionTop(80, 20);
            Check(caption + 20 < 80 - 3 - 7 * 2, "Above-head caption must clear the context bar");
            bool saved = gengar.IsShiny;
            var restored = new PetView(agent, "gengar", SpriteSheet.Named("gengar")!);
            Check(restored.IsShiny == saved, "Pet recreation preserves its shiny roll");
            var sparkle = new PetView(new Agent("test:hover", "idle", "", "test"), "gengar", SpriteSheet.Named("gengar")!);
            sparkle.Update(sparkle.Agent);
            sparkle.ApplyAppearance(SpriteSheet.Named("gengar")!, false);
            sparkle.Hovering = true;
            Check(sparkle.ShinyBurst.Start == null, "Normal Pokemon do not sparkle on hover");
            sparkle.Hovering = false;
            sparkle.ApplyAppearance(SpriteSheet.Named("gengar", true)!, true);
            sparkle.Hovering = true;
            int? started = sparkle.ShinyBurst.Start;
            Check(started != null, "Shiny hover starts a burst");
            for (int i = 0; i < 3; i++) sparkle.Animate();
            sparkle.Hovering = true;
            Check(sparkle.ShinyBurst.Start == started, "Repeated mouse tracking cannot restart stars");
            var sparkleFrame = Render(sparkle, (int)sparkle.Width, (int)sparkle.Height);
            Check(GoldPixels(sparkleFrame) > 30, "Shiny hover visibly draws gold stars");
            Check(VisualTreeHelper.HitTest(sparkle, new Point(1, 1)) == null, "Stars cannot expand mouse targets into empty space");
            sparkle.Hovering = false;
            for (int i = 0; i < ShinyHoverBurst.Duration; i++) sparkle.Animate();
            Check(GoldPixels(Render(sparkle, (int)sparkle.Width, (int)sparkle.Height)) == 0, "Stars dissipate completely after leaving");
            sparkle.Hovering = true;
            Check(sparkle.ShinyBurst.Start != started, "A fresh hover can replay the burst");
            int? restarted = sparkle.ShinyBurst.Start;
            for (int i = 0; i < ShinyHoverBurst.Duration; i++) sparkle.Animate();
            sparkle.Hovering = true;
            Check(sparkle.ShinyBurst.Start == restarted, "Holding the pointer cannot loop the burst");
            Check(sparkle.IsShiny, "Hover never rerolls the appearance");
            sparkle.SetPokemon("kyogre", SpriteSheet.Named("kyogre")!);
            Check(!sparkle.IsShiny && sparkle.ShinyBurst.Start == null, "Species swaps clear existing stars");
            var sizeWindow = new PetWindow(sparkle) { Left = -32000, Top = -32000 };
            try
            {
                sizeWindow.Show();
                sparkle.UpdateLayout();
                Check(Math.Abs(sizeWindow.ActualHeight - sparkle.Height) < 1, "Large species fit their native window");
                sparkle.SetPokemon("gengar", SpriteSheet.Named("gengar")!);
                sparkle.UpdateLayout();
                Check(Math.Abs(sizeWindow.ActualHeight - sparkle.Height) < 1, "Species swaps resize the native window");
            }
            finally { sizeWindow.Content = null; sizeWindow.Close(); }
            var picker = new PickerWindow("gengar", new HashSet<string> { "charmander", "regirock" }, _ => { }, 494, 649);
            picker.WindowStartupLocation = WindowStartupLocation.Manual;
            picker.Left = -32000;
            picker.Top = -32000;
            picker.ShowActivated = false;
            picker.Show();
            picker.UpdateLayout();
            var resultsScroll = LogicalTreeHelper.FindLogicalNode(picker, "PokemonResults") as System.Windows.Controls.ScrollViewer;
            Check(picker.ActualHeight <= SystemParameters.WorkArea.Height && resultsScroll != null && resultsScroll.ScrollableHeight > 0,
                "Generation results scroll while the search header fits within the display");
            resultsScroll!.ScrollToBottom();
            picker.UpdateLayout();
            Check(resultsScroll.VerticalOffset > 0, "The last generation row is reachable by scrolling");
            picker.SearchField.Text = "char";
            picker.UpdateLayout();
            Check(resultsScroll.VerticalOffset == 0 && picker.VisiblePokemon.Length == 4, "Searching from the bottom returns to the matching results at the top");
            picker.SearchField.Clear();
            picker.GenerationSelector.SelectedIndex = 0;
            picker.UpdateLayout();
            IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
            {
                for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
                {
                    var child = VisualTreeHelper.GetChild(root, i);
                    if (child is T item) yield return item;
                    foreach (var nested in Descendants<T>(child)) yield return nested;
                }
            }
            var previews = Descendants<System.Windows.Controls.Image>(picker).ToArray();
            Check(previews.Length == 649 && previews.All(image => image.Opacity == 1 &&
                RenderOptions.GetBitmapScalingMode(image) == BitmapScalingMode.NearestNeighbor),
                "All previews, including assigned Pokemon, retain full opacity and sharp pixels");
            Check(Descendants<System.Windows.Controls.Border>(picker).Count(cell => cell.ToolTip is string tip && tip.Contains("swaps")) == 2,
                "Assigned previews explain their in-use marker");
            foreach (System.Windows.Controls.TabItem tab in picker.GenerationSelector.Items)
            {
                var origin = tab.TranslatePoint(new Point(0, 0), picker.GenerationSelector);
                Check(tab.ActualHeight > 0 && origin.X >= 0 && origin.Y >= 0 &&
                    origin.X + tab.ActualWidth <= picker.GenerationSelector.ActualWidth + 1 &&
                    origin.Y + tab.ActualHeight <= picker.GenerationSelector.ActualHeight + 1,
                    "Generation tabs fit in the header without clipping");
            }
            if (args.Length > 0)
            {
                Directory.CreateDirectory(args[0]);
                System.Windows.Threading.Dispatcher.CurrentDispatcher.Invoke(() => { }, System.Windows.Threading.DispatcherPriority.Render);
                var content = (FrameworkElement)picker.Content;
                var image = new RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth), (int)Math.Ceiling(content.ActualHeight),
                    96, 96, PixelFormats.Pbgra32);
                var background = new DrawingVisual();
                using (var drawing = background.RenderOpen())
                    drawing.DrawRectangle(picker.Background, null, new Rect(0, 0, content.ActualWidth, content.ActualHeight));
                image.Render(background);
                image.Render(content);
                Save(image, Path.Combine(args[0], "windows-pokemon-picker.png"));
            }
            picker.Close();
            string unlocked = Path.Combine(temporary, "unlocked.lock");
            File.WriteAllText(unlocked, "");
            Check(LockOwner.Find(unlocked, false) == null, "Stale lock files cannot create pets");
            using (var held = new FileStream(unlocked, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite))
                Check(LockOwner.Find(unlocked, false) == Environment.ProcessId, "Windows file-owner detection identifies the live process");
            if (args.Length > 0)
            {
                Directory.CreateDirectory(args[0]);
                var canvas = new System.Windows.Controls.Canvas { Width = 480, Height = 900, Background = Brushes.WhiteSmoke };
                var party = names.Select(name => new PetView(new Agent("preview:" + name, "idle", "", "preview"), name, SpriteSheet.Named(name)!)).ToList();
                var origins = Stacking.Origins(party, new Rect(0, 0, 480, 900), new Arrangement { Vertical = true, Corner = Corner.TopRight });
                foreach (var pair in party.Zip(origins))
                {
                    canvas.Children.Add(pair.First);
                    System.Windows.Controls.Canvas.SetLeft(pair.First, pair.Second.X);
                    System.Windows.Controls.Canvas.SetTop(pair.First, pair.Second.Y);
                }
                Save(Render(canvas, 480, 900), Path.Combine(args[0], "windows-mixed-sprite-column.png"));
                gengar.Update(agent);
                Save(Render(gengar, (int)gengar.Width, (int)gengar.Height), Path.Combine(args[0], "windows-attention-context-caption.png"));
                Save(sparkleFrame, Path.Combine(args[0], "windows-shiny-hover.png"));
            }
            Console.WriteLine($"Passed {checks} native Windows checks, including all 1,298 sprite variants.");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
        finally { Directory.Delete(temporary, true); }
    }

    static RenderTargetBitmap Render(FrameworkElement view, int width, int height)
    {
        // A presentation source lets WPF commit invalidated animation drawings.
        // An unattached visual can otherwise return a cached frame indefinitely.
        var host = new Window
        {
            Width = width, Height = height, WindowStyle = WindowStyle.None, ShowInTaskbar = false,
            ResizeMode = ResizeMode.NoResize, AllowsTransparency = true, Background = Brushes.Transparent,
            ShowActivated = false, Left = -32000, Top = -32000, Content = view
        };
        try
        {
            host.Show();
            view.InvalidateVisual();
            view.Measure(new Size(width, height));
            view.Arrange(new Rect(0, 0, width, height));
            view.UpdateLayout();
            System.Windows.Threading.Dispatcher.CurrentDispatcher.Invoke(() => { }, System.Windows.Threading.DispatcherPriority.Render);
            var image = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
            image.Render(view);
            return image;
        }
        finally { host.Content = null; host.Close(); }
    }
    static int RedPixels(BitmapSource image)
    {
        byte[] pixels = new byte[image.PixelWidth * image.PixelHeight * 4];
        image.CopyPixels(pixels, image.PixelWidth * 4, 0);
        return Enumerable.Range(0, pixels.Length / 4).Count(i => pixels[i * 4 + 3] > 200 &&
            pixels[i * 4 + 2] > 200 && pixels[i * 4 + 2] > pixels[i * 4 + 1] * 2 && pixels[i * 4 + 2] > pixels[i * 4] * 2);
    }
    static int GoldPixels(BitmapSource image)
    {
        byte[] pixels = new byte[image.PixelWidth * image.PixelHeight * 4];
        image.CopyPixels(pixels, image.PixelWidth * 4, 0);
        return Enumerable.Range(0, pixels.Length / 4).Count(i => pixels[i * 4 + 3] > 100 &&
            pixels[i * 4 + 2] > 200 && pixels[i * 4 + 1] > 140 && pixels[i * 4] < 130);
    }
    static void Save(BitmapSource image, string path)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(image));
        using var stream = File.Create(path);
        encoder.Save(stream);
    }
}
