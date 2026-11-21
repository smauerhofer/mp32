using System.Text;
using Mp32.Core;

namespace Mp32.Linker;

public sealed class LinkerOptions
{
    public LinkerConfig Config { get; set; } = LinkerConfig.Parse(LinkerConfig.Default, "<default config>");
    /// <summary>The -o name: replaces "%O" in the file attributes of the memory areas.</summary>
    public string Output { get; set; } = "a.hex";
    public Dictionary<string, long> Defines { get; } = new(StringComparer.Ordinal);
}

/// <summary>
/// The mp32 linker: takes object modules (all of them) and libraries (only the
/// members that define a symbol still needed), places the sections into the
/// segments and memory areas of the configuration, fills in the relocations and
/// writes one image for each memory area with a file attribute.
/// </summary>
public sealed class Linker(LinkerOptions options)
{
    private const string Code = "LD";

    private sealed class LinkedModule(ObjectModule module, string origin)
    {
        public ObjectModule Module { get; } = module;
        /// <summary>Where it came from: a file, or "lib.lib(member.o)".</summary>
        public string Origin { get; } = origin;
        public long[] SectionAddress { get; } = new long[module.Sections.Count];
    }

    private sealed record GlobalDef(LinkedModule? Module, ObjSymbol? Symbol, long Value);

    private readonly List<LinkedModule> _modules = [];
    private readonly List<(string Path, Library Lib, Dictionary<string, LibraryMember> Index)> _libs = [];
    private readonly HashSet<LibraryMember> _pulled = [];
    private readonly Dictionary<string, GlobalDef> _globals = new(StringComparer.Ordinal);
    private readonly Dictionary<string, long> _linkerSymbols = new(StringComparer.Ordinal);

    public DiagnosticBag Diagnostics { get; } = new();
    public LinkerConfig Config => options.Config;

    public void AddObject(ObjectModule m, string origin) => _modules.Add(new LinkedModule(m, origin));

    public void AddLibrary(Library lib, string path) => _libs.Add((path, lib, lib.BuildIndex()));

    public void AddFile(string path)
    {
        var bytes = File.ReadAllBytes(path);
        if (ObjectModule.IsObject(bytes)) AddObject(ObjectModule.Read(bytes, path), path);
        else if (Library.IsLibrary(bytes)) AddLibrary(Library.Read(path), path);
        else throw new InvalidDataException($"{path}: not an mp32 object file or library");
    }

    /// <summary>Links everything added. Returns false on errors (see <see cref="Diagnostics"/>).</summary>
    public bool Link()
    {
        DefineLinkerSymbolNames();
        Resolve();
        if (Diagnostics.HasErrors) return false;
        Place();
        if (Diagnostics.HasErrors) return false;
        ComputeLinkerSymbols();
        BuildImages();
        Relocate();
        return !Diagnostics.HasErrors;
    }

    // ------------------------------------------------------------------ symbols

    private IEnumerable<(string Name, Func<long> Value)> LinkerSymbolSources()
    {
        foreach (var s in Config.Segments.Where(s => s.Define))
        {
            var seg = s;
            yield return ($"__{seg.Name}_START__", () => seg.Address);
            yield return ($"__{seg.Name}_SIZE__", () => seg.Size);
            yield return ($"__{seg.Name}_END__", () => seg.Address + seg.Size);
        }
        foreach (var m in Config.Memory.Where(m => m.Define))
        {
            var mem = m;
            yield return ($"__{mem.Name}_START__", () => mem.Start);
            yield return ($"__{mem.Name}_SIZE__", () => mem.Size);
            yield return ($"__{mem.Name}_END__", () => mem.Start + mem.Size);
        }
    }

    private void DefineLinkerSymbolNames()
    {
        foreach (var (name, value) in options.Defines)
            _globals[name] = new GlobalDef(null, null, value);
        foreach (var (name, _) in LinkerSymbolSources())
            _globals.TryAdd(name, new GlobalDef(null, null, 0));
    }

    private void ComputeLinkerSymbols()
    {
        foreach (var (name, value) in LinkerSymbolSources())
            if (_globals[name].Module is null && !options.Defines.ContainsKey(name))
                _linkerSymbols[name] = value();
    }

    private void Include(LinkedModule lm)
    {
        foreach (var s in lm.Module.Exports)
        {
            if (_globals.TryGetValue(s.Name, out var other))
            {
                var where = other.Module?.Origin ?? "the linker (-D or a segment symbol)";
                Diagnostics.Error(Code, $"symbol '{s.Name}' is defined in {lm.Origin} and in {where}");
                continue;
            }
            _globals[s.Name] = new GlobalDef(lm, s, 0);
        }
    }

