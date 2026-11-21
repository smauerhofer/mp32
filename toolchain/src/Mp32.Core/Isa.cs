namespace Mp32.Core;

/// <summary>How the bytes after the opcode byte are used.</summary>
public enum OperandForm
{
    /// <summary>1-byte instruction, no operands.</summary>
    None,
    /// <summary>LIT8 / LIT16 / LIT24: a signed constant in bytes 1..n.</summary>
    Imm,
    /// <summary>CJMPL: byte 1 = condition (7..4), offset in the line (3..0).</summary>
    CondLocal,
    /// <summary>CBR / CBRL: condition in byte 1 bits 7..4, signed offset in the rest.</summary>
    CondRel,
    /// <summary>JSRS / JSR / JSRL: signed offset in bytes 1..n.</summary>
    Rel,
    /// <summary>MOVR / ADDR .. CMPR: byte 1 = 0, direction (bit 6), register (5..0).</summary>
    RegMove,
    /// <summary>ADD2 .. CMP2: byte 1 = opx 0 (7..6), destination and source 1 (5..0); byte 2 = source 2 (5..0).</summary>
    RegReg,
    /// <summary>ADD3 .. CMP3: byte 1 = opx 0 (7..6), destination (5..0); byte 2 = source 1; byte 3 = source 2.</summary>
    RegRegReg,
    /// <summary>MOV2: byte 1 = 0 (7), 0 (6), destination (5..0); byte 2 = source (5..0).</summary>
    Mov2,
    /// <summary>INCR .. DECWR: byte 1 = dec (7), by 4 (6), the register (5..0); the two bits from the mnemonic.</summary>
    RegStep,
    /// <summary>LDR / STR and their sizes: byte 1 = size (7..6), data register (5..0); byte 2 = signed (7), address register (5..0).</summary>
    Mem,
    /// <summary>LDR3 / STR3 and their sizes: as Mem, with byte 2 bit 6 = 1: byte 3 an imm8 offset, 0: byte 3 an offset register.</summary>
    Mem3,
    /// <summary>ENTER, ENTER2, ENTER3: an unsigned constant in bytes 1..n (8, 16, 24 bits).</summary>
    UImm,
    /// <summary>MOVI2: byte 1 = 1 (7), 0 (6), destination (5..0); byte 2 = a signed 8-bit constant.</summary>
    MovImm,
    /// <summary>LSLI .. RORI (SHI, 0x47): byte 1 = the shift op (7..5, from the mnemonic), the count 0..31 (4..0).</summary>
    ShiftImm,
    /// <summary>TTAG: byte 1 = the mask, byte 2 = the value (two constants 0..255).</summary>
    Tag,
}

/// <summary>One opcode of the mp32 instruction set (cpu/isa.md).</summary>
public sealed record Instruction(string Mnemonic, byte Opcode, OperandForm Form, string Summary)
{
    /// <summary>Length in bytes, from the size bits 7..6 of the opcode byte.</summary>
    public int Length => Isa.LengthOf(Opcode);
}

/// <summary>The mp32 instruction set: opcodes, branch conditions, registers.</summary>
public static class Isa
{
    /// <summary>The size of a fetch line: an instruction must not cross it (unless the bytes past it are 0).</summary>
    public const int LineSize = 16;

    /// <summary>Address the processor starts at after reset (the mapped block RAM).</summary>
    public const uint ResetPc = 0xF000_0000;

    public static int LengthOf(byte opcode) => (opcode >> 6) + 1;

