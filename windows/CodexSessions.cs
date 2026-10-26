using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;

namespace ClaudePet;

static class CodexSessions
{
    public const string Prefix = "codex:";
    static readonly Dictionary<string, CodexLogReader> logs = new();

    static IEnumerable<string> Homes()
    {
        var homes = new List<string> { Environment.GetEnvironmentVariable("CODEX_HOME") ?? Path.Combine(Paths.Home, ".codex") };
        string roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        foreach (var root in new[] { roaming, local })
        {
            string orca = Path.Combine(root, "orca");
            homes.Add(Path.Combine(orca, "codex-runtime-home", "home"));
            string accounts = Path.Combine(orca, "codex-accounts");
            try
            {
                if (Directory.Exists(accounts)) homes.AddRange(Directory.GetDirectories(accounts).Select(p => Path.Combine(p, "home")));
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return homes.Distinct(StringComparer.OrdinalIgnoreCase).Where(h => File.Exists(Path.Combine(h, "state_5.sqlite")));
    }

    public static List<Agent> Agents()
    {
        var result = new Dictionary<string, Agent>();
        var activePaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var home in Homes())
        {
            string directory = Path.Combine(home, "thread-writer-locks");
            if (!Directory.Exists(directory)) continue;
            var owners = new Dictionary<string, int>();
            try
            {
                foreach (var file in Directory.GetFiles(directory, "*.lock"))
                {
                    string id = Path.GetFileNameWithoutExtension(file);
                    if (!Guid.TryParse(id, out _)) continue;
                    if (LockOwner.Find(file) is int pid) owners[id] = pid;
                }
            }
            catch (IOException) { continue; }
            catch (UnauthorizedAccessException) { continue; }
            if (owners.Count == 0) continue;
            foreach (var thread in CodexStore.Read(home, owners.Keys))
            {
                activePaths.Add(thread.Rollout);
                if (!logs.TryGetValue(thread.Rollout, out var reader)) logs[thread.Rollout] = reader = new();
                var activity = reader.Read(thread.Rollout);
                string status = activity?.Status ?? "idle";
                if (status == "done" && File.Exists(thread.Rollout) &&
                    double.TryParse(Prefs.Get("codexSeen", thread.Id), NumberStyles.Float, CultureInfo.InvariantCulture, out var seen) &&
                    new DateTimeOffset(File.GetLastWriteTimeUtc(thread.Rollout)).ToUnixTimeMilliseconds() / 1000.0 <= seen)
                    status = "idle";
                var (project, workspace) = CodexStore.Scope(thread);
                result[thread.Id] = new Agent(Prefix + thread.Id, status, thread.Title, project, owners[thread.Id])
                {
                    Kind = AgentKind.Codex, Workspace = workspace, ContextUsed = activity?.ContextUsed,
                    HostApp = Processes.HostingApp(owners[thread.Id])
                };
            }
        }
        foreach (var path in logs.Keys.Where(p => !activePaths.Contains(p)).ToArray()) logs.Remove(path);
        return result.OrderBy(pair => pair.Key).Select(pair => pair.Value).ToList();
    }

    public static void Focus(Agent agent)
    {
        string id = agent.Pane[Prefix.Length..];
        Prefs.Set("codexSeen", id, Util.Now().ToString(CultureInfo.InvariantCulture));
        if (string.Equals(agent.HostApp, "Codex", StringComparison.OrdinalIgnoreCase))
        {
            try { Process.Start(new ProcessStartInfo($"codex://threads/{id}") { UseShellExecute = true }); return; }
            catch (System.ComponentModel.Win32Exception) { }
        }
        if (agent.Pid is int pid) Processes.BringForward(pid);
    }
}

/// Restart Manager identifies the process holding a thread's writer lock.
/// Stale files have no owner and cannot create ghost pets.
static class LockOwner
{
    [StructLayout(LayoutKind.Sequential)]
    struct UniqueProcess { public int Id; public System.Runtime.InteropServices.ComTypes.FILETIME Start; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct ProcessInfo
    {
        public UniqueProcess Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string Service;
        public uint Type, Status, Session;
        [MarshalAs(UnmanagedType.Bool)] public bool Restartable;
    }
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmStartSession(out uint handle, int flags, StringBuilder key);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmRegisterResources(uint handle, uint files,
        string[] paths, uint applications, IntPtr processes, uint services, IntPtr serviceNames);
    [DllImport("rstrtmgr.dll")] static extern int RmGetList(uint handle, out uint needed, ref uint count,
        [In, Out] ProcessInfo[]? processes, ref uint reasons);
    [DllImport("rstrtmgr.dll")] static extern int RmEndSession(uint handle);

    public static int? Find(string path, bool codexOnly = true)
    {
        try
        {
            using var unused = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
            return null;
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { return null; }
        var key = new StringBuilder(33);
        if (RmStartSession(out uint session, 0, key) != 0) return null;
        try
        {
            if (RmRegisterResources(session, 1, new[] { path }, 0, IntPtr.Zero, 0, IntPtr.Zero) != 0) return null;
            uint count = 0, reasons = 0;
            int error = RmGetList(session, out uint needed, ref count, null, ref reasons);
            if (error != 234 || needed == 0 || needed > 256) return null;
            var processes = new ProcessInfo[needed];
            count = needed;
            if (RmGetList(session, out needed, ref count, processes, ref reasons) != 0) return null;
            foreach (var info in processes.Take((int)count))
            {
                try
                {
                    using var process = Process.GetProcessById(info.Process.Id);
                    if (!codexOnly || process.ProcessName.Contains("codex", StringComparison.OrdinalIgnoreCase)) return process.Id;
                }
                catch (ArgumentException) { }
                catch (InvalidOperationException) { }
                catch (System.ComponentModel.Win32Exception) { }
            }
            return null;
        }
        finally { RmEndSession(session); }
    }
}
