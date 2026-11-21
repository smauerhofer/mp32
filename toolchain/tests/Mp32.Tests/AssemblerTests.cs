using Mp32.Core;

namespace Mp32.Tests;

public class AssemblerTests
{
    [Fact]
    public void EveryOneByteOpcodeEncodesAsItself()
    {
        foreach (var op in Isa.Instructions.Where(i => i.Form == OperandForm.None))
            Assert.Equal(new[] { op.Opcode }, Asm.Code($"  {op.Mnemonic}\n").Take(1).ToArray());
    }

    [Fact]
    public void MnemonicsAreCaseInsensitive() =>
        Assert.Equal("02 03 04", Asm.Hex(Asm.Code(" dup\n Drop\n SWAP\n")[..3]));

    [Theory]
    [InlineData("LIT 5", "40 05")]
    [InlineData("LIT -128", "40 80")]
    [InlineData("LIT -129", "80 7F FF")]
    [InlineData("LIT $7FFF", "80 FF 7F")]
    [InlineData("LIT $8000", "C0 00 80 00")]
    [InlineData("LIT $FFFFFFFF", "40 FF")]
    [InlineData("LIT -$800000", "C0 00 00 80")]
    [InlineData("LIT8 -1", "40 FF")]
    [InlineData("LIT16 1", "80 01 00")]
    [InlineData("LIT24 $123456", "C0 56 34 12")]
    [InlineData("LIT 'A'", "40 41")]
    [InlineData("LIT %1010", "40 0A")]
    [InlineData("LIT 0b11 << 4 | 1", "40 31")]
    public void Literals(string line, string bytes)
    {
        var code = Asm.Code($"  {line}\n");
        Assert.Equal(bytes, Asm.Hex(code[..((bytes.Length + 1) / 3)]));
    }

    [Theory]
    [InlineData("LIT8 200")]
    [InlineData("LIT16 $8000")]
    [InlineData("LIT $800000")]
    [InlineData("LIT $F0000000")]
    public void LiteralsOutOfRange(string line) => Assert.NotEmpty(Asm.Errors($"  {line}\n"));

    [Fact]
    public void ForwardEquateSizesLit()
    {
        var code = Asm.Code("  LIT BIG\nBIG = $1234\n");
        Assert.Equal("80 34 12", Asm.Hex(code[..3]));
    }

    [Theory]
    [InlineData("MOVR T, PSP", "43 64")]
    [InlineData("MOVR PSP, T", "43 24")]
    [InlineData("MOVR r5, T", "43 05")]
    [InlineData("MOVR T, r31", "43 5F")]
    [InlineData("MOVR L, T", "43 23")]
    [InlineData("MOVR PC, T", "43 27")]
    [InlineData("MOVR T, TMPH", "43 69")]
    [InlineData("MOVR T, ST", "43 6A")]
    [InlineData("MOVR ST, T", "43 2A")]
    [InlineData("ANDR ST, T", "54 2A")]
    [InlineData("ADDR T, r5", "50 45")]
    [InlineData("ADDR PSP, T", "50 24")]
    [InlineData("ADDR PC, T", "50 27")]
    [InlineData("ADCR T, r5", "51 45")]
    [InlineData("ADCR r5, T", "51 05")]
    [InlineData("SUBR T, r5", "52 45")]
    [InlineData("SUBR FP, T", "52 26")]
    [InlineData("SUBR T, PSP", "52 64")]
    [InlineData("SBCR T, TMPH", "53 69")]
    [InlineData("SBCR r31, T", "53 1F")]
    [InlineData("ANDR T, r5", "54 45")]
    [InlineData("ORR r5, T", "55 05")]
    [InlineData("XORR T, S", "56 61")]
    [InlineData("CMPR T, r5", "57 45")]
    [InlineData("CMPR PSP, T", "57 24")]
    public void RegisterMoves(string line, string bytes) =>
        Assert.Equal(bytes, Asm.Hex(Asm.Code($"  {line}\n")[..2]));

