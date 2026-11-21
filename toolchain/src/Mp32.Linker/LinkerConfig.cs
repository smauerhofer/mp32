using System.Globalization;
using System.Text;

namespace Mp32.Linker;

public enum SegmentType { ReadOnly, ReadWrite, Bss }

public sealed class MemoryArea
{
    public required string Name { get; init; }
    public long Start { get; set; }
    public long Size { get; set; }
    /// <summary>Output file; "%O" is replaced by the -o name. Null: the area is not written.</summary>
    public string? File { get; set; }
    /// <summary>Write the whole area (true), or only up to the last byte with contents.</summary>
    public bool Fill { get; set; }
    public byte FillValue { get; set; }
    /// <summary>hex (one 16-byte line per row, for $readmemh into bram.v), hex32 (one word per row), or bin.</summary>
    public string? Format { get; set; }
    public bool Define { get; set; }

    // set by the linker
    public long Used { get; set; }
    public long ContentEnd { get; set; }
    public byte[] Image { get; set; } = [];
}

public sealed class SegmentDef
{
    public required string Name { get; init; }
    public required string Load { get; set; }
    public SegmentType Type { get; set; } = SegmentType.ReadOnly;
    public int Align { get; set; } = Mp32.Core.Isa.LineSize;
    public long? Start { get; set; }
    public bool Define { get; set; }

    // set by the linker
    public MemoryArea? Memory { get; set; }
    public long Address { get; set; }
    public long Size { get; set; }
}

/// <summary>
/// The linker configuration, in the style of ld65:
/// <code>
/// MEMORY {
///     BRAM: start = $F0000000, size = $2000, file = "%O", fill = yes;
/// }
/// SEGMENTS {
///     CODE: load = BRAM, type = ro;
///     BSS:  load = BRAM, type = bss, define = yes;
/// }
/// </code>
/// </summary>
public sealed class LinkerConfig
{
    public List<MemoryArea> Memory { get; } = [];
    public List<SegmentDef> Segments { get; } = [];

    public const string Default = """
        # The default configuration: everything in the block RAM the mp32 boots from
        # (8 KB at $F0000000), written as a $readmemh file for BRAM_INIT of membus.v.
        MEMORY {
            BRAM:  start = $F0000000, size = $2000, file = "%O", fill = yes, format = hex;
            SDRAM: start = $00000000, size = $800000;
        }
        SEGMENTS {
            CODE:   load = BRAM, type = ro;
            RODATA: load = BRAM, type = ro;
            DATA:   load = BRAM, type = rw;
            BSS:    load = BRAM, type = bss, define = yes;
            HEAP:   load = SDRAM, type = bss, define = yes;
        }
        """;

    public MemoryArea? FindMemory(string name) =>
        Memory.FirstOrDefault(m => string.Equals(m.Name, name, StringComparison.OrdinalIgnoreCase));

    public SegmentDef? FindSegment(string name) =>
        Segments.FirstOrDefault(s => string.Equals(s.Name, name, StringComparison.OrdinalIgnoreCase));

    // ------------------------------------------------------------------ parser

    private sealed record Tok(string Kind, string Text, long Num, int Line);

