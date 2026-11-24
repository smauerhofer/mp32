using System.Buffers.Binary;

namespace Mp32.Core;

/// <summary>
/// The image the boot loader (computer/boot.s) loads from the SPI flash, the microSD
/// card or the serial port: a header of 32 bytes, then the payload, the bytes that go
/// into the SDRAM from <see cref="Load"/> on.
///
/// <code>
///   +0   magic   "mp32" (0x3233706D)
///   +4   load    where the payload goes; 1 KB aligned: VEC = load, so the payload
///                begins with its vector table
///   +8   size    the payload's length in bytes, a multiple of 4, not 0
///   +12  entry   where the loader jumps to (normally load: entry 0 of the vector
///                table, the reset, a jump to the start)
///   +16  sum     the payload's words (little-endian) added up, modulo 2^32
///   +20  0
///   +24  0
///   +28  check   makes the header's eight words add up to 0 (modulo 2^32)
/// </code>
///
/// All words are little-endian. The payload must fit below the screen:
/// load + size &lt;= <see cref="RamEnd"/>.
/// </summary>
public sealed class BootImage
{
    public const uint Magic = 0x3233706D;          // "mp32"
    public const int HeaderSize = 32;
    public const uint RamEnd = 0x0078_0000;        // the screen starts here
    public const uint VecAlign = 0x400;            // VEC: bits 9..0 are 0

    public uint Load { get; init; }
    public uint Entry { get; init; }
    public byte[] Payload { get; init; } = [];

    public uint Size => (uint)Payload.Length;
    public uint Sum => Checksum(Payload);

    /// <summary>The payload's words added up (little-endian), modulo 2^32.</summary>
    public static uint Checksum(ReadOnlySpan<byte> payload)
    {
        uint sum = 0;
        for (int i = 0; i + 4 <= payload.Length; i += 4)
            sum += BinaryPrimitives.ReadUInt32LittleEndian(payload[i..]);
        return sum;
    }

    /// <summary>
    /// An image of the payload: padded with 0 to a multiple of 4. Throws
    /// <see cref="ArgumentException"/> when the loader would refuse it.
    /// </summary>
    public static BootImage Create(byte[] payload, uint load, uint? entry = null)
    {
        var padded = new byte[(payload.Length + 3) & ~3];
        payload.CopyTo(padded, 0);
        var img = new BootImage { Load = load, Entry = entry ?? load, Payload = padded };
        var problem = img.Problem();
        if (problem is not null) throw new ArgumentException(problem);
        return img;
    }

    /// <summary>What the boot loader would object to, or null.</summary>
    public string? Problem()
    {
        if (Size == 0) return "the payload is empty";
        if (Size % 4 != 0) return "the payload's size is not a multiple of 4";
        if (Load % VecAlign != 0) return $"load ${Load:X8} is not 1 KB aligned (VEC = load)";
        if ((ulong)Load + Size > RamEnd)
            return $"${Load:X8} + ${Size:X} bytes goes past ${RamEnd:X8}, where the screen starts";
        if (Entry < Load || Entry >= Load + Size)
            return $"entry ${Entry:X8} is not in the payload (${Load:X8} .. ${Load + Size - 1:X8})";
        return null;
    }

    /// <summary>The header and the payload, as the loader reads them.</summary>
    public byte[] ToBytes()
    {
        var b = new byte[HeaderSize + Payload.Length];
        var h = b.AsSpan(0, HeaderSize);
        uint[] w = [Magic, Load, Size, Entry, Sum, 0, 0, 0];
        w[7] = 0u - (w[0] + w[1] + w[2] + w[3] + w[4] + w[5] + w[6]);
        for (int i = 0; i < 8; i++)
            BinaryPrimitives.WriteUInt32LittleEndian(h[(4 * i)..], w[i]);
        Payload.CopyTo(b, HeaderSize);
        return b;
    }

    /// <summary>
    /// Reads an image back and checks it as the loader does: the magic, the header's
    /// check word, the payload's sum and <see cref="Problem"/>. Throws
    /// <see cref="InvalidDataException"/> with what is wrong.
    /// </summary>
    public static BootImage Read(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length < HeaderSize) throw new InvalidDataException("shorter than the header (32 bytes)");
        var w = new uint[8];
        uint total = 0;
        for (int i = 0; i < 8; i++)
        {
            w[i] = BinaryPrimitives.ReadUInt32LittleEndian(bytes[(4 * i)..]);
            total += w[i];
        }
        if (w[0] != Magic) throw new InvalidDataException($"no mp32 image (magic ${w[0]:X8})");
        if (total != 0) throw new InvalidDataException("the header's check word is wrong");
        if (w[2] > bytes.Length - HeaderSize)
            throw new InvalidDataException($"the header says {w[2]} bytes, the file holds {bytes.Length - HeaderSize}");
        var img = new BootImage
        {
            Load = w[1], Entry = w[3],
            Payload = bytes.Slice(HeaderSize, (int)w[2]).ToArray(),
        };
        var problem = img.Problem();
        if (problem is not null) throw new InvalidDataException(problem);
        if (img.Sum != w[4]) throw new InvalidDataException($"the payload's sum is ${img.Sum:X8}, the header says ${w[4]:X8}");
        return img;
    }
}