    [Theory]
    [InlineData("MOVR")]
    [InlineData("ADDR")]
    [InlineData("ADCR")]
    [InlineData("SUBR")]
    [InlineData("SBCR")]
    [InlineData("ANDR")]
    [InlineData("ORR")]
    [InlineData("XORR")]
    [InlineData("CMPR")]
    public void RegisterMoveNeedsT(string mnemonic) =>
        Assert.Contains(Asm.Errors($"  {mnemonic} r1, r2\n"), e => e.Contains("must be T"));

    [Theory]
    [InlineData("ADD2 r1, r2", "90 01 02")]
    [InlineData("ADD2 r31, T", "90 1F 20")]
    [InlineData("ADD2 T, S", "90 20 21")]
    [InlineData("ADD2 PSP, r3", "90 24 03")]
    [InlineData("ADD2 r3, TMPH", "90 03 29")]
    [InlineData("ADD2 PC, r4", "90 27 04")]
    [InlineData("ADD2 FP, PC", "90 26 27")]
    [InlineData("ADC2 r1, r2", "91 01 02")]
    [InlineData("SUB2 PSP, r3", "92 24 03")]
    [InlineData("SBC2 r3, TMPH", "93 03 29")]
    [InlineData("AND2 T, S", "94 20 21")]
    [InlineData("OR2 L, r0", "95 23 00")]
    [InlineData("XOR2 r7, r7", "96 07 07")]
    [InlineData("CMP2 r1, FP", "97 01 26")]
    public void TwoRegisterOps(string line, string bytes) =>
        Assert.Equal(bytes, Asm.Hex(Asm.Code($"  {line}\n")[..3]));

    [Theory]
    [InlineData("ADD2 FP, PSP")]
    [InlineData("ADD2 TMPL, TMPH")]
    [InlineData("OR2 ST, PSP")]
    [InlineData("SUB2 PSP, RSP")]
    [InlineData("CMP2 FP, TMPL")]
    public void TwoRegisterOpsTakeOneStage3Register(string line) =>
        Assert.Contains(Asm.Errors($"  {line}\n"), e => e.Contains("at most one"));

    [Theory]
    [InlineData("ADD3 r1, r2, r3", "D0 01 02 03")]
    [InlineData("ADC3 T, S, r0", "D1 20 21 00")]
    [InlineData("SUB3 r5, PSP, r6", "D2 05 24 06")]
    [InlineData("SBC3 r5, r6, TMPH", "D3 05 06 29")]
    [InlineData("AND3 FP, FP, r1", "D4 26 26 01")]
    [InlineData("OR3 PSP, TMPL, r2", "D5 24 28 02")]
    [InlineData("XOR3 PC, r1, PC", "D6 27 01 27")]
    [InlineData("CMP3 r0, r1, r2", "D7 00 01 02")]
    [InlineData("ADD3 FP, PSP, r1", "D0 26 24 01")]
    [InlineData("SUB3 RSP, r1, PSP", "D2 25 01 24")]
    public void ThreeRegisterOps(string line, string bytes) =>
        Assert.Equal(bytes, Asm.Hex(Asm.Code($"  {line}\n")[..4]));

    [Theory]
    [InlineData("ADD3 r1, PSP, FP", "at most one source")]
    [InlineData("SUB3 r1, TMPL, TMPH", "at most one source")]
    [InlineData("ADD3 r1, ST, FP", "at most one source")]
    [InlineData("CMP3 PC, r1, r2", "cannot be PC")]
    public void ThreeRegisterOpsLimits(string line, string error) =>
        Assert.Contains(Asm.Errors($"  {line}\n"), e => e.Contains(error));

    [Theory]
    [InlineData("MOV2 r1, r2", "83 01 02")]
    [InlineData("MOV2 TMPL, PSP", "83 28 24")]
    [InlineData("MOV2 FP, FP", "83 26 26")]
    [InlineData("MOV2 FP, PSP", "83 26 24")]
    [InlineData("MOV2 PC, r3", "83 27 03")]
    [InlineData("MOVI2 r1, 5", "83 81 05")]
    [InlineData("MOVI2 r1, -1", "83 81 FF")]
    [InlineData("MOVI2 T, -$80", "83 A0 80")]
    [InlineData("MOVI2 ST, $7F", "83 AA 7F")]
    public void Moves(string line, string bytes) =>
        Assert.Equal(bytes, Asm.Hex(Asm.Code($"  {line}\n")[..3]));

