// Claude Pet for Windows: a floating pixel Pokemon for every Claude or Codex
// session you're running. Shared sprite sources and matching pet behaviour;
// the README describes platform-specific integrations and verification.
//
//   ClaudePet.exe                 the pets
//   ClaudePet.exe --install       set up (what install.cmd runs)
//   ClaudePet.exe --uninstall     remove everything --install added
//   ClaudePet.exe --remove-hooks  take only the Claude Code hooks out
//   ClaudePet.exe --toggle        summon or dismiss the pets (what /pet runs)
//   ClaudePet.exe --status        list the sessions the pets can see
//   ClaudePet.exe --hook          run by Claude Code on each hook event

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using UIA = System.Windows.Automation;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace ClaudePet;

static class Program
{
    public const string MutexName = @"Local\ClaudePet.Pets";
    public const string QuitEventName = @"Local\ClaudePet.Quit";

    [STAThread]
    static int Main(string[] args)
    {
        if (args.Any(a => a is "--install" or "--uninstall" or "--remove-hooks") &&
            Environment.GetEnvironmentVariable("CLAUDE_PET_DATA_DIRECTORY") != null)
        {
            MessageBox.Show("Unset CLAUDE_PET_DATA_DIRECTORY before using installer commands. The test-data override cannot change an installation.",
                "Claude Pet", MessageBoxButton.OK, MessageBoxImage.Warning);
            return 1;
        }
        if (args.Contains("--hook"))
        {
            HookSessions.HandleHook();
            return 0;
        }
        if (args.Contains("--status"))
        {
            Win32.AttachConsole(-1); // print into the terminal that ran us
            foreach (var agent in Agents.Current())
            {
                var context = agent.ContextUsed is double used ? $"ctx {Math.Round((1 - used) * 100)}% left" : "ctx ?";
                Console.WriteLine($"{agent.Pane} {agent.Status} {agent.Kind} {agent.Label} {context}");
            }
            return 0;
        }
        if (args.Contains("--toggle"))
        {
            if (Setup.StopRunningPets())
            {
                Console.WriteLine("Claude Pet dismissed");
            }
            else
            {
                // Shell-launched, so the pets don't hold on to the caller's output pipe.
                Process.Start(new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = true });
                Console.WriteLine("Claude Pet summoned");
            }
            return 0;
        }
        if (args.Contains("--install")) return Setup.Install();
        if (args.Contains("--uninstall")) return Setup.Uninstall();
        if (args.Contains("--remove-hooks"))
        {
            Setup.SetHooks(add: false);
            return 0;
        }

        using var mutex = new Mutex(true, MutexName, out bool first);
        if (!first) return 0; // one set of pets at a time
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var pets = new PetsController();
        app.Startup += (_, _) => pets.Start();
        app.Run();
        return 0;
    }
}

// MARK: - Files and small helpers

static class Paths
{
    public static readonly string Home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    public static readonly string Data = Environment.GetEnvironmentVariable("CLAUDE_PET_DATA_DIRECTORY") ??
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClaudePet");
    public static readonly string Exe = Path.Combine(Data, "ClaudePet.exe");
    public static readonly string Sprites = Path.Combine(Data, "sprites");
    public static readonly string Sessions = Path.Combine(Data, "sessions");
    public static readonly string Prefs = Path.Combine(Data, "settings.json");
    public static readonly string ClaudeSettings = Path.Combine(Home, ".claude", "settings.json");
    public static readonly string PetCommand = Path.Combine(Home, ".claude", "commands", "pet.md");
}

static class Json
{
    public static readonly JsonSerializerOptions Pretty =
        new() { WriteIndented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static JsonObject? ReadObject(string path)
    {
        try { return JsonNode.Parse(File.ReadAllText(path)) as JsonObject; }
        catch { return null; }
    }

    public static string? Str(JsonNode? node) => node is JsonValue v && v.TryGetValue(out string? s) ? s : null;
    public static double Num(JsonNode? node) => node is JsonValue v && v.TryGetValue(out double d) ? d : 0;

    /// Writes through a temporary file, so a reader never sees half a file.
    public static void WriteAtomic(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = $"{path}.{Environment.ProcessId}.tmp";
        File.WriteAllText(temp, text);
        File.Move(temp, path, overwrite: true);
    }
}

static class Util
{
    public static double Now() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
    public static string ProjectName(string cwd) => Path.GetFileName(cwd.TrimEnd('\\', '/'));
}

/// The pets' own settings (which Pokemon each agent has, where pets were
/// dragged, the line-up), in %LOCALAPPDATA%\ClaudePet\settings.json.
static class Prefs
{
    static readonly object gate = new();
    static JsonObject? root;
    static JsonObject Root => root ??= Json.ReadObject(Paths.Prefs) ?? new JsonObject();

    static JsonObject Section(string name)
    {
        if (Root[name] is not JsonObject section)
        {
            section = new JsonObject();
            Root[name] = section;
        }
        return section;
    }

    public static string? Get(string section, string key)
    {
        lock (gate) return Json.Str(Section(section)[key]);
    }

    public static void Set(string section, string key, string? value)
    {
        lock (gate)
        {
            if (value == null) Section(section).Remove(key);
            else Section(section)[key] = value;
            Save();
        }
    }

    public static void Clear(string section)
    {
        lock (gate) { Root.Remove(section); Save(); }
    }

    static void Save() => Json.WriteAtomic(Paths.Prefs, Root.ToJsonString(Json.Pretty));
}

/// How big the pets are, from the Size slider in the right-click menu. The
/// slider moves freely from small to large but holds for a moment at each of
/// the three sizes on the way.
static class PetSize
{
    public const double Small = 1.5, Medium = 3, Large = 4.5;
    public static readonly double[] Locks = { Small, Medium, Large };
    /// How close the slider has to come to one of the sizes before it holds there.
    const double Pull = 0.3;

    /// The slider's position, kept across restarts.
    public static double Saved
    {
        get => double.TryParse(Prefs.Get("settings", "size"), NumberStyles.Float, CultureInfo.InvariantCulture, out var v)
            ? Math.Clamp(v, Small, Large) : Medium;
        set => Prefs.Set("settings", "size", value.ToString(CultureInfo.InvariantCulture));
    }

    /// The slider's value, pulled onto a size when it's close to one.
    public static double Settle(double value) => Locks.FirstOrDefault(l => Math.Abs(l - value) <= Pull, value);
}

/// When each agent last worked or asked for input, kept across restarts.
static class LastActive
{
    public static double? Get(string pane) =>
        double.TryParse(Prefs.Get("lastActive", pane), NumberStyles.Float, CultureInfo.InvariantCulture, out var t) ? t : null;

    public static void Set(string pane, double time) =>
        Prefs.Set("lastActive", pane, time.ToString(CultureInfo.InvariantCulture));
}

// MARK: - Roster and sprites

static class Roster
{
    public static readonly Species[] Species = Load();
    public static readonly string[] Names = Species.Select(p => p.Asset).ToArray();
    static Species[] Load()
    {
        using var stream = typeof(Roster).Assembly.GetManifestResourceStream("ClaudePet.pokemon.json")
            ?? throw new InvalidDataException("Missing Pokemon catalog.");
        return PokemonCatalog.Parse(stream);
    }
    public static string Display(string name) => Species.FirstOrDefault(p => p.Asset == name)?.Display ?? name;
}

/// A follower sheet: square frames for down x2, up x2, left x2, and
/// optionally right x2 (otherwise left is mirrored).
sealed class SpriteSheet
{
    public readonly BitmapSource[] Frames;
    public readonly byte[][] Pixels; // BGRA per frame, for tinting
    public readonly int Size;
    /// The highest row any frame draws in, for stacking pets in a column by their real height.
    public readonly int Top;
    /// The farthest any frame reaches from its centre column, for spacing pets in a row.
    public readonly int HalfWidth;

    SpriteSheet(BitmapSource[] frames, byte[][] pixels, int size, int top, int halfWidth)
    {
        Frames = frames;
        Pixels = pixels;
        Size = size;
        Top = top;
        HalfWidth = halfWidth;
    }

    static readonly Dictionary<string, SpriteSheet?> cache = new();

    public static SpriteSheet? Named(string name, bool shiny = false)
    {
        string key = name + (shiny ? ":shiny" : ":normal");
        if (!cache.TryGetValue(key, out var sheet))
        {
            string palettePath = Path.Combine(Paths.Sprites, "palettes", name + (shiny ? "_shiny.pal" : "_normal.pal"));
            if (!File.Exists(palettePath)) return null;
            sheet = Load(Path.Combine(Paths.Sprites, name + ".png"), minimumFrames: 6, palettePath);
            if (sheet != null) cache[key] = sheet;
        }
        return sheet;
    }

    /// FireRed's overworld item ball (16x16), where pets rest after a long idle.
    public static readonly SpriteSheet? Pokeball = Load(Path.Combine(Paths.Sprites, "_pokeball.png"), minimumFrames: 1);

    /// Decodes a row of square frames and makes the background (palette entry 0) transparent.
    static SpriteSheet? Load(string path, int minimumFrames, string? palettePath = null)
    {
        if (!File.Exists(path)) return null;
        try
        {
            var decoder = BitmapDecoder.Create(new Uri(path), BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
            BitmapSource source = decoder.Frames[0];
            byte[]? indices = null;
            int bits = source.Format.BitsPerPixel, indexedStride = (source.PixelWidth * bits + 7) / 8;
            if (source.Palette != null && bits is 1 or 2 or 4 or 8)
            {
                indices = new byte[indexedStride * source.PixelHeight];
                source.CopyPixels(indices, indexedStride, 0);
            }
            if (palettePath != null)
            {
                var colours = SpritePalette.Parse(File.ReadAllText(palettePath));
                if (indices == null) return null;
                source = BitmapSource.Create(source.PixelWidth, source.PixelHeight, source.DpiX, source.DpiY,
                    source.Format, new BitmapPalette(colours.Select(c => Color.FromRgb(c.R, c.G, c.B)).ToList()), indices, indexedStride);
            }
            var bgra = new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
            int w = bgra.PixelWidth, h = bgra.PixelHeight;
            var all = new byte[w * h * 4];
            bgra.CopyPixels(all, w * 4, 0);

            var key = source.Palette is { Colors.Count: > 0 } palette
                ? palette.Colors[0]
                : Color.FromRgb(all[2], all[1], all[0]); // no palette: the top-left pixel
            for (int i = 0; i < all.Length; i += 4)
            {
                int pixel = i / 4;
                bool background = indices != null ? SpriteIndices.At(indices, indexedStride, bits, pixel % w, pixel / w) == 0 :
                    Math.Abs(all[i] - key.B) < 3 && Math.Abs(all[i + 1] - key.G) < 3 && Math.Abs(all[i + 2] - key.R) < 3;
                if (background)
                    all[i] = all[i + 1] = all[i + 2] = all[i + 3] = 0;
            }

            int size = h, count = w / size;
            if (count < minimumFrames) return null;
            var frames = new BitmapSource[count];
            var pixels = new byte[count][];
            int top = size, half = 0;
            for (int f = 0; f < count; f++)
            {
                var px = new byte[size * size * 4];
                for (int y = 0; y < size; y++) Buffer.BlockCopy(all, (y * w + f * size) * 4, px, y * size * 4, size * 4);
                pixels[f] = px;
                frames[f] = Bitmap(px, size);
                for (int y = 0; y < size; y++)
                    for (int x = 0; x < size; x++)
                        if (px[(y * size + x) * 4 + 3] > 0)
                        {
                            top = Math.Min(top, y);
                            half = Math.Max(half, x < size / 2 ? size / 2 - x : x + 1 - size / 2);
                        }
            }
            return new SpriteSheet(frames, pixels, size, top, half);
        }
        catch
        {
            return null;
        }
    }

    public static BitmapSource Bitmap(byte[] px, int size)
    {
        var bitmap = BitmapSource.Create(size, size, 96, 96, PixelFormats.Bgra32, null, px, size * 4);
        bitmap.Freeze();
        return bitmap;
    }

    /// The frame washed with a colour, keeping its silhouette.
    public static BitmapSource Tinted(byte[] px, int size, Color color, double amount)
    {
        var tinted = (byte[])px.Clone();
        for (int i = 0; i < tinted.Length; i += 4)
        {
            if (tinted[i + 3] == 0) continue;
            tinted[i] = (byte)(tinted[i] * (1 - amount) + color.B * amount);
            tinted[i + 1] = (byte)(tinted[i + 1] * (1 - amount) + color.G * amount);
            tinted[i + 2] = (byte)(tinted[i + 2] * (1 - amount) + color.R * amount);
        }
        return Bitmap(tinted, size);
    }
}

// MARK: - Agents

/// One coding agent: a herdr pane, or a Claude Code session reported by the
/// pets' hooks (its pane is then "session:<id>").
enum AgentKind { Claude, Codex }

sealed record Agent(string Pane, string Status, string Title, string Project, int? Pid = null)
{
    public AgentKind Kind { get; init; }
    public string Workspace { get; init; } = "";
    public string? HostApp { get; init; }
    public string Label => PetRules.Label(Project, Workspace, Title);
    /// How full its context window is, 0 to 1, when known.
    public double? ContextUsed { get; init; }
}

static class Agents
{
    /// herdr's agents in its sidebar order, then Claude sessions outside herdr, oldest first.
    public static List<Agent> Current()
    {
        var herdr = Herdr.Agents();
        var records = HookSessions.LiveRecords();
        return (herdr ?? new List<Agent>()).Concat(HookSessions.Agents(records, herdrRunning: herdr != null))
            .Select(agent => agent with { ContextUsed = Context.Used(agent, records) })
            .Concat(ClaudeApp.Agents())
            .Concat(CodexSessions.Agents())
            .ToList();
    }

