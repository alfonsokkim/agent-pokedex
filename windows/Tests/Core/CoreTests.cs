using System.Net;
using System.Reflection;
using System.Text;
using System.Text.Json;
using ClaudePet;
using Microsoft.Data.Sqlite;

int checks = 0;
void Check(bool value, string message) { checks++; if (!value) throw new Exception(message); }
void Reject(Action action, string message)
{
    try { action(); } catch (InvalidDataException) { checks++; return; }
    throw new Exception(message);
}
string Event(string type, object payload) => JsonSerializer.Serialize(new { type, payload }) + "\n";
string Call(string id, string name, string type = "function_call") => Event("response_item", new { type, call_id = id, name });
string Output(string id, string output, string type = "function_call_output") => Event("response_item", new { type, call_id = id, output });
string Boundary(string type) => Event("event_msg", new { type });
string Reply() => Event("response_item", new { type = "message", role = "user", content = "answer 🌱" });
using var catalog = Assembly.GetExecutingAssembly().GetManifestResourceStream("ClaudePet.pokemon.json")!;
var species = PokemonCatalog.Parse(catalog);
Check(species.Length == 649 && species[0].Slug == "bulbasaur" && species[^1].Slug == "genesect", "National Dex order");
Check(PokemonCatalog.Generations.Select(g => species.Count(p => p.Id >= g.First && p.Id <= g.Last))
    .SequenceEqual(new[] { 151, 100, 135, 107, 156 }), "Generation boundaries");
Check(species.Single(p => p.Id == 29).Display == "Nidoran♀", "Special species labels");
Check(species.Single(p => p.Id == 122).Asset == "mr_mime", "Asset names must match the shared sprite source");
Check(Enumerable.Range(0, 25).Count(i => EncounterRules.Resolve(null, "virizion", roll: () => i).Shiny) == 1, "Exactly 1 in 25");
var saved = new Appearance("virizion", true);
Check(EncounterRules.Resolve(saved, "virizion", roll: () => throw new Exception("Unexpected reroll")) == saved, "Persistent appearance");
Check(!EncounterRules.Resolve(saved, "virizion", true, () => 1).Shiny, "Release permits a reroll");
Check(!EncounterRules.Resolve(saved, "gengar", roll: () => 1).Shiny, "Species changes cannot reuse an appearance");
var palette = SpritePalette.Parse("JASC-PAL\r\n0100\r\n1\r\n12 234 56\r\n");
Check(palette[0] == new Rgb(12, 234, 56), "Palette channels");
Check(SpriteIndices.At(new byte[] { 0x01, 0x20 }, 2, 4, 2, 0) == 2, "Packed palette indices are decoded without colour matching");
Check(SpriteIndices.At(new byte[] { 0x40 }, 1, 2, 0, 0) == 1, "Two-bit palette index");
Check(SpriteIndices.At(new byte[] { 0, 15 }, 2, 8, 1, 0) == 15, "Eight-bit palette index");
foreach (string invalid in new[] { "1 2 3 junk", "1 2 256", "1 2", "-1 2 3" })
    Reject(() => SpritePalette.Parse("JASC-PAL\n0100\n1\n" + invalid), "Malformed palette accepted");
foreach (bool left in new[] { false, true })
{
    double center = PetRules.ColumnCenter(-1600, -160, 16, new[] { 96.0, 180.0, 240.0 }, left);
    Check(center - 120 >= -1600 + 16 && center + 120 <= -160 - 16, "Mixed sprite footprint fits screen");
}
Check(PetRules.Label("project", "root", "chat") == "[project] [root]: chat", "Project and workspace naming");
Check(PetRules.SpinningPokemon.Contains("klinklang") && !PetRules.SpinningPokemon.Contains("groudon"), "Object animation classification");

var activity = new CodexActivity();
activity.Consume(Boundary("task_started"));
activity.Consume(Call("sync", "functions.request_user_input"));
Check(activity.Status == "blocked", "Function-call questions must trigger attention");
activity.Consume(Output("unrelated", "{}"));
Check(activity.Status == "blocked", "Unrelated outputs must not clear attention");
activity.Consume(Output("sync", "{\"answers\":{}}"));
Check(activity.Status == "working", "Matching answer clears attention");
activity.Consume(Call("old", "request_user_input", "custom_tool_call"));
activity.Consume(Output("old", "answer", "custom_tool_call_output"));
Check(activity.Status == "working", "Legacy calls and outputs");
activity.Consume(Call("async", "request_user_input_async"));
activity.Consume(Output("async", "{\"accepted\":true}"));
activity.Consume(Boundary("task_complete"));
Check(activity.Status == "blocked", "Async acceptance and task completion are not an answer");
activity.Consume(Reply());
Check(activity.Status == "done", "User reply clears async attention");
activity.Consume(Call("abort", "request_user_input_async"));
activity.Consume(Boundary("turn_aborted"));
Check(activity.Status == "idle", "Abort clears attention");
activity.Consume("[]"); activity.Consume("invalid");
activity.Consume(Event("event_msg", new { type = "token_count", info = new { last_token_usage = new { total_tokens = 250 }, model_context_window = 1000 } }));
Check(activity.ContextUsed == 0.25, "Context telemetry is retained");
activity.Consume(Event("event_msg", new { type = "token_count", info = new { last_token_usage = new { total_tokens = "oops" }, model_context_window = 1000 } }));
Check(activity.ContextUsed == 0.25, "Invalid telemetry is ignored");