    [Theory]
    [InlineData("MOVI2 r1, $80", "out of range")]
    [InlineData("MOVI2 r1, -$81", "out of range")]
    [InlineData("MOVI2 r1, x\nx:", "needs a constant")]
    public void MoveErrors(string line, string error) =>
        Assert.Contains(Asm.Errors($"  {line}\n"), e => e.Contains(error));

    [Theory]
    [InlineData("INCR r1", "44 01")]
    [InlineData("DECR r1", "44 81")]
    [InlineData("INCWR PSP", "44 64")]
    [InlineData("DECWR FP", "44 E6")]
    [InlineData("INCR T", "44 20")]
    [InlineData("DECR ST", "44 AA")]
    public void RegisterSteps(string line, string bytes) =>
        Assert.Equal(bytes, Asm.Hex(Asm.Code($"  {line}\n")[..2]));

    [Theory]
    [InlineData("LDR r1, r2", "84 81 02")]
    [InlineData("LDRH r1, r2", "84 41 02")]
    [InlineData("LDRSH r1, r2", "84 41 82")]
    [InlineData("LDRB T, PSP", "84 20 24")]
    [InlineData("LDRSB T, FP", "84 20 A6")]
    [InlineData("LDR r0, PC", "84 80 27")]
    [InlineData("STR r1, r2", "85 81 02")]
    [InlineData("STRH S, RSP", "85 61 25")]
    [InlineData("STRB r31, T", "85 1F 20")]
    public void LoadsAndStores(string line, string bytes) =>
        Assert.Equal(bytes, Asm.Hex(Asm.Code($"  {line}\n")[..3]));

    [Theory]
    [InlineData("LDR PSP, r1", "data register")]
    [InlineData("STR TMPL, r1", "data register")]
    [InlineData("LDR r1, TMPH", "address register")]
    [InlineData("STRB r1, ST", "address register")]
    public void LoadStoreRegisters(string line, string error) =>
        Assert.Contains(Asm.Errors($"  {line}\n"), e => e.Contains(error));

    [Theory]
    [InlineData("LDR3 r1, r2, r3", "C4 81 02 03")]
    [InlineData("LDR3 r1, r2, 8", "C4 81 42 08")]
    [InlineData("LDRSB3 T, FP, -1", "C4 20 E6 FF")]
    [InlineData("LDRH3 r0, PC, r5", "C4 40 27 05")]
    [InlineData("LDR3 r1, PSP, r2", "C4 81 24 02")]
    [InlineData("STR3 r1, r2, 8", "C5 81 42 08")]
    [InlineData("STRB3 r1, PSP, r3", "C5 01 24 03")]
    [InlineData("STRH3 S, PC, -4", "C5 61 67 FC")]
    [InlineData("STR3 r1, r2, TMPL", "C5 81 02 28")]
    public void LoadsAndStoresWithOffset(string line, string bytes) =>
        Assert.Equal(bytes, Asm.Hex(Asm.Code($"  {line}\n")[..4]));

    [Theory]
    [InlineData("STR3 r1, r2, r3", "two read ports")]
    [InlineData("LDR3 r1, PSP, FP", "at most one of base and offset")]
    [InlineData("LDR3 r1, r2, PC", "cannot be PC")]
    [InlineData("LDR3 PSP, r2, 4", "data register")]
    [InlineData("LDR3 r1, r2, $80", "out of range")]
    public void LoadStoreWithOffsetErrors(string line, string error) =>
        Assert.Contains(Asm.Errors($"  {line}\n"), e => e.Contains(error));

    [Theory]
    [InlineData("ENTER 16", "46 10")]
    [InlineData("ENTER 255", "46 FF")]
    [InlineData("ENTER2 $1234", "86 34 12")]
    [InlineData("ENTER3 $123456", "C6 56 34 12")]
    [InlineData("LEAVE", "30")]
    public void StackFrames(string line, string bytes) =>
        Assert.Equal(bytes, Asm.Hex(Asm.Code($"  {line}\n")[..((bytes.Length + 1) / 3)]));