    /// Switches to an agent: through herdr for its panes, otherwise by bringing its terminal forward.
    public static void Focus(Agent agent)
    {
        if (agent.Pane.StartsWith(CodexSessions.Prefix)) { CodexSessions.Focus(agent); return; }
        if (agent.Pane.StartsWith(ClaudeApp.Prefix))
        {
            var title = agent.Pane[ClaudeApp.Prefix.Length..];
            Task.Run(() => ClaudeApp.Open(title)); // UI Automation stays off the UI thread
            return;
        }
        if (!agent.Pane.StartsWith(HookSessions.Prefix))
        {
            Herdr.Focus(agent.Pane);
            return;
        }
        HookSessions.MarkSeen(agent.Pane[HookSessions.Prefix.Length..]);
        if (agent.Pid is int pid) Processes.BringForward(pid);
    }
}

static class Processes
{
    public static string? HostingApp(int pid)
    {
        var table = Table();
        var seen = new HashSet<int>();
        while (pid > 0 && seen.Add(pid))
        {
            try
            {
                using var process = Process.GetProcessById(pid);
                if (process.MainWindowHandle != IntPtr.Zero) return process.ProcessName;
            }
            catch (ArgumentException) { }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
            if (!table.TryGetValue(pid, out var entry)) break;
            pid = entry.Parent;
        }
        return null;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct ProcessEntry
    {
        public uint Size, Usage, ProcessId;
        public IntPtr DefaultHeapId;
        public uint ModuleId, Threads, ParentProcessId;
        public int PriorityClassBase;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string ExeFile;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "Process32FirstW")]
    static extern bool Process32First(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "Process32NextW")]
    static extern bool Process32Next(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    /// Every process's parent and exe name, from one snapshot.
    public static Dictionary<int, (int Parent, string Name)> Table()
    {
        var table = new Dictionary<int, (int Parent, string Name)>();
        var snapshot = CreateToolhelp32Snapshot(0x2 /* TH32CS_SNAPPROCESS */, 0);
        if (snapshot == IntPtr.Zero || snapshot == new IntPtr(-1)) return table;
        try
        {
            var entry = new ProcessEntry { Size = (uint)Marshal.SizeOf<ProcessEntry>() };
            if (Process32First(snapshot, ref entry))
                do table[(int)entry.ProcessId] = ((int)entry.ParentProcessId, entry.ExeFile);
                while (Process32Next(snapshot, ref entry));
        }
        finally
        {
            CloseHandle(snapshot);
        }
        return table;
    }

    public static bool IsAlive(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            try { return !process.HasExited; }
            catch { return true; } // running, just not ours to inspect
        }
        catch (ArgumentException)
        {
            return false; // no process with that id
        }
        catch
        {
            return true;
        }
    }

    static readonly string[] Shells =
        { "sh.exe", "bash.exe", "zsh.exe", "dash.exe", "fish.exe", "cmd.exe", "powershell.exe", "pwsh.exe" };

    /// Claude Code's process: the hook's parent, skipping any shell in between.
    public static int ClaudePid()
    {
        var table = Table();
        if (!table.TryGetValue(Environment.ProcessId, out var me)) return 0;
        int pid = me.Parent;
        for (int i = 0; i < 4 && table.TryGetValue(pid, out var info) && Shells.Contains(info.Name, StringComparer.OrdinalIgnoreCase); i++)
            pid = info.Parent;
        return pid;
    }

    /// Brings forward the window a process runs in, such as its terminal, found by walking up its parents.
    public static bool BringForward(int pid)
    {
        var table = Table();
        for (int i = 0, current = pid; i < 12 && current > 4; i++)
        {
            if (!table.TryGetValue(current, out var info) || info.Name.Equals("explorer.exe", StringComparison.OrdinalIgnoreCase))
                return false;
            try
            {
                using var process = Process.GetProcessById(current);
                if (process.MainWindowHandle != IntPtr.Zero)
                {
                    Win32.Focus(process.MainWindowHandle);
                    return true;
                }
            }
            catch
            {
                // gone, or not ours to inspect; keep walking up
            }
            current = info.Parent;
        }
        return false;
    }
}

static class Win32
{
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr window, int index);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr window, int index, int value);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out Pt point);
    [DllImport("kernel32.dll")] public static extern bool AttachConsole(int processId);

    struct Pt { public int X, Y; }

    public static void Focus(IntPtr window)
    {
        if (IsIconic(window)) ShowWindow(window, 9 /* SW_RESTORE */);
        SetForegroundWindow(window);
    }

    /// Never takes focus when clicked, and stays out of Alt-Tab.
    public static void MakeToolWindow(IntPtr window) =>
        SetWindowLong(window, -20 /* GWL_EXSTYLE */, GetWindowLong(window, -20) | 0x08000000 /* NOACTIVATE */ | 0x80 /* TOOLWINDOW */);

    /// A tool window that clicks pass straight through.
    public static void MakeClickThrough(IntPtr window)
    {
        MakeToolWindow(window);
        SetWindowLong(window, -20, GetWindowLong(window, -20) | 0x20 /* TRANSPARENT */);
    }

    /// Puts a window in front of the other always-on-top windows.
    public static void BringToTop(IntPtr window) =>
        SetWindowPos(window, new IntPtr(-1) /* HWND_TOPMOST */, 0, 0, 0, 0, 0x1 | 0x2 | 0x10 /* NOSIZE NOMOVE NOACTIVATE */);

    /// The mouse in device pixels.
    public static Point Cursor()
    {
        GetCursorPos(out var p);
        return new Point(p.X, p.Y);
    }
}

// MARK: - Claude app chats

/// Chats in the Claude desktop app, read from its sidebar through UI
/// Automation. A chat shows a "Running" status beside it while it replies;
/// it's done when that goes. A chat gets a pet once it runs, and keeps it for
/// a day after it last ran.
static class ClaudeApp
{
    public const string Prefix = "app:";
    static readonly string RanFile = Path.Combine(Paths.Data, "app-chats.json");

    record Chat(string Title, string? Status, UIA.AutomationElement Row);

    /// The Claude app's main process (it shares its name with the claude CLI, which has no window of its own).
    static Process? Running() => Process.GetProcessesByName("Claude").FirstOrDefault(p =>
    {
        if (p.MainWindowHandle == IntPtr.Zero) return false;
        try { return p.MainModule?.FileName.Contains("AnthropicClaude", StringComparison.OrdinalIgnoreCase) == true || p.MainWindowTitle == "Claude"; }
        catch { return p.MainWindowTitle == "Claude"; }
    });

    static string Name(UIA.AutomationElement e)
    {
        try { return e.Current.Name ?? ""; }
        catch { return ""; }
    }

    static List<UIA.AutomationElement> Children(UIA.AutomationElement e)
    {
        var kids = new List<UIA.AutomationElement>();
        try
        {
            for (var c = UIA.TreeWalker.RawViewWalker.GetFirstChild(e); c != null; c = UIA.TreeWalker.RawViewWalker.GetNextSibling(c))
                kids.Add(c);
        }
        catch { }
        return kids;
    }

    static bool IsMenu(UIA.AutomationElement e) => Name(e).StartsWith("More options for");

    /// The chats in the sidebar, top to bottom, and the one that's open. null when
    /// the app isn't running, can't be read, or its sidebar is hidden or showing
    /// Code sessions instead of chats.
    static (List<Chat> Chats, string? Open)? Sidebar(Process app)
    {
        try
        {
            var root = UIA.AutomationElement.FromHandle(app.MainWindowHandle);
            // Breadth-first to the sidebar, never into the conversation, which can be huge.
            string? open = null;
            UIA.AutomationElement? sidebar = null;
            var queue = new Queue<UIA.AutomationElement>();
            queue.Enqueue(root);
            for (int visited = 0; queue.Count > 0 && visited < 400; visited++)
            {
                var e = queue.Dequeue();
                var name = Name(e);
                if (name.EndsWith(" - Claude") && e.Current.ControlType == UIA.ControlType.Document) open = name[..^" - Claude".Length];
                if (name == "Sidebar")
                {
                    sidebar = e;
                    break;
                }
                if (name == "Primary pane") continue;
                foreach (var kid in Children(e)) queue.Enqueue(kid);
            }
            if (sidebar == null) return null;

            var chats = new List<Chat>();
            var titles = new HashSet<string>();
            bool showingChats = true;
            // A chat's row: a titled button, its "More options for …" menu, and while it runs a status.
            void Walk(UIA.AutomationElement e, int depth)
            {
                if (depth > 25) return;
                if (e.Current.ControlType == UIA.ControlType.RadioButton && Name(e) == "Claude" &&
                    e.TryGetCurrentPattern(UIA.SelectionItemPattern.Pattern, out var selection))
                    showingChats = ((UIA.SelectionItemPattern)selection).Current.IsSelected;
                var kids = Children(e);
                var button = kids.FirstOrDefault(k => k.Current.ControlType == UIA.ControlType.Button && Name(k).Length > 0 && !IsMenu(k));
                if (button != null && kids.Any(k => IsMenu(k) || Children(k).Any(IsMenu)))
                {
                    var status = kids.FirstOrDefault(k => !ReferenceEquals(k, button) && !IsMenu(k) && Name(k).Length > 0 &&
                        k.Current.ControlType != UIA.ControlType.Button && !Children(k).Any(IsMenu));
                    if (titles.Add(Name(button))) chats.Add(new Chat(Name(button), status == null ? null : Name(status), button));
                    return;
                }
                foreach (var kid in kids) Walk(kid, depth + 1);
            }
            Walk(sidebar, 0);
            return showingChats ? (chats, open) : null;
        }
        catch
        {
            return null;
        }
    }

    // Used only from the polling thread.
    static readonly HashSet<string> running = new();
    /// Chats that finished replying and haven't been opened since.
    static readonly HashSet<string> finished = new();
    /// What the chats were last time the sidebar could be read.
    static List<Agent> latest = new();

    /// Agents for chats that ran in the last day, in the sidebar's order.
    public static List<Agent> Agents()
    {
        if (Running() is not Process app)
        {
            // Closed: they've all stopped.
            running.Clear();
            latest = latest.Select(a => a with { Status = a.Status == "done" ? "done" : "idle" }).ToList();
            return latest;
        }
        if (Sidebar(app) is not { } sidebar) return latest; // hidden for now: keep what we knew
        var (chats, open) = sidebar;
        double now = Util.Now();
        var viewing = Win32.GetForegroundWindow() == app.MainWindowHandle ? open : null;
        var ran = Json.ReadObject(RanFile) ?? new JsonObject();
        var agents = new List<Agent>();
        foreach (var chat in chats)
        {
            var label = chat.Status?.ToLowerInvariant() ?? "";
            var status = label.Length == 0 ? "idle"
                : new[] { "input", "permission", "approv", "waiting" }.Any(label.Contains) ? "blocked"
                : "working"; // "Running"
            if (status != "idle")
            {
                ran[chat.Title] = now;
                running.Add(chat.Title);
            }
            else if (running.Remove(chat.Title)) finished.Add(chat.Title);
            if (viewing == chat.Title) finished.Remove(chat.Title);
            if (now - Json.Num(ran[chat.Title]) >= 86_400) continue;
            agents.Add(new Agent(Prefix + chat.Title, status == "idle" && finished.Contains(chat.Title) ? "done" : status, "", chat.Title));
        }
        foreach (var old in ran.Where(r => now - Json.Num(r.Value) >= 86_400).Select(r => r.Key).ToList()) ran.Remove(old);
        try { Json.WriteAtomic(RanFile, ran.ToJsonString()); } catch { }
        latest = agents;
        return agents;
    }

