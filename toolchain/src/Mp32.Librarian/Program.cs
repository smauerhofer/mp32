using Mp32.Core;

namespace Mp32.Librarian;

public static class Program
{
    private const string Usage = """
        mp32ar - librarian for the mp32 toolchain

        usage: mp32ar <command> library.lib [files...]

          a   add object files; a member of the same name is replaced
              (the library is created if it does not exist)
          d   delete members
          l   list the members
          t   list the members with their exported and imported symbols
          x   extract members (all of them when none is named)

          -h, --help   show this help
          --version    show the version
        """;

    public static int Main(string[] args)
    {
        try { return Run(args, Console.Out, Console.Error); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            Console.Error.WriteLine($"mp32ar: error: {ex.Message}");
            return 1;
        }
    }

    public static int Run(string[] args, TextWriter stdout, TextWriter stderr)
    {
        if (args.Length == 1 && args[0] is "-h" or "--help" or "/?") { stdout.Write(Usage); return 0; }
        if (args.Length == 1 && args[0] == "--version")
        {
            stdout.WriteLine($"mp32ar {typeof(Program).Assembly.GetName().Version}");
            return 0;
        }
        if (args.Length < 2) { stderr.Write(Usage); return 2; }

        var cmd = args[0].TrimStart('-').ToLowerInvariant();
        var libPath = args[1];
        var files = args[2..];

        switch (cmd)
        {
            case "a":
            {
                if (files.Length == 0) { stderr.WriteLine("mp32ar: error: no object files to add"); return 2; }
                var lib = File.Exists(libPath) ? Library.Read(libPath) : new Library();
                foreach (var f in files)
                {
                    var data = File.ReadAllBytes(f);
                    if (!ObjectModule.IsObject(data))
                    {
                        stderr.WriteLine($"mp32ar: error: {f} is not an mp32 object file");
                        return 1;
                    }
                    var name = Path.GetFileName(f);
                    bool replaced = lib.AddOrReplace(name, data);
                    stdout.WriteLine($"{(replaced ? "replaced" : "added")} {name}");
                }
                CheckDuplicates(lib, stderr);
                lib.Write(libPath);
                return 0;
            }
            case "d":
            {
                var lib = Library.Read(libPath);
                int rc = 0;
                foreach (var f in files)
                {
                    if (lib.Remove(Path.GetFileName(f))) stdout.WriteLine($"deleted {f}");
                    else { stderr.WriteLine($"mp32ar: error: {f} is not in {libPath}"); rc = 1; }
                }
                lib.Write(libPath);
                return rc;
            }
            case "l":
            {
                foreach (var m in Library.Read(libPath).Members) stdout.WriteLine(m.Name);
                return 0;
            }
            case "t":
            {
                foreach (var m in Library.Read(libPath).Members)
                {
                    var mod = m.Module;
                    var size = string.Join(", ", mod.Sections.Select(s => $"{s.Name} {s.Size}"));
                    stdout.WriteLine($"{m.Name}  ({size})");
                    foreach (var s in mod.Exports.OrderBy(s => s.Name, StringComparer.Ordinal))
                        stdout.WriteLine($"    export {s.Name}");
                    foreach (var s in mod.Imports.OrderBy(s => s.Name, StringComparer.Ordinal))
                        stdout.WriteLine($"    import {s.Name}");
                }
                return 0;
            }
            case "x":
            {
                var lib = Library.Read(libPath);
                var wanted = files.Length == 0 ? lib.Members : files.Select(f =>
                    lib.Members.FirstOrDefault(m => string.Equals(m.Name, Path.GetFileName(f), StringComparison.OrdinalIgnoreCase))
                    ?? throw new InvalidDataException($"{f} is not in {libPath}")).ToList();
                foreach (var m in wanted)
                {
                    File.WriteAllBytes(m.Name, m.Data);
                    stdout.WriteLine($"extracted {m.Name}");
                }
                return 0;
            }
            default:
                stderr.WriteLine($"mp32ar: error: unknown command '{args[0]}'");
                stderr.Write(Usage);
                return 2;
        }
    }

    /// <summary>Warns about symbols exported by more than one member (the first one wins in the linker).</summary>
    private static bool CheckDuplicates(Library lib, TextWriter stderr)
    {
        var seen = new Dictionary<string, string>(StringComparer.Ordinal);
        bool ok = true;
        foreach (var m in lib.Members)
            foreach (var s in m.Module.Exports)
            {
                if (seen.TryGetValue(s.Name, out var other))
                {
                    stderr.WriteLine($"mp32ar: warning: symbol '{s.Name}' is exported by {other} and {m.Name}; the linker takes {other}");
                    ok = false;
                }
                else seen[s.Name] = m.Name;
            }
        return ok;
    }
}