    public static LinkerConfig Parse(string text, string fileName)
    {
        var toks = Tokenize(text, fileName);
        var cfg = new LinkerConfig();
        int i = 0;
        Tok Peek() => toks[i];
        Tok Take() => toks[i++];
        Tok Expect(string kind, string what)
        {
            var t = Take();
            if (t.Kind != kind) throw new ConfigException($"{what} expected, got '{t.Text}'", fileName, t.Line);
            return t;
        }

        while (Peek().Kind != "end")
        {
            var block = Expect("id", "MEMORY or SEGMENTS");
            var bname = block.Text.ToUpperInvariant();
            if (bname is not ("MEMORY" or "SEGMENTS"))
                throw new ConfigException($"unknown block '{block.Text}' (MEMORY or SEGMENTS)", fileName, block.Line);
            Expect("{", "'{'");
            while (Peek().Kind != "}")
            {
                var name = Expect("id", "a name");
                Expect(":", "':'");
                var attrs = new List<(Tok Key, Tok Value)>();
                while (true)
                {
                    var key = Expect("id", "an attribute");
                    Expect("=", "'='");
                    var val = Take();
                    if (val.Kind is not ("id" or "num" or "str"))
                        throw new ConfigException($"value expected for '{key.Text}'", fileName, val.Line);
                    attrs.Add((key, val));
                    if (Peek().Kind == ",") { i++; continue; }
                    break;
                }
                Expect(";", "';'");
                if (bname == "MEMORY") cfg.Memory.Add(MakeMemory(name, attrs, fileName));
                else cfg.Segments.Add(MakeSegment(name, attrs, fileName));
            }
            Expect("}", "'}'");
        }

        foreach (var g in cfg.Memory.GroupBy(m => m.Name, StringComparer.OrdinalIgnoreCase).Where(g => g.Count() > 1))
            throw new ConfigException($"memory area {g.Key} is defined twice", fileName);
        foreach (var g in cfg.Segments.GroupBy(m => m.Name, StringComparer.OrdinalIgnoreCase).Where(g => g.Count() > 1))
            throw new ConfigException($"segment {g.Key} is defined twice", fileName);
        foreach (var s in cfg.Segments)
            s.Memory = cfg.FindMemory(s.Load) ?? throw new ConfigException($"segment {s.Name}: no memory area '{s.Load}'", fileName);
        return cfg;
    }

    private static MemoryArea MakeMemory(Tok name, List<(Tok Key, Tok Value)> attrs, string file)
    {
        var m = new MemoryArea { Name = name.Text };
        bool hasStart = false, hasSize = false;
        foreach (var (k, v) in attrs)
        {
            switch (k.Text.ToLowerInvariant())
            {
                case "start": m.Start = Num(v, file); hasStart = true; break;
                case "size": m.Size = Num(v, file); hasSize = true; break;
                case "file": m.File = v.Text; break;
                case "fill": m.Fill = YesNo(v, file); break;
                case "fillval":
                    var f = Num(v, file);
                    if (f is < 0 or > 255) throw new ConfigException("fillval must be a byte", file, v.Line);
                    m.FillValue = (byte)f;
                    break;
                case "format":
                    var fmt = v.Text.ToLowerInvariant();
                    if (fmt is not ("hex" or "hex32" or "bin"))
                        throw new ConfigException($"unknown format '{v.Text}' (hex, hex32, bin)", file, v.Line);
                    m.Format = fmt;
                    break;
                case "define": m.Define = YesNo(v, file); break;
                default: throw new ConfigException($"unknown memory attribute '{k.Text}'", file, k.Line);
            }
        }
        if (!hasStart || !hasSize) throw new ConfigException($"memory area {m.Name} needs start and size", file, name.Line);
        if (m.Size <= 0 || m.Start < 0 || m.Start + m.Size > 0x1_0000_0000L)
            throw new ConfigException($"memory area {m.Name} is outside the 32-bit address space", file, name.Line);
        return m;
    }

    private static SegmentDef MakeSegment(Tok name, List<(Tok Key, Tok Value)> attrs, string file)
    {
        string? load = null;
        var s = new SegmentDef { Name = name.Text, Load = "" };
        foreach (var (k, v) in attrs)
        {
            switch (k.Text.ToLowerInvariant())
            {
                case "load": load = v.Text; break;
                case "type":
                    s.Type = v.Text.ToLowerInvariant() switch
                    {
                        "ro" => SegmentType.ReadOnly,
                        "rw" => SegmentType.ReadWrite,
                        "bss" => SegmentType.Bss,
                        _ => throw new ConfigException($"unknown segment type '{v.Text}' (ro, rw, bss)", file, v.Line),
                    };
                    break;
                case "align":
                    var a = Num(v, file);
                    if (a < 1 || a > 0x10000 || (a & (a - 1)) != 0)
                        throw new ConfigException("align must be a power of two", file, v.Line);
                    s.Align = (int)a;
                    break;
                case "start": s.Start = Num(v, file); break;
                case "define": s.Define = YesNo(v, file); break;
                default: throw new ConfigException($"unknown segment attribute '{k.Text}'", file, k.Line);
            }
        }
        s.Load = load ?? throw new ConfigException($"segment {s.Name} needs load = <memory area>", file, name.Line);
        if (s.Align < Mp32.Core.Isa.LineSize && s.Type != SegmentType.Bss)
            s.Align = Mp32.Core.Isa.LineSize; // code must start on a fetch line
        return s;
    }