    /// Brings the Claude app forward on a chat, by pressing its row in the sidebar.
    public static void Open(string title)
    {
        if (Running() is not Process app) return;
        try
        {
            if (Sidebar(app)?.Chats.FirstOrDefault(c => c.Title == title)?.Row is UIA.AutomationElement row &&
                row.TryGetCurrentPattern(UIA.InvokePattern.Pattern, out var invoke))
                ((UIA.InvokePattern)invoke).Invoke();
        }
        catch { }
        Win32.Focus(app.MainWindowHandle);
    }
}

// MARK: - herdr

static class Herdr
{
    /// herdr wherever it's installed.
    static readonly string? exe = new[] { Path.Combine(Paths.Home, ".local", "bin", "herdr.exe") }
        .Concat((Environment.GetEnvironmentVariable("PATH") ?? "")
            .Split(';', StringSplitOptions.RemoveEmptyEntries)
            .Select(dir => Path.Combine(dir.Trim(), "herdr.exe")))
        .FirstOrDefault(File.Exists);

    public static string? Run(params string[] args)
    {
        if (exe == null) return null;
        try
        {
            var info = new ProcessStartInfo(exe) { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true };
            foreach (var arg in args) info.ArgumentList.Add(arg);
            using var process = Process.Start(info)!;
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(5000);
            return process.ExitCode == 0 ? output : null;
        }
        catch
        {
            return null;
        }
    }

    /// null when herdr isn't installed or running.
    public static List<Agent>? Agents()
    {
        var output = Run("agent", "list");
        if (output == null) return null;
        try
        {
            if (JsonNode.Parse(output)?["result"]?["agents"] is not JsonArray list) return null;
            return list.OfType<JsonObject>()
                .Where(a => Json.Str(a["pane_id"]) != null)
                .Select(a => new Agent(
                    Json.Str(a["pane_id"])!,
                    Json.Str(a["agent_status"]) ?? "unknown",
                    Json.Str(a["terminal_title_stripped"]) ?? "",
                    Util.ProjectName(Json.Str(a["foreground_cwd"]) ?? Json.Str(a["cwd"]) ?? ""))
                    { Kind = (Json.Str(a["agent_type"]) ?? "").Contains("codex", StringComparison.OrdinalIgnoreCase) ? AgentKind.Codex : AgentKind.Claude })
                .ToList();
        }
        catch
        {
            return null;
        }
    }

    /// Switches herdr to the agent (marking a done agent as seen) and raises herdr's window.
    public static void Focus(string pane)
    {
        var dispatcher = Application.Current.Dispatcher;
        Task.Run(() =>
        {
            Run("agent", "focus", pane);
            dispatcher.InvokeAsync(() =>
            {
                foreach (var process in Process.GetProcessesByName("herdr"))
                    using (process)
                        if (Processes.BringForward(process.Id)) break;
            });
        });
    }
}

// MARK: - Claude Code hooks

/// Claude Code sessions reported by the pets' own hooks. `ClaudePet --hook`
/// runs on each hook event and keeps one JSON file per session.
static class HookSessions
{
    public const string Prefix = "session:";

    static string FileFor(string session) => Path.Combine(Paths.Sessions, session + ".json");

    static void Write(JsonObject record) =>
        Json.WriteAtomic(FileFor(Json.Str(record["session"])!), record.ToJsonString());

    /// Runs as a Claude Code hook: records the session's state from the event on stdin.
    /// Prints nothing, since some events show a hook's output to Claude.
    public static void HandleHook()
    {
        double started = Util.Now(); // the event's time, as hooks run in the background
        JsonObject? hookEvent;
        try
        {
            using var reader = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false));
            hookEvent = JsonNode.Parse(reader.ReadToEnd()) as JsonObject;
        }
        catch
        {
            return;
        }
        var session = Json.Str(hookEvent?["session_id"]);
        var name = Json.Str(hookEvent?["hook_event_name"]);
        if (hookEvent == null || string.IsNullOrEmpty(session) || name == null ||
            session.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0) return;

        if (name == "SessionEnd")
        {
            try { File.Delete(FileFor(session)); } catch { }
            return;
        }
        string? status = name switch
        {
            "SessionStart" or "StopFailure" => "idle",
            "UserPromptSubmit" or "PreToolUse" or "PostToolUse" or "PostToolUseFailure" => "working",
            "PermissionRequest" or "Notification" => "blocked", // Notification is matched to prompts only
            "Stop" => "done",
            _ => null,
        };
        if (status == null) return;

        var record = Json.ReadObject(FileFor(session))
            ?? new JsonObject { ["session"] = session, ["started"] = started, ["updated"] = 0.0 };
        // A hook that started earlier but finished later mustn't undo a newer state.
        if (started < Json.Num(record["updated"])) return;
        record["status"] = status;
        record["updated"] = started;
        if (Json.Str(hookEvent["cwd"]) is string cwd) record["cwd"] = cwd;
        if (Json.Str(hookEvent["transcript_path"]) is string transcript) record["transcript"] = transcript;
        if (Json.Str(hookEvent["model"]) is string model) record["model"] = model; // SessionStart, when included
        record["pid"] = Processes.ClaudePid();
        if (Environment.GetEnvironmentVariable("HERDR_PANE_ID") is string pane) record["herdrPane"] = pane;
        else record.Remove("herdrPane");
        Write(record);
    }

    /// Every live session's record, oldest first. Drops ones whose Claude has
    /// exited, and settles ones you interrupted.
    public static List<JsonObject> LiveRecords()
    {
        if (!Directory.Exists(Paths.Sessions)) return new List<JsonObject>();
        double now = Util.Now();
        var found = new List<JsonObject>();
        foreach (var path in Directory.GetFiles(Paths.Sessions, "*.json"))
        {
            if (Json.ReadObject(path) is not JsonObject record || Json.Str(record["session"]) == null) continue;
            int pid = (int)Json.Num(record["pid"]);
            bool gone = pid > 0 ? !Processes.IsAlive(pid) : now - Json.Num(record["updated"]) > 86_400;
            if (gone)
            {
                try { File.Delete(path); } catch { }
                continue;
            }
            var status = Json.Str(record["status"]) ?? "idle";
            if ((status == "working" || status == "blocked") && WasInterrupted(record))
            {
                record["status"] = "idle";
                Write(record);
            }
            found.Add(record);
        }
        return found.OrderBy(r => Json.Num(r["started"])).ToList();
    }

    /// The sessions as agents, leaving out ones inside herdr while herdr is reporting them itself.
    public static List<Agent> Agents(List<JsonObject> records, bool herdrRunning) => records
        .Where(record => !(Json.Str(record["herdrPane"]) != null && herdrRunning))
        .Select(record =>
        {
            int pid = (int)Json.Num(record["pid"]);
            return new Agent(Prefix + Json.Str(record["session"]), Json.Str(record["status"]) ?? "idle", "",
                Util.ProjectName(Json.Str(record["cwd"]) ?? ""), pid > 0 ? pid : null);
        })
        .ToList();

    /// Whether you pressed Esc since the last hook. Claude Code runs no hook
    /// for an interrupt or a denied prompt, but writes a marker to the transcript.
    static bool WasInterrupted(JsonObject record)
    {
        var path = Json.Str(record["transcript"]);
        if (path == null || !File.Exists(path)) return false;
        double modified = new DateTimeOffset(File.GetLastWriteTimeUtc(path)).ToUnixTimeMilliseconds() / 1000.0;
        if (modified <= Json.Num(record["updated"])) return false;
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            stream.Seek(Math.Max(0, stream.Length - 16_384), SeekOrigin.Begin);
            var tail = new StreamReader(stream).ReadToEnd();
            // The latest message, skipping the metadata lines written after it.
            var last = tail.Split('\n').LastOrDefault(l => l.Contains("\"type\":\"user\"") || l.Contains("\"type\":\"assistant\""));
            return last?.Contains("[Request interrupted by user") ?? false;
        }
        catch
        {
            return false;
        }
    }

    /// Clears a finished session's "done" once you've clicked through to it.
    public static void MarkSeen(string session)
    {
        if (Json.ReadObject(FileFor(session)) is not JsonObject record || Json.Str(record["status"]) != "done") return;
        record["status"] = "idle";
        Write(record);
    }
}

/// How full each agent's context window is, from the token counts in its transcript.
static class Context
{
    /// Token counts by transcript, re-read only when the file changes.
    static readonly Dictionary<string, (DateTime Modified, int? Tokens)> cache = new();

    public static double? Used(Agent agent, List<JsonObject> records)
    {
        // A herdr pane's session is whichever reported from that pane most recently.
        var record = agent.Pane.StartsWith(HookSessions.Prefix)
            ? records.FirstOrDefault(r => HookSessions.Prefix + Json.Str(r["session"]) == agent.Pane)
            : records.Where(r => Json.Str(r["herdrPane"]) == agent.Pane).MaxBy(r => Json.Num(r["updated"]));
        if (record == null || Json.Str(record["transcript"]) is not string path || Tokens(path) is not int tokens) return null;
        return tokens / (double)Window(Json.Str(record["model"]), tokens);
    }

    static int? Tokens(string path)
    {
        if (!File.Exists(path)) return null;
        var modified = File.GetLastWriteTimeUtc(path);
        if (cache.TryGetValue(path, out var cached) && cached.Modified == modified) return cached.Tokens;
        var tokens = LatestTokens(path);
        cache[path] = (modified, tokens);
        return tokens;
    }

    /// The input tokens of the main conversation's latest reply. null before the
    /// first reply, and after a compaction until the next one.
    static int? LatestTokens(string path)
    {
        string tail;
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            stream.Seek(Math.Max(0, stream.Length - 524_288), SeekOrigin.Begin);
            tail = new StreamReader(stream).ReadToEnd();
        }
        catch
        {
            return null;
        }
        foreach (var line in Enumerable.Reverse(tail.Split('\n')))
        {
            if (line.Contains("\"subtype\":\"compact_boundary\"")) return null;
            if (!line.Contains("\"type\":\"assistant\"") || !line.Contains("\"usage\"") ||
                line.Contains("\"isSidechain\":true")) continue;
            JsonObject? usage;
            try { usage = JsonNode.Parse(line)?["message"]?["usage"] as JsonObject; }
            catch { continue; }
            if (usage == null) continue;
            int tokens = (int)(Json.Num(usage["input_tokens"]) + Json.Num(usage["cache_creation_input_tokens"]) +
                Json.Num(usage["cache_read_input_tokens"]));
            if (tokens > 0) return tokens; // skip error placeholders with empty usage
        }
        return null;
    }

    /// 1M for extended-context sessions, otherwise 200k. Transcripts don't say
    /// which, so: past 200k it must be 1M; below that, the session's model if
    /// SessionStart reported it, else the default model in Claude Code's settings.
    static int Window(string? model, int tokens)
    {
        if (tokens > 200_000) return 1_000_000;
        model ??= Json.Str(Json.ReadObject(Paths.ClaudeSettings)?["model"]);
        return (model ?? "").Contains("[1m]") ? 1_000_000 : 200_000;
    }
}

// MARK: - Pet

/// `Stored` is back in its Poke Ball and out of sight: 12 hours unused, or
/// recalled from the menu.
enum Mood { Idle, Working, Alert, Done, Sleeping, Stored }

/// Going into the Poke Ball (a red glow, shrinking away to nothing) or coming
/// out of it (a white flash).
enum TransitionKind { Recall, Release }

readonly record struct Transition(TransitionKind Kind, int Start)
{
    public int Ticks => Kind == TransitionKind.Recall ? 8 : 6;
}

/// A Poke Ball's flight from just off the side of the screen onto the spot
/// where a pet comes out: from the right edge for a pet on the right half of
/// the screen, the left otherwise. One high arc, spinning, then a small bounce.
readonly struct BallThrow
{
    public readonly Point Start, End; // the ball's top-left corner, on screen
    public readonly double Arc, Duration;
    public readonly bool FromRight;
    /// The arc's share of the flight; the bounce takes the rest.
    const double ArcShare = 0.82;

    public BallThrow(Rect landing, Rect screen, Rect visible)
    {
        FromRight = landing.X + landing.Width / 2 > screen.X + screen.Width / 2;
        Start = new Point(FromRight ? screen.Right + 2 : screen.Left - landing.Width - 2, Math.Max(landing.Y - 40, visible.Top));
        End = landing.TopLeft;
        double distance = Math.Abs(End.X - Start.X);
        Arc = Math.Max(0, Math.Min(Math.Min(Math.Max(90, distance * 0.3), 200), Math.Min(Start.Y, End.Y) - visible.Top));
        Duration = Math.Min(1.1, 0.65 + distance / 2000);
    }

    /// Where the ball is `t` (0 to 1) through its flight, and how many quarter
    /// turns it has spun clockwise (rolling the way it's going), upright again
    /// once it lands.
    public (Point TopLeft, int QuarterTurns) At(double t)
    {
        if (t < ArcShare)
        {
            double u = t / ArcShare;
            double x = Start.X + (End.X - Start.X) * u;
            double y = Start.Y + (End.Y - Start.Y) * u - Arc * 4 * u * (1 - u);
            int turns = (int)(t * Duration / 0.07);
            return (new Point(Math.Round(x), Math.Round(y)), FromRight ? -turns : turns);
        }
        double v = (t - ArcShare) / (1 - ArcShare);
        return (new Point(End.X, Math.Round(End.Y - 12 * 4 * v * (1 - v))), 0);
    }
}

