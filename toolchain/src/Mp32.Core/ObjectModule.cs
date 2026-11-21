using System.Text;

namespace Mp32.Core;

public enum SymbolKind : byte
{
    /// <summary>The start of a section of this module (value 0); relocations use it for local labels.</summary>
    Section = 0,
    /// <summary>An exported symbol defined in this module.</summary>
    Global = 1,
    /// <summary>A symbol this module uses but another module defines.</summary>
    Import = 2,
}

public sealed class ObjSymbol
{
    public required string Name { get; init; }
    public SymbolKind Kind { get; init; }
    /// <summary>Index of the section the value is relative to; -1 for an absolute value or an import.</summary>
    public int SectionIndex { get; init; } = -1;
    public long Value { get; init; }
}

public sealed class ObjReloc
{
    public int Offset { get; init; }
    public RelocType Type { get; init; }
    public int SymbolIndex { get; init; }
    public long Addend { get; init; }
    /// <summary>Where the field came from, for the linker's error messages.</summary>
    public string SourceFile { get; init; } = "";
    public int SourceLine { get; init; }
}

public sealed class ObjSection
{
    /// <summary>The segment name, e.g. CODE, RODATA, DATA, BSS.</summary>
    public required string Name { get; init; }
    public int Align { get; set; } = Isa.LineSize;
    /// <summary>True for a section with no contents (only space): it is not stored in an image.</summary>
    public bool IsBss { get; init; }
    public int Size { get; set; }
    /// <summary>The contents (empty for BSS).</summary>
    public byte[] Data { get; set; } = [];
    public List<ObjReloc> Relocs { get; } = [];
}

/// <summary>An object module (.o): what the assembler writes and the linker reads.</summary>
public sealed class ObjectModule
{
    private static readonly byte[] Magic = "MP32OBJ"u8.ToArray();
    public const byte FormatVersion = 1;

    /// <summary>The module name (the source file name).</summary>
    public string Name { get; set; } = "";
    public List<ObjSection> Sections { get; } = [];
    public List<ObjSymbol> Symbols { get; } = [];

    public IEnumerable<ObjSymbol> Exports => Symbols.Where(s => s.Kind == SymbolKind.Global);
    public IEnumerable<ObjSymbol> Imports => Symbols.Where(s => s.Kind == SymbolKind.Import);

    public byte[] ToBytes()
    {
        using var ms = new MemoryStream();
        Write(ms);
        return ms.ToArray();
    }

    public void Write(Stream stream)
    {
        using var w = new BinaryWriter(stream, Encoding.UTF8, leaveOpen: true);
        w.Write(Magic);
        w.Write(FormatVersion);
        w.Write(Name);
        w.Write(Sections.Count);
        foreach (var s in Sections)
        {
            w.Write(s.Name);
            w.Write(s.Align);
            w.Write(s.IsBss);
            w.Write(s.Size);
            if (!s.IsBss) w.Write(s.Data, 0, s.Size);
            w.Write(s.Relocs.Count);
            foreach (var r in s.Relocs)
            {
                w.Write(r.Offset);
                w.Write((byte)r.Type);
                w.Write(r.SymbolIndex);
                w.Write(r.Addend);
                w.Write(r.SourceFile);
                w.Write(r.SourceLine);
            }
        }
        w.Write(Symbols.Count);
        foreach (var s in Symbols)
        {
            w.Write(s.Name);
            w.Write((byte)s.Kind);
            w.Write(s.SectionIndex);
            w.Write(s.Value);
        }
    }

    public static ObjectModule Read(byte[] bytes, string what) => Read(new MemoryStream(bytes), what);

    public static ObjectModule Read(Stream stream, string what)
    {
        try
        {
            using var r = new BinaryReader(stream, Encoding.UTF8, leaveOpen: true);
            var magic = r.ReadBytes(Magic.Length);
            if (!magic.AsSpan().SequenceEqual(Magic)) throw new InvalidDataException($"{what}: not an mp32 object file");
            var version = r.ReadByte();
            if (version != FormatVersion)
                throw new InvalidDataException($"{what}: object format version {version}, expected {FormatVersion}");
            var m = new ObjectModule { Name = r.ReadString() };
            int nsec = r.ReadInt32();
            for (int i = 0; i < nsec; i++)
            {
                var s = new ObjSection { Name = r.ReadString(), Align = r.ReadInt32(), IsBss = r.ReadBoolean() };
                s.Size = r.ReadInt32();
                s.Data = s.IsBss ? [] : r.ReadBytes(s.Size);
                int nrel = r.ReadInt32();
                for (int j = 0; j < nrel; j++)
                {
                    s.Relocs.Add(new ObjReloc
                    {
                        Offset = r.ReadInt32(),
                        Type = (RelocType)r.ReadByte(),
                        SymbolIndex = r.ReadInt32(),
                        Addend = r.ReadInt64(),
                        SourceFile = r.ReadString(),
                        SourceLine = r.ReadInt32(),
                    });
                }
                m.Sections.Add(s);
            }
            int nsym = r.ReadInt32();
            for (int i = 0; i < nsym; i++)
            {
                m.Symbols.Add(new ObjSymbol
                {
                    Name = r.ReadString(),
                    Kind = (SymbolKind)r.ReadByte(),
                    SectionIndex = r.ReadInt32(),
                    Value = r.ReadInt64(),
                });
            }
            return m;
        }
        catch (EndOfStreamException)
        {
            throw new InvalidDataException($"{what}: object file is truncated");
        }
    }

    public static bool IsObject(byte[] bytes) => bytes.AsSpan().StartsWith(Magic);
}
