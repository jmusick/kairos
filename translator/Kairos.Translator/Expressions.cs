using System.Text.RegularExpressions;

namespace Kairos.Translator;

// All expressions produce numbers. SimC's false/true are 0/1; Lua's 0 is truthy.
// N converts a Lua predicate to a SimC number, T converts a number to a predicate.
public sealed class ExpressionCompiler(Func<string, string?> bind)
{
    private static readonly Regex Token = new(@"\G\s*(?:(?<number>\d+(?:\.\d+)?)|(?<name>[a-zA-Z_][a-zA-Z_0-9.]*)|(?<op>>=|<=|<\?|>\?|!=|==|[()+*<>=!&|^+\-]))");
    private readonly List<string> tokens = [];
    private int position;
    public HashSet<string> Identifiers { get; } = new(StringComparer.Ordinal);
    // The last expression's top-level `|` clauses, compiled; one entry when there is no
    // top-level `|`. Reports use them to say which clause of a condition fired.
    public List<string> Clauses { get; } = [];

    public string Compile(string input)
    {
        tokens.Clear(); Identifiers.Clear(); Clauses.Clear(); position = 0;
        for (int offset = 0; offset < input.TrimEnd().Length;)
        {
            var match = Token.Match(input, offset);
            if (!match.Success) throw new FormatException($"Invalid expression at {offset}: {input}");
            tokens.Add(match.Groups["number"].Success ? match.Groups["number"].Value
                : match.Groups["name"].Success ? match.Groups["name"].Value : match.Groups["op"].Value);
            offset = match.Index + match.Length;
        }
        var result = Parse(0, top: true);
        if (position != tokens.Count) throw new FormatException($"Unexpected token {tokens[position]}");
        if (Clauses.Count == 0) Clauses.Add(result);
        return result;
    }

    private static int Precedence(string op) => op switch
    {
        "|" => 1, "^" => 2, "&" => 3,
        "=" or "==" or "!=" or "<" or ">" or "<=" or ">=" => 4,
        "<?" or ">?" => 5, "+" or "-" => 6, "*" => 7, _ => -1
    };

    // At the top level, `|` has the lowest precedence, so everything before the first `|`
    // is the first clause and each right operand of a top-level `|` is one more clause.
    private string Parse(int minimum, bool top = false)
    {
        if (position == tokens.Count) throw new FormatException("Expected operand");
        var token = tokens[position++];
        string left;
        if (token is "!" or "-" or "+")
        {
            var operand = Parse(8);
            left = token switch { "!" => $"N(not T({operand}))", "+" => operand, _ => $"(-{operand})" };
        }
        else if (token == "(")
        {
            left = Parse(0);
            if (position == tokens.Count || tokens[position++] != ")") throw new FormatException("Expected )");
        }
        else if (char.IsDigit(token[0])) left = token;
        else if (char.IsLetter(token[0]) || token[0] == '_')
        {
            Identifiers.Add(token);
            left = bind(token) ?? throw new NotSupportedException($"Unbound expression: {token}");
        }
        else throw new FormatException($"Expected operand, got {token}");

        while (position < tokens.Count && Precedence(tokens[position]) >= minimum)
        {
            var op = tokens[position++];
            var right = Parse(Precedence(op) + 1);
            if (top && op == "|")
            {
                if (Clauses.Count == 0) Clauses.Add(left);
                Clauses.Add(right);
            }
            left = op switch
            {
                "&" => $"N(T({left}) and T({right}))",
                "|" => $"N(T({left}) or T({right}))",
                "^" => $"N(T({left}) ~= T({right}))",
                "=" or "==" => $"N({left} == {right})",
                "!=" => $"N({left} ~= {right})",
                "<" or ">" or "<=" or ">=" => $"N({left} {op} {right})",
                // SimC's `<?` is max and `>?` is min (engine/sim/expressions.cpp).
                "<?" => $"math.max({left}, {right})",
                ">?" => $"math.min({left}, {right})",
                _ => $"({left} {op} {right})"
            };
        }
        return left;
    }
}