static class Look
{
    public const double Width = 320, SpriteTop = 48, BottomPad = 26, CaptionSize = 12;
    /// Points per sprite pixel before rounding to the screen's pixels, from the Size slider (3 is medium).
    public static double BaseScale = PetSize.Saved;
    public static readonly Typeface CaptionFace =
        new(new FontFamily("Cascadia Mono, Consolas"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
    public static readonly Color HitRed = Color.FromRgb(255, 31, 31);
    public static readonly Brush Blue = Frozen(Color.FromRgb(87, 105, 247)); // working dots
    public static readonly Brush Grey = Frozen(Color.FromRgb(116, 120, 136)); // snoring z's
    public static readonly Brush Pill = Frozen(Color.FromArgb(217, 26, 26, 26));
    public static readonly Brush Shadow = Frozen(Color.FromArgb(46, 0, 0, 0));
    public static readonly Brush ClaudeAccent = Frozen(Color.FromRgb(217, 119, 87));
    public static readonly BitmapSource CodexBadge = LoadCodexBadge();

    static BitmapSource LoadCodexBadge()
    {
        var source = new BitmapImage(new Uri("pack://application:,,,/ClaudePet;component/Assets/codex.png"));
        var cropped = new CroppedBitmap(source, new Int32Rect(source.PixelWidth / 4, source.PixelHeight / 4,
            source.PixelWidth / 2, source.PixelHeight / 2));
        cropped.Freeze();
        return cropped;
    }

    public static Brush Frozen(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }
}

/// The colours of FireRed's HP bar, and the pixel letters that replace its "HP".
static class ContextBar
{
    public static readonly Brush Outline = Look.Frozen(Color.FromRgb(41, 43, 51));
    public static readonly Brush Body = Look.Frozen(Color.FromRgb(71, 71, 79));
    public static readonly Brush Label = Look.Frozen(Color.FromRgb(247, 176, 48));
    public static readonly Brush Border = Look.Frozen(Color.FromRgb(247, 247, 247));
    public static readonly Brush Empty = Look.Frozen(Color.FromRgb(56, 56, 64));
    /// (light, shade) for more than half left, more than a fifth, and the rest.
    public static readonly (Brush, Brush) Green = (Look.Frozen(Color.FromRgb(112, 247, 168)), Look.Frozen(Color.FromRgb(71, 199, 120)));
    public static readonly (Brush, Brush) Yellow = (Look.Frozen(Color.FromRgb(247, 224, 56)), Look.Frozen(Color.FromRgb(199, 168, 8)));
    public static readonly (Brush, Brush) Red = (Look.Frozen(Color.FromRgb(247, 89, 56)), Look.Frozen(Color.FromRgb(176, 56, 48)));
    /// "C", "T", "X" in a 3x5 pixel font.
    public static readonly string[][] Glyphs =
    {
        new[] { ".##", "#..", "#..", "#..", ".##" },
        new[] { "###", ".#.", ".#.", ".#.", ".#." },
        new[] { "#.#", "#.#", ".#.", "#.#", "#.#" },
    };
}

sealed class PetView : FrameworkElement
{
    public const double ColumnPace = 12, RowPace = 4;
    /// How far a caption reaches below the ground; a column leaves this much room under every pet.
    public static readonly double CaptionDepth = 2 + Caption("Ag", 1).Height + 4;

    public Agent Agent { get; private set; }
    public string Pokemon { get; private set; }
    SpriteSheet sheet;

    public Action<PetView>? OnMoved, OnResize, OnHoverEnd;
    public Action<PetView, int, int>? OnPickGeneration;
    /// Shift-dragging moves every pet: called with how far the mouse has gone, then null when it's let go.
    public Action<Vector?>? OnDragAll;
    /// Once it has gone into its ball, to close up the gap; when it's coming
    /// back out, to make room and throw its ball in.
    public Action<PetView>? OnVanish, OnSummon;
    public Action? OnLineUp;
    /// Called as the Size slider moves, with its value.
    public Action<double>? OnSize;
    /// The pets resting out of sight, for Let Out.
    public Func<List<PetView>>? RestingPets;

    /// How far it paces either side while working: less in a row, where
    /// neighbours stand close enough that they'd walk into each other.
    public double Pace = ColumnPace;
    public bool CaptionAbove;
    public bool IsShiny { get; private set; }
    internal ShinyHoverBurst ShinyBurst { get; } = new();
    bool SpinsWhileWorking => PetRules.SpinningPokemon.Contains(Pokemon);

    Mood mood = Mood.Idle;
    int tick = Random.Shared.Next(64); // so pets don't move in lockstep
    double walkX, walkDirection = 1;
    bool hovering;
    double hopUntil, labelUntil, lastBusy;
    string? previousStatus;
    double? finishedAt;
    Transition? transition;
    /// While its Poke Ball is in the air there's nothing to draw here yet.
    bool arriving;
    /// Set by its first update, so a pet that starts out resting is simply out of sight.
    bool settled;
    double dpi = 1;

    /// Resting out of sight, once it has gone into its ball.
    public bool IsGone => mood == Mood.Stored && transition == null;
    internal Mood CurrentMood => mood;

    public PetView(Agent agent, string pokemon, SpriteSheet sheet)
    {
        Agent = agent;
        Pokemon = pokemon;
        this.sheet = sheet;
        UpdateAppearance();
        if (LastActive.Get(agent.Pane) is double saved) lastBusy = saved;
        else LastActive.Set(agent.Pane, lastBusy = Util.Now());
        Width = Look.Width;
        Height = ViewHeight;
        RenderOptions.SetBitmapScalingMode(this, BitmapScalingMode.NearestNeighbor);
        Loaded += (_, _) => UpdateDpi(VisualTreeHelper.GetDpi(this).DpiScaleX);
    }

    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi) => UpdateDpi(newDpi.DpiScaleX);

    void UpdateDpi(double value)
    {
        if (value == dpi) return;
        dpi = value;
        Height = ViewHeight;
        InvalidateVisual();
        OnResize?.Invoke(this);
    }

    /// Screen points per sprite pixel: about three, rounded to whole device pixels so they stay crisp.
    public double Scale => Math.Max(1, Math.Round(Look.BaseScale * dpi)) / dpi;
    public double SpriteSize => sheet.Size * Scale;
    double ContextPixel => Math.Max(1, Math.Round(2 * Look.BaseScale / 3 * dpi)) / dpi;
    /// Where the sprite rests: the middle of the window, so the caption under it
    /// can centre. At a screen edge the window simply hangs past it.
    public double HomeX => Snap((Look.Width - SpriteSize) / 2);
    /// The ground: the bottom of the resting sprite frame.
    public double Ground => Look.SpriteTop + SpriteSize;
    double ViewHeight => Look.SpriteTop + SpriteSize + Look.BottomPad;
    double Snap(double v) => Math.Round(v * dpi) / dpi;
    public Point SnapPoint(Point p) => new(Snap(p.X), Snap(p.Y));
    public string DisplayName => Roster.Display(Pokemon);

    /// How far the pet reaches above the ground, from its topmost pixel.
    public double VisibleHeight => (sheet.Size - sheet.Top) * Scale;

    /// How much room the pet needs across in a row: its sprite at its widest
    /// plus its pacing room.
    public double FootprintWidth => 2 * sheet.HalfWidth * Scale + 2 * Pace;

    Rect SpriteHitBox => new(HomeX + walkX + SpriteSize / 2 - sheet.HalfWidth * Scale,
        Look.SpriteTop + sheet.Top * Scale, 2 * sheet.HalfWidth * Scale, VisibleHeight);

    // Stars are decoration, not extra hover or click targets.
    protected override HitTestResult? HitTestCore(PointHitTestParameters parameters) =>
        !arriving && !IsGone && SpriteHitBox.Contains(parameters.HitPoint) ? new PointHitTestResult(this, parameters.HitPoint) : null;

    public void SetPokemon(string name, SpriteSheet newSheet)
    {
        Pokemon = name;
        Prefs.Set("appearances", Agent.Pane, JsonSerializer.Serialize(new Appearance(name, false)));
        ApplyAppearance(newSheet, false);
    }

    internal void ApplyAppearance(SpriteSheet selected, bool shiny)
    {
        sheet = selected;
        IsShiny = shiny;
        ShinyBurst.Reset();
        FitSize();
    }

    void UpdateAppearance(bool reroll = false)
    {
        Appearance? previous = null;
        try { previous = JsonSerializer.Deserialize<Appearance>(Prefs.Get("appearances", Agent.Pane) ?? "null"); }
        catch (JsonException) { }
        var appearance = EncounterRules.Resolve(previous, Pokemon, reroll);
        Prefs.Set("appearances", Agent.Pane, JsonSerializer.Serialize(appearance));
        if (SpriteSheet.Named(Pokemon, appearance.Shiny) is SpriteSheet selected)
        {
            ApplyAppearance(selected, appearance.Shiny);
        }
        else if (SpriteSheet.Named(Pokemon) is SpriteSheet normal) ApplyAppearance(normal, false);
    }

    /// Matches the view's height to its sprite at the current size; its window follows.
    public void FitSize()
    {
        Height = ViewHeight;
        InvalidateVisual();
    }

    public void Update(Agent latest)
    {
        double now = Util.Now();
        if (previousStatus == "working" && latest.Status != "working") finishedAt = now;
        else if (latest.Status == "done" && finishedAt == null) finishedAt = now;
        previousStatus = latest.Status;
        Agent = latest;

        Mood next;
        if (latest.Status == "blocked") next = Mood.Alert;
        else if (latest.Status == "working") next = Mood.Working;
        else
        {
            // herdr's done lasts until the agent is viewed; a plain stop counts briefly.
            double quiet = now - lastBusy;
            if (finishedAt is double at && now - at < (latest.Status == "done" ? 900 : 15)) next = Mood.Done;
            else if (quiet > 12 * 3600) next = Mood.Stored;
            else if (quiet > 600) next = Mood.Sleeping;
            else next = Mood.Idle;
        }
        if (next is Mood.Working or Mood.Alert) MarkActive(now);
        SetMood(next);
    }

    /// Records activity, saving it at most once a minute.
    void MarkActive(double now)
    {
        if (now - lastBusy > 60) LastActive.Set(Agent.Pane, now);
        lastBusy = now;
    }

    /// Changes mood. Going into its ball it glows red and shrinks away; coming
    /// back out, its ball is thrown in and it pops out where it lands.
    void SetMood(Mood next)
    {
        if (!settled)
        {
            settled = true;
            mood = next;
            return;
        }
        bool wasGone = IsGone;
        if (next == Mood.Stored && mood != Mood.Stored)
        {
            ShinyBurst.Reset();
            transition = new Transition(TransitionKind.Recall, tick);
        }
        else if (mood == Mood.Stored && next != Mood.Stored)
        {
            UpdateAppearance(reroll: true);
            // Called back mid-recall, it just comes straight back out.
            transition = wasGone ? null : new Transition(TransitionKind.Release, tick);
            arriving = wasGone;
        }
        if (next != mood && next == Mood.Alert) labelUntil = Util.Now() + 5;
        mood = next;
        if (wasGone && next != Mood.Stored) OnSummon?.Invoke(this);
    }

    /// Its ball has landed: out it comes.
    public void Land()
    {
        arriving = false;
        transition = new Transition(TransitionKind.Release, tick);
        hopUntil = Util.Now() + 1.6; // a happy hop once it's out
        InvalidateVisual();
    }

    /// Recalls the pet into its Poke Ball until you let it out or its agent gets busy.
    public void ReturnToBall()
    {
        lastBusy = 0;
        LastActive.Set(Agent.Pane, 0);
        finishedAt = null;
        SetMood(Mood.Stored);
    }

    /// Brings the pet out of its ball, or wakes it from a nap.
    public void Wake()
    {
        double now = Util.Now();
        lastBusy = now;
        LastActive.Set(Agent.Pane, now);
        if (mood is Mood.Stored or Mood.Sleeping)
        {
            SetMood(Mood.Idle);
            if (!arriving) hopUntil = now + 1.4; // a happy hop once it's out
        }
    }

    /// Lets the pet out (or wakes it), then jumps to its agent.
    public void Clicked()
    {
        finishedAt = null;
        hopUntil = Util.Now() + 0.6;
        Wake();
        Agents.Focus(Agent);
    }

    public string Summary => Agent.Label;

    /// Advances one animation step: walks while working, and walks home after.
    public void Animate()
    {
        tick++;
        if (transition is Transition t && tick - t.Start >= t.Ticks)
        {
            transition = null;
            if (t.Kind == TransitionKind.Recall)
            {
                Hovering = false;
                OnVanish?.Invoke(this);
            }
        }
        const double speed = 2;
        if (mood == Mood.Working && !SpinsWhileWorking)
        {
            walkX += walkDirection * speed;
            if (Math.Abs(walkX) >= Pace) walkDirection = walkX > 0 ? -1 : 1;
        }
        else if (walkX != 0)
        {
            walkDirection = walkX > 0 ? -1 : 1;
            walkX = Math.Abs(walkX) <= speed ? 0 : walkX + walkDirection * speed;
        }
        InvalidateVisual();
    }

    // MARK: Drawing

    static readonly double[] DoneJump = { 0, 6, 14, 18, 14, 6, 0, 0, 0, 0 };
    static readonly double[] HoverHop = { 0, 4, 6, 4 };

    protected override void OnRender(DrawingContext dc)
    {
        if (transition is Transition t)
        {
            double progress = (tick - t.Start) / (double)t.Ticks;
            if (progress < 1)
            {
                DrawTransition(dc, t.Kind, Math.Max(progress, 0), SpriteSheet.Pokeball);
                return;
            }
        }
        if (arriving || mood == Mood.Stored) return;

        int step = tick / 2 % 2;
        int frame = tick / 6 % 2;
        bool mirrored = false, flash = false;
        double lift = 0;
        bool spinning = mood == Mood.Working && SpinsWhileWorking;
        bool walking = !spinning && (walkX != 0 || mood == Mood.Working);
        if (walking)
        {
            bool right = walkDirection > 0;
            if (right && sheet.Frames.Length >= 8) frame = 6 + step;
            else
            {
                frame = 4 + step;
                mirrored = right;
            }
        }

        if (spinning)
        {
            int turn = tick / 3 % 4, turnStep = tick / 2 % 2;
            frame = turn switch { 0 => turnStep, 1 => 4 + turnStep, 2 => 2 + turnStep,
                _ => sheet.Frames.Length >= 8 ? 6 + turnStep : 4 + turnStep };
            mirrored = turn == 3 && sheet.Frames.Length < 8;
        }

        switch (mood)
        {
            case Mood.Alert:
                if (!walking) frame = step;
                lift = tick / 3 % 2 == 0 ? 0 : 8;
                flash = tick / 2 % 2 == 0; // hard on/off, like taking a hit
                break;
            case Mood.Done:
                if (!walking) frame = step;
                lift = DoneJump[tick % 10];
                break;
            case Mood.Sleeping:
            case Mood.Stored:
                if (!walking) frame = 0;
                break;
            case Mood.Idle:
                if (!walking && (hovering || Util.Now() < hopUntil))
                {
                    frame = step;
                    lift = HoverHop[tick % 4];
                }
                break;
        }

        var rect = new Rect(Snap(HomeX + walkX), Snap(Look.SpriteTop - lift), SpriteSize, SpriteSize);
        // Only a pet off the ground casts a shadow.
        if (lift > 0) DrawShadow(dc, rect, sheet.Size, 14, lift);
        var image = flash ? SpriteSheet.Tinted(sheet.Pixels[frame], sheet.Size, Look.HitRed, 0.85) : sheet.Frames[frame];
        DrawSprite(dc, image, rect, mirrored);
        DrawShinyBurst(dc, lift);

        if (mood == Mood.Working) DrawWorkingDots(dc, rect);
        else if (mood is Mood.Sleeping or Mood.Stored) DrawSnores(dc, rect);
        double headTop = rect.Top + sheet.Top * Scale;
        DrawContextBarIfShown(dc, headTop);
        // One caption under the pet: its status while hovered (or just after it
        // needs you), otherwise "is done" when it has finished.
        if (hovering || Util.Now() < labelUntil) DrawCaption(dc, Summary, headTop, badge: true);
        else if (mood == Mood.Done) DrawCaption(dc, $"{DisplayName} is done", headTop);
    }

    void DrawShinyBurst(DrawingContext dc, double lift)
    {
        if (!IsShiny || ShinyBurst.Progress(tick) == null) return;
        var box = SpriteHitBox;
        var colors = new Dictionary<char, Color>
        {
            ['G'] = Color.FromRgb(217, 130, 20), ['Y'] = Color.FromRgb(255, 217, 61), ['W'] = Color.FromRgb(255, 255, 224)
        };
        foreach (var star in ShinyBurst.Stars(tick, box.X + box.Width / 2, box.Y + box.Height / 2 - lift,
            box.Width, box.Height, Width, Height, Scale))
        {
            foreach (var pair in colors)
            {
                var brush = new SolidColorBrush(pair.Value) { Opacity = star.Alpha };
                for (int row = 0; row < ShinyHoverBurst.Pattern.Length; row++)
                    for (int col = 0; col < ShinyHoverBurst.Pattern[row].Length; col++)
                        if (ShinyHoverBurst.Pattern[row][col] == pair.Key)
                            dc.DrawRectangle(brush, null, new Rect(Snap(star.X + col * star.Pixel), Snap(star.Y + row * star.Pixel),
                                star.Pixel, star.Pixel));
            }
        }
    }

    static void DrawSprite(DrawingContext dc, ImageSource image, Rect rect, bool mirrored)
    {
        if (mirrored) dc.PushTransform(new ScaleTransform(-1, 1, rect.X + rect.Width / 2, 0));
        dc.DrawImage(image, rect);
        if (mirrored) dc.Pop();
    }

    /// A pixel-art shadow on the sprite's own grid: a 3-row oval `width` pixels
    /// across under a frame `pixels` wide, shrinking as the pet lifts off.
    void DrawShadow(DrawingContext dc, Rect frame, int pixels, int width, double lift)
    {
        int w = (int)Math.Round(width * (1 - lift / 50));
        w -= w % 2; // stay centred on the frame
        if (w < 6) return;
        double s = Scale;
        int[] insets = { 2, 0, 2 };
        for (int row = 0; row < 3; row++)
        {
            int rowPixels = w - insets[row] * 2;
            dc.DrawRectangle(Look.Shadow, null,
                new Rect(frame.X + (pixels - rowPixels) / 2 * s, Ground - (3 - row) * s, rowPixels * s, s));
        }
    }

    /// One to three dots, centred just under the pet, while it works.
    void DrawWorkingDots(DrawingContext dc, Rect rect)
    {
        int count = tick / 3 % 3 + 1;
        const double dot = 4, spacing = 4;
        double left = Snap(rect.X + rect.Width / 2 - (3 * dot + 2 * spacing) / 2);
        for (int i = 0; i < count; i++)
            dc.DrawRectangle(Look.Blue, null, new Rect(left + i * (dot + spacing), Ground + 4, dot, dot));
    }

    static FormattedText Caption(string text, double pixelsPerDip) =>
        new(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, Look.CaptionFace, Look.CaptionSize,
            Brushes.White, pixelsPerDip);

    /// The part of this view that's on screen.
    Rect OnScreenRect()
    {
        var bounds = new Rect(0, 0, Look.Width, Height);
        if (Window.GetWindow(this) is not Window window) return bounds;
        var shown = new Rect(window.Left, window.Top, bounds.Width, bounds.Height);
        shown.Intersect(SystemParameters.WorkArea);
        return shown.IsEmpty ? bounds : new Rect(shown.X - window.Left, shown.Y - window.Top, shown.Width, shown.Height);
    }

    /// A caption centred under the pet, such as "Pikachu is done" or its status,
    /// slid inward only as far as it takes to stay on screen.
    void DrawCaption(DrawingContext dc, string text, double headTop, bool badge = false)
    {
        var room = OnScreenRect();
        room = new Rect(room.X + 4, room.Y, Math.Max(0, room.Width - 8), room.Height);
        string shown = text;
        var formatted = Caption(shown, dpi);
        double badgeRoom = badge ? 12 : 0;
        for (int keep = text.Length; formatted.Width + 12 + badgeRoom > room.Width && keep > 1;)
        {
            keep--;
            shown = text[..keep] + "…";
            formatted = Caption(shown, dpi);
        }
        double width = formatted.Width + 12 + badgeRoom;
        double x = Math.Min(Math.Max(HomeX + SpriteSize / 2 - width / 2, room.Left), room.Right - width);
        double height = formatted.Height + 4;
        double y = CaptionTop(headTop, height);
        var pill = new Rect(Snap(x), Snap(y), width, height);
        dc.DrawRoundedRectangle(Look.Pill, null, pill, pill.Height / 2, pill.Height / 2);
        if (badge)
        {
            if (Agent.Kind == AgentKind.Codex)
                dc.DrawImage(Look.CodexBadge, new Rect(pill.X + 3, pill.Y + (pill.Height - 12) / 2, 12, 12));
            else dc.DrawEllipse(Look.ClaudeAccent, null, new Point(pill.X + 9, pill.Y + pill.Height / 2), 3, 3);
        }
        dc.DrawText(formatted, new Point(pill.X + 6 + badgeRoom, pill.Y + 2));
    }

    internal double CaptionTop(double headTop, double height)
    {
        bool contextShown = Agent.ContextUsed is double used && (hovering || used >= 0.8);
        double anchor = headTop - (contextShown ? 3 + 7 * ContextPixel : 0);
        return CaptionAbove ? Math.Max(0, anchor - height - 5) : Ground + 2;
    }

    /// Three pixel z's drifting up and to the right off the top of the pet's
    /// head, each growing and fading in turn.
    void DrawSnores(DrawingContext dc, Rect rect)
    {
        string[] glyph = { "SSSS", "..S.", ".S..", "SSSS" };
        double headTop = rect.Y + sheet.Top * Scale;
        double startX = rect.X + rect.Width / 2 + SpriteSize * 0.15;
        const int period = 24; // 3 seconds per z
        // Anything rising past this line, a little above the head, is hidden.
        dc.PushClip(new RectangleGeometry(new Rect(0, headTop - 32, Look.Width, Math.Max(0, Height - headTop + 32))));
        for (int k = 0; k < 3; k++)
        {
            double t = (tick + k * period / 3) % period / (double)period;
            double pixel = Math.Round(2 + t); // grows from 2 to 3 points
            double x = Math.Round(startX + t * 33), y = Math.Round(headTop - 4 * pixel - 2 - t * 42);
            dc.PushOpacity(t < 0.7 ? 1 : (1 - t) / 0.3);
            for (int row = 0; row < 4; row++)
                for (int col = 0; col < 4; col++)
                    if (glyph[row][col] == 'S')
                        dc.DrawRectangle(Look.Grey, null, new Rect(x + col * pixel, y + row * pixel, pixel, pixel));
            dc.Pop();
        }
        dc.Pop();
    }

    void DrawContextBarIfShown(DrawingContext dc, double headTop)
    {
        if (Agent.ContextUsed is double used && (hovering || used >= 0.8)) DrawContextBar(dc, used, headTop);
    }

    /// A Gen 3 HP bar labelled CTX: it drains as the chat fills its context
    /// window, from green to yellow below half to red below a fifth.
    void DrawContextBar(DrawingContext dc, double used, double headTop)
    {
        const int width = 42, height = 7, track = 24;
        double px = ContextPixel;
        double left = Snap(HomeX + SpriteSize / 2 - width * px / 2);
        double top = Snap(headTop - 3 - height * px);
        void Fill(Brush brush, int x, int y, int w = 1, int h = 1) =>
            dc.DrawRectangle(brush, null, new Rect(left + x * px, top + y * px, w * px, h * px));

        // A dark capsule with rounded ends around a grey body.
        Fill(ContextBar.Outline, 1, 0, width - 2);
        Fill(ContextBar.Outline, 1, height - 1, width - 2);
        Fill(ContextBar.Outline, 0, 1, 1, height - 2);
        Fill(ContextBar.Outline, width - 1, 1, 1, height - 2);
        Fill(ContextBar.Body, 1, 1, width - 2, height - 2);
        // "CTX" where the HP label would be.
        for (int i = 0; i < ContextBar.Glyphs.Length; i++)
            for (int row = 0; row < 5; row++)
                for (int col = 0; col < 3; col++)
                    if (ContextBar.Glyphs[i][row][col] == '#') Fill(ContextBar.Label, 2 + i * 4 + col, 1 + row);
        // The white-edged track, filled with what's left.
        Fill(ContextBar.Border, 14, 1, track + 2, 5);
        Fill(ContextBar.Empty, 15, 2, track, 3);
        double remaining = Math.Clamp(1 - used, 0, 1);
        int filled = remaining > 0 ? Math.Max(1, (int)Math.Round(track * remaining)) : 0;
        var (light, shade) = remaining > 0.5 ? ContextBar.Green : remaining > 0.2 ? ContextBar.Yellow : ContextBar.Red;
        if (filled > 0)
        {
            Fill(light, 15, 2, filled, 2);
            Fill(shade, 15, 4, filled);
        }
    }

    /// Where the Poke Ball sits: on the ground, centred where the pet stood.
    public Rect BallRect(SpriteSheet? ball)
    {
        double size = (ball?.Size ?? 16) * Scale;
        return new Rect(Snap(HomeX + (SpriteSize - size) / 2), Ground - size, size, size);
    }

    /// Recall turns the pet red and shrinks it away to nothing where its ball
    /// would sit, as red sparkles close in; release pops it out of the ball in
    /// a white flash and sparkles. `p` runs 0 to 1.
    void DrawTransition(DrawingContext dc, TransitionKind kind, double p, SpriteSheet? ball)
    {
        var front = sheet.Pixels[0];
        var ballFrame = BallRect(ball);
        if (kind == TransitionKind.Recall)
        {
            var red = Color.FromRgb(255, 51, 51);
            // A moment glowing red, then it shrinks, fading over the second half.
            double shrink = Math.Max(0, (p - 0.25) / 0.75);
            double size = Math.Round(sheet.Size * (1 - shrink)) * Scale;
            double centerX = HomeX + SpriteSize / 2, fullMidY = Look.SpriteTop + SpriteSize / 2;
            double centerY = fullMidY + (ballFrame.Y + ballFrame.Height / 2 - fullMidY) * shrink;
            if (size > 0)
            {
                dc.PushOpacity(Math.Min(1, 2 - 2 * shrink));
                dc.DrawImage(SpriteSheet.Tinted(front, sheet.Size, red, Math.Min(1, 0.3 + p * 3)),
                    new Rect(Snap(centerX - size / 2), Snap(centerY - size / 2), size, size));
                dc.Pop();
            }
            if (shrink > 0) DrawSparkles(dc, new Rect(centerX - 8, centerY - 8, 16, 16), 1 - shrink, red, 1 - shrink * 0.7);
        }
        else
        {
            double size = SpriteSize * (0.3 + 0.7 * p);
            var rect = new Rect(HomeX + SpriteSize / 2 - size / 2, Ground - size, size, size);
            dc.DrawImage(SpriteSheet.Tinted(front, sheet.Size, Colors.White, 1 - p), rect);
            if (p < 0.5)
            {
                if (ball != null) dc.DrawImage(ball.Frames[0], ballFrame);
                DrawSparkles(dc, ballFrame, p * 2);
            }
        }
    }

    /// Eight pixel sparkles, `p` of the way out from `around`.
    void DrawSparkles(DrawingContext dc, Rect around, double p, Color? color = null, double? alpha = null)
    {
        double s = Scale, distance = around.Width / 2 + p * 30;
        var c = color ?? Color.FromRgb(247, 209, 64);
        var brush = new SolidColorBrush(Color.FromArgb((byte)(255 * (alpha ?? 1 - p * 0.6)), c.R, c.G, c.B));
        for (int i = 0; i < 8; i++)
        {
            double angle = i * Math.PI / 4;
            double x = Math.Round((around.X + around.Width / 2 + Math.Cos(angle) * distance) / s) * s;
            double y = Math.Round((around.Y + around.Height / 2 + Math.Sin(angle) * distance) / s) * s;
            dc.DrawRectangle(brush, null, new Rect(x - s, y, 3 * s, s)); // a small pixel "+"
            dc.DrawRectangle(brush, null, new Rect(x, y - s, s, 3 * s));
        }
    }

    // MARK: Mouse

    Point? dragStart;
    Point windowStart;
    bool dragged, draggingAll;

    internal bool Hovering
    {
        set
        {
            if (hovering == value) return;
            hovering = value;
            if (value && IsShiny && !arriving && mood != Mood.Stored && transition == null) ShinyBurst.Begin(tick);
            // The hovered pet comes to the front so its caption shows on top.
            if (value) (Window.GetWindow(this) as PetWindow)?.BringToTop();
            else OnHoverEnd?.Invoke(this);
            InvalidateVisual();
        }
    }

    protected override void OnMouseEnter(MouseEventArgs e) => Hovering = true;
    protected override void OnMouseLeave(MouseEventArgs e) => Hovering = false;

    Point CursorInPoints()
    {
        var p = Win32.Cursor();
        return new Point(p.X / dpi, p.Y / dpi);
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        if (Window.GetWindow(this) is not Window window) return;
        dragStart = CursorInPoints();
        windowStart = new Point(window.Left, window.Top);
        dragged = false;
        draggingAll = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        CaptureMouse();
        e.Handled = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (dragStart is not Point start || !IsMouseCaptured || Window.GetWindow(this) is not Window window) return;
        var offset = CursorInPoints() - start;
        if (offset.Length > 3) dragged = true;
        if (!dragged) return;
        if (draggingAll)
        {
            OnDragAll?.Invoke(offset);
            return;
        }
        window.Left = windowStart.X + offset.X;
        window.Top = windowStart.Y + offset.Y;
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        ReleaseMouseCapture();
        if (dragStart == null) return;
        dragStart = null;
        if (!dragged) Clicked();
        else if (draggingAll) OnDragAll?.Invoke(null);
        else OnMoved?.Invoke(this);
        e.Handled = true;
    }

    protected override void OnMouseRightButtonUp(MouseButtonEventArgs e)
    {
        var menu = new ContextMenu();
        menu.Items.Add(new MenuItem { Header = $"{DisplayName} · {Agent.Status}", IsEnabled = false });
        menu.Items.Add(new MenuItem { Header = Agent.Label, IsEnabled = false });
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("Go to Agent", Clicked));
        var ball = Item("Return to Poke Ball", ReturnToBall);
        ball.IsEnabled = mood != Mood.Working && mood != Mood.Alert; // a busy agent would pop it straight back out
        menu.Items.Add(ball);
        // Let Out: each pet resting out of sight.
        var resting = RestingPets?.Invoke() ?? new List<PetView>();
        if (resting.Count > 0)
        {
            var letOut = new MenuItem { Header = "Let Out" };
            foreach (var pet in resting) letOut.Items.Add(Item($"{pet.DisplayName} · {pet.Agent.Label}", pet.Wake));
            menu.Items.Add(letOut);
        }
        var pokemonMenu = new MenuItem { Header = "Pokemon" };
        foreach (var generation in PokemonCatalog.Generations)
        {
            var selected = generation;
            pokemonMenu.Items.Add(Item(selected.Title, () => OnPickGeneration?.Invoke(this, selected.First, selected.Last)));
        }
        menu.Items.Add(pokemonMenu);
        menu.Items.Add(new Separator());

        // Line Up Pets: vertical or horizontal, then a corner. Picking any of
        // them lines the pets up again, undoing drags.
        var lineUp = new MenuItem { Header = "Line Up Pets" };
        var current = Arrangement.Saved;
        foreach (var (title, vertical) in new[] { ("Vertical", true), ("Horizontal", false) })
        {
            var item = Item(title, () =>
            {
                var arrangement = Arrangement.Saved;
                arrangement.Vertical = vertical;
                Arrangement.Saved = arrangement;
                OnLineUp?.Invoke();
            });
            item.IsChecked = current.Vertical == vertical;
            lineUp.Items.Add(item);
        }
        lineUp.Items.Add(new Separator());
        foreach (var corner in Enum.GetValues<Corner>())
        {
            var item = Item(Arrangement.Title(corner), () =>
            {
                var arrangement = Arrangement.Saved;
                arrangement.Corner = corner;
                Arrangement.Saved = arrangement;
                OnLineUp?.Invoke();
            });
            item.IsChecked = current.Corner == corner;
            lineUp.Items.Add(item);
        }
        menu.Items.Add(lineUp);
        menu.Items.Add(SizeItem());
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("Quit Claude Pet", () => Application.Current.Shutdown()));

