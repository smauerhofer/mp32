using Mp32.Core;
using Mp32.Linker;

namespace Mp32.Tests;

public class ObjectFormatTests
{
    [Fact]
    public void ObjectModuleRoundTrips()
    {
        var m = Asm.Ok("  .import f\n  .export g\ng: CALL f\n  .rodata\n  .word g\n  .bss\n  .res 8\n");
        var back = ObjectModule.Read(m.ToBytes(), "x");
        Assert.Equal(m.ToBytes(), back.ToBytes());
        Assert.Equal(["CODE", "RODATA", "BSS"], back.Sections.Select(s => s.Name));
        Assert.Equal(2, back.Sections.Sum(s => s.Relocs.Count));
    }

    [Fact]
    public void BadFilesAreRejected()
    {
        Assert.Throws<InvalidDataException>(() => ObjectModule.Read([1, 2, 3], "x"));
        var bytes = Asm.Ok(" NOP\n").ToBytes();
        Assert.Throws<InvalidDataException>(() => ObjectModule.Read(bytes[..^3], "x"));
    }

    [Fact]
    public void LibraryRoundTripsAndIndexes()
    {
        var lib = new Library();
        lib.AddOrReplace("a.o", Asm.Ok("  .export fa\nfa: RET\n").ToBytes());
        lib.AddOrReplace("b.o", Asm.Ok("  .export fb\nfb: RET\n").ToBytes());
        Assert.True(lib.AddOrReplace("a.o", Asm.Ok("  .export fa, fa2\nfa: RET\nfa2: RET\n").ToBytes()));
        var path = Path.GetTempFileName();
        try
        {
            lib.Write(path);
            var back = Library.Read(path);
            Assert.Equal(["a.o", "b.o"], back.Members.Select(m => m.Name));
            var index = back.BuildIndex();
            Assert.Equal("a.o", index["fa2"].Name);
            Assert.Equal("b.o", index["fb"].Name);
            Assert.True(back.Remove("b.o"));
            Assert.Single(back.Members);
        }
        finally { File.Delete(path); }
    }
}

public class LinkerTests
{
    [Fact]
    public void LinksTwoModulesIntoTheBlockRam()
    {
        var main = Asm.Ok("  .import f\nstart: CALL f\n  JMP start\n");
        var lib = Asm.Ok("  .export f\nf: RET\n");
        var l = Link.Run([main, lib]);
        Assert.False(l.Diagnostics.HasErrors, string.Join("\n", l.Diagnostics.Items));
        var img = Link.Bram(l);
        // main CODE at $F0000000 (16 bytes with alignment), lib CODE at $F0000010
        Assert.Equal("C2 0C 00 00", Asm.Hex(img[..4]));   // JSRL: $10 - 4
        Assert.Equal(0x01, img[0x10]);
    }