    public static readonly IReadOnlyList<Instruction> Instructions =
    [
        new("NOP",   0x00, OperandForm.None, "no operation"),
        new("RET",   0x01, OperandForm.None, "PC = R, pop the return stack into R"),
        new("DUP",   0x02, OperandForm.None, "( a -- a a )"),
        new("DROP",  0x03, OperandForm.None, "( a -- )"),
        new("SWAP",  0x04, OperandForm.None, "( a b -- b a )"),
        new("OVER",  0x05, OperandForm.None, "( a b -- a b a )"),
        new("DIP",   0x06, OperandForm.None, "( a b -- a a b )"),
        new("NIP",   0x07, OperandForm.None, "( a b c -- a c )"),
        new("TUCK",  0x08, OperandForm.None, "( a b -- b a b )"),
        new("DRIP",  0x09, OperandForm.None, "pop the parameter stack into T"),
        new("PUSH",  0x0A, OperandForm.None, "push R, R = T"),
        new("POP",   0x0B, OperandForm.None, "T = R, pop the return stack into R"),
        new("PUSHS", 0x0C, OperandForm.None, "push R, R = S"),
        new("POPS",  0x0D, OperandForm.None, "S = R, pop the return stack into R"),
        new("ROT",   0x0E, OperandForm.None, "( a b c -- b c a )"),
        new("DROT",  0x0F, OperandForm.None, "( a b c -- c a b )"),
        new("ADD",   0x10, OperandForm.None, "( a b -- a+b )"),
        new("ADC",   0x11, OperandForm.None, "( a b -- a+b+C )"),
        new("SUB",   0x12, OperandForm.None, "( a b -- a-b )"),
        new("SBC",   0x13, OperandForm.None, "( a b -- a-b-(1-C) )"),
        new("CSUB",  0x14, OperandForm.None, "T = T - S if no borrow"),
        new("DIVS",  0x15, OperandForm.None, "one step of a 64 / 32 division"),
        new("MUL",   0x16, OperandForm.None, "{S, T} = S * T unsigned"),
        new("SMUL",  0x17, OperandForm.None, "{S, T} = S * T signed"),
        new("AND",   0x18, OperandForm.None, "( a b -- a&b )"),
        new("OR",    0x19, OperandForm.None, "( a b -- a|b )"),
        new("XOR",   0x1A, OperandForm.None, "( a b -- a^b )"),
        new("INV",   0x1B, OperandForm.None, "T = ~T"),
        new("NEG",   0x1C, OperandForm.None, "T = 0 - T"),
        new("MULS",  0x1D, OperandForm.None, "one step of a 32 x 32 multiply"),
        new("CMP",   0x1E, OperandForm.None, "flags of S - T"),
        new("EXC",   0x1F, OperandForm.None, "exchange R and PC"),
        new("ASL",   0x20, OperandForm.None, "arithmetic shift left"),
        new("ASR",   0x21, OperandForm.None, "arithmetic shift right"),
        new("LSL",   0x22, OperandForm.None, "logical shift left"),
        new("LSR",   0x23, OperandForm.None, "logical shift right"),
        new("ROL",   0x24, OperandForm.None, "rotate left"),
        new("ROR",   0x25, OperandForm.None, "rotate right"),
        new("ROLC",  0x26, OperandForm.None, "rotate left through C"),
        new("RORC",  0x27, OperandForm.None, "rotate right through C"),
        new("LEAVE", 0x30, OperandForm.None, "RSP = FP, pop FP from the return stack (FP = R, pop R)"),
        new("INC",   0x28, OperandForm.None, "T = T + 1"),
        new("DEC",   0x29, OperandForm.None, "T = T - 1"),
        new("INCW",  0x2A, OperandForm.None, "T = T + 4 (a word)"),
        new("DECW",  0x2B, OperandForm.None, "T = T - 4 (a word)"),
        new("CAR",   0x2C, OperandForm.None, "T = the word at T - 1 (the car of a cons, tag 01)"),
        new("CDR",   0x2D, OperandForm.None, "T = the word at T + 3 (the cdr)"),
        new("RPLACA", 0x2E, OperandForm.None, "the word at T - 1 = S (set the car); the stack unchanged"),
        new("RPLACD", 0x2F, OperandForm.None, "the word at T + 3 = S (set the cdr); the stack unchanged"),
        new("CONS",  0x31, OperandForm.None, "( a d -- cell ): cell at L, L += 8; traps to the GC if L > HLIM"),
        new("TADD",  0x32, OperandForm.None, "( a b -- a+b ), V also if a tag is not 00 (fixnums)"),
        new("TSUB",  0x33, OperandForm.None, "( a b -- a-b ), V also if a tag is not 00 (fixnums)"),
        new("LIT8",  0x40, OperandForm.Imm, "T = 8-bit signed constant"),
        new("CJMPL", 0x41, OperandForm.CondLocal, "conditional jump within the line"),
        new("JSRS",  0x42, OperandForm.Rel, "call, 8-bit offset"),
        new("MOVR",  0x43, OperandForm.RegMove, "move between T and a register"),
        new("ENTER", 0x46, OperandForm.UImm, "push FP on the return stack, FP = RSP, RSP -= 4n (n words, 8 bits)"),
        new("LSLI",  0x47, OperandForm.ShiftImm, "T = T << n (n = 0 .. 31)"),
        new("LSRI",  0x47, OperandForm.ShiftImm, "T = T >> n, 0s in"),
        new("ASRI",  0x47, OperandForm.ShiftImm, "T = T >> n, the sign kept"),
        new("ROLI",  0x47, OperandForm.ShiftImm, "T rotated left by n"),
        new("RORI",  0x47, OperandForm.ShiftImm, "T rotated right by n"),
        new("INCR",  0x44, OperandForm.RegStep, "reg = reg + 1"),
        new("DECR",  0x44, OperandForm.RegStep, "reg = reg - 1 (byte 1 bit 7)"),
        new("INCWR", 0x44, OperandForm.RegStep, "reg = reg + 4 (byte 1 bit 6)"),
        new("DECWR", 0x44, OperandForm.RegStep, "reg = reg - 4 (bits 7, 6)"),
        new("ADDR",  0x50, OperandForm.RegMove, "add T and a register"),
        new("ADCR",  0x51, OperandForm.RegMove, "add T and a register, with carry"),
        new("SUBR",  0x52, OperandForm.RegMove, "destination - the other: T - register, or register - T"),
        new("SBCR",  0x53, OperandForm.RegMove, "subtract with carry: as SUBR, - (1 - C)"),
        new("ANDR",  0x54, OperandForm.RegMove, "AND T and a register"),
        new("ORR",   0x55, OperandForm.RegMove, "OR T and a register"),
        new("XORR",  0x56, OperandForm.RegMove, "XOR T and a register"),
        new("CMPR",  0x57, OperandForm.RegMove, "flags of destination - the other, nothing written"),
        new("LIT16", 0x80, OperandForm.Imm, "T = 16-bit signed constant"),
        new("CBR",   0x81, OperandForm.CondRel, "conditional branch, 12-bit offset"),
        new("JSR",   0x82, OperandForm.Rel, "call, 16-bit offset"),
        new("ENTER2", 0x86, OperandForm.UImm, "ENTER with a 16-bit size (words)"),
        new("TTAG",  0x87, OperandForm.Tag, "Z = ((T & mask) == value); T unchanged"),
        new("LDR",   0x84, OperandForm.Mem, "load a word: reg = mem32[addr]"),
        new("LDRH",  0x84, OperandForm.Mem, "load a halfword, zero-extended"),
        new("LDRSH", 0x84, OperandForm.Mem, "load a halfword, sign-extended"),
        new("LDRB",  0x84, OperandForm.Mem, "load a byte, zero-extended"),
        new("LDRSB", 0x84, OperandForm.Mem, "load a byte, sign-extended"),
        new("STR",   0x85, OperandForm.Mem, "store a word: mem32[addr] = reg"),
        new("STRH",  0x85, OperandForm.Mem, "store a halfword"),
        new("STRB",  0x85, OperandForm.Mem, "store a byte"),
        new("LDR3",  0xC4, OperandForm.Mem3, "load a word from base + offset (register or imm8)"),
        new("LDRH3", 0xC4, OperandForm.Mem3, "load a halfword from base + offset, zero-extended"),
        new("LDRSH3", 0xC4, OperandForm.Mem3, "load a halfword from base + offset, sign-extended"),
        new("LDRB3", 0xC4, OperandForm.Mem3, "load a byte from base + offset, zero-extended"),
        new("LDRSB3", 0xC4, OperandForm.Mem3, "load a byte from base + offset, sign-extended"),
        new("STR3",  0xC5, OperandForm.Mem3, "store a word to base + offset"),
        new("STRH3", 0xC5, OperandForm.Mem3, "store a halfword to base + offset"),
        new("STRB3", 0xC5, OperandForm.Mem3, "store a byte to base + offset"),
        new("MOV2",  0x83, OperandForm.Mov2, "dst = src, any two registers; no flags"),
        new("MOVI2", 0x83, OperandForm.MovImm, "dst = a signed 8-bit constant; no flags (byte 1 bit 7 = 1)"),
        new("ADD2",  0x90, OperandForm.RegReg, "dst = dst + src, any two registers"),
        new("ADC2",  0x91, OperandForm.RegReg, "dst = dst + src + C"),
        new("SUB2",  0x92, OperandForm.RegReg, "dst = dst - src"),
        new("SBC2",  0x93, OperandForm.RegReg, "dst = dst - src - (1 - C)"),
        new("AND2",  0x94, OperandForm.RegReg, "dst = dst & src"),
        new("OR2",   0x95, OperandForm.RegReg, "dst = dst | src"),
        new("XOR2",  0x96, OperandForm.RegReg, "dst = dst ^ src"),
        new("CMP2",  0x97, OperandForm.RegReg, "flags of dst - src, nothing written"),
        new("LIT24", 0xC0, OperandForm.Imm, "T = 24-bit signed constant"),
        new("CBRL",  0xC1, OperandForm.CondRel, "conditional branch, 20-bit offset"),
        new("JSRL",  0xC2, OperandForm.Rel, "call, 24-bit offset"),
        new("ENTER3", 0xC6, OperandForm.UImm, "ENTER with a 24-bit size (words)"),
        new("ADD3",  0xD0, OperandForm.RegRegReg, "dst = src1 + src2, any three registers"),
        new("ADC3",  0xD1, OperandForm.RegRegReg, "dst = src1 + src2 + C"),
        new("SUB3",  0xD2, OperandForm.RegRegReg, "dst = src1 - src2"),
        new("SBC3",  0xD3, OperandForm.RegRegReg, "dst = src1 - src2 - (1 - C)"),
        new("AND3",  0xD4, OperandForm.RegRegReg, "dst = src1 & src2"),
        new("OR3",   0xD5, OperandForm.RegRegReg, "dst = src1 | src2"),
        new("XOR3",  0xD6, OperandForm.RegRegReg, "dst = src1 ^ src2"),
        new("CMP3",  0xD7, OperandForm.RegRegReg, "flags of src1 - src2, also into dst as {V, N, Z, C}"),
    ];

