using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Kairos.Translator;

public sealed class Translator(Metadata metadata)
{
    public const string Version = "0.1.0";
    private static string Q(string s) => JsonSerializer.Serialize(s, new JsonSerializerOptions
        { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });

    public Translation Translate(string source)
    {
        var actions = SimcParser.Parse(source);
        var coverage = new List<Coverage>();
        var variables = new HashSet<string>(StringComparer.Ordinal);
        var generated = new Dictionary<int, (string? Condition, string? Value)>();
        var clauses = new Dictionary<int, List<string>>();
        var supported = new HashSet<int>();
        var lists = actions.Select(a => a.List).ToHashSet();
        string? Bind(string name)
        {
            if (metadata.Bindings.TryGetValue(name, out var binding)) return binding;
            var p = name.Split('.');
            if (p.Length == 2 && p[0] == "talent") return $"V(s.talent[{Q(p[1])}])";
            if (p.Length == 2 && p[0] == "variable" && variables.Contains(p[1])) return $"(v[{Q(p[1])}] or 0)";
            if (p.Length == 3 && p[0] == "cooldown" && metadata.Spells.TryGetValue(p[1], out var spell))
                return p[2] switch
                {
                    "ready" => $"N(has(s, {spell.Id}) and s.ready[{spell.Id}])",
                    "remains" => $"(s.remains[{spell.Id}] or 0)",
                    "charges_fractional" => $"(s.chargesFractional[{spell.Id}] or 0)",
                    _ => null
                };
            if (p.Length == 3 && p[0] == "prev_gcd" && p[1] == "1" && metadata.Spells.TryGetValue(p[2], out var prev))
                return $"N(s.prevGcd == {prev.Id})";
            return null;
        }

        string? Compile(ActionLine a, string key, ref bool valid)
        {
            if (!a.Options.TryGetValue(key, out var expression)) return null;
            // Report every identifier, including ones after an unbound identifier.
            foreach (Match m in Regex.Matches(expression, @"[a-zA-Z_][a-zA-Z_0-9.]*"))
                coverage.Add(new(a.Number, a.List, "binding", m.Value, Bind(m.Value) is null ? "unsupported" : "bound",
                    Bind(m.Value) ?? "No state binding"));
            try
            {
                var compiler = new ExpressionCompiler(Bind);
                var lua = compiler.Compile(expression);
                if (key == "if") clauses[a.Number] = [.. compiler.Clauses];
                coverage.Add(new(a.Number, a.List, "expression", expression, "bound", key));
                return lua;
            }
            catch (Exception e) when (e is FormatException or NotSupportedException)
            {
                valid = false;
                coverage.Add(new(a.Number, a.List, "expression", expression, "unsupported", e.Message));
                return null;
            }
        }

        foreach (var a in actions)
        {
            bool valid = true;
            var condition = Compile(a, "if", ref valid);
            var value = Compile(a, "value", ref valid);
            _ = Compile(a, "interrupt_if", ref valid);
            string? reason = null;
            if (metadata.ExcludedLists.Contains(a.List)) reason = "List outside initial Sunfury scope";
            else if (a.Action == "variable")
            {
                if (!a.Options.ContainsKey("name") || value is null || a.Options.GetValueOrDefault("op", "set") != "set")
                    reason = "Only variable op=set with a bound value is supported";
            }
            else if (a.List == "precombat") reason = "Precombat recommendations not implemented (variables only)";
            else if (a.Action == "call_action_list")
            {
                if (!a.Options.TryGetValue("name", out var target) || !lists.Contains(target)) reason = "Missing action list";
                else if (metadata.ExcludedLists.Contains(target)) reason = "Target list outside initial Sunfury scope";
            }
            else if (!metadata.Spells.ContainsKey(a.Action)) reason = "Action has no supported spell metadata";

            foreach (var (key, option) in a.Options)
            {
                var status = "bound";
                var detail = "";
                if (key == "chain" && option == "1")
                {
                    status = "approximated";
                    detail = "Recommendation only; no channel timing/clip cue (D32)";
                }
                else if (key == "use_off_gcd" && option is not ("0" or "1")) status = "unsupported";
                else if (key is not ("name" or "op" or "if" or "value" or "use_off_gcd")) status = "unsupported";
                else if (key == "op" && option != "set") status = "unsupported";
                if (key is "name" && a.Action is not ("call_action_list" or "variable")) status = "unsupported";
                if (key is "op" or "value" && a.Action != "variable") status = "unsupported";
                if (key == "use_off_gcd" && !metadata.Spells.ContainsKey(a.Action)) status = "unsupported";
                if (status == "unsupported") valid = false;
                coverage.Add(new(a.Number, a.List, "option", $"{key}={option}", status, detail));
            }
            valid &= reason is null;
            coverage.Add(new(a.Number, a.List, "action", a.Source, valid ? "bound" : "unsupported",
                reason ?? (valid ? "" : "Unsupported expression or option; entire action omitted")));
            if (!valid) continue;
            supported.Add(a.Number);
            generated[a.Number] = (condition, value);
            if (a.Action == "variable") variables.Add(a.Options["name"]);
        }

        // Recursive list calls could overflow Lua's stack. Reject them before emitting anything.
        void Visit(string list, HashSet<string> path)
        {
            if (!path.Add(list)) throw new NotSupportedException($"Recursive action-list call: {list}");
            foreach (var a in actions.Where(a => a.List == list && a.Action == "call_action_list" && supported.Contains(a.Number)))
                Visit(a.Options["name"], path);
            path.Remove(list);
        }
        foreach (var list in lists) Visit(list, []);

        // Short labels for reports: list:action, #n when the action repeats in its list
        // (counting every source line, so labels don't move as coverage grows).
        var labels = new Dictionary<int, string>();
        foreach (var group in actions.GroupBy(a => (a.List, a.Action)))
        {
            var lines = group.ToList();
            for (int i = 0; i < lines.Count; i++)
                labels[lines[i].Number] = $"{group.Key.List}:{group.Key.Action}" + (lines.Count > 1 ? $"#{i + 1}" : "");
        }

        var b = new StringBuilder();
        void Line(string text = "") => b.Append(text).Append('\n');
        Line($"-- GENERATED by Kairos.Translator {Version} from SimC midnight {metadata.Simc}. DO NOT EDIT:");
        Line("-- regenerate it as translator/README.md describes.");
        Line($"-- {metadata.Name}, spec {metadata.Spec}. Partial: the coverage report lists every omitted rule.");
        Line("-- Takes the plain, non-secret state documented in translator/README.md.");
        Line("-- Each pick is { spellID, line = the SimC line, label = list:action (clause i/k) }.");
        Line("local _, Kairos = ...");
        Line($"local APL = {{ name = {Q(metadata.Name + " (generated)")}, simc = {Q(metadata.Simc)}, spec = {metadata.Spec} }}");
        var spells = metadata.Spells.Select(p => $"{p.Value.Key ?? p.Key.ToUpperInvariant()} = {p.Value.Id}");
        Line($"APL.SPELLS = {{ {string.Join(", ", spells)} }}");
        Line("local function T(v) return v ~= nil and v ~= false and v ~= 0 end");
        Line("local function N(v) return T(v) and 1 or 0 end");
        Line("local function V(v) if type(v) == \"number\" then return v end return N(v) end");
        Line("local function has(s, id) return not (s.known and s.known[id] == false) end");
        Line("local lists = {}");
        foreach (var list in lists.Where(l => l != "precombat" && !metadata.ExcludedLists.Contains(l)))
        {
            Line($"lists[{Q(list)}] = function(s, v, offGcd)");
            foreach (var a in actions.Where(a => a.List == list && supported.Contains(a.Number))) Emit(a, "    ");
            Line("    return nil");
            Line("end");
        }
        void Emit(ActionLine a, string indent)
        {
            var (condition, value) = generated[a.Number];
            if (a.Action == "variable")
            {
                Line($"{indent}if { (condition is null ? "true" : $"T({condition})") } then v[{Q(a.Options["name"])}] = {value} end");
            }
            else if (a.Action == "call_action_list")
            {
                Line($"{indent}if {(condition is null ? "true" : $"T({condition})")} then");
                Line($"{indent}    local result = lists[{Q(a.Options["name"])}](s, v, offGcd)");
                Line($"{indent}    if result then return result end");
                Line($"{indent}end");
            }
            else
            {
                var spell = metadata.Spells[a.Action];
                var mode = a.Options.GetValueOrDefault("use_off_gcd") == "1" ? "offGcd" : "not offGcd";
                var availability = spell.Availability.Replace("{id}", spell.Id.ToString(System.Globalization.CultureInfo.InvariantCulture));
                var label = labels[a.Number];
                var parts = clauses.GetValueOrDefault(a.Number);
                if (parts is { Count: > 1 })
                {
                    // Same test as T(condition), clause by clause, to report which one fired.
                    var which = string.Join(" or ", parts.Select((c, i) => $"T({c}) and {i + 1}"));
                    Line($"{indent}if {mode} and has(s, {spell.Id}) and ({availability}) then");
                    Line($"{indent}    local clause = {which} or nil");
                    Line($"{indent}    if clause then");
                    Line($"{indent}        return {{ spellID = {spell.Id}, line = {Q(a.Source)}, label = {Q(label + " (")} .. clause .. {Q($"/{parts.Count})")} }}");
                    Line($"{indent}    end");
                    Line($"{indent}end");
                }
                else
                {
                    Line($"{indent}if {mode} and has(s, {spell.Id}) and ({availability}){(condition is null ? "" : $" and T({condition})")} then");
                    Line($"{indent}    return {{ spellID = {spell.Id}, line = {Q(a.Source)}, label = {Q(label)} }}");
                    Line($"{indent}end");
                }
            }
        }
        Line("local function evaluate(s, offGcd)");
        Line("    local v = {}");
        foreach (var a in actions.Where(a => a.List == "precombat" && supported.Contains(a.Number))) Emit(a, "    ");
        if (lists.Contains("default")) Line("    return lists.default(s, v, offGcd)");
        else Line("    return nil");
        Line("end");
        Line("function APL:Evaluate(s) return evaluate(s, false) end");
        Line("function APL:OffGcd(s) return evaluate(s, true) end");
        Line($"Kairos.{metadata.Module} = APL");
        Line("return APL");
        return new(b.ToString(), coverage);
    }
}
