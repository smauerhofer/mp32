namespace Mp32.Core;

public enum Severity { Warning, Error }

/// <summary>
/// A message in the format Visual Studio and MSBuild understand:
/// <c>file(line,col): error CODE: text</c>.
/// </summary>
public sealed record Diagnostic(Severity Severity, string Code, string Message, string File = "", int Line = 0, int Column = 0)
{
    public override string ToString()
    {
        var where = File.Length == 0 ? "" :
            Line == 0 ? $"{File}: " :
            Column == 0 ? $"{File}({Line}): " : $"{File}({Line},{Column}): ";
        var sev = Severity == Severity.Error ? "error" : "warning";
        return $"{where}{sev} {Code}: {Message}";
    }
}

public sealed class DiagnosticBag
{
    private readonly List<Diagnostic> _items = [];
    public IReadOnlyList<Diagnostic> Items => _items;
    public bool HasErrors => _items.Any(d => d.Severity == Severity.Error);
    public int ErrorCount => _items.Count(d => d.Severity == Severity.Error);

    public void Add(Diagnostic d) => _items.Add(d);

    public void Error(string code, string message, string file = "", int line = 0, int column = 0) =>
        _items.Add(new Diagnostic(Severity.Error, code, message, file, line, column));

    public void Warning(string code, string message, string file = "", int line = 0, int column = 0) =>
        _items.Add(new Diagnostic(Severity.Warning, code, message, file, line, column));

    public void WriteTo(TextWriter w)
    {
        foreach (var d in _items) w.WriteLine(d);
    }
}