    public static readonly IReadOnlyDictionary<string, Instruction> ByMnemonic =
        Instructions.ToDictionary(i => i.Mnemonic, StringComparer.OrdinalIgnoreCase);

    // MOV2 and MOVI2 share 0x83, INCR .. DECWR 0x44, LSLI .. RORI 0x47, the LDRs 0x84 / 0xC4,
    // the STRs 0x85 / 0xC5 (bytes 1, 2 tell them apart): the first one is kept.
    private static readonly Dictionary<byte, Instruction> ByOpcode =
        Instructions.GroupBy(i => i.Opcode).ToDictionary(g => g.Key, g => g.First());

    public static Instruction? Decode(byte opcode) => ByOpcode.GetValueOrDefault(opcode);

    /// <summary>Branch condition codes (byte 1 bits 7..4 of CJMPL, CBR, CBRL).</summary>
    public static readonly IReadOnlyDictionary<string, int> Conditions =
        new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase)
        {
            ["EQ"] = 0x0, ["NE"] = 0x1, ["CS"] = 0x2, ["HS"] = 0x2, ["CC"] = 0x3, ["LO"] = 0x3,
            ["MI"] = 0x4, ["PL"] = 0x5, ["VS"] = 0x6, ["VC"] = 0x7, ["HI"] = 0x8, ["LS"] = 0x9,
            ["GE"] = 0xA, ["LT"] = 0xB, ["GT"] = 0xC, ["LE"] = 0xD, ["A"] = 0xE, ["TZ"] = 0xF,
        };

    public static readonly string[] ConditionNames =
        ["EQ", "NE", "CS", "CC", "MI", "PL", "VS", "VC", "HI", "LS", "GE", "LT", "GT", "LE", "A", "TZ"];

    /// <summary>The special registers MOVR / ADDR .. CMPR name (bit 5 = 1, bits 4..0 below).</summary>
    public static readonly IReadOnlyDictionary<string, int> SpecialRegisters =
        new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase)
        {
            ["T"] = 0x00, ["S"] = 0x01, ["R"] = 0x02, ["L"] = 0x03,
            ["PSP"] = 0x04, ["RSP"] = 0x05, ["FP"] = 0x06, ["PC"] = 0x07,
            ["TMPL"] = 0x08, ["TMPH"] = 0x09, ["ST"] = 0x0A, ["HLIM"] = 0x0B,
        };

    /// <summary>The 6-bit selector of T as MOVR / ADDR .. CMPR name it.</summary>
    public const int RegT = 0x20;

    /// <summary>
    /// Parses a register name for MOVR / ADDR .. CMPR: r0..r31 give 0..31, the special
    /// registers 0x20 | their number.
    /// </summary>
    public static bool TryParseRegister(string name, out int selector)
    {
        selector = 0;
        if (SpecialRegisters.TryGetValue(name, out var s)) { selector = 0x20 | s; return true; }
        if (name.Length >= 2 && (name[0] == 'r' || name[0] == 'R') &&
            int.TryParse(name.AsSpan(1), System.Globalization.NumberStyles.None, null, out var n) &&
            n is >= 0 and <= 31 && name[1..] == n.ToString())
        {
            selector = n;
            return true;
        }
        return false;
    }

    /// <summary>
    /// True for the registers of stage 3 (PSP, RSP, FP, TMPL, TMPH, ST, HLIM): they reach the ALU
    /// only on one input, so ADD2 .. CMP2 can name at most one of them.
    /// </summary>
    public static bool IsStage3(int selector) =>
        (selector & 0x20) != 0 && (selector & 0x1F) is 0x04 or 0x05 or 0x06 or 0x08 or 0x09 or 0x0A or 0x0B;

    public static string RegisterName(int selector)
    {
        if ((selector & 0x20) == 0) return "r" + (selector & 0x1F);
        foreach (var (k, v) in SpecialRegisters)
            if (v == (selector & 0x1F)) return k;
        return $"?{selector:X2}";
    }

    /// <summary>Byte 1 bits 7..6 of INCR, DECR, INCWR, DECWR: dec (7), by 4 (6).</summary>
    public static int StepBits(string mnemonic) => mnemonic.ToUpperInvariant() switch
    {
        "INCR" => 0x00, "DECR" => 0x80, "INCWR" => 0x40, "DECWR" => 0xC0,
        _ => throw new ArgumentException(mnemonic),
    };

    /// <summary>Byte 1 bits 7..5 of LSLI .. RORI (SHI, 0x47): the shift op.</summary>
    public static int ShiftBits(string mnemonic) => mnemonic.ToUpperInvariant() switch
    {
        "LSLI" => 0x00, "LSRI" => 0x20, "ASRI" => 0x40, "ROLI" => 0x60, "RORI" => 0x80,
        _ => throw new ArgumentException(mnemonic),
    };

    /// <summary>LDR / STR: byte 1 bits 7..6 (the size: 00 byte, 01 halfword, 10 word) and byte 2 bit 7 (signed).</summary>
    public static (int Size, int Signed) MemBits(string mnemonic) => mnemonic.ToUpperInvariant().TrimEnd('3') switch
    {
        "LDRB" or "STRB" => (0x00, 0), "LDRSB" => (0x00, 0x80),
        "LDRH" or "STRH" => (0x40, 0), "LDRSH" => (0x40, 0x80),
        "LDR" or "STR" => (0x80, 0),
        _ => throw new ArgumentException(mnemonic),
    };

    /// <summary>True for the registers of the register file: r0 .. r31, T, S, R, L.</summary>
    public static bool IsFileReg(int selector) => (selector & 0x20) == 0 || (selector & 0x1F) < 4;

    /// <summary>True if <paramref name="value"/> fits a signed field of <paramref name="bits"/> bits.</summary>
    public static bool FitsSigned(long value, int bits) =>
        value >= -(1L << (bits - 1)) && value < (1L << (bits - 1));

    /// <summary>Takes a value as a 32-bit word: 0x8000_0000..0xFFFF_FFFF become negative.</summary>
    public static long ToSigned32(long value) =>
        value is >= 0x8000_0000L and <= 0xFFFF_FFFFL ? value - 0x1_0000_0000L : value;
}
