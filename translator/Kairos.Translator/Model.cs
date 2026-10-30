using System.Text.Json;
using System.Text.RegularExpressions;

namespace Kairos.Translator;

// Key names the spell in the module's SPELLS table (default: the action name, upper-cased).
public sealed record Spell(int Id, string Availability, string? Toggle = null, string? Key = null);
// Module is the namespace field the generated table is exposed as (Kairos.<Module>).
public sealed record Metadata(string Name, int Spec, string Simc, string Module, Dictionary<string, Spell> Spells,
    Dictionary<string, string> Bindings, string[] ExcludedLists)
{
    public static Metadata Load(string path) => JsonSerializer.Deserialize<Metadata>(File.ReadAllText(path),
        new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? throw new FormatException("Empty metadata");
}

public sealed record ActionLine(int Number, string List, string Action, Dictionary<string, string> Options, string Source);
public sealed record Coverage(int Number, string List, string Kind, string Text, string Status, string Detail);
public sealed record Translation(string Lua, IReadOnlyList<Coverage> Coverage)
{
    public string Report => JsonSerializer.Serialize(Coverage, new JsonSerializerOptions { WriteIndented = true })
        .Replace("\r\n", "\n") + "\n";
}

public static class SimcParser
{
    public static List<ActionLine> Parse(string source)
    {
        var result = new List<ActionLine>();
        var lines = source.Replace("\r\n", "\n").Split('\n');
        for (int i = 0; i < lines.Length; i++)
        {
            var text = lines[i].Split('#')[0].Trim();
            if (text.Length == 0) continue;
            var match = Regex.Match(text, @"^actions(?:\.(?<list>\w+))?(?<append>\+)?=(?:/)?(?<body>.+)$");
            if (!match.Success) throw new FormatException($"Line {i + 1}: not an action-list assignment: {text}");
            var list = match.Groups["list"].Success ? match.Groups["list"].Value : "default";
            // '=' replaces an earlier definition; '+=' appends. Keep source lines for coverage.
            if (!match.Groups["append"].Success && result.Any(a => a.List == list))
                throw new NotSupportedException($"Line {i + 1}: redefining list {list} is not supported");
            var pieces = match.Groups["body"].Value.Split(',');
            var options = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var piece in pieces.Skip(1))
            {
                var eq = piece.IndexOf('=');
                if (eq <= 0 || !options.TryAdd(piece[..eq].Trim(), piece[(eq + 1)..].Trim()))
                    throw new FormatException($"Line {i + 1}: malformed or duplicate option {piece}");
            }
            result.Add(new(i + 1, list, pieces[0].Trim(), options, text));
        }
        return result;
    }
}