    private static long Num(Tok t, string file) =>
        t.Kind == "num" ? t.Num : throw new ConfigException($"number expected, got '{t.Text}'", file, t.Line);

    private static bool YesNo(Tok t, string file) => t.Text.ToLowerInvariant() switch
    {
        "yes" or "true" => true,
        "no" or "false" => false,
        _ => throw new ConfigException($"yes or no expected, got '{t.Text}'", file, t.Line),
    };

    private static List<Tok> Tokenize(string text, string file)
    {
        var list = new List<Tok>();
        int line = 1, i = 0;
        while (i < text.Length)
        {
            char c = text[i];
            if (c == '\n') { line++; i++; continue; }
            if (char.IsWhiteSpace(c)) { i++; continue; }
            if (c == '#') { while (i < text.Length && text[i] != '\n') i++; continue; }
            if ("{}:=,;".Contains(c)) { list.Add(new Tok(c.ToString(), c.ToString(), 0, line)); i++; continue; }
            if (c == '"')
            {
                int s = ++i;
                while (i < text.Length && text[i] != '"' && text[i] != '\n') i++;
                if (i >= text.Length || text[i] != '"') throw new ConfigException("unterminated string", file, line);
                list.Add(new Tok("str", text[s..i], 0, line));
                i++;
                continue;
            }
            if (c == '$' || char.IsDigit(c))
            {
                int s = i;
                if (c == '$') i++;
                else if (c == '0' && i + 1 < text.Length && text[i + 1] is 'x' or 'X') i += 2;
                while (i < text.Length && (char.IsLetterOrDigit(text[i]) || text[i] == '_')) i++;
                var raw = text[s..i].Replace("_", "");
                long mult = 1;
                if (raw.EndsWith('K') || raw.EndsWith('k')) { mult = 1024; raw = raw[..^1]; }
                else if (raw.EndsWith('M') && !raw.StartsWith('$') && !raw.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
                { mult = 1024 * 1024; raw = raw[..^1]; }
                bool ok = raw.StartsWith('$') ? long.TryParse(raw[1..], NumberStyles.HexNumber, null, out var v)
                    : raw.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ? long.TryParse(raw[2..], NumberStyles.HexNumber, null, out v)
                    : long.TryParse(raw, out v);
                if (!ok) throw new ConfigException($"bad number '{text[s..i]}'", file, line);
                list.Add(new Tok("num", text[s..i], v * mult, line));
                continue;
            }
            if (char.IsLetter(c) || c is '_' or '%' or '.')
            {
                int s = i++;
                while (i < text.Length && (char.IsLetterOrDigit(text[i]) || text[i] is '_' or '.' or '%')) i++;
                list.Add(new Tok("id", text[s..i], 0, line));
                continue;
            }
            throw new ConfigException($"unexpected character '{c}'", file, line);
        }
        list.Add(new Tok("end", "end of file", 0, line));
        return list;
    }

    public override string ToString()
    {
        var sb = new StringBuilder();
        sb.AppendLine("MEMORY {");
        foreach (var m in Memory)
            sb.AppendLine($"    {m.Name}: start = ${m.Start:X8}, size = ${m.Size:X}{(m.File is null ? "" : $", file = \"{m.File}\"")}{(m.Fill ? ", fill = yes" : "")};");
        sb.AppendLine("}");
        sb.AppendLine("SEGMENTS {");
        foreach (var s in Segments)
            sb.AppendLine($"    {s.Name}: load = {s.Load}, type = {s.Type switch { SegmentType.Bss => "bss", SegmentType.ReadWrite => "rw", _ => "ro" }}, align = {s.Align};");
        sb.AppendLine("}");
        return sb.ToString();
    }
}

public sealed class ConfigException(string message, string file, int line = 0) : Exception(message)
{
    public string File { get; } = file;
    public int Line { get; } = line;
}
