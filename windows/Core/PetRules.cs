using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace ClaudePet;

sealed record Species(int Id, string Slug)
{
    public string Asset => Slug.Replace('-', '_');
    public string Display => Slug switch
    {
        "nidoran-f" => "Nidoran♀", "nidoran-m" => "Nidoran♂", "farfetchd" => "Farfetch’d",
        "mr-mime" => "Mr. Mime", "mime-jr" => "Mime Jr.", "ho-oh" => "Ho-Oh", "porygon-z" => "Porygon-Z",
        _ => string.Join(" ", Slug.Split('-').Select(s => char.ToUpperInvariant(s[0]) + s[1..]))
    };
}

static class PokemonCatalog
{
    public static readonly (string Title, int First, int Last)[] Generations =
    {
        ("Generation I · Kanto", 1, 151), ("Generation II · Johto", 152, 251),
        ("Generation III · Hoenn", 252, 386), ("Generation IV · Sinnoh", 387, 493),
        ("Generation V · Unova", 494, 649)
    };
    public static Species[] Parse(Stream source)
    {
        var names = JsonSerializer.Deserialize<string[]>(source) ?? Array.Empty<string>();
        if (names.Length != 649 || names.Distinct().Count() != 649 ||
            names.Any(n => string.IsNullOrEmpty(n) || n.Any(c => !char.IsAsciiLetterLower(c) && !char.IsAsciiDigit(c) && c != '-')))
            throw new InvalidDataException("The Pokemon catalog must contain 649 unique species.");
        return names.Select((name, i) => new Species(i + 1, name)).ToArray();
    }
}

sealed record Appearance(string Pokemon, bool Shiny);

static class EncounterRules
{
    public const int Denominator = 25;
    public static Appearance Resolve(Appearance? previous, string pokemon, bool reroll = false, Func<int>? roll = null) =>
        !reroll && previous?.Pokemon == pokemon ? previous :
            new Appearance(pokemon, (roll ?? (() => Random.Shared.Next(Denominator)))() == 0);
}

readonly record struct Rgb(byte R, byte G, byte B);

/// One hover, one short burst, driven by the pet's existing animation clock.
sealed class ShinyHoverBurst
{
    public const int Duration = 10;
    public static readonly string[] Pattern = { "...G...", "...Y...", "..YWY..", "GYWWWYG", "..YWY..", "...Y...", "...G..." };
    public int? Start { get; private set; }
    public void Begin(int tick) { if (Progress(tick) == null) Start = tick; }
    public void Reset() => Start = null;
    public double? Progress(int tick) => Start is int start && tick >= start && tick - start < Duration
        ? (tick - start) / (double)Duration : null;
    public readonly record struct Star(double X, double Y, double Pixel, double Alpha);

    public IEnumerable<Star> Stars(int tick, double centerX, double centerY, double boxWidth, double boxHeight,
        double width, double height, double scale)
    {
        if (Progress(tick) is not double progress) yield break;
        double basePixel = Math.Max(1, Math.Round(scale * 0.65, MidpointRounding.AwayFromZero));
        double rx = Math.Max(0, Math.Min(boxWidth / 2 + 10 * scale, Math.Min(centerX, width - centerX) - 4 * basePixel));
        double ry = Math.Max(0, Math.Min(boxHeight / 2 + 10 * scale, Math.Min(centerY, height - centerY) - 4 * basePixel));
        for (int i = 0; i < 8; i++)
        {
            double p = Math.Clamp(progress * 1.2 - i % 3 * 0.08, 0, 1);
            double angle = i * Math.PI / 4 + Math.PI / 8 + p * 0.25;
            double distance = 0.25 + 0.75 * (1 - Math.Pow(1 - p, 2));
            double pixel = p > 0.72 ? Math.Max(1, Math.Round(basePixel / 2, MidpointRounding.AwayFromZero)) : basePixel;
            double x = Math.Round((centerX + Math.Cos(angle) * rx * distance) / pixel, MidpointRounding.AwayFromZero) * pixel - 3 * pixel;
            double y = Math.Round((centerY + Math.Sin(angle) * ry * distance) / pixel, MidpointRounding.AwayFromZero) * pixel - 3 * pixel;
            double twinkle = (tick + i) % 3 == 0 ? 0.65 : 1;
            yield return new Star(x, y, pixel, Math.Min(1, (1 - p) * 2.5) * twinkle);
        }
    }
}

static class SpriteIndices
{
    public static int At(byte[] pixels, int stride, int bits, int x, int y) =>
        (pixels[y * stride + x * bits / 8] >> (8 - bits - x * bits % 8)) & ((1 << bits) - 1);
}

static class SpritePalette
{
    public static Rgb[] Parse(string text)
    {
        var lines = text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
        if (lines.Length < 3 || lines[0] != "JASC-PAL" || lines[1] != "0100" ||
            !int.TryParse(lines[2], out int count) || count < 1 || count > 256 || lines.Length != count + 3)
            throw new InvalidDataException("Invalid sprite palette.");
        return lines.Skip(3).Select(line =>
        {
            var values = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (values.Length != 3 || !byte.TryParse(values[0], out var r) ||
                !byte.TryParse(values[1], out var g) || !byte.TryParse(values[2], out var b))
                throw new InvalidDataException("Invalid palette colour.");
            return new Rgb(r, g, b);
        }).ToArray();
    }
}