        menu.PlacementTarget = this;
        menu.IsOpen = true;
        e.Handled = true;
    }

    /// The Size row: a slider from Small to Large that holds briefly at Small,
    /// Medium and Large, resizing the pets as it moves.
    MenuItem SizeItem()
    {
        var slider = new Slider
        {
            Minimum = PetSize.Small, Maximum = PetSize.Large, Value = PetSize.Saved, Width = 180,
            TickPlacement = TickPlacement.BottomRight, Ticks = new DoubleCollection(PetSize.Locks),
        };
        bool settling = false;
        slider.ValueChanged += (_, e) =>
        {
            if (settling) return;
            double value = PetSize.Settle(e.NewValue);
            if (value != e.NewValue)
            {
                settling = true;
                slider.Value = value;
                settling = false;
            }
            OnSize?.Invoke(value);
        };
        var labels = new Grid { Width = 180 };
        foreach (var (text, align) in new[] { ("Small", HorizontalAlignment.Left), ("Medium", HorizontalAlignment.Center), ("Large", HorizontalAlignment.Right) })
            labels.Children.Add(new TextBlock { Text = text, HorizontalAlignment = align, FontSize = 11, Opacity = 0.7 });
        var row = new StackPanel();
        row.Children.Add(new TextBlock { Text = "Size" });
        row.Children.Add(slider);
        row.Children.Add(labels);
        return new MenuItem { Header = row, StaysOpenOnClick = true };
    }

    static MenuItem Item(string header, Action action)
    {
        var item = new MenuItem { Header = header };
        item.Click += (_, _) => action();
        return item;
    }
}