    [Theory]
    [InlineData("ENTER 256")]
    [InlineData("ENTER -1")]
    [InlineData("ENTER2 $10000")]
    [InlineData("ENTER3 $1000000")]
    public void StackFrameSizeOutOfRange(string line) =>
        Assert.Contains(Asm.Errors($"  {line}\n"), e => e.Contains("out of range"));

    [Fact]
    public void InstructionsDoNotCrossALine()
    {
        // 14 NOPs, then a LIT24: it would cross into the next line, so 2 NOPs pad it
        var src = string.Concat(Enumerable.Repeat("  NOP\n", 14)) + "x: LIT24 1\n";
        var m = Asm.Ok(src);
        var code = m.Sections[0].Data;
        Assert.Equal(20, code.Length);
        Assert.Equal("C0 01 00 00", Asm.Hex(code[16..20]));
        Assert.All(code[..16], b => Assert.Equal(0, b));
    }

    [Fact]
    public void ALabelPointsPastThePadding()
    {
        var src = string.Concat(Enumerable.Repeat("  NOP\n", 15)) + "x: CJMPL A, x\n";
        var code = Asm.Code(src);
        // the CJMPL moved to offset 16: it jumps to offset 0 of its own line
        Assert.Equal("41 E0", Asm.Hex(code[16..18]));
    }

    [Fact]
    public void ConditionalBranches()
    {
        var code = Asm.Code("""
            loop:   NOP
                    CMP
                    CBR   NE, loop
                    CJMPL A, 3
                    CBRL  TZ, -1000
            """);
        // CBR at 2: offset 0 - 5 = -5 = $FFB: byte 1 = 1B (NE, low nibble B), byte 2 = FF
        Assert.Equal("00 1E 81 1B FF 41 E3", Asm.Hex(code[..7]));
        // CBRL at 7 (fits in its line): -1000 = $FFC18
        Assert.Equal("C1 F8 C1 FF", Asm.Hex(code[7..11]));
    }

    [Fact]
    public void CjmplOutsideTheLineIsAnError()
    {
        var src = "a: NOP\n" + string.Concat(Enumerable.Repeat("  NOP\n", 20)) + "  CJMPL EQ, a\n";
        Assert.Contains(Asm.Errors(src), e => e.Contains("same 16-byte line"));
    }

    [Fact]
    public void UnsignedConditionAliases() =>
        Assert.Equal(Asm.Hex(Asm.Code("x: CBR HS, x\n CBR LO, x\n")), Asm.Hex(Asm.Code("x: CBR CS, x\n CBR CC, x\n")));

    [Fact]
    public void CallPicksTheShortestForm()
    {
        var near = Asm.Code("f: RET\n  CALL f\n");
        Assert.Equal("42 FD", Asm.Hex(near[1..3]));         // JSRS, offset 0 - 3

        var far = Asm.Code("f: RET\n  .res 300\n  CALL f\n");
        Assert.Equal(0x82, far[301]);                        // JSR

        var farther = Asm.Code("f: RET\n  .res 40000\n  CALL f\n");
        Assert.Equal(0xC2, farther[40001]);                   // JSRL
    }

    [Fact]
    public void BranchPicksCbrOrCbrl()
    {
        Assert.Equal(0x81, Asm.Code("x: B EQ, x\n")[0]);
        var far = Asm.Code("  JMP x\n  .res 3000\nx: NOP\n");
        Assert.Equal("C1 E8 BB 00", Asm.Hex(far[..4]));     // CBRL A, 3000
    }

    [Fact]
    public void CallToAnotherModuleLeavesARelocation()
    {
        var m = Asm.Ok("  .import f\n  CALL f\n");
        var r = Assert.Single(m.Sections[0].Relocs);
        Assert.Equal(RelocType.Rel24, r.Type);
        Assert.Equal("f", m.Symbols[r.SymbolIndex].Name);
    }

