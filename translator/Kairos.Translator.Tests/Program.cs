using System.Diagnostics;
using Kairos.Translator;

var directory = new DirectoryInfo(AppContext.BaseDirectory);
while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "translator/metadata/mage_arcane.json")))
    directory = directory.Parent;
var root = directory?.FullName ?? throw new Exception("Cannot find repository root");
Directory.SetCurrentDirectory(root);
var translator = new Translator(Metadata.Load("translator/metadata/mage_arcane.json"));
var scratch = Path.Combine(root, "translator/Kairos.Translator.Tests/obj/verification");
Directory.CreateDirectory(scratch);
int passed = 0, failed = 0;
void Test(string name, Action test)
{
    try { test(); passed++; Console.WriteLine($"PASS {name}"); }
    catch (Exception e) { failed++; Console.Error.WriteLine($"FAIL {name}: {e.Message}"); }
}
void Equal<T>(T expected, T actual)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
    {
        if (expected is string e && actual is string a && (e.Length > 200 || a.Length > 200))
        {
            int i = 0;
            while (i < Math.Min(e.Length, a.Length) && e[i] == a[i]) i++;
            throw new Exception($"Text differs at offset {i}; expected length {e.Length}, actual {a.Length}");
        }
        throw new Exception($"Expected {expected}; got {actual}");
    }
}
void Throws<T>(Action test) where T : Exception
{
    try { test(); } catch (T) { return; }
    throw new Exception($"Expected {typeof(T).Name}");
}
string Normalize(string text) => text.Replace("\r\n", "\n");
foreach (var fixture in new[] { "mage_arcane", "control" })
{
    Test($"golden Lua and coverage: {fixture}", () =>
    {
        var result = translator.Translate(File.ReadAllText($"translator/fixtures/{fixture}.simc"));
        Equal(Normalize(File.ReadAllText($"translator/golden/{fixture}/APL.lua")), result.Lua);
        Equal(Normalize(File.ReadAllText($"translator/golden/{fixture}/coverage.json")), result.Report);
        File.WriteAllText(Path.Combine(scratch, fixture + ".lua"), result.Lua);
    });
}

var expressionCompiler = new ExpressionCompiler(name => name switch { "a" => "a", "b" => "b", "c" => "c", _ => null });
var expressions = new (string Input, string Lua, int Expected)[]
{
    ("0", "0", 0),
    ("2+3*4", "(2 + (3 * 4))", 14),
    ("(2+3)*4", "((2 + 3) * 4)", 20),
    ("10-3-2", "((10 - 3) - 2)", 5),
    ("!0", "N(not T(0))", 1),
    ("!2", "N(not T(2))", 0),
    ("0&3", "N(T(0) and T(3))", 0),
    ("0|3", "N(T(0) or T(3))", 1),
    ("1|0&0", "N(T(1) or T(N(T(0) and T(0))))", 1),
    ("1^1", "N(T(1) ~= T(1))", 0),
    ("1^0", "N(T(1) ~= T(0))", 1),
    ("3*(!0)", "(3 * N(not T(0)))", 3),
    ("a>=b&c=0", "N(T(N(a >= b)) and T(N(c == 0)))", 1),
    ("a!=b", "N(a ~= b)", 1),
    ("a<=b", "N(a <= b)", 0),
    ("a==3", "N(a == 3)", 1),
    ("-a+ +b", "((-a) + b)", -1),
    ("0.95<1", "N(0.95 < 1)", 1)
};
foreach (var example in expressions)
    Test("expression: " + example.Input, () => Equal(example.Lua, expressionCompiler.Compile(example.Input)));
foreach (var malformed in new[] { "", "a+", "(a", "a)", "a b", "a&&b", "a?b", "a/2", "a%2", "a**b" })
    Test("reject expression: " + malformed, () => Throws<FormatException>(() => expressionCompiler.Compile(malformed)));
