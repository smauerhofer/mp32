using System.Buffers.Binary;
using Mp32.Core;

namespace Mp32.Tests;

public class BootImageTests
{
    private static uint Word(byte[] b, int at) => BinaryPrimitives.ReadUInt32LittleEndian(b.AsSpan(at));

    [Fact]
    public void HeaderIsWhatTheLoaderReads()
    {
        var img = BootImage.Create([1, 0, 0, 0, 2, 0, 0, 0, 3], load: 0);
        var b = img.ToBytes();
        Assert.Equal(32 + 12, b.Length);                 // padded to 3 words
        Assert.Equal(0x3233706Du, Word(b, 0));
        Assert.Equal("mp32", System.Text.Encoding.ASCII.GetString(b, 0, 4));
        Assert.Equal(0u, Word(b, 4));                    // load
        Assert.Equal(12u, Word(b, 8));                   // size
        Assert.Equal(0u, Word(b, 12));                   // entry: load
        Assert.Equal(6u, Word(b, 16));                   // sum: 1 + 2 + 3
        uint total = 0;
        for (int i = 0; i < 32; i += 4) total += Word(b, i);
        Assert.Equal(0u, total);                         // the check word
        Assert.Equal(3, b[40]);
    }

    [Fact]
    public void ReadsBackWhatItWrote()
    {
        var payload = Enumerable.Range(0, 4000).Select(i => (byte)(i * 7)).ToArray();
        var img = BootImage.Create(payload, load: 0x10000, entry: 0x10400);
        var back = BootImage.Read(img.ToBytes());
        Assert.Equal(0x10000u, back.Load);
        Assert.Equal(0x10400u, back.Entry);
        Assert.Equal(payload, back.Payload);
        Assert.Equal(img.Sum, back.Sum);
    }

    [Fact]
    public void RefusesWhatTheLoaderRefuses()
    {
        Assert.Throws<ArgumentException>(() => BootImage.Create([], 0));
        Assert.Throws<ArgumentException>(() => BootImage.Create([0, 0, 0, 0], load: 0x200));         // not 1 KB aligned
        Assert.Throws<ArgumentException>(() => BootImage.Create([0, 0, 0, 0], load: 0, entry: 4));   // entry outside
        Assert.Throws<ArgumentException>(() => BootImage.Create(new byte[0x400], load: 0x77FC00 + 0x400)); // over the screen
        BootImage.Create(new byte[0x400], load: 0x77FC00);                                           // just fits
    }

    [Fact]
    public void FindsDamage()
    {
        var good = BootImage.Create([1, 2, 3, 4, 5, 6, 7, 8], 0).ToBytes();

        var payload = (byte[])good.Clone(); payload[33] ^= 1;
        Assert.Contains("sum", Assert.Throws<InvalidDataException>(() => BootImage.Read(payload)).Message);

        var header = (byte[])good.Clone(); header[13] ^= 1;          // entry
        Assert.Contains("check", Assert.Throws<InvalidDataException>(() => BootImage.Read(header)).Message);

        var blank = Enumerable.Repeat((byte)0xFF, 64).ToArray();     // an erased flash
        Assert.Contains("magic", Assert.Throws<InvalidDataException>(() => BootImage.Read(blank)).Message);

        Assert.Throws<InvalidDataException>(() => BootImage.Read(good[..^4]));
    }

    [Fact]
    public void ToolWritesAndChecksAnImage()
    {
        var dir = Directory.CreateTempSubdirectory("mp32img").FullName;
        try
        {
            var bin = Path.Combine(dir, "os.bin");
            File.WriteAllBytes(bin, [0xC1, 0x0F, 0x00, 0x10]);
            var o = new StringWriter(); var e = new StringWriter();
            Assert.Equal(0, Mp32.Image.Program.Run([bin, "--load", "$0"], o, e));
            var img = Path.Combine(dir, "os.img");
            Assert.True(File.Exists(img), e.ToString());
            Assert.Equal(0, Mp32.Image.Program.Run(["--info", img], o, e));
            Assert.Contains("good", o.ToString());
            Assert.Equal(1, Mp32.Image.Program.Run([bin, "--load", "0x300"], o, e));
            Assert.Equal(0x4000u, Mp32.Image.Program.ParseNumber("$4000"));
        }
        finally { Directory.Delete(dir, true); }
    }
}