/// A borderless, see-through, always-on-top window for one pet. Clicks pass
/// through its empty parts, and it never takes focus.
sealed class PetWindow : Window
{
    public PetView Pet { get; }
    IntPtr handle;

    public PetWindow(PetView pet)
    {
        Pet = pet;
        Title = "Claude Pet";
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        Content = pet;
        SourceInitialized += (_, _) =>
        {
            handle = new WindowInteropHelper(this).Handle;
            Win32.MakeToolWindow(handle);
        };
    }

    public void BringToTop()
    {
        if (handle != IntPtr.Zero) Win32.BringToTop(handle);
    }
}

/// A see-through window spanning a Poke Ball's whole flight, closed once it lands.
sealed class ThrowWindow : Window
{
    public ThrowWindow(SpriteSheet ball, BallThrow flight, Size size, Func<Point, Point> snap, Action landed)
    {
        var corner = snap(new Point(Math.Min(flight.Start.X, flight.End.X), Math.Min(flight.Start.Y, flight.End.Y) - flight.Arc - 16));
        Left = corner.X;
        Top = corner.Y;
        Width = Math.Abs(flight.End.X - flight.Start.X) + size.Width;
        Height = Math.Max(flight.Start.Y, flight.End.Y) + size.Height - corner.Y;
        Title = "Claude Pet";
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;
        IsHitTestVisible = false;
        SourceInitialized += (_, _) => Win32.MakeClickThrough(new WindowInteropHelper(this).Handle);

        var rotation = new RotateTransform();
        var image = new Image
        {
            Source = ball.Frames[0], Width = size.Width, Height = size.Height,
            RenderTransformOrigin = new Point(0.5, 0.5), RenderTransform = rotation,
        };
        RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.NearestNeighbor);
        var canvas = new Canvas();
        canvas.Children.Add(image);
        Content = canvas;

        void Place(double t)
        {
            var (at, turns) = flight.At(t);
            at = snap(at);
            Canvas.SetLeft(image, at.X - corner.X);
            Canvas.SetTop(image, at.Y - corner.Y);
            rotation.Angle = turns * 90;
        }
        Place(0);
        var clock = Stopwatch.StartNew();
        void Step(object? sender, EventArgs e)
        {
            double t = Math.Min(1, clock.Elapsed.TotalSeconds / flight.Duration);
            Place(t);
            if (t < 1) return;
            CompositionTarget.Rendering -= Step;
            // The pet draws its ball on the same spot, then pops out of it.
            landed();
            var close = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
            close.Tick += (_, _) =>
            {
                close.Stop();
                Close();
            };
            close.Start();
        }
        Loaded += (_, _) => CompositionTarget.Rendering += Step;
    }
}

/// Every Pokemon in a grid to pick from. The current one is highlighted, ones
/// other agents have are faded (picking one swaps), and the hovered one walks in place.
sealed class PickerWindow : Window
{
    bool closing;