Test("unbound identifier is explicit", () => Throws<NotSupportedException>(() => expressionCompiler.Compile("unbound.name")));
Test("compiler can be reused after a failure", () => Equal("(a + b)", expressionCompiler.Compile(" a + b ")));
Test("all identifiers reported after first unsupported binding", () =>
{
    var result = translator.Translate("actions=arcane_blast,if=missing.one&missing.two");
    Equal(2, result.Coverage.Count(c => c.Kind == "binding" && c.Status == "unsupported"));
    Equal(false, result.Lua.Contains("spellID = 30451"));
});
Test("no option silently ignored", () =>
{
    foreach (var option in new[] { "line_cd=999", "target_if=active_enemies", "chain=0", "op=add", "use_off_gcd=2", "name=bogus", "value=1" })
    {
        var result = translator.Translate("actions=arcane_blast," + option);
        Equal(true, result.Coverage.Any(c => c.Kind == "option" && c.Status == "unsupported"));
        Equal(false, result.Lua.Contains("spellID = 30451"));
    }
});
Test("unsupported variable does not become a zero-valued binding", () =>
{
    var result = translator.Translate("actions.precombat=variable,name=x,op=add,value=1\nactions=arcane_blast,if=variable.x");
    Equal(true, result.Coverage.Any(c => c.Kind == "binding" && c.Text == "variable.x" && c.Status == "unsupported"));
});
Test("unsupported action types reported", () =>
{
    foreach (var action in new[] { "run_action_list,name=x", "potion", "use_item,name=x", "use_items", "cancel_action", "invoke_external_buff,name=x" })
        Equal(true, translator.Translate("actions=" + action).Coverage.Any(c => c.Kind == "action" && c.Status == "unsupported"));
});
Test("missing list reported", () => Equal(true, translator.Translate("actions=call_action_list,name=missing")
    .Coverage.Any(c => c.Kind == "action" && c.Status == "unsupported")));
Test("recursive calls rejected", () => Throws<NotSupportedException>(() => translator.Translate("actions=call_action_list,name=a\nactions.a=call_action_list,name=default")));
Test("malformed assignments rejected", () => Throws<FormatException>(() => translator.Translate("actions+=/arcane_blast,bogus")));
Test("list redefinition rejected", () => Throws<NotSupportedException>(() => translator.Translate("actions=arcane_blast\nactions=arcane_barrage")));
Test("fixture action coverage is exhaustive", () =>
{
    var source = File.ReadAllText("translator/fixtures/mage_arcane.simc");
    var result = translator.Translate(source);
    Equal(SimcParser.Parse(source).Count, result.Coverage.Count(c => c.Kind == "action"));
    Equal(7, result.Coverage.Count(c => c.Kind == "action" && c.List == "sunfury" && c.Status == "bound"));
    Equal(2, result.Coverage.Count(c => c.Kind == "action" && c.List == "cooldowns" && c.Status == "bound"));
    Equal(true, result.Coverage.Any(c => c.Kind == "option" && c.Text == "chain=1" && c.Status == "approximated"));
});

// Execute the compiled expressions in a real Lua runtime, including short-circuit tests.
var checks = new List<string>
{
    "local function T(v) return v ~= nil and v ~= false and v ~= 0 end",
    "local function N(v) return T(v) and 1 or 0 end",
    "local a,b,c = 3,2,0"
};
foreach (var example in expressions)
    checks.Add($"assert(({expressionCompiler.Compile(example.Input)}) == {example.Expected}, \"expression {checks.Count}\")");
var shortCircuit = new ExpressionCompiler(n => n == "explode" ? "error('must short circuit')" : null);
checks.Add($"assert(({shortCircuit.Compile("0&explode")}) == 0)");
checks.Add($"assert(({shortCircuit.Compile("1|explode")}) == 1)");
File.WriteAllLines(Path.Combine(scratch, "expressions.lua"), checks);

Test("Lua expression semantics and APL parity", () =>
{
    string? lua = args.Length == 2 && args[0] == "--lua" ? args[1] : Environment.GetEnvironmentVariable("LUA_EXE");
    if (lua is null)
    {
        var extensions = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".vscode/extensions");
        if (Directory.Exists(extensions))
            lua = Directory.GetFiles(extensions, "lua-language-server.exe", SearchOption.AllDirectories).FirstOrDefault();
    }
    lua ??= "lua";
    var info = new ProcessStartInfo(lua) { WorkingDirectory = root, UseShellExecute = false };
    info.ArgumentList.Add("translator/Kairos.Translator.Tests/verify.lua");
    info.ArgumentList.Add(scratch.Replace('\\', '/'));
    using var process = Process.Start(info) ?? throw new Exception("Could not start Lua");
    if (!process.WaitForExit(60_000)) { process.Kill(); throw new Exception("Lua tests timed out"); }
    Equal(0, process.ExitCode);
});
Console.WriteLine($"{passed} passed; {failed} failed.");
return failed == 0 ? 0 : 1;
