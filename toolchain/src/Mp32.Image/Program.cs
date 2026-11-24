using System.Globalization;
using Mp32.Core;

namespace Mp32.Image;

public static class Program
{
    private const string Usage = """
        mp32img - makes the boot image the mp32 boot loader loads

        usage: mp32img [options] payload.bin
               mp32img --info image.img

          payload.bin      the program as raw bytes from its load address on (the
                           linker's "bin" output, e.g. of computer/os.cfg)
          -o <name>        the image (default: the payload's name with .img)
          --load <addr>    where the payload goes in the SDRAM, 1 KB aligned; it
                           begins with the vector table, VEC = load (default 0)
          --entry <addr>   where the loader jumps to (default: load, the reset
                           entry of the vector table)
          --info           check an image as the loader would and describe it
          -h, --help       show this help
          --version        show the version

        Numbers: 123, $7F, 0x7F. The image is a header of 32 bytes (magic "mp32",
        load, size, entry, the payload's sum, a check word) and the payload, padded
        to a multiple of 4 bytes. Put it into the flash at $400000, onto the microSD
        card from block 0, or send it over the serial port (see computer/README.md).
        """;

    public static int Main(string[] args)
    {
        try { return Run(args, Console.Out, Console.Error); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine($"mp32img: error: {ex.Message}");
            return 1;
        }
    }

    public static int Run(string[] args, TextWriter stdout, TextWriter stderr)
    {
        string? output = null, input = null;
        uint load = 0;
        uint? entry = null;
        bool info = false;

        for (int i = 0; i < args.Length; i++)
        {
            var a = args[i];
            string Next() => i + 1 < args.Length ? args[++i] : throw new ArgumentException($"{a} needs a value");
            try
            {
                switch (a)
                {
                    case "-h" or "--help" or "/?": stdout.Write(Usage); return 0;
                    case "--version": stdout.WriteLine($"mp32img {typeof(Program).Assembly.GetName().Version}"); return 0;
                    case "-o": output = Next(); break;
                    case "--load": load = ParseNumber(Next()); break;
                    case "--entry": entry = ParseNumber(Next()); break;
                    case "--info": info = true; break;
                    default:
                        if (a.StartsWith('-')) throw new ArgumentException($"unknown option {a}");
                        if (input is not null) throw new ArgumentException("only one input file");
                        input = a;
                        break;
                }
            }
            catch (ArgumentException ex)
            {
                stderr.WriteLine($"mp32img: error: {ex.Message}");
                return 2;
            }
        }
        if (input is null) { stderr.Write(Usage); return 2; }

        if (info)
        {
            try
            {
                var img = BootImage.Read(File.ReadAllBytes(input));
                stdout.WriteLine($"{input}: mp32 boot image, good");
                stdout.WriteLine($"  load   ${img.Load:X8} (VEC)");
                stdout.WriteLine($"  size   ${img.Size:X8} ({img.Size} bytes)");
                stdout.WriteLine($"  entry  ${img.Entry:X8}");
                stdout.WriteLine($"  sum    ${img.Sum:X8}");
                return 0;
            }
            catch (InvalidDataException ex)
            {
                stderr.WriteLine($"mp32img: {input}: {ex.Message}");
                return 1;
            }
        }

        try
        {
            var img = BootImage.Create(File.ReadAllBytes(input), load, entry);
            output ??= Path.ChangeExtension(input, ".img");
            File.WriteAllBytes(output, img.ToBytes());
            return 0;
        }
        catch (ArgumentException ex)
        {
            stderr.WriteLine($"mp32img: error: {input}: {ex.Message}");
            return 1;
        }
    }

    /// <summary>123, $7F or 0x7F, 0 .. $FFFFFFFF.</summary>
    public static uint ParseNumber(string s)
    {
        s = s.Trim();
        bool ok = s.StartsWith('$') ? uint.TryParse(s[1..], NumberStyles.HexNumber, null, out var v)
            : s.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ? uint.TryParse(s[2..], NumberStyles.HexNumber, null, out v)
            : uint.TryParse(s, out v);
        if (!ok) throw new ArgumentException($"not a number: {s}");
        return v;
    }
}