static class PetRules
{
    public static readonly HashSet<string> SpinningPokemon = new(StringComparer.Ordinal)
    {
        "magnemite", "magneton", "voltorb", "electrode", "unown", "baltoy", "claydol",
        "lunatone", "solrock", "bronzor", "bronzong", "magnezone", "rotom",
        "klink", "klang", "klinklang", "cryogonal"
    };
    public static double ColumnCenter(double left, double right, double margin, IEnumerable<double> widths, bool onLeft)
    {
        double half = widths.DefaultIfEmpty(0).Max() / 2;
        return onLeft ? left + margin + half : right - margin - half;
    }
    public static string Label(string project, string workspace, string title) =>
        string.IsNullOrEmpty(workspace) ? (string.IsNullOrEmpty(title) ? project : $"{project}: {title}") :
            $"[{project}] [{workspace}]" + (string.IsNullOrEmpty(title) ? "" : $": {title}");
}

/// Only actual user-input calls trigger attention. An async acknowledgement is not an answer.
sealed class CodexActivity
{
    public string Phase { get; private set; } = "idle";
    public double? ContextUsed { get; private set; }
    readonly Dictionary<string, bool> questions = new();
    public string Status => questions.Count == 0 ? Phase : "blocked";

    public void Consume(string line)
    {
        JsonDocument document;
        try { document = JsonDocument.Parse(line); } catch (JsonException) { return; }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("payload", out var payload) || payload.ValueKind != JsonValueKind.Object) return;
            string? type = Text(root, "type"), item = Text(payload, "type");
            if (type == "event_msg")
            {
                switch (item)
                {
                    case "task_started": case "turn_started": Phase = "working"; break;
                    case "task_complete": case "turn_complete":
                        Phase = "done";
                        foreach (var id in questions.Where(q => !q.Value).Select(q => q.Key).ToArray()) questions.Remove(id);
                        break;
                    case "turn_aborted": Phase = "idle"; questions.Clear(); break;
                    case "user_message": questions.Clear(); break;
                    case "token_count":
                        if (payload.TryGetProperty("info", out var info) && info.ValueKind == JsonValueKind.Object &&
                            info.TryGetProperty("last_token_usage", out var usage) && usage.ValueKind == JsonValueKind.Object &&
                            usage.TryGetProperty("total_tokens", out var tokens) && tokens.ValueKind == JsonValueKind.Number && tokens.TryGetDouble(out var total) &&
                            info.TryGetProperty("model_context_window", out var window) && window.ValueKind == JsonValueKind.Number && window.TryGetDouble(out var capacity) && capacity > 0)
                            ContextUsed = Math.Clamp(total / capacity, 0, 1);
                        break;
                }
            }
            else if (type == "response_item")
            {
                if (item == "message" && Text(payload, "role") == "user") questions.Clear();
                else if (item is "function_call" or "custom_tool_call")
                {
                    string? name = Text(payload, "name")?.Split('.').Last(), id = Text(payload, "call_id");
                    if (id != null && name is "request_user_input" or "request_user_input_async")
                        questions[id] = name == "request_user_input_async";
                }
                else if (item is "function_call_output" or "custom_tool_call_output")
                {
                    var id = Text(payload, "call_id");
                    if (id != null && questions.TryGetValue(id, out bool asynchronous))
                    {
                        bool accepted = false;
                        try
                        {
                            using var output = JsonDocument.Parse(Text(payload, "output") ?? "{}");
                            accepted = output.RootElement.ValueKind == JsonValueKind.Object &&
                                output.RootElement.TryGetProperty("accepted", out var value) && value.ValueKind == JsonValueKind.True;
                        }
                        catch (JsonException) { }
                        if (!asynchronous || !accepted) questions.Remove(id);
                    }
                }
            }
        }
    }

    static string? Text(JsonElement node, string key) =>
        node.ValueKind == JsonValueKind.Object && node.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() : null;
}

/// Reads complete appended lines, retaining pending questions even in long sessions.
sealed class CodexLogReader
{
    long offset;
    DateTime created;
    string partial = "";
    readonly System.Text.Decoder decoder = System.Text.Encoding.UTF8.GetDecoder();
    public CodexActivity State { get; private set; } = new();
    public CodexActivity? Read(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists) { Reset(); return null; }
            if (info.Length < offset || created != info.CreationTimeUtc) Reset();
            created = info.CreationTimeUtc;
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            stream.Seek(offset, SeekOrigin.Begin);
            byte[] bytes = new byte[65536];
            char[] chars = new char[System.Text.Encoding.UTF8.GetMaxCharCount(bytes.Length)];
            int count;
            while ((count = stream.Read(bytes, 0, bytes.Length)) > 0)
            {
                offset += count;
                int length = decoder.GetChars(bytes, 0, count, chars, 0, false);
                string text = partial + new string(chars, 0, length);
                int start = 0, newline;
                while ((newline = text.IndexOf('\n', start)) >= 0)
                {
                    State.Consume(text[start..newline]);
                    start = newline + 1;
                }
                partial = text[start..];
            }
            return State;
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }
    void Reset() { offset = 0; partial = ""; State = new(); decoder.Reset(); }
}
