using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace ClaudePet;

static class SpriteDownloads
{
    public const string Base = "https://raw.githubusercontent.com/rh-hideout/pokeemerald-expansion/master/graphics/pokemon";
    public const string Ball = "https://raw.githubusercontent.com/pret/pokefirered/master/graphics/object_events/pics/misc/item_ball.png";
    static bool Valid(string name, byte[] bytes)
    {
        if (name.EndsWith(".pal", StringComparison.Ordinal))
        {
            try { _ = SpritePalette.Parse(System.Text.Encoding.UTF8.GetString(bytes)); return true; }
            catch (InvalidDataException) { return false; }
        }
        return bytes.Length >= 8 && bytes.Take(8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 });
    }

    public static async Task<int> Fetch(HttpClient http, string directory, IEnumerable<string> names)
    {
        Directory.CreateDirectory(directory);
        Directory.CreateDirectory(Path.Combine(directory, "palettes"));
        var jobs = new List<(string File, string Url)>();
        foreach (var name in names)
        {
            if (name.Length == 0 || name.Any(c => !char.IsAsciiLetterLower(c) && !char.IsAsciiDigit(c) && c != '_'))
                throw new InvalidDataException("Invalid sprite name.");
            jobs.Add((name + ".png", $"{Base}/{name}/overworld.png"));
            foreach (var variant in new[] { "normal", "shiny" })
                jobs.Add((Path.Combine("palettes", name + "_" + variant + ".pal"), $"{Base}/{name}/overworld_{variant}.pal"));
        }
        jobs.Add(("_pokeball.png", Ball));
        int missing = 0;
        await Parallel.ForEachAsync(jobs, new ParallelOptions { MaxDegreeOfParallelism = 8 }, async (job, cancellation) =>
        {
            string path = Path.Combine(directory, job.File);
            string temporary = path + "." + Guid.NewGuid().ToString("N") + ".part";
            try
            {
                if (File.Exists(path) && Valid(job.File, await File.ReadAllBytesAsync(path, cancellation))) return;
                byte[] bytes = await http.GetByteArrayAsync(job.Url, cancellation);
                if (!Valid(job.File, bytes)) throw new InvalidDataException("Invalid downloaded sprite asset.");
                await File.WriteAllBytesAsync(temporary, bytes, cancellation);
                File.Move(temporary, path, overwrite: true);
            }
            catch (Exception e) when (e is IOException or InvalidDataException or UnauthorizedAccessException or HttpRequestException or OperationCanceledException)
            {
                Interlocked.Increment(ref missing);
            }
            finally
            {
                try { if (File.Exists(temporary)) File.Delete(temporary); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        });
        return missing;
    }
}
