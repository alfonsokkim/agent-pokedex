using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace ClaudePet;

sealed record CodexThread(string Id, string Rollout, string Cwd, string Title, string Branch, string AgentPath);

static class CodexStore
{
    public static List<CodexThread> Read(string home, IEnumerable<string> activeIds)
    {
        var result = new List<CodexThread>();
        string path = Path.Combine(home, "state_5.sqlite");
        if (!File.Exists(path)) return result;
        try
        {
            using var db = new SqliteConnection(new SqliteConnectionStringBuilder
            {
                DataSource = path, Mode = SqliteOpenMode.ReadOnly, Pooling = false, DefaultTimeout = 1
            }.ToString());
            db.Open();
            using var schema = db.CreateCommand();
            schema.CommandText = "PRAGMA table_info(threads)";
            var columns = new HashSet<string>();
            using (var fields = schema.ExecuteReader()) while (fields.Read()) columns.Add(fields.GetString(1));
            string Field(string name) => columns.Contains(name) ? $"NULLIF({name}, '')" : "NULL";
            using var command = db.CreateCommand();
            command.CommandText = $"SELECT id, COALESCE(rollout_path, ''), COALESCE(cwd, ''), COALESCE({Field("name")}, {Field("preview")}, {Field("title")}, ''), " +
                $"COALESCE({Field("git_branch")}, ''), COALESCE({Field("agent_path")}, '') FROM threads WHERE id = $id AND archived = 0";
            var parameter = command.Parameters.Add("$id", SqliteType.Text);
            foreach (var id in activeIds.Distinct())
            {
                parameter.Value = id;
                using var rows = command.ExecuteReader();
                if (rows.Read() && !string.IsNullOrEmpty(rows.GetString(1))) result.Add(new CodexThread(rows.GetString(0), rows.GetString(1), rows.GetString(2),
                    CleanTitle(rows.GetString(3)), rows.GetString(4), rows.GetString(5)));
            }
        }
        catch (SqliteException) { }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        return result;
    }

    public static string CleanTitle(string text)
    {
        int end = text.LastIndexOf("</system_instruction>", StringComparison.Ordinal);
        if (end >= 0) text = text[(end + "</system_instruction>".Length)..];
        text = Regex.Replace(text, @"\s+", " ").Trim();
        return text.Length > 80 ? text[..79] + "…" : text;
    }

    public static (string Project, string Workspace) Scope(CodexThread thread)
    {
        var parts = thread.Cwd.Split(new[] { '/', '\\' }, StringSplitOptions.RemoveEmptyEntries);
        var agent = thread.AgentPath.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault();
        string branch = thread.Branch.Split('/').LastOrDefault() ?? "";
        string workspace = agent ?? (branch is "" or "main" or "master" ? "root" : branch);
        int index = Array.LastIndexOf(parts, "workspaces");
        return index >= 0 && index + 2 < parts.Length ? (parts[index + 1], agent ?? parts[index + 2]) :
            (parts.LastOrDefault() ?? "Codex", workspace);
    }
}
