namespace Mp32.Core;

/// <summary>
/// Kinds of fields the assembler leaves for the linker. For the instruction kinds
/// the relocation offset is the address of the opcode byte; for the data kinds it
/// is the address of the field itself.
/// </summary>
public enum RelocType : byte
{
    /// <summary>A data byte (.byte): -128 .. 255.</summary>
    Abs8 = 1,
    /// <summary>A data halfword (.half), little-endian: -32768 .. 65535.</summary>
    Abs16 = 2,
    /// <summary>A data word (.word), little-endian.</summary>
    Abs32 = 3,
    /// <summary>LIT8: signed 8-bit constant in byte 1.</summary>
    Lit8 = 4,
    /// <summary>LIT16: signed 16-bit constant in bytes 1..2.</summary>
    Lit16 = 5,
    /// <summary>LIT24: signed 24-bit constant in bytes 1..3.</summary>
    Lit24 = 6,
    /// <summary>JSRS: 8-bit offset from the next instruction.</summary>
    Rel8 = 7,
    /// <summary>JSR: 16-bit offset from the next instruction.</summary>
    Rel16 = 8,
    /// <summary>JSRL: 24-bit offset from the next instruction.</summary>
    Rel24 = 9,
    /// <summary>CBR: 12-bit offset, bits 3..0 in byte 1 (3..0), bits 11..4 in byte 2.</summary>
    Cbr12 = 10,
    /// <summary>CBRL: 20-bit offset, as CBR plus bits 19..12 in byte 3.</summary>
    Cbrl20 = 11,
    /// <summary>CJMPL, UNEXT: the target's offset in the line, byte 1 bits 3..0; same line only.</summary>
    Cjmpl4 = 12,
    /// <summary>
    /// LEA: LIT24 followed by ADDR T, PC (6 bytes); the LIT24 holds the target
    /// minus the address after the ADDR, so T ends up as the target's address.
    /// </summary>
    Lea24 = 13,
    /// <summary>NEXT2: 8-bit offset from the next instruction, in byte 2.</summary>
    Next8 = 14,
    /// <summary>NEXT3: 16-bit offset from the next instruction, in bytes 2..3.</summary>
    Next16 = 15,
}

public static class Fields
{
    /// <summary>The length of the instruction an instruction relocation patches; 0 for data.</summary>
    public static int InstructionLength(RelocType type) => type switch
    {
        RelocType.Lit8 or RelocType.Rel8 or RelocType.Cjmpl4 => 2,
        RelocType.Lit16 or RelocType.Rel16 or RelocType.Cbr12 or RelocType.Next8 => 3,
        RelocType.Lit24 or RelocType.Rel24 or RelocType.Cbrl20 or RelocType.Next16 => 4,
        RelocType.Lea24 => 6,
        _ => 0,
    };

    /// <summary>Number of bytes, counted from the relocation offset, that the field touches.</summary>
    public static int Span(RelocType type) => type switch
    {
        RelocType.Abs8 => 1,
        RelocType.Abs16 => 2,
        RelocType.Abs32 => 4,
        _ => InstructionLength(type),
    };

    /// <summary>
    /// Writes <paramref name="target"/> into the field at <paramref name="offset"/>.
    /// <paramref name="place"/> is the address of that offset (for the relative
    /// kinds and CJMPL). Returns an error message, or null when it fits.
    /// </summary>
    public static string? Apply(byte[] data, int offset, RelocType type, long target, long place)
    {
        switch (type)
        {
            case RelocType.Abs8:
                if (target is < -128 or > 255) return $"value {target} does not fit in a byte";
                data[offset] = (byte)target;
                return null;
            case RelocType.Abs16:
                if (target is < -32768 or > 65535) return $"value {target} does not fit in a halfword";
                WriteLe(data, offset, target, 2);
                return null;
            case RelocType.Abs32:
                if (target is < int.MinValue or > uint.MaxValue) return $"value {target} does not fit in a word";
                WriteLe(data, offset, target, 4);
                return null;
            case RelocType.Lit8:
            case RelocType.Lit16:
            case RelocType.Lit24:
            {
                int bytes = InstructionLength(type) - 1;
                long v = Isa.ToSigned32(target);
                if (!Isa.FitsSigned(v, bytes * 8))
                    return $"constant {Format(target)} does not fit in a signed {bytes * 8}-bit LIT";
                WriteLe(data, offset + 1, v, bytes);
                return null;
            }
            case RelocType.Rel8:
            case RelocType.Rel16:
            case RelocType.Rel24:
            {
                int len = InstructionLength(type);
                long d = target - (place + len);
                if (!Isa.FitsSigned(d, (len - 1) * 8))
                    return $"call target out of range for {(len == 2 ? "JSRS" : len == 3 ? "JSR" : "JSRL")} (offset {d})";
                WriteLe(data, offset + 1, d, len - 1);
                return null;
            }
            case RelocType.Cbr12:
            case RelocType.Cbrl20:
            {
                int len = InstructionLength(type);
                int bits = type == RelocType.Cbr12 ? 12 : 20;
                long d = target - (place + len);
                if (!Isa.FitsSigned(d, bits))
                    return $"branch target out of range for {(bits == 12 ? "CBR" : "CBRL")} (offset {d})";
                PutBranchOffset(data, offset, d, bits);
                return null;
            }
            case RelocType.Next8:
            case RelocType.Next16:
            {
                int len = InstructionLength(type);
                int bits = type == RelocType.Next8 ? 8 : 16;
                long d = target - (place + len);
                if (!Isa.FitsSigned(d, bits))
                    return $"loop target out of range for {(bits == 8 ? "NEXT2" : "NEXT3")} (offset {d})";
                WriteLe(data, offset + 2, d, bits / 8);
                return null;
            }
            case RelocType.Lea24:
            {
                long d = target - (place + 6);
                if (!Isa.FitsSigned(d, 24))
                    return $"LEA target {Format(target)} is more than 8 MB away from the LEA at {Format(place)}";
                WriteLe(data, offset + 1, d, 3);
                return null;
            }
            case RelocType.Cjmpl4:
                if ((target >> 4) != (place >> 4))
                    return $"target {Format(target)} is not in the same 16-byte line as the CJMPL / UNEXT at {Format(place)}";
                data[offset + 1] = (byte)((data[offset + 1] & 0xF0) | (int)(target & 0xF));
                return null;
            default:
                return $"unknown relocation type {type}";
        }
    }

    /// <summary>Puts a CBR / CBRL offset into its bytes, keeping the condition nibble.</summary>
    public static void PutBranchOffset(byte[] data, int offset, long d, int bits)
    {
        data[offset + 1] = (byte)((data[offset + 1] & 0xF0) | (int)(d & 0xF));
        data[offset + 2] = (byte)((d >> 4) & 0xFF);
        if (bits == 20) data[offset + 3] = (byte)((d >> 12) & 0xFF);
    }

    public static void WriteLe(byte[] data, int offset, long value, int bytes)
    {
        for (int i = 0; i < bytes; i++) data[offset + i] = (byte)(value >> (8 * i));
    }

    public static string Format(long v) => v < 0 ? v.ToString() : $"${v:X}";
}
