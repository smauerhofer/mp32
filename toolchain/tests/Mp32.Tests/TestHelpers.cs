using Mp32.Core;
using Mp32.Linker;

namespace Mp32.Tests;

internal static class Asm
{
    public static ObjectModule Ok(string source, string name = "t.s")
    {
        var a = new Assembler.Assembler();
        var m = a.AssembleText(source, name);
        Assert.True(m is not null, string.Join("\n", a.Diagnostics.Items));
        return m!;
    }

    /// <summary>The bytes of the CODE section.</summary>
    public static byte[] Code(string source) =>
        Ok(source).Sections.Single(s => s.Name == "CODE").Data;

    public static string Hex(byte[] b) => string.Join(" ", b.Select(x => x.ToString("X2")));

    /// <summary>The error messages for a source that must not assemble.</summary>
    public static List<string> Errors(string source)
    {
        var a = new Assembler.Assembler();
        var m = a.AssembleText(source, "t.s");
        Assert.Null(m);
        return a.Diagnostics.Items.Where(d => d.Severity == Severity.Error).Select(d => d.Message).ToList();
    }
}

internal static class Link
{
    /// <summary>Links modules with the default configuration; returns the linker.</summary>
    public static Linker.Linker Run(IEnumerable<ObjectModule> modules, IEnumerable<Library>? libs = null, string? config = null)
    {
        var opt = new LinkerOptions { Output = "out.hex" };
        if (config is not null) opt.Config = LinkerConfig.Parse(config, "test.cfg");
        var l = new Linker.Linker(opt);
        int n = 0;
        foreach (var m in modules) l.AddObject(m, $"m{n++}.o");
        foreach (var lib in libs ?? []) l.AddLibrary(lib, "test.lib");
        l.Link();
        return l;
    }

    public static byte[] Bram(Linker.Linker l) => l.Config.FindMemory("BRAM")!.Image;
}