    [Fact]
    public void LeaInTheSameSection()
    {
        var code = Asm.Code("  LEA x\n  NOP\nx: NOP\n");
        // x at 7; the LIT24 holds 7 - 6 = 1, then ADDR T, PC
        Assert.Equal("C0 01 00 00 50 67", Asm.Hex(code[..6]));
    }

    [Fact]
    public void LeaIsNotSplitAcrossALine()
    {
        var src = string.Concat(Enumerable.Repeat("  NOP\n", 11)) + "  LEA x\nx: NOP\n";
        var code = Asm.Code(src);
        // at offset 11 the ADDR would cross the line: one NOP more
        Assert.Equal("C0 00 00 00 50 67", Asm.Hex(code[12..18]));
    }

    [Fact]
    public void DataDirectives()
    {
        var m = Asm.Ok("""
                    .rodata
            t:      .byte 1, -1, "ab"
                    .half $1234
                    .word $deadbeef, t
                    .asciiz "\n"
            """);
        var ro = m.Sections.Single(s => s.Name == "RODATA");
        Assert.Equal("01 FF 61 62 34 12 EF BE AD DE 00 00 00 00 0A 00", Asm.Hex(ro.Data));
        var r = Assert.Single(ro.Relocs);
        Assert.Equal((RelocType.Abs32, 10, 0L), (r.Type, r.Offset, r.Addend));
    }

    [Fact]
    public void BssHasNoContents()
    {
        var m = Asm.Ok("  .bss\nbuf: .res 100\nend: .res 4\n  .export end\n");
        var bss = m.Sections.Single();
        Assert.True(bss.IsBss);
        Assert.Equal(104, bss.Size);
        Assert.Equal(100, m.Exports.Single().Value);
        Assert.NotEmpty(Asm.Errors("  .bss\n  NOP\n"));
        Assert.NotEmpty(Asm.Errors("  .bss\n  .word 1\n"));
    }

    [Fact]
    public void AlignAndPc()
    {
        var code = Asm.Code("  NOP\n  .align 8, $FF\nhere: LIT here - *\n");
        Assert.Equal("00 FF FF FF FF FF FF FF 40 00", Asm.Hex(code[..10]));
    }

    [Fact]
    public void LocalLabelsAreScoped()
    {
        var code = Asm.Code("""
            a:      NOP
            @l:     CJMPL A, @l
            b:      NOP
            @l:     CJMPL A, @l
            """);
        Assert.Equal("00 41 E1 00 41 E4", Asm.Hex(code[..6]));
    }

    [Fact]
    public void Macros()
    {
        var code = Asm.Code("""
            .macro PUSHLIT n
                    DUP
                    LIT n
            .endmacro
            .macro SPIN
            l\@:    CJMPL A, l\@
            .endm
                    PUSHLIT 300
                    SPIN
                    SPIN
            """);
        Assert.Equal("02 80 2C 01 41 E4 41 E6", Asm.Hex(code[..8]));
    }

    [Fact]
    public void Repeat()
    {
        var code = Asm.Code("  .rept 3\n  DIVS\n  .endr\n  .rept 2\n  LIT \\@ + 1\n  .endr\n");
        Assert.Equal("15 15 15 40 01 40 02", Asm.Hex(code[..7]));
    }

    [Fact]
    public void ConditionalAssembly()
    {
        const string src = """
            .ifdef FAST
                    NOP
            .elseif MODE == 2
                    DUP
            .else
                    DROP
            .endif
            """;
        Assert.Equal(0x03, Asm.Code("MODE = 1\n" + src)[0]);
        Assert.Equal(0x02, Asm.Code("MODE = 2\n" + src)[0]);
        Assert.Equal(0x00, Asm.Code("FAST = 1\n" + src)[0]);
        Assert.Contains(Asm.Errors(src), e => e.Contains("undefined symbol 'MODE'"));
    }

    [Fact]
    public void BinaryNumbersAndModulo()
    {
        Assert.Equal("40 05 40 01", Asm.Hex(Asm.Code("  LIT %101\n  LIT 7 % 3\n")[..4]));
    }

