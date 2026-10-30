using Kairos.Translator;

if (args.Length is not (3 or 4))
{
    Console.Error.WriteLine("Usage: Kairos.Translator <input.simc> <metadata.json> <output-directory> [<module.lua>]");
    Console.Error.WriteLine("Writes coverage.json to the output directory, and the Lua module to <module.lua>");
    Console.Error.WriteLine("(the spec's APL.lua in the addon) or, without it, to APL.lua in the output directory.");
    return 1;
}
try
{
    var result = new Translator(Metadata.Load(args[1])).Translate(File.ReadAllText(args[0]));
    Directory.CreateDirectory(args[2]);
    var module = args.Length == 4 ? args[3] : Path.Combine(args[2], "APL.lua");
    File.WriteAllText(module, result.Lua);
    File.WriteAllText(Path.Combine(args[2], "coverage.json"), result.Report);
    var unsupported = result.Coverage.Count(c => c.Status == "unsupported");
    Console.WriteLine($"Generated partial {module} and coverage.json ({unsupported} unsupported records).");
    // 2 means output is partial and must not be mistaken for a complete translation.
    return unsupported == 0 ? 0 : 2;
}
catch (Exception e) when (e is IOException or FormatException or NotSupportedException or System.Text.Json.JsonException)
{
    Console.Error.WriteLine(e.Message);
    return 1;
}