    private void Resolve()
    {
        foreach (var m in _modules) Include(m);

        bool progress = true;
        while (progress)
        {
            progress = false;
            var needed = _modules.SelectMany(m => m.Module.Imports).Select(s => s.Name)
                .Where(n => !_globals.ContainsKey(n)).Distinct().ToList();
            if (needed.Count == 0) break;
            foreach (var name in needed)
            {
                if (_globals.ContainsKey(name)) continue;
                foreach (var (path, _, index) in _libs)
                {
                    if (!index.TryGetValue(name, out var member) || !_pulled.Add(member)) continue;
                    var lm = new LinkedModule(member.Module, $"{path}({member.Name})");
                    _modules.Add(lm);
                    Include(lm);
                    progress = true;
                    break;
                }
            }
        }

        foreach (var m in _modules)
            foreach (var s in m.Module.Imports)
                if (!_globals.ContainsKey(s.Name))
                {
                    var r = m.Module.Sections.SelectMany(x => x.Relocs)
                        .FirstOrDefault(x => x.SymbolIndex == m.Module.Symbols.IndexOf(s));
                    if (r is not null)
                        Diagnostics.Error(Code, $"undefined symbol '{s.Name}'", r.SourceFile, r.SourceLine);
                    else
                        Diagnostics.Error(Code, $"undefined symbol '{s.Name}' (imported by {m.Origin})");
                }
    }

    // ------------------------------------------------------------------ placement

    private void Place()
    {
        foreach (var m in _modules)
            foreach (var sec in m.Module.Sections)
            {
                if (sec.Size == 0 && sec.Relocs.Count == 0 && Config.FindSegment(sec.Name) is null) continue;
                var seg = Config.FindSegment(sec.Name);
                if (seg is null)
                    Diagnostics.Error(Code, $"{m.Origin}: segment '{sec.Name}' is not in the linker configuration");
                else if (seg.Type == SegmentType.Bss && !sec.IsBss && sec.Data.Any(b => b != 0))
                    Diagnostics.Error(Code, $"{m.Origin}: segment '{sec.Name}' is BSS in the configuration but has contents");
            }
        if (Diagnostics.HasErrors) return;

        foreach (var mem in Config.Memory)
        {
            long pos = mem.Start;
            foreach (var seg in Config.Segments.Where(s => s.Memory == mem))
            {
                if (seg.Start is { } start)
                {
                    if (start < pos)
                        Diagnostics.Error(Code, $"segment {seg.Name}: start ${start:X8} overlaps what comes before it in {mem.Name} (up to ${pos:X8})");
                    pos = start;
                }
                pos = AlignUp(pos, seg.Align);
                seg.Address = pos;
                foreach (var m in _modules)
                    for (int i = 0; i < m.Module.Sections.Count; i++)
                    {
                        var sec = m.Module.Sections[i];
                        if (!string.Equals(sec.Name, seg.Name, StringComparison.OrdinalIgnoreCase)) continue;
                        pos = AlignUp(pos, sec.Align);
                        m.SectionAddress[i] = pos;
                        pos += sec.Size;
                    }
                seg.Size = pos - seg.Address;
                if (seg.Type != SegmentType.Bss && seg.Size > 0) mem.ContentEnd = Math.Max(mem.ContentEnd, pos - mem.Start);
            }
            mem.Used = pos - mem.Start;
            if (mem.Used > mem.Size)
                Diagnostics.Error(Code, $"memory area {mem.Name} overflows by {mem.Used - mem.Size} bytes (size ${mem.Size:X}, used ${mem.Used:X})");
        }
    }

    private static long AlignUp(long v, long a) => (v + a - 1) / a * a;

    // ------------------------------------------------------------------ images and relocation

    private void BuildImages()
    {
        foreach (var mem in Config.Memory)
        {
            mem.Image = new byte[mem.ContentEnd];
            if (mem.FillValue != 0) Array.Fill(mem.Image, mem.FillValue);
        }
        foreach (var m in _modules)
            for (int i = 0; i < m.Module.Sections.Count; i++)
            {
                var sec = m.Module.Sections[i];
                var mem = Config.FindSegment(sec.Name)?.Memory;
                if (mem is null || sec.IsBss || sec.Size == 0 || Config.FindSegment(sec.Name)!.Type == SegmentType.Bss) continue;
                sec.Data.AsSpan(0, sec.Size).CopyTo(mem.Image.AsSpan((int)(m.SectionAddress[i] - mem.Start)));
            }
    }

    private long SymbolValue(LinkedModule m, ObjSymbol s)
    {
        switch (s.Kind)
        {
            case SymbolKind.Section:
                return m.SectionAddress[s.SectionIndex];
            case SymbolKind.Global:
                return s.SectionIndex >= 0 ? m.SectionAddress[s.SectionIndex] + s.Value : s.Value;
            default:
                var g = _globals[s.Name];
                if (g.Module is null)
                    return _linkerSymbols.TryGetValue(s.Name, out var v) ? v : g.Value;
                return SymbolValue(g.Module, g.Symbol!);
        }
    }

