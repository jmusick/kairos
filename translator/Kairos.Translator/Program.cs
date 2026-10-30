using Kairos.Translator;

if (args.Length != 3)
{
    Console.Error.WriteLine("Usage: Kairos.Translator <input.simc> <metadata.json> <output-directory>");
    return 1;
}
try
{
    var result = new Translator(Metadata.Load(args[1])).Translate(File.ReadAllText(args[0]));
    Directory.CreateDirectory(args[2]);
    File.WriteAllText(Path.Combine(args[2], "APL.lua"), result.Lua);
    File.WriteAllText(Path.Combine(args[2], "coverage.json"), result.Report);
    var unsupported = result.Coverage.Count(c => c.Status == "unsupported");
    Console.WriteLine($"Generated partial APL.lua and coverage.json ({unsupported} unsupported records).");
    // 2 means output is partial and must not be mistaken for a complete translation.
    return unsupported == 0 ? 0 : 2;
}
catch (Exception e) when (e is IOException or FormatException or NotSupportedException or System.Text.Json.JsonException)
{
    Console.Error.WriteLine(e.Message);
    return 1;
}