    [Fact]
    public void HexOutputIsOneLinePerRowWithTheHighByteFirst()
    {
        var l = Link.Run([Asm.Ok("  LIT24 $030201\n")]);
        var (path, contents) = l.Outputs().Single();
        Assert.Equal("out.hex", path);
        var lines = System.Text.Encoding.ASCII.GetString(contents).Split('\n', StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal(512, lines.Length); // 8 KB, filled
        Assert.Equal("000000000000000000000000030201c0", lines[0]);
        Assert.Equal("04030201\n", Linker.Linker.HexLines([1, 2, 3, 4], 4));
    }

    [Fact]
    public void LibraryMembersAreTakenOnlyWhenNeeded()
    {
        var lib = new Library();
        lib.AddOrReplace("used.o", Asm.Ok("  .export f\n  .import g\nf: CALL g\n").ToBytes());
        lib.AddOrReplace("g.o", Asm.Ok("  .export g\ng: RET\n").ToBytes());
        lib.AddOrReplace("unused.o", Asm.Ok("  .export h\nh: NOP\n").ToBytes());
        var l = Link.Run([Asm.Ok("  .import f\n  CALL f\n")], [lib]);
        Assert.False(l.Diagnostics.HasErrors, string.Join("\n", l.Diagnostics.Items));
        var map = l.MapFile();
        Assert.Contains("test.lib(used.o)", map);
        Assert.Contains("test.lib(g.o)", map);
        Assert.DoesNotContain("unused.o", map);
    }

    [Fact]
    public void LeaReachesDataInAnotherSegment()
    {
        var l = Link.Run([Asm.Ok("  LEA tab\n  .rodata\ntab: .word 7\n")]);
        Assert.False(l.Diagnostics.HasErrors, string.Join("\n", l.Diagnostics.Items));
        var img = Link.Bram(l);
        // RODATA at $F0000010; the ADDR's next instruction is at $F0000006: $0A
        Assert.Equal("C0 0A 00 00 50 67", Asm.Hex(img[..6]));
        Assert.Equal(7, img[0x10]);
    }

    [Fact]
    public void AnAbsoluteLitOfABlockRamAddressDoesNotFit()
    {
        var l = Link.Run([Asm.Ok("  LIT tab\n  .rodata\ntab: .word 7\n")]);
        Assert.Contains(l.Diagnostics.Items, d => d.Message.Contains("LEA"));
    }

    [Fact]
    public void DataWordsGetAbsoluteAddresses()
    {
        // no CODE: RODATA is first in the block RAM
        var l = Link.Run([Asm.Ok("  .rodata\nt: .word t + 4\n")]);
        Assert.Equal("04 00 00 F0", Asm.Hex(Link.Bram(l)[..4]));
    }

    [Fact]
    public void SegmentSymbolsAreDefined()
    {
        var l = Link.Run([Asm.Ok("  .import __BSS_START__, __BSS_SIZE__\n  .rodata\n  .word __BSS_START__, __BSS_SIZE__\n  .bss\n  .res 32\n")]);
        Assert.False(l.Diagnostics.HasErrors, string.Join("\n", l.Diagnostics.Items));
        // RODATA at $F0000000 (8 bytes), BSS at the next 16-byte line
        Assert.Equal("10 00 00 F0 20 00 00 00", Asm.Hex(Link.Bram(l)[..8]));
    }

    [Fact]
    public void Errors()
    {
        var undefined = Link.Run([Asm.Ok("  .import f\n  CALL f\n")]);
        Assert.Contains(undefined.Diagnostics.Items, d => d.Message.Contains("undefined symbol 'f'"));

        var twice = Link.Run([Asm.Ok("  .export f\nf: RET\n"), Asm.Ok("  .export f\nf: RET\n")]);
        Assert.Contains(twice.Diagnostics.Items, d => d.Message.Contains("is defined in"));

        var big = Link.Run([Asm.Ok("  .res $3000\n")]);
        Assert.Contains(big.Diagnostics.Items, d => d.Message.Contains("overflows"));

        var unknown = Link.Run([Asm.Ok("  .segment \"VECTORS\"\n  .word 0\n")]);
        Assert.Contains(unknown.Diagnostics.Items, d => d.Message.Contains("not in the linker configuration"));

        var cjmpl = Link.Run([Asm.Ok("  .import f\n  CJMPL A, f\n"), Asm.Ok("  .export f\nf: RET\n")]);
        Assert.Contains(cjmpl.Diagnostics.Items, d => d.Message.Contains("same 16-byte line"));
    }

    [Fact]
    public void CustomConfiguration()
    {
        const string cfg = """
            # code in SDRAM, as a binary
            MEMORY {
                RAM: start = $1000, size = 4K, file = "%O.bin";
            }
            SEGMENTS {
                CODE:   load = RAM, type = ro;
                VECTORS: load = RAM, type = ro, start = $1F00;
                BSS:    load = RAM, type = bss;
            }
            """;
        var l = Link.Run([Asm.Ok("  NOP\n  .segment \"VECTORS\"\n  .word 1\n")], config: cfg);
        Assert.False(l.Diagnostics.HasErrors, string.Join("\n", l.Diagnostics.Items));
        var (path, contents) = l.Outputs().Single();
        Assert.Equal("out.hex.bin", path);
        Assert.Equal(0xF04, contents.Length);        // up to the end of VECTORS, not filled
        Assert.Equal(1, contents[0xF00]);
    }

    [Fact]
    public void ConfigurationErrorsHaveALine()
    {
        var ex = Assert.Throws<ConfigException>(() => LinkerConfig.Parse("MEMORY {\n  A: start = 0;\n}\n", "x.cfg"));
        Assert.Equal(2, ex.Line);
        Assert.Throws<ConfigException>(() => LinkerConfig.Parse("SEGMENTS { CODE: load = NOWHERE; }", "x.cfg"));
    }

    [Fact]
    public void DefaultConfigurationParses()
    {
        var cfg = LinkerConfig.Parse(LinkerConfig.Default, "default");
        Assert.Equal(Isa.ResetPc, (uint)cfg.FindMemory("BRAM")!.Start);
        Assert.Equal(0x2000, cfg.FindMemory("BRAM")!.Size);
    }
}

public class CommandLineTests
{
    [Fact]
    public void AssembleArchiveAndLinkThroughTheCommandLines()
    {
        var dir = Directory.CreateTempSubdirectory("mp32").FullName;
        var cwd = Directory.GetCurrentDirectory();
        try
        {
            Directory.SetCurrentDirectory(dir);
            File.WriteAllText("main.s", "  .import f\nstart: CALL f\n  JMP start\n");
            File.WriteAllText("f.s", "  .export f\nf: RET\n");
            var o = new StringWriter();
            var e = new StringWriter();
            Assert.Equal(0, Assembler.Program.Run(["main.s", "-l", "main.lst"], o, e));
            Assert.Equal(0, Assembler.Program.Run(["f.s", "-o", "f.o"], o, e));
            Assert.Equal(0, Librarian.Program.Run(["a", "my.lib", "f.o"], o, e));
            Assert.Equal(0, Librarian.Program.Run(["t", "my.lib"], o, e));
            Assert.Contains("export f", o.ToString());
            Assert.Equal(0, Linker.Program.Run(["-o", "boot.hex", "-m", "boot.map", "main.o", "my.lib"], o, e));
            Assert.Equal("", e.ToString());
            Assert.Equal(512, File.ReadAllLines("boot.hex").Length);
            Assert.True(File.Exists("boot.map"));
            Assert.True(File.Exists("main.lst"));

            File.WriteAllText("bad.s", "  CALL g\n");
            Assert.Equal(1, Assembler.Program.Run(["bad.s"], o, e));
            Assert.Contains("bad.s(1): error AS: undefined symbol 'g'", e.ToString());
        }
        finally
        {
            Directory.SetCurrentDirectory(cwd);
            Directory.Delete(dir, true);
        }
    }
}
