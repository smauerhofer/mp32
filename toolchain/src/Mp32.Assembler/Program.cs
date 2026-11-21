using Mp32.Core;

namespace Mp32.Assembler;

public static class Program
{
    private const string Usage = """
        mp32as - assembler for the mp32 processor

        usage: mp32as [options] source.s

          -o <file>        object file to write (default: source with .o)
          -l <file>        write a listing
          -I <dir>         add a directory for .include and .incbin
          -D <name>[=val]  define a symbol (default value 1)
          -h, --help       show this help
          --version        show the version
        """;

    public static int Main(string[] args)
    {
        try { return Run(args, Console.Out, Console.Error); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            Console.Error.WriteLine($"mp32as: error: {ex.Message}");
            return 1;
        }
    }

    public static int Run(string[] args, TextWriter stdout, TextWriter stderr)
    {
        var opt = new AssemblerOptions();
        string? input = null, output = null, listing = null;

        for (int i = 0; i < args.Length; i++)
        {
            var a = args[i];
            string Next() => i + 1 < args.Length ? args[++i] : throw new ArgumentException($"{a} needs a value");
            try
            {
                switch (a)
                {
                    case "-h" or "--help" or "/?": stdout.Write(Usage); return 0;
                    case "--version": stdout.WriteLine($"mp32as {typeof(Program).Assembly.GetName().Version}"); return 0;
                    case "-o": output = Next(); break;
                    case "-l": listing = Next(); break;
                    case "-I": opt.IncludePaths.Add(Next()); break;
                    case "-D": AddDefine(opt, Next()); break;
                    default:
                        if (a.StartsWith("-I") && a.Length > 2) opt.IncludePaths.Add(a[2..]);
                        else if (a.StartsWith("-D") && a.Length > 2) AddDefine(opt, a[2..]);
                        else if (a.StartsWith('-')) throw new ArgumentException($"unknown option {a}");
                        else if (input is not null) throw new ArgumentException("only one source file at a time");
                        else input = a;
                        break;
                }
            }
            catch (ArgumentException ex)
            {
                stderr.WriteLine($"mp32as: error: {ex.Message}");
                return 2;
            }
        }
        if (input is null)
        {
            stderr.Write(Usage);
            return 2;
        }

        opt.MakeListing = listing is not null;
        output ??= Path.ChangeExtension(input, ".o");
        var asm = new Assembler(opt);
        var module = asm.AssembleFile(input);
        asm.Diagnostics.WriteTo(stderr);
        if (module is null)
        {
            stderr.WriteLine($"mp32as: {asm.Diagnostics.ErrorCount} error(s)");
            return 1;
        }
        File.WriteAllBytes(output, module.ToBytes());
        if (listing is not null) File.WriteAllText(listing, asm.Listing);
        return 0;
    }

    private static void AddDefine(AssemblerOptions opt, string def)
    {
        var parts = def.Split('=', 2);
        long value = 1;
        if (parts.Length == 2 && !TryParseNumber(parts[1], out value))
            throw new ArgumentException($"bad value in -D {def}");
        opt.Defines[parts[0]] = value;
    }

    public static bool TryParseNumber(string s, out long value)
    {
        s = s.Trim();
        var style = System.Globalization.NumberStyles.HexNumber;
        if (s.StartsWith('$')) return long.TryParse(s[1..], style, null, out value);
        if (s.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) return long.TryParse(s[2..], style, null, out value);
        return long.TryParse(s, out value);
    }
}
