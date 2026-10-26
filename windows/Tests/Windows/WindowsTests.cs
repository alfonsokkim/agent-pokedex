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
            var picker = new PickerWindow("gengar", new HashSet<string>(), _ => { }, 494, 649);
            Check(picker.Content is System.Windows.Controls.ScrollViewer, "Generation picker scrolls within the display");
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
