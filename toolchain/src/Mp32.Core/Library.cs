using System.Text;

namespace Mp32.Core;

public sealed class LibraryMember
{
    public required string Name { get; init; }
    public required byte[] Data { get; init; }

    private ObjectModule? _module;
    public ObjectModule Module => _module ??= ObjectModule.Read(Data, Name);
}

/// <summary>
/// A library (.lib): a set of object modules. The linker takes from it only the
/// modules that define a symbol still undefined.
/// </summary>
public sealed class Library
{
    private static readonly byte[] Magic = "MP32LIB"u8.ToArray();
    public const byte FormatVersion = 1;

    public List<LibraryMember> Members { get; } = [];

    /// <summary>Adds a module, replacing a member of the same name.</summary>
    public bool AddOrReplace(string name, byte[] data)
    {
        ObjectModule.Read(data, name); // validate
        int i = Members.FindIndex(m => string.Equals(m.Name, name, StringComparison.OrdinalIgnoreCase));
        var member = new LibraryMember { Name = name, Data = data };
        if (i >= 0) { Members[i] = member; return true; }
        Members.Add(member);
        return false;
    }

    public bool Remove(string name) =>
        Members.RemoveAll(m => string.Equals(m.Name, name, StringComparison.OrdinalIgnoreCase)) > 0;

    /// <summary>Which member exports each symbol (the first one, if several do).</summary>
    public Dictionary<string, LibraryMember> BuildIndex()
    {
        var index = new Dictionary<string, LibraryMember>(StringComparer.Ordinal);
        foreach (var m in Members)
            foreach (var s in m.Module.Exports)
                index.TryAdd(s.Name, m);
        return index;
    }

    public void Write(string path)
    {
        using var fs = File.Create(path);
        using var w = new BinaryWriter(fs, Encoding.UTF8);
        w.Write(Magic);
        w.Write(FormatVersion);
        w.Write(Members.Count);
        foreach (var m in Members)
        {
            w.Write(m.Name);
            w.Write(m.Data.Length);
            w.Write(m.Data);
        }
    }

    public static Library Read(string path)
    {
        var bytes = File.ReadAllBytes(path);
        if (!IsLibrary(bytes)) throw new InvalidDataException($"{path}: not an mp32 library");
        try
        {
            using var r = new BinaryReader(new MemoryStream(bytes), Encoding.UTF8);
            r.ReadBytes(Magic.Length);
            var version = r.ReadByte();
            if (version != FormatVersion)
                throw new InvalidDataException($"{path}: library format version {version}, expected {FormatVersion}");
            var lib = new Library();
            int n = r.ReadInt32();
            for (int i = 0; i < n; i++)
            {
                var name = r.ReadString();
                int len = r.ReadInt32();
                lib.Members.Add(new LibraryMember { Name = name, Data = r.ReadBytes(len) });
            }
            return lib;
        }
        catch (EndOfStreamException)
        {
            throw new InvalidDataException($"{path}: library is truncated");
        }
    }

    public static bool IsLibrary(byte[] bytes) => bytes.AsSpan().StartsWith(Magic);
}