    public PickerWindow(string current, ISet<string> taken, Action<string> onPick, int first = 1, int last = 649)
    {
        Title = "Pick a Pokemon";
        WindowStyle = WindowStyle.ToolWindow;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = true;
        ShowInTaskbar = false;
        Background = Brushes.White;

        Image? hoveredImage = null;
        SpriteSheet? hoveredSheet = null;
        int step = 0;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        timer.Tick += (_, _) =>
        {
            if (hoveredImage == null || hoveredSheet == null) return;
            step++;
            hoveredImage.Source = hoveredSheet.Frames[step % 2];
        };
        timer.Start();

        var grid = new UniformGrid { Columns = 8, Margin = new Thickness(8) };
        var highlight = new SolidColorBrush(Color.FromArgb(77, 0, 120, 215));
        var hover = new SolidColorBrush(Color.FromArgb(26, 0, 0, 0));
        foreach (var name in Roster.Species.Where(p => p.Id >= first && p.Id <= last).Select(p => p.Asset))
        {
            if (SpriteSheet.Named(name) is not SpriteSheet sheet) continue;
            bool inUse = taken.Contains(name);
            var image = new Image { Source = sheet.Frames[0], Width = 64, Height = 64, Opacity = inUse ? 0.4 : 1 };
            RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.NearestNeighbor);
            var label = new TextBlock
            {
                Text = Roster.Display(name),
                FontSize = 11,
                HorizontalAlignment = HorizontalAlignment.Center,
                Foreground = inUse ? Brushes.Gray : Brushes.Black,
            };
            var cell = new Border
            {
                Width = 76,
                Height = 90,
                Margin = new Thickness(2),
                CornerRadius = new CornerRadius(6),
                Background = name == current ? highlight : Brushes.Transparent,
                Cursor = Cursors.Hand,
                Child = new StackPanel { Children = { image, label } },
            };
            cell.MouseEnter += (_, _) =>
            {
                if (name != current) cell.Background = hover;
                hoveredImage = image;
                hoveredSheet = sheet;
            };
            cell.MouseLeave += (_, _) =>
            {
                if (name != current) cell.Background = Brushes.Transparent;
                image.Source = sheet.Frames[0];
                hoveredImage = null;
            };
            cell.MouseLeftButtonUp += (_, _) =>
            {
                onPick(name);
                if (!closing) Close();
            };
            grid.Children.Add(cell);
        }
        Content = new ScrollViewer { Content = grid, MaxHeight = Math.Max(200, SystemParameters.WorkArea.Height - 120),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };

        Closing += (_, _) =>
        {
            closing = true;
            timer.Stop();
        };
        Deactivated += (_, _) =>
        {
            if (!closing) Close();
        };
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape && !closing) Close();
        };
    }
}

// MARK: - Lining up

enum Corner { TopLeft, TopRight, BottomLeft, BottomRight }

/// How the pets line up: a column or a row, tucked into one corner of the screen.
struct Arrangement
{
    public bool Vertical;
    public Corner Corner;
    /// How far the whole line-up has been Shift-dragged from its corner.
    public Vector Offset;

    public bool OnLeft => Corner is Corner.TopLeft or Corner.BottomLeft;
    public bool AtTop => Corner is Corner.TopLeft or Corner.TopRight;

    public static string Title(Corner corner) => corner switch
    {
        Corner.TopLeft => "Top Left",
        Corner.TopRight => "Top Right",
        Corner.BottomLeft => "Bottom Left",
        _ => "Bottom Right",
    };

    /// The choice from the right-click menu, kept across restarts.
    public static Arrangement Saved
    {
        get => new()
        {
            Vertical = Prefs.Get("lineUp", "direction") != "horizontal",
            Corner = Enum.TryParse<Corner>(Prefs.Get("lineUp", "corner"), out var corner) ? corner : Corner.BottomRight,
            Offset = ParseVector(Prefs.Get("lineUp", "offset")),
        };
        set
        {
            Prefs.Set("lineUp", "direction", value.Vertical ? "vertical" : "horizontal");
            Prefs.Set("lineUp", "corner", value.Corner.ToString());
            Prefs.Set("lineUp", "offset", FormattableString.Invariant($"{value.Offset.X},{value.Offset.Y}"));
        }
    }

    static Vector ParseVector(string? text)
    {
        var parts = text?.Split(',');
        return parts?.Length == 2 &&
            double.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var x) &&
            double.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var y)
            ? new Vector(x, y) : default;
    }
}

static class Stacking
{
    /// Bottom corners start just above Claude Code's prompt box at the bottom of the terminal.
    public const double Base = 92;
    /// Top corners keep heads this far below the top of the screen.
    public const double Top = 24;
    /// Clear space between neighbours: in a column, below one pet's caption room
    /// and above the next one's head; in a row, between their widest points.
    public const double Gap = 8;
    /// Room between the sprites and the screen's side edge.
    public const double Margin = 16;

    /// Where each pet's window goes (its top-left corner), lined up in `arrangement`
    /// within `visible` in `pets` order: top to bottom in a column, left to right in a row.
    public static List<Point> Origins(List<PetView> pets, Rect visible, Arrangement arrangement)
    {
        var origins = new List<Point>();
        if (pets.Count == 0) return origins;
        bool onLeft = arrangement.OnLeft;
        var heights = pets.Select(p => p.VisibleHeight).ToList();
        // The window position that puts a pet's sprite at `spriteLeft`, standing on `ground`.
        Point Origin(PetView pet, double spriteLeft, double ground) => new(spriteLeft - pet.HomeX, ground - pet.Ground);

        if (!arrangement.Vertical)
        {
            // Centre to centre, neighbours sit the gap apart at their widest (a Poke
            // Ball takes far less room than a Pokemon). Squeezed evenly if they won't fit.
            var widths = pets.Select(p => p.FootprintWidth).ToList();
            var steps = Enumerable.Range(0, pets.Count - 1).Select(i => widths[i] / 2 + Gap + widths[i + 1] / 2).ToList();
            double available = visible.Width - 2 * Margin - pets[0].SpriteSize, total = steps.Sum();
            if (total > available) steps = steps.Select(s => s * available / total).ToList();
            double center = onLeft
                ? visible.Left + Margin + pets[0].SpriteSize / 2
                : visible.Right - Margin - pets[0].SpriteSize / 2 - steps.Sum();
            double rowGround = arrangement.AtTop ? visible.Top + Top + heights.Max() : visible.Bottom - Base - 4;
            for (int i = 0; i < pets.Count; i++)
            {
                origins.Add(Origin(pets[i], center - pets[i].SpriteSize / 2, rowGround));
                if (i < steps.Count) center += steps[i];
            }
            return origins;
        }

        // In a column, each pet's ground sits its caption room plus the gap away
        // from the head of the next; the gap shrinks if they won't fit.
        double depth = PetView.CaptionDepth;
        double room = visible.Height - Base - Top - heights.Sum() - pets.Count * depth;
        double gap = pets.Count > 1 ? Math.Max(0, Math.Min(Gap, room / (pets.Count - 1))) : 0;
        double centerX = PetRules.ColumnCenter(visible.Left, visible.Right, Margin, pets.Select(p => p.FootprintWidth), onLeft);
        double Left(PetView pet) => centerX - pet.SpriteSize / 2;

        if (arrangement.AtTop)
        {
            double ground = visible.Top + Top + heights[0];
            for (int i = 0; i < pets.Count; i++)
            {
                origins.Add(Origin(pets[i], Left(pets[i]), ground));
                if (i + 1 < pets.Count) ground += depth + gap + heights[i + 1];
            }
        }
        else
        {
            double ground = visible.Bottom - Base - 4;
            for (int i = pets.Count - 1; i >= 0; i--)
            {
                origins.Insert(0, Origin(pets[i], Left(pets[i]), ground));
                ground -= heights[i] + gap + depth;
            }
        }
        return origins;
    }
}

// MARK: - App

sealed class PetsController
{
    readonly Dictionary<string, PetView> pets = new(); // by pane
    readonly Dictionary<string, PetWindow> windows = new();
    readonly HashSet<PetWindow> placed = new(); // on screen, so they slide to new spots
    List<string> order = new(); // agent order: herdr's sidebar, then sessions oldest first
    bool polling;
    EventWaitHandle? quit;

    public void Start()
    {
        var animation = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(125) };
        animation.Tick += (_, _) =>
        {
            foreach (var pet in pets.Values) pet.Animate();
        };
        animation.Start();

        var poll = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        poll.Tick += (_, _) => Poll();
        poll.Start();
        Poll();