    private void Relocate()
    {
        foreach (var m in _modules)
            for (int i = 0; i < m.Module.Sections.Count; i++)
            {
                var sec = m.Module.Sections[i];
                if (sec.Relocs.Count == 0) continue;
                var mem = Config.FindSegment(sec.Name)!.Memory!;
                foreach (var r in sec.Relocs)
                {
                    if (r.SymbolIndex < 0 || r.SymbolIndex >= m.Module.Symbols.Count)
                    {
                        Diagnostics.Error(Code, $"{m.Origin}: bad relocation (symbol {r.SymbolIndex})");
                        continue;
                    }
                    long place = m.SectionAddress[i] + r.Offset;
                    long target = SymbolValue(m, m.Module.Symbols[r.SymbolIndex]) + r.Addend;
                    if (place - mem.Start + Fields.Span(r.Type) > mem.Image.Length)
                    {
                        Diagnostics.Error(Code, $"{m.Origin}: relocation outside the contents of {mem.Name}", r.SourceFile, r.SourceLine);
                        continue;
                    }
                    var err = Fields.Apply(mem.Image, (int)(place - mem.Start), r.Type, target, place);
                    if (err is not null)
                    {
                        var sym = m.Module.Symbols[r.SymbolIndex];
                        var what = sym.Kind == SymbolKind.Section ? "" : $" (symbol '{sym.Name}')";
                        if (r.Type is RelocType.Lit8 or RelocType.Lit16 or RelocType.Lit24)
                            what += "; for an address use LEA, which is PC-relative";
                        Diagnostics.Error(Code, err + what, r.SourceFile, r.SourceLine);
                    }
                }
            }
    }

    // ------------------------------------------------------------------ output

    /// <summary>The files to write: path and contents.</summary>
    public IEnumerable<(string Path, byte[] Contents)> Outputs()
    {
        foreach (var mem in Config.Memory.Where(m => m.File is not null))
        {
            var path = mem.File!.Replace("%O", options.Output);
            var format = mem.Format ?? Path.GetExtension(path).ToLowerInvariant() switch
            {
                ".hex" or ".mem" => "hex",
                _ => "bin",
            };
            long len = mem.Fill ? mem.Size : mem.ContentEnd;
            var image = new byte[len];
            if (mem.FillValue != 0) Array.Fill(image, mem.FillValue);
            mem.Image.AsSpan().CopyTo(image);
            yield return (path, format switch
            {
                "hex" => Encoding.ASCII.GetBytes(HexLines(image, 16)),
                "hex32" => Encoding.ASCII.GetBytes(HexLines(image, 4)),
                _ => image,
            });
        }
    }

    /// <summary>
    /// $readmemh text: one row of <paramref name="width"/> bytes, the byte at the
    /// highest address first (byte k of a row is bits 8k+7..8k, as bram.v wants).
    /// </summary>
    public static string HexLines(byte[] image, int width)
    {
        var sb = new StringBuilder();
        for (int row = 0; row < image.Length; row += width)
        {
            for (int k = width - 1; k >= 0; k--)
                sb.Append((row + k < image.Length ? image[row + k] : (byte)0).ToString("x2"));
            sb.Append('\n');
        }
        return sb.ToString();
    }

    public string MapFile()
    {
        var sb = new StringBuilder();
        sb.AppendLine($"mp32ld map for {options.Output}");
        sb.AppendLine();
        sb.AppendLine("Memory areas:");
        sb.AppendLine("  Name        Start     Size      Used      File");
        foreach (var m in Config.Memory)
            sb.AppendLine($"  {m.Name,-10}  {m.Start:X8}  {m.Size,8:X}  {m.Used,8:X}  {m.File?.Replace("%O", options.Output)}");
        sb.AppendLine();
        sb.AppendLine("Segments:");
        sb.AppendLine("  Name        Start     End       Size      Memory   Type");
        foreach (var s in Config.Segments)
            sb.AppendLine($"  {s.Name,-10}  {s.Address:X8}  {(s.Size == 0 ? s.Address : s.Address + s.Size - 1):X8}  {s.Size,8:X}  {s.Load,-8} {s.Type}");
        sb.AppendLine();
        sb.AppendLine("Modules:");
        foreach (var m in _modules)
        {
            sb.AppendLine($"  {m.Origin}");
            for (int i = 0; i < m.Module.Sections.Count; i++)
            {
                var s = m.Module.Sections[i];
                if (s.Size == 0) continue;
                sb.AppendLine($"    {s.Name,-10}  {m.SectionAddress[i]:X8}  size {s.Size:X}");
            }
        }
        var all = new List<(string Name, long Value, string Where)>();
        foreach (var (name, g) in _globals)
        {
            if (g.Module is not null) all.Add((name, SymbolValue(g.Module, g.Symbol!), g.Module.Origin));
            else all.Add((name, _linkerSymbols.TryGetValue(name, out var v) ? v : g.Value, "linker"));
        }
        sb.AppendLine();
        sb.AppendLine("Symbols by name:");
        foreach (var e in all.OrderBy(e => e.Name, StringComparer.Ordinal))
            sb.AppendLine($"  {e.Name,-32}  {e.Value & 0xFFFF_FFFFL:X8}  {e.Where}");
        sb.AppendLine();
        sb.AppendLine("Symbols by address:");
        foreach (var e in all.OrderBy(e => e.Value & 0xFFFF_FFFFL).ThenBy(e => e.Name, StringComparer.Ordinal))
            sb.AppendLine($"  {e.Value & 0xFFFF_FFFFL:X8}  {e.Name}");
        return sb.ToString();
    }
}
