using System.Globalization;
using Mp32.Core;

namespace Mp32.Linker;

public static class Program
{
    private const string Usage = """
        mp32ld - linker for the mp32 processor

        usage: mp32ld [options] files...

          files            object files (.o, always linked) and libraries (.lib,
                           only the members that are needed), in any order
          -o <name>        output name, put where the configuration says %O
                           (default: a.hex)
          -C <file>        linker configuration (default: the built-in one, see
                           --print-config)
          -m <file>        write a map file
          -L <dir>         a directory to look for libraries and objects in
          -D <name>=<val>  define a symbol
          --print-config   print the built-in configuration and stop
          -h, --help       show this help
          --version        show the version
        """;

    public static int Main(string[] args)
    {
        try { return Run(args, Console.Out, Console.Error); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            Console.Error.WriteLine($"mp32ld: error: {ex.Message}");
            return 1;
        }
    }

    public static int Run(string[] args, TextWriter stdout, TextWriter stderr)
    {
        var opt = new LinkerOptions();
        var inputs = new List<string>();
        var libDirs = new List<string>();
        string? configPath = null, mapPath = null;

        for (int i = 0; i < args.Length; i++)
        {
            var a = args[i];
            string Next() => i + 1 < args.Length ? args[++i] : throw new ArgumentException($"{a} needs a value");
            try
            {
                switch (a)
                {
                    case "-h" or "--help" or "/?": stdout.Write(Usage); return 0;
                    case "--version": stdout.WriteLine($"mp32ld {typeof(Program).Assembly.GetName().Version}"); return 0;
                    case "--print-config": stdout.Write(LinkerConfig.Default); stdout.WriteLine(); return 0;
                    case "-o": opt.Output = Next(); break;
                    case "-C": configPath = Next(); break;
                    case "-m": mapPath = Next(); break;
                    case "-L": libDirs.Add(Next()); break;
                    case "-D": AddDefine(opt, Next()); break;
                    default:
                        if (a.StartsWith("-L") && a.Length > 2) libDirs.Add(a[2..]);
                        else if (a.StartsWith("-D") && a.Length > 2) AddDefine(opt, a[2..]);
                        else if (a.StartsWith('-')) throw new ArgumentException($"unknown option {a}");
                        else inputs.Add(a);
                        break;
                }
            }
            catch (ArgumentException ex)
            {
                stderr.WriteLine($"mp32ld: error: {ex.Message}");
                return 2;
            }
        }
        if (inputs.Count == 0) { stderr.Write(Usage); return 2; }

        if (configPath is not null)
        {
            try { opt.Config = LinkerConfig.Parse(File.ReadAllText(configPath), configPath); }
            catch (ConfigException ex)
            {
                stderr.WriteLine(new Diagnostic(Severity.Error, "LD", ex.Message, ex.File, ex.Line));
                return 1;
            }
        }

        var linker = new Linker(opt);
        foreach (var input in inputs)
        {
            var path = File.Exists(input) ? input
                : libDirs.Select(d => Path.Combine(d, input)).FirstOrDefault(File.Exists);
            if (path is null)
            {
                stderr.WriteLine($"mp32ld: error: {input}: file not found");
                return 1;
            }
            linker.AddFile(path);
        }

        bool ok = linker.Link();
        linker.Diagnostics.WriteTo(stderr);
        if (!ok)
        {
            stderr.WriteLine($"mp32ld: {linker.Diagnostics.ErrorCount} error(s)");
            return 1;
        }

        int written = 0;
        foreach (var (path, contents) in linker.Outputs())
        {
            File.WriteAllBytes(path, contents);
            written++;
        }
        if (written == 0)
            stderr.WriteLine("mp32ld: warning: no memory area has a file attribute: nothing written");
        if (mapPath is not null) File.WriteAllText(mapPath, linker.MapFile());
        return 0;
    }

    private static void AddDefine(LinkerOptions opt, string def)
    {
        var parts = def.Split('=', 2);
        if (parts.Length != 2) throw new ArgumentException($"-D needs name=value: {def}");
        var s = parts[1].Trim();
        bool ok = s.StartsWith('$') ? long.TryParse(s[1..], NumberStyles.HexNumber, null, out var v)
            : s.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ? long.TryParse(s[2..], NumberStyles.HexNumber, null, out v)
            : long.TryParse(s, out v);
        if (!ok) throw new ArgumentException($"bad value in -D {def}");
        opt.Defines[parts[0]] = v;
    }
}