        // `--toggle` and `--install` ask a running set of pets to quit through this.
        var quitEvent = new EventWaitHandle(false, EventResetMode.AutoReset, Program.QuitEventName);
        quit = quitEvent;
        var dispatcher = Dispatcher.CurrentDispatcher;
        new Thread(() =>
        {
            quitEvent.WaitOne();
            dispatcher.Invoke(() => Application.Current.Shutdown());
        }) { IsBackground = true }.Start();
    }

    void Poll()
    {
        if (polling) return;
        polling = true;
        var dispatcher = Dispatcher.CurrentDispatcher;
        Task.Run(() =>
        {
            List<Agent> agents;
            try { agents = Agents.Current(); }
            catch { agents = new List<Agent>(); }
            dispatcher.InvokeAsync(() =>
            {
                polling = false;
                Sync(agents);
            });
        });
    }

    /// Adds a pet for each new agent and removes pets whose agents have gone.
    void Sync(List<Agent> agents)
    {
        bool changed = false;
        var latestOrder = agents.Select(a => a.Pane).ToList();
        if (!latestOrder.SequenceEqual(order))
        {
            order = latestOrder;
            changed = true;
        }
        foreach (var pane in pets.Keys.Where(p => !order.Contains(p)).ToList())
        {
            placed.Remove(windows[pane]);
            windows[pane].Close();
            windows.Remove(pane);
            pets.Remove(pane);
            changed = true;
        }
        foreach (var agent in agents)
        {
            if (pets.TryGetValue(agent.Pane, out var existing))
            {
                existing.Update(agent);
                continue;
            }
            if (PokemonFor(agent.Pane) is not string name || SpriteSheet.Named(name) is not SpriteSheet sheet) continue;
            var pet = new PetView(agent, name, sheet)
            {
                OnMoved = p => Prefs.Set("positions", p.Pokemon,
                    FormattableString.Invariant($"{windows[p.Agent.Pane].Left},{windows[p.Agent.Pane].Top}")),
                OnPickGeneration = (p, first, last) => new PickerWindow(p.Pokemon,
                    pets.Values.Where(o => o != p).Select(o => o.Pokemon).ToHashSet(),
                    choice => Choose(choice, p), first, last).Show(),
                OnLineUp = () =>
                {
                    Prefs.Clear("positions");
                    var arrangement = Arrangement.Saved;
                    arrangement.Offset = default;
                    Arrangement.Saved = arrangement;
                    Layout();
                },
                OnDragAll = DragAll,
                OnResize = _ => Layout(),
                OnSize = Resize,
                OnHoverEnd = _ => Restack(),
                OnVanish = _ => Layout(),
                OnSummon = Summon,
                RestingPets = () => order.Where(pets.ContainsKey).Select(p => pets[p]).Where(p => p.IsGone).ToList(),
            };
            pet.Update(agent);
            pets[agent.Pane] = pet;
            windows[agent.Pane] = new PetWindow(pet);
            changed = true;
        }
        if (changed) Layout();
    }

    /// The pane's Pokemon from last time, or a random one no live pet is using.
    string? PokemonFor(string pane)
    {
        var taken = pets.Values.Select(p => p.Pokemon).ToHashSet();
        if (Prefs.Get("assignments", pane) is string saved && !taken.Contains(saved) && SpriteSheet.Named(saved) != null)
            return saved;
        var available = Roster.Names.Where(n => !taken.Contains(n) && SpriteSheet.Named(n) != null).ToList();
        var pick = available.Count > 0
            ? available[Random.Shared.Next(available.Count)]
            : Roster.Names.FirstOrDefault(n => SpriteSheet.Named(n) != null);
        if (pick != null) Prefs.Set("assignments", pane, pick);
        return pick;
    }

    /// Gives a pet a new Pokemon, swapping with any live pet that already has it.
    void Choose(string name, PetView pet)
    {
        if (name == pet.Pokemon || SpriteSheet.Named(name) is not SpriteSheet sheet) return;
        var previous = pet.Pokemon;
        if (pets.Values.FirstOrDefault(p => p != pet && p.Pokemon == name) is PetView other &&
            SpriteSheet.Named(previous) is SpriteSheet previousSheet)
        {
            other.SetPokemon(previous, previousSheet);
            Prefs.Set("assignments", other.Agent.Pane, previous);
        }
        pet.SetPokemon(name, sheet);
        Prefs.Set("assignments", pet.Agent.Pane, name);
        Layout(); // the new Pokemon may be taller or shorter
    }

    /// Where each visible pet's window was when a Shift-drag began, and how far it has gone.
    Dictionary<string, Point>? groupStart;
    Vector groupOffset;

    /// Moves every visible pet with a Shift-drag. When it's let go, the line-up
    /// keeps its new spot (pets coming and going still line up there), and pets
    /// dragged off on their own keep theirs, moved by the same amount.
    void DragAll(Vector? offset)
    {
        if (offset is not Vector by)
        {
            if (groupStart == null) return;
            var arrangement = Arrangement.Saved;
            arrangement.Offset += groupOffset;
            Arrangement.Saved = arrangement;
            foreach (var (pane, start) in groupStart)
                if (pets.TryGetValue(pane, out var pet) && Prefs.Get("positions", pet.Pokemon) != null)
                    Prefs.Set("positions", pet.Pokemon, FormattableString.Invariant($"{start.X + groupOffset.X},{start.Y + groupOffset.Y}"));
            groupStart = null;
            Layout();
            return;
        }
        groupStart ??= windows.Where(w => pets.TryGetValue(w.Key, out var p) && !p.IsGone)
            .ToDictionary(w => w.Key, w => new Point(w.Value.Left, w.Value.Top));
        groupOffset = by;
        foreach (var (pane, start) in groupStart)
        {
            if (!windows.TryGetValue(pane, out var window)) continue;
            window.BeginAnimation(Window.LeftProperty, null);
            window.BeginAnimation(Window.TopProperty, null);
            window.Left = start.X + by.X;
            window.Top = start.Y + by.Y;
        }
    }

    /// Resizes every pet for the Size slider; their windows fit them, and the line-up follows.
    void Resize(double value)
    {
        PetSize.Saved = value;
        if (value == Look.BaseScale) return;
        Look.BaseScale = value;
        foreach (var pet in pets.Values) pet.FitSize();
        Layout(animated: false); // follows the slider as it moves
    }

    /// Puts dragged pets where they were left, and lines the rest up in agent
    /// order as chosen under Line Up Pets (by default a column in the bottom-right corner).
    void Layout(bool animated = true)
    {
        var visible = SystemParameters.WorkArea;
        var arrangement = Arrangement.Saved;
        var stack = new List<(PetView Pet, PetWindow Window)>();
        foreach (var pane in order)
        {
            if (!pets.TryGetValue(pane, out var pet) || !windows.TryGetValue(pane, out var window)) continue;
            pet.CaptionAbove = false;
            if (pet.IsGone)
            {
                // Out of sight, taking no room; it's put straight in place when it comes back.
                window.Hide();
                placed.Remove(window);
                continue;
            }
            if (Prefs.Get("positions", pet.Pokemon) is string saved && TryParsePoint(saved, out var point) && OnScreen(point))
                Move(window, point, animated);
            else
                stack.Add((pet, window));
        }
        for (int i = 0; i < stack.Count; i++)
        {
            stack[i].Pet.Pace = arrangement.Vertical ? PetView.ColumnPace : PetView.RowPace;
            stack[i].Pet.CaptionAbove = !arrangement.Vertical && i % 2 == 1;
        }
        var origins = Stacking.Origins(stack.Select(s => s.Pet).ToList(), visible, arrangement)
            .Select(o => o + arrangement.Offset).ToList();
        // Last first, each brought in front of the next, so in a column a pet's
        // caption covers the z's rising from the one below.
        for (int i = stack.Count - 1; i >= 0; i--)
        {
            Move(stack[i].Window, origins[i], animated);
            stack[i].Window.BringToTop();
        }
    }

    /// Pets coming back out this round, thrown in together once all have room.
    readonly List<PetView> summoning = new();

    /// Brings a resting pet back, along with any others coming out at the same time.
    void Summon(PetView pet)
    {
        summoning.Add(pet);
        if (summoning.Count > 1) return;
        Dispatcher.CurrentDispatcher.InvokeAsync(() =>
        {
            var coming = summoning.ToList();
            summoning.Clear();
            Layout(); // makes room for them all first, so none moves once its ball is in the air
            foreach (var p in coming) ThrowBall(p);
        });
    }

    /// Throws a pet's Poke Ball in from the side of the screen it's on; the pet
    /// comes out where it lands.
    void ThrowBall(PetView pet)
    {
        if (!windows.TryGetValue(pet.Agent.Pane, out var window) || window.Pet != pet ||
            SpriteSheet.Pokeball is not SpriteSheet ball)
        {
            pet.Land();
            return;
        }
        var spot = pet.BallRect(ball);
        var landing = new Rect(window.Left + spot.X, window.Top + spot.Y, spot.Width, spot.Height);
        var screen = new Rect(0, 0, SystemParameters.PrimaryScreenWidth, SystemParameters.PrimaryScreenHeight);
        var flight = new BallThrow(landing, screen, SystemParameters.WorkArea);
        new ThrowWindow(ball, flight, spot.Size, pet.SnapPoint, pet.Land).Show();
    }

    /// Puts the column's layering back after a hovered pet was brought to the front.
    void Restack()
    {
        for (int i = order.Count - 1; i >= 0; i--)
            if (windows.TryGetValue(order[i], out var window)) window.BringToTop();
    }

    /// Slides a window that's already on screen; puts a new one straight in place.
    void Move(PetWindow window, Point to, bool animated = true)
    {
        to = window.Pet.SnapPoint(to);
        if (placed.Add(window))
        {
            window.Left = to.X;
            window.Top = to.Y;
            window.Show();
            return;
        }
        if (!animated)
        {
            window.BeginAnimation(Window.LeftProperty, null);
            window.BeginAnimation(Window.TopProperty, null);
            window.Left = to.X;
            window.Top = to.Y;
            return;
        }
        if (window.Left == to.X && window.Top == to.Y) return;
        Slide(window, Window.LeftProperty, window.Left, to.X);
        Slide(window, Window.TopProperty, window.Top, to.Y);
    }

    static void Slide(Window window, DependencyProperty property, double from, double to)
    {
        window.BeginAnimation(property, null);
        window.SetValue(property, to);
        window.BeginAnimation(property, new DoubleAnimation(from, to, TimeSpan.FromMilliseconds(250))
        {
            FillBehavior = FillBehavior.Stop,
            EasingFunction = new QuadraticEase(),
        });
    }

    static bool TryParsePoint(string text, out Point point)
    {
        point = default;
        var parts = text.Split(',');
        if (parts.Length != 2 ||
            !double.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var x) ||
            !double.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var y)) return false;
        point = new Point(x, y);
        return true;
    }

    static bool OnScreen(Point point) =>
        new Rect(SystemParameters.VirtualScreenLeft, SystemParameters.VirtualScreenTop,
            SystemParameters.VirtualScreenWidth, SystemParameters.VirtualScreenHeight).Contains(point);
}

// MARK: - Setup

static class Setup
{
    const string Title = "Claude Agent Pokedex";

    // Each event the pets react to. Notification is limited to the prompts that
    // wait on you; PermissionRequest catches the same thing without its delay.
    static readonly (string Event, string? Matcher)[] HookEvents =
    {
        ("SessionStart", null), ("UserPromptSubmit", null), ("PreToolUse", null), ("PostToolUse", null),
        ("PostToolUseFailure", null), ("PermissionRequest", null),
        ("Notification", "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input"),
        ("Stop", null), ("StopFailure", null), ("SessionEnd", null),
    };

    /// Copies this exe to %LOCALAPPDATA%\ClaudePet, downloads the sprites, adds
    /// the hooks and /pet, then starts the pets. Safe to run again.
    public static int Install()
    {
        try
        {
            StopRunningPets();
            Directory.CreateDirectory(Paths.Data);
            CopySelfTo(Paths.Exe);
            int missing = FetchSprites();
            SetHooks(add: true);
            WritePetCommand();
            Process.Start(new ProcessStartInfo(Paths.Exe) { UseShellExecute = true });
            MessageBox.Show(
                "Claude Pet is installed and running.\n\n" +
                "A pet appears for each Claude Code or live native Codex session. " +
                "Type /pet in Claude Code to summon or dismiss them." +
                (missing > 0 ? $"\n\n{missing} sprites couldn't be downloaded. Run install.cmd again to retry." : ""),
                Title);
            return 0;
        }
        catch (Exception e)
        {
            MessageBox.Show("Setup didn't finish: " + e.Message, Title, MessageBoxButton.OK, MessageBoxImage.Warning);
            return 1;
        }
    }

    /// Removes the hooks, /pet, the sprites, the sessions, the settings and the app.
    public static int Uninstall()
    {
        StopRunningPets();
        try
        {
            SetHooks(add: false);
        }
        catch (Exception e)
        {
            MessageBox.Show("Couldn't take the hooks out of Claude Code's settings: " + e.Message, Title);
        }
        try { File.Delete(Paths.PetCommand); } catch { }
        // This may be the installed copy, which can't delete itself while running.
        Process.Start(new ProcessStartInfo("cmd.exe", $"/c timeout /t 2 /nobreak >nul & rmdir /s /q \"{Paths.Data}\"")
        {
            CreateNoWindow = true,
            UseShellExecute = false,
        });
        MessageBox.Show("Claude Pet is uninstalled.", Title);
        return 0;
    }

    /// Asks a running set of pets to quit and waits for it; false if none was running.
    public static bool StopRunningPets()
    {
        try
        {
            using var quit = EventWaitHandle.OpenExisting(Program.QuitEventName);
            quit.Set();
        }
        catch (WaitHandleCannotBeOpenedException)
        {
            return false;
        }
        for (int i = 0; i < 30 && Mutex.TryOpenExisting(Program.MutexName, out var running); i++)
        {
            running.Dispose();
            Thread.Sleep(100);
        }
        return true;
    }

    /// Copies this exe into place, retrying while a hook briefly has the old one open.
    static void CopySelfTo(string target)
    {
        var self = Path.GetFullPath(Environment.ProcessPath!);
        if (string.Equals(self, Path.GetFullPath(target), StringComparison.OrdinalIgnoreCase)) return;
        for (int attempt = 0; ; attempt++)
        {
            try
            {
                File.Copy(self, target, overwrite: true);
                return;
            }
            catch (IOException) when (attempt < 20)
            {
                Thread.Sleep(250);
            }
        }
    }

    /// Downloads the sprites the pets use; returns how many couldn't be fetched.
    static int FetchSprites()
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(45) };
        return SpriteDownloads.Fetch(http, Paths.Sprites, Roster.Names).GetAwaiter().GetResult();
    }

    /// Adds or removes the pets' hooks in Claude Code's settings.json, leaving
    /// every other setting (and its order) as it was.
    public static void SetHooks(bool add)
    {
        var path = Paths.ClaudeSettings;
        JsonObject root;
        if (File.Exists(path))
        {
            var text = File.ReadAllText(path);
            root = string.IsNullOrWhiteSpace(text)
                ? new JsonObject()
                : JsonNode.Parse(text) as JsonObject ?? throw new InvalidDataException($"{path} isn't a JSON object, so it was left alone.");
        }
        else
        {
            root = new JsonObject();
        }
        if (root["hooks"] is not JsonObject hooks) hooks = new JsonObject();

        // Drop any of our earlier entries first, so running this twice is harmless.
        foreach (var (name, node) in hooks.ToList())
        {
            if (node is not JsonArray groups) continue;
            for (int i = groups.Count - 1; i >= 0; i--)
                if (groups[i]?["hooks"] is JsonArray handlers &&
                    handlers.Any(h => (Json.Str(h?["command"]) ?? "").EndsWith("ClaudePet.exe", StringComparison.OrdinalIgnoreCase)))
                    groups.RemoveAt(i);
            if (groups.Count == 0) hooks.Remove(name);
        }

        if (add)
        {
            foreach (var (name, matcher) in HookEvents)
            {
                if (hooks[name] is not JsonArray groups)
                {
                    groups = new JsonArray();
                    hooks[name] = groups;
                }
                var group = new JsonObject();
                if (matcher != null) group["matcher"] = matcher;
                // Exec form (no shell) and in the background, so Claude never waits on the pets.
                group["hooks"] = new JsonArray(new JsonObject
                {
                    ["type"] = "command",
                    ["command"] = Paths.Exe,
                    ["args"] = new JsonArray("--hook"),
                    ["async"] = true,
                });
                groups.Add(group);
            }
        }

        if (hooks.Count > 0)
        {
            if (hooks.Parent == null) root["hooks"] = hooks;
        }
        else
        {
            root.Remove("hooks");
        }
        Json.WriteAtomic(path, root.ToJsonString(Json.Pretty) + "\n");
    }

    /// Adds /pet to Claude Code, which runs `ClaudePet.exe --toggle`.
    static void WritePetCommand()
    {
        var exe = Paths.Exe.Replace('\\', '/');
        Directory.CreateDirectory(Path.GetDirectoryName(Paths.PetCommand)!);
        File.WriteAllText(Paths.PetCommand,
            "---\n" +
            "description: Summon or dismiss Claude Pet, the floating agent-status companion\n" +
            $"allowed-tools: Bash(\"{exe}\" --toggle)\n" +
            "---\n" +
            $"!`\"{exe}\" --toggle`\n\n" +
            "Reply with only the line above, nothing else.\n");
    }
}