    [Fact]
    public void Errors()
    {
        Assert.Contains(Asm.Errors("  CALL nowhere\n"), e => e.Contains("undefined symbol 'nowhere'"));
        Assert.Contains(Asm.Errors("x: NOP\nx: NOP\n"), e => e.Contains("already defined"));
        Assert.Contains(Asm.Errors("  FOO\n"), e => e.Contains("unknown instruction"));
        Assert.Contains(Asm.Errors("  .export x\n"), e => e.Contains("not defined"));
        Assert.Contains(Asm.Errors("  NOP 1\n"), e => e.Contains("operand"));
        Assert.Contains(Asm.Errors("  .if 1\n"), e => e.Contains(".endif"));
        Assert.Contains(Asm.Errors("a = b\nb = a\n LIT a\n"), e => e.Contains("itself"));
    }

    [Fact]
    public void GlobalExportsWhatIsDefinedAndImportsTheRest()
    {
        var m = Asm.Ok("  .global f, g\nf: CALL g\n");
        Assert.Equal("f", m.Exports.Single().Name);
        Assert.Equal("g", m.Imports.Single().Name);
    }

    [Fact]
    public void ListingShowsAddressesAndBytes()
    {
        var a = new Assembler.Assembler(new Assembler.AssemblerOptions { MakeListing = true });
        Assert.NotNull(a.AssembleText("start: DUP\n  LIT 1000\n", "t.s"));
        Assert.Contains("80 E8 03", a.Listing);
        Assert.Contains("start", a.Listing);
    }

    // ---- LISP

    [Theory]
    [InlineData("CAR", "2C")]
    [InlineData("CDR", "2D")]
    [InlineData("RPLACA", "2E")]
    [InlineData("RPLACD", "2F")]
    [InlineData("CONS", "31")]
    [InlineData("TADD", "32")]
    [InlineData("TSUB", "33")]
    public void ListOps(string line, string bytes) =>
        Assert.Equal(bytes, Asm.Hex(Asm.Code($"  {line}\n")[..1]));

    [Theory]
    [InlineData("LSLI 2", "47 02")]
    [InlineData("LSRI 31", "47 3F")]
    [InlineData("ASRI 2", "47 42")]
    [InlineData("ROLI 1", "47 61")]
    [InlineData("RORI 8", "47 88")]
    [InlineData("LSLI 0", "47 00")]
    public void ShiftsByAConstant(string line, string bytes) =>
        Assert.Equal(bytes, Asm.Hex(Asm.Code($"  {line}\n")[..2]));

    [Theory]
    [InlineData("LSLI 32", "out of range")]
    [InlineData("ASRI -1", "out of range")]
    [InlineData("LSRI here", "constant")]
    public void ShiftCountErrors(string line, string error) =>
        Assert.Contains(Asm.Errors($"here: {line}\n"), e => e.Contains(error));

    [Theory]
    [InlineData("TTAG 3, 1", "87 03 01")]
    [InlineData("TTAG $FF, $0B", "87 FF 0B")]
    [InlineData("TTAG 7, 2", "87 07 02")]
    public void TagTests(string line, string bytes) =>
        Assert.Equal(bytes, Asm.Hex(Asm.Code($"  {line}\n")[..3]));

    [Theory]
    [InlineData("TTAG 256, 0", "mask")]
    [InlineData("TTAG 3, -1", "value")]
    [InlineData("TTAG 3", "operand")]
    public void TagTestErrors(string line, string error) =>
        Assert.Contains(Asm.Errors($"  {line}\n"), e => e.Contains(error));

    [Theory]
    [InlineData("MOVR HLIM, T", "43 2B")]
    [InlineData("MOVR T, HLIM", "43 6B")]
    [InlineData("MOVI2 HLIM, -1", "83 AB FF")]
    [InlineData("MOV2 HLIM, r3", "83 2B 03")]
    public void HeapLimitRegister(string line, string bytes)
    {
        var code = Asm.Code($"  {line}\n");
        Assert.Equal(bytes, Asm.Hex(code[..((bytes.Length + 1) / 3)]));
    }

    [Fact]
    public void HeapLimitIsAStage3Register() =>
        Assert.Contains(Asm.Errors("  ADD2 FP, HLIM\n"), e => e.Contains("at most one"));
}
