using Mp32.Core;

namespace Mp32.Assembler;

/// <summary>One line of source, after includes and macro expansion.</summary>
public sealed record SourceLine(string File, int Line, string Text, string? Macro = null);

internal sealed class Section(string name, bool isBss, int index)
{
    public string Name { get; } = name;
    public bool IsBss { get; } = isBss;
    public int Index { get; } = index;
    public int Align { get; set; } = Isa.LineSize;
    public int Pos { get; set; }
    public int Size { get; set; }
    public List<Symbol> Pending { get; } = [];
    public byte[] Data { get; set; } = [];
    public List<ObjReloc> Relocs { get; } = [];
    public int SymbolIndex { get; set; }
}

internal enum SymbolState { Undefined, Label, Equate, Import }

internal sealed class Symbol(string name)
{
    public string Name { get; } = name;
    public SymbolState State { get; set; }
    public Section? Section { get; set; }
    public int Offset { get; set; }
    public Expr? Equate { get; set; }
    public bool Export { get; set; }
    public bool GlobalDecl { get; set; }
    public bool Hidden { get; set; }
    public SourceLine? DefinedAt { get; set; }
    public SourceLine? FirstUse { get; set; }
    public bool Evaluating { get; set; }
    public int ObjIndex { get; set; } = -1;
}

internal abstract class Stmt
{
    public required SourceLine Src { get; init; }
    public required Section Sec { get; init; }
    /// <summary>Offset in the section, set by the layout.</summary>
    public int Addr { get; set; }
}

internal sealed class LabelStmt : Stmt
{
    public required Symbol Symbol { get; init; }
}

internal enum InstrMode
{
    /// <summary>An opcode named exactly: its length is fixed.</summary>
    Fixed,
    /// <summary>LIT: the shortest of LIT8, LIT16, LIT24.</summary>
    LitAuto,
    /// <summary>CALL: the shortest of JSRS, JSR, JSRL.</summary>
    CallAuto,
    /// <summary>B cond, target / JMP target: CBR or CBRL.</summary>
    BranchAuto,
    /// <summary>LEA target: LIT24 + ADDR T, PC, 6 bytes, PC-relative.</summary>
    Lea,
}

internal sealed class InstrStmt : Stmt
{
    public Instruction? Op { get; init; }
    public InstrMode Mode { get; init; }
    public OperandForm Form { get; init; }
    /// <summary>The length chosen; only grows while the assembler relaxes.</summary>
    public int Size { get; set; }
    /// <summary>NOPs put before the instruction so it does not cross a 16-byte line.</summary>
    public int Pad { get; set; }
    public int Cond { get; init; }
    public int Register { get; init; }
    /// <summary>RegReg: the second register (byte 2).</summary>
    public int Register2 { get; init; }
    /// <summary>RegRegReg: the third register (byte 3).</summary>
    public int Register3 { get; init; }
    public int Direction { get; init; }
    public Expr? Operand { get; init; }
    /// <summary>Tag (TTAG): the second constant (the value; Operand is the mask).</summary>
    public Expr? Operand2 { get; init; }
}

internal sealed class DataStmt : Stmt
{
    /// <summary>1, 2 or 4 bytes per item.</summary>
    public int Unit { get; init; }
    /// <summary>Each item is an <see cref="Expr"/> or a byte[] (a string, for .byte).</summary>
    public required List<object> Items { get; init; }
    public int Size => Items.Sum(i => i is byte[] b ? b.Length : Unit);
}

internal sealed class ResStmt : Stmt
{
    public required Expr Count { get; init; }
    public Expr? Fill { get; init; }
    public int Size { get; set; }
}

internal sealed class AlignStmt : Stmt
{
    public int Align { get; init; }
    public byte Fill { get; init; }
    public int Pad { get; set; }
}

internal sealed class BytesStmt : Stmt
{
    public required byte[] Bytes { get; init; }
}