string temporary = Path.Combine(Path.GetTempPath(), "claude-pet-core-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(temporary);
try
{
    string log = Path.Combine(temporary, "rollout.jsonl");
    File.WriteAllText(log, Boundary("task_started") + Call("pending", "request_user_input_async") + Output("pending", "{\"accepted\":true}") +
        Output("noise", new string('x', 700_000)));
    var reader = new CodexLogReader();
    Check(reader.Read(log)?.Status == "blocked", "Question outside a short log tail");
    Check(reader.Read(log)?.Status == "blocked", "Cached attention state");
    byte[] reply = Encoding.UTF8.GetBytes(Reply());
    using (var append = new FileStream(log, FileMode.Append, FileAccess.Write, FileShare.ReadWrite))
    {
        append.Write(reply.AsSpan(0, reply.Length - 3)); append.Flush();
        Check(reader.Read(log)?.Status == "blocked", "Partial line cannot resolve a question");
        append.Write(reply.AsSpan(reply.Length - 3)); append.Flush();
    }
    Check(reader.Read(log)?.Status == "working", "Appended reply and UTF-8 decoder");
    Check(new CodexLogReader().Read(log)?.Status == "working", "Restart recovers the same state");
    File.WriteAllText(log, Boundary("turn_aborted"));
    Check(reader.Read(log)?.Status == "idle", "Truncation resets state");
    File.Delete(log);
    Check(reader.Read(log) == null, "Missing log cannot retain attention");
    string opening = Boundary("task_started") + Call("unicode", "request_user_input_async");
    string messageStart = "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":\"";
    int padding = 65533 - Encoding.UTF8.GetByteCount(opening + messageStart);
    File.WriteAllText(log, opening + messageStart + new string('x', padding) + "🌱" + new string('x', 65536) + "\"}}\n", new UTF8Encoding(false));
    Check(new CodexLogReader().Read(log)?.Status == "working", "Four-byte UTF-8 split across read blocks must preserve the user reply");

    using (var db = new SqliteConnection("Data Source=" + Path.Combine(temporary, "state_5.sqlite")))
    {
        db.Open();
        using var command = db.CreateCommand();
        command.CommandText = "CREATE TABLE threads (id TEXT, rollout_path TEXT, cwd TEXT, title TEXT, archived INTEGER);" +
            "INSERT INTO threads VALUES ('live','rollout','C:/dev/project','A chat',0), ('archived','rollout','C:/dev/project','Old',1);";
        command.ExecuteNonQuery();
    }
    var threads = CodexStore.Read(temporary, new[] { "live", "archived", "missing" });
    Check(threads.Count == 1 && threads[0].Title == "A chat", "Read-only store handles older schemas and excludes archived threads");
    Check(CodexStore.Read(Path.Combine(temporary, "absent"), new[] { "live" }).Count == 0, "Missing store is not created");
    Check(CodexStore.Scope(threads[0]) == ("project", "root"), "Windows path scope");
    Check(CodexStore.Scope(threads[0] with { Cwd = "C:/workspaces/repo/feature" }) == ("repo", "feature"), "Workspace path scope");
    Check(CodexStore.CleanTitle("<system_instruction>hidden</system_instruction>\n useful chat") == "useful chat", "Prompt metadata is not a title");

    var handler = new FakeAssets();
    using var http = new HttpClient(handler);
    string assets = Path.Combine(temporary, "sprites");
    Check(await SpriteDownloads.Fetch(http, assets, new[] { "virizion" }) == 0 && handler.Calls == 4, "Both palettes, sheet and ball are downloaded");
    Check(await SpriteDownloads.Fetch(http, assets, new[] { "virizion" }) == 0 && handler.Calls == 4, "Valid assets are not downloaded twice");
    File.WriteAllText(Path.Combine(assets, "palettes", "virizion_normal.pal"), "broken");
    Check(await SpriteDownloads.Fetch(http, assets, new[] { "virizion" }) == 0 && handler.Calls == 5, "Invalid assets are repaired");
    handler.Fail = true;
    File.Delete(Path.Combine(assets, "virizion.png"));
    Check(await SpriteDownloads.Fetch(http, assets, new[] { "virizion" }) == 1, "Download failure is reported without a partial file");
    Check(!Directory.GetFiles(assets, "*.part", SearchOption.AllDirectories).Any(), "No partial downloads remain");
}
finally { SqliteConnection.ClearAllPools(); Directory.Delete(temporary, true); }

if (args.Length > 0)
{
    foreach (var pokemon in species)
        foreach (var variant in new[] { "normal", "shiny" })
            Check(SpritePalette.Parse(File.ReadAllText(Path.Combine(args[0], "palettes", pokemon.Asset + "_" + variant + ".pal"))).Length is >= 1 and <= 256,
                "Shared upstream palette is valid");
}
Console.WriteLine($"Passed {checks} Windows core checks.");

sealed class FakeAssets : HttpMessageHandler
{
    public int Calls;
    public bool Fail;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Interlocked.Increment(ref Calls);
        byte[] bytes = request.RequestUri!.AbsolutePath.EndsWith(".pal", StringComparison.Ordinal) ?
            Encoding.UTF8.GetBytes("JASC-PAL\n0100\n1\n1 2 3\n") : new byte[] { 137, 80, 78, 71, 13, 10, 26, 10, 0 };
        return Task.FromResult(new HttpResponseMessage(Fail ? HttpStatusCode.ServiceUnavailable : HttpStatusCode.OK)
            { Content = new ByteArrayContent(bytes) });
    }
}
