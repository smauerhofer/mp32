using System.Text;
using System.Text.RegularExpressions;
using Mp32.Core;

namespace Mp32.Assembler;

public sealed class AssemblerOptions
{
    public List<string> IncludePaths { get; } = [];
    /// <summary>Symbols defined on the command line (-D name=value).</summary>
    public Dictionary<string, long> Defines { get; } = new(StringComparer.Ordinal);
    public bool MakeListing { get; set; }
}

/// <summary>
/// The mp32 assembler: reads a source file and makes an object module.
/// Pass 1 reads the source (includes, macros, conditionals) into statements; then
/// the layout is repeated, growing LIT / CALL / B to the length they need and
/// padding instructions with NOPs so none crosses a 16-byte line, until nothing
/// changes; the last pass writes the bytes and the relocations.
/// </summary>
public sealed class Assembler(AssemblerOptions? options = null) : IEvalContext
{
    private const string Code = "AS";
    private const int MaxMacroDepth = 64;
    private const int MaxIncludeDepth = 32;

    private readonly AssemblerOptions _opt = options ?? new AssemblerOptions();
    private readonly List<Section> _sections = [];
    private readonly Dictionary<string, Symbol> _symbols = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Macro> _macros = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<Stmt> _stmts = [];
    private readonly List<(SourceLine Line, List<Stmt> Stmts)> _listing = [];
    private readonly Stack<CondFrame> _conds = new();
    private Section? _current;
    private string _scope = "";
    private int _macroCounter;
    private int _hiddenCounter;
    private int _includeDepth;
    private bool _strict;
    private List<Stmt>? _lineStmts;
    private SourceLine? _evalLine;

    public DiagnosticBag Diagnostics { get; } = new();
    public string? Listing { get; private set; }

    private sealed record Macro(string Name, List<string> Params, List<string> Body, SourceLine DefinedAt);

    private sealed class CondFrame
    {
        public bool ParentActive;
        public bool Active;
        public bool Taken;
        public bool SeenElse;
        public required SourceLine Start;
    }

    private bool Active => _conds.Count == 0 || _conds.Peek().Active;

    // ------------------------------------------------------------------ entry points

    public ObjectModule? AssembleFile(string path)
    {
        string text;
        try { text = File.ReadAllText(path); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Diagnostics.Error(Code, $"cannot read {path}: {ex.Message}");
            return null;
        }
        return AssembleText(text, path);
    }

    public ObjectModule? AssembleText(string text, string fileName)
    {
        foreach (var (name, value) in _opt.Defines)
        {
            var s = GetSymbol(name);
            s.State = SymbolState.Equate;
            s.Equate = new NumberExpr(value, 0);
            s.DefinedAt = new SourceLine("<command line>", 0, "");
        }

        ProcessText(text, fileName);
        foreach (var f in _conds)
            Report(f.Start, "'.if' without '.endif'");
        if (Diagnostics.HasErrors) return null;

        CheckSymbols();
        if (Diagnostics.HasErrors) return null;

        Relax();
        _strict = true;
        Emit();
        if (Diagnostics.HasErrors) return null;

        if (_opt.MakeListing) Listing = MakeListing();
        return BuildObject(Path.GetFileName(fileName));
    }

    // ------------------------------------------------------------------ pass 1: reading

    private void ProcessText(string text, string file)
    {
        var lines = text.Replace("\r\n", "\n").Split('\n');
        if (lines.Length > 0 && lines[^1].Length == 0) lines = lines[..^1];
        var src = lines.Select((t, i) => new SourceLine(file, i + 1, t)).ToList();
        ProcessLines(src, 0);
    }

    private void ProcessLines(IReadOnlyList<SourceLine> lines, int macroDepth)
    {
        for (int i = 0; i < lines.Count; i++)
        {
            var sl = lines[i];
            _lineStmts = [];
            _listing.Add((sl, _lineStmts));
            try
            {
                i = ProcessLine(lines, i, macroDepth);
            }
            catch (AsmException ex)
            {
                Report(sl, ex.Message, ex.Column);
            }
        }
    }

    private int ProcessLine(IReadOnlyList<SourceLine> lines, int index, int macroDepth)
    {
        var sl = lines[index];
        var t = Lexer.Tokenize(sl.Text);
        int p = 0;

        // conditionals are looked at even where the code is switched off
        if (t[0].Kind == TokenKind.Ident && HandleConditional(t, sl)) return index;
        if (!Active) return index;

        // label:
        if (t[0].Kind == TokenKind.Ident && t[1].Is(":"))
        {
            DefineLabel(t[0], sl);
            p = 2;
        }

        if (t[p].Kind == TokenKind.End) return index;

        // name = expr, name .equ expr, name .set expr
        if (t[p].Kind == TokenKind.Ident && (t[p + 1].Is("=") || t[p + 1].IsIdent(".equ") || t[p + 1].IsIdent(".set")))
        {
            if (p != 0) throw new AsmException("a label and an assignment on one line", t[p].Column);
            DefineEquate(t[p], ParseExpr(t, p + 2, t.Count - 1, sl), sl);
            return index;
        }

        var word = t[p];
        if (word.Kind != TokenKind.Ident) throw new AsmException($"unexpected {word}", word.Column);
        var ops = SplitOperands(t, p + 1);

        if (word.Text.StartsWith('.'))
            return Directive(word, t, ops, lines, index, sl, macroDepth);

        if (_macros.TryGetValue(word.Text, out var macro))
        {
            ExpandMacro(macro, t, ops, sl, macroDepth);
            return index;
        }

        Instruction(word, t, ops, sl);
        return index;
    }

    /// <summary>Operands: slices of tokens between top-level commas.</summary>
    private static List<(int Start, int End)> SplitOperands(List<Token> t, int start)
    {
        var list = new List<(int, int)>();
        int end = t.Count - 1;
        if (start >= end) return list;
        int depth = 0, s = start;
        for (int i = start; i < end; i++)
        {
            if (t[i].Is("(")) depth++;
            else if (t[i].Is(")")) depth--;
            else if (t[i].Is(",") && depth == 0)
            {
                list.Add((s, i));
                s = i + 1;
            }
        }
        list.Add((s, end));
        foreach (var (a, b) in list)
            if (a >= b) throw new AsmException("empty operand", t[Math.Min(a, end)].Column);
        return list;
    }

    // ------------------------------------------------------------------ conditionals

    private bool HandleConditional(List<Token> t, SourceLine sl)
    {
        var name = t[0].Text.ToLowerInvariant();
        switch (name)
        {
            case ".if":
            case ".ifdef":
            case ".ifndef":
            {
                bool parent = Active;
                bool cond = false;
                if (parent)
                {
                    if (name == ".if")
                        cond = EvalConstNow(ParseExpr(t, 1, t.Count - 1, sl), sl) != 0;
                    else
                    {
                        if (t[1].Kind != TokenKind.Ident || t[2].Kind != TokenKind.End)
                            throw new AsmException($"{name} needs one symbol name", t[0].Column);
                        bool defined = IsDefined(Mangle(t[1].Text));
                        cond = name == ".ifdef" ? defined : !defined;
                    }
                }
                _conds.Push(new CondFrame { ParentActive = parent, Active = parent && cond, Taken = parent && cond, Start = sl });
                return true;
            }
            case ".elseif":
            {
                var f = TopCond(name, t[0]);
                if (f.SeenElse) throw new AsmException("'.elseif' after '.else'", t[0].Column);
                if (f.ParentActive && !f.Taken)
                {
                    f.Active = EvalConstNow(ParseExpr(t, 1, t.Count - 1, sl), sl) != 0;
                    f.Taken = f.Active;
                }
                else f.Active = false;
                return true;
            }
            case ".else":
            {
                var f = TopCond(name, t[0]);
                if (f.SeenElse) throw new AsmException("two '.else' for one '.if'", t[0].Column);
                f.SeenElse = true;
                f.Active = f.ParentActive && !f.Taken;
                f.Taken = true;
                return true;
            }
            case ".endif":
                TopCond(name, t[0]);
                _conds.Pop();
                return true;
        }
        return false;
    }

    private CondFrame TopCond(string name, Token tok) =>
        _conds.Count > 0 ? _conds.Peek() : throw new AsmException($"'{name}' without '.if'", tok.Column);

    private bool IsDefined(string name) =>
        _symbols.TryGetValue(name, out var s) && s.State != SymbolState.Undefined;

    /// <summary>Evaluates an expression that must be a constant now (in pass 1).</summary>
    private long EvalConstNow(Expr e, SourceLine sl)
    {
        var saved = _strict;
        _strict = true;
        _evalLine = sl;
        try
        {
            var v = Evaluator.Eval(e, this);
            if (!v.IsConstant) throw new AsmException("a constant is needed here", e.Column);
            return v.Num;
        }
        finally { _strict = saved; }
    }

    // ------------------------------------------------------------------ symbols

    private string Mangle(string name)
    {
        if (!name.StartsWith('@')) return name;
        if (_scope.Length == 0) throw new AsmException($"local label {name} before any global label");
        return _scope + name;
    }

    private Symbol GetSymbol(string name)
    {
        if (!_symbols.TryGetValue(name, out var s))
        {
            s = new Symbol(name);
            _symbols[name] = s;
        }
        return s;
    }

    private Section CurrentSection => _current ??= GetSection("CODE", false);

    private Section GetSection(string name, bool bss)
    {
        var s = _sections.FirstOrDefault(x => string.Equals(x.Name, name, StringComparison.OrdinalIgnoreCase));
        if (s is null)
        {
            s = new Section(name, bss || string.Equals(name, "BSS", StringComparison.OrdinalIgnoreCase), _sections.Count);
            _sections.Add(s);
        }
        else if (bss && !s.IsBss)
            throw new AsmException($"segment {name} was used before as a segment with contents");
        return s;
    }

    private void DefineLabel(Token tok, SourceLine sl)
    {
        if (Isa.ByMnemonic.ContainsKey(tok.Text))
            throw new AsmException($"'{tok.Text}' is an instruction and cannot be a label", tok.Column);
        if (!tok.Text.StartsWith('@')) _scope = tok.Text;
        var s = GetSymbol(Mangle(tok.Text));
        if (s.State != SymbolState.Undefined)
            throw new AsmException($"symbol '{s.Name}' is already defined{Where(s.DefinedAt)}", tok.Column);
        s.State = SymbolState.Label;
        s.Section = CurrentSection;
        s.DefinedAt = sl;
        AddStmt(new LabelStmt { Src = sl, Sec = CurrentSection, Symbol = s });
    }

    private void DefineEquate(Token tok, Expr e, SourceLine sl)
    {
        if (tok.Text.StartsWith('@')) throw new AsmException("a local label cannot be assigned", tok.Column);
        var s = GetSymbol(tok.Text);
        if (s.State != SymbolState.Undefined)
            throw new AsmException($"symbol '{s.Name}' is already defined{Where(s.DefinedAt)}", tok.Column);
        s.State = SymbolState.Equate;
        s.Equate = e;
        s.DefinedAt = sl;
    }

    private static string Where(SourceLine? sl) =>
        sl is null || sl.Line == 0 ? "" : $" at {Path.GetFileName(sl.File)}({sl.Line})";

    private void AddStmt(Stmt s)
    {
        _stmts.Add(s);
        _lineStmts?.Add(s);
    }

    /// <summary>
    /// Parses an expression. '*' (the current address) becomes a hidden label at
    /// this point, so it means the address of the statement that follows.
    /// </summary>
    private Expr ParseExpr(List<Token> t, int start, int end, SourceLine sl)
    {
        var e = ExprParser.Parse(t, start, end, n =>
        {
            var m = Mangle(n);
            var s = GetSymbol(m);
            s.FirstUse ??= sl;
            return m;
        });
        string? hidden = null;
        return ReplacePc(e, () =>
        {
            if (hidden is null)
            {
                hidden = $"*{++_hiddenCounter}";
                var s = GetSymbol(hidden);
                s.State = SymbolState.Label;
                s.Section = CurrentSection;
                s.Hidden = true;
                s.DefinedAt = sl;
                AddStmt(new LabelStmt { Src = sl, Sec = CurrentSection, Symbol = s });
            }
            return hidden;
        });
    }

    private static Expr ReplacePc(Expr e, Func<string> pcLabel) => e switch
    {
        PcExpr p => new SymbolExpr(pcLabel(), p.Column),
        UnaryExpr u => u with { Operand = ReplacePc(u.Operand, pcLabel) },
        BinaryExpr b => b with { Left = ReplacePc(b.Left, pcLabel), Right = ReplacePc(b.Right, pcLabel) },
        _ => e,
    };

    // ------------------------------------------------------------------ directives

    private int Directive(Token word, List<Token> t, List<(int Start, int End)> ops,
                          IReadOnlyList<SourceLine> lines, int index, SourceLine sl, int macroDepth)
    {
        var name = word.Text.ToLowerInvariant();
        switch (name)
        {
            case ".segment":
            {
                Need(ops, 1, 2, word);
                var segName = OperandName(t, ops[0]);
                bool bss = false;
                if (ops.Count == 2)
                {
                    var kind = OperandName(t, ops[1]);
                    if (!kind.Equals("bss", StringComparison.OrdinalIgnoreCase))
                        throw new AsmException($"unknown segment type '{kind}' (only 'bss')", t[ops[1].Start].Column);
                    bss = true;
                }
                _current = GetSection(segName, bss);
                break;
            }
            case ".code": Need(ops, 0, 0, word); _current = GetSection("CODE", false); break;
            case ".rodata": Need(ops, 0, 0, word); _current = GetSection("RODATA", false); break;
            case ".data": Need(ops, 0, 0, word); _current = GetSection("DATA", false); break;
            case ".bss": Need(ops, 0, 0, word); _current = GetSection("BSS", true); break;

            case ".byte" or ".db":
                Data(1, t, ops, sl, word, allowStrings: true);
                break;
            case ".half" or ".dh":
                Data(2, t, ops, sl, word, allowStrings: false);
                break;
            case ".word" or ".dw":
                Data(4, t, ops, sl, word, allowStrings: false);
                break;
            case ".ascii" or ".asciiz":
            {
                if (ops.Count == 0) throw new AsmException($"{word.Text} needs a string", word.Column);
                var bytes = new List<byte>();
                foreach (var op in ops)
                {
                    if (op.End - op.Start != 1 || t[op.Start].Kind != TokenKind.String)
                        throw new AsmException("string expected", t[op.Start].Column);
                    bytes.AddRange(t[op.Start].Bytes!);
                }
                if (name == ".asciiz") bytes.Add(0);
                NoBss(word);
                AddStmt(new BytesStmt { Src = sl, Sec = CurrentSection, Bytes = bytes.ToArray() });
                break;
            }
            case ".res" or ".space" or ".ds":
            {
                Need(ops, 1, 2, word);
                var count = ParseExpr(t, ops[0].Start, ops[0].End, sl);
                Expr? fill = ops.Count == 2 ? ParseExpr(t, ops[1].Start, ops[1].End, sl) : null;
                if (fill is not null && CurrentSection.IsBss)
                    throw new AsmException("a BSS segment cannot be filled", t[ops[1].Start].Column);
                AddStmt(new ResStmt { Src = sl, Sec = CurrentSection, Count = count, Fill = fill });
                break;
            }
            case ".align":
            {
                Need(ops, 1, 2, word);
                long a = EvalConstNow(ParseExpr(t, ops[0].Start, ops[0].End, sl), sl);
                if (a < 1 || a > 4096 || (a & (a - 1)) != 0)
                    throw new AsmException(".align needs a power of two from 1 to 4096", t[ops[0].Start].Column);
                long fill = ops.Count == 2 ? EvalConstNow(ParseExpr(t, ops[1].Start, ops[1].End, sl), sl) : 0;
                if (fill is < 0 or > 255) throw new AsmException("fill must be a byte", t[ops[1].Start].Column);
                var sec = CurrentSection;
                sec.Align = Math.Max(sec.Align, (int)a);
                AddStmt(new AlignStmt { Src = sl, Sec = sec, Align = (int)a, Fill = (byte)fill });
                break;
            }
            case ".incbin":
            {
                Need(ops, 1, 1, word);
                var file = ResolveInclude(StringOperand(t, ops[0]), sl, t[ops[0].Start]);
                NoBss(word);
                AddStmt(new BytesStmt { Src = sl, Sec = CurrentSection, Bytes = File.ReadAllBytes(file) });
                break;
            }
            case ".include":
            {
                Need(ops, 1, 1, word);
                var file = ResolveInclude(StringOperand(t, ops[0]), sl, t[ops[0].Start]);
                if (_includeDepth >= MaxIncludeDepth) throw new AsmException("includes nested too deep", word.Column);
                _includeDepth++;
                try { ProcessText(File.ReadAllText(file), file); }
                finally { _includeDepth--; }
                break;
            }
            case ".import" or ".extern":
                foreach (var op in ops)
                {
                    var s = GetSymbol(SymbolOperand(t, op));
                    if (s.State is SymbolState.Label or SymbolState.Equate)
                        throw new AsmException($"'{s.Name}' is defined here and cannot be imported", t[op.Start].Column);
                    s.State = SymbolState.Import;
                    s.DefinedAt ??= sl;
                }
                if (ops.Count == 0) throw new AsmException($"{word.Text} needs symbol names", word.Column);
                break;
            case ".export" or ".globl":
                foreach (var op in ops)
                {
                    var s = GetSymbol(SymbolOperand(t, op));
                    s.Export = true;
                    s.FirstUse ??= sl;
                }
                if (ops.Count == 0) throw new AsmException($"{word.Text} needs symbol names", word.Column);
                break;
            case ".global":
                foreach (var op in ops)
                {
                    var s = GetSymbol(SymbolOperand(t, op));
                    s.GlobalDecl = true;
                    s.FirstUse ??= sl;
                }
                if (ops.Count == 0) throw new AsmException($"{word.Text} needs symbol names", word.Column);
                break;
            case ".macro":
                return DefineMacro(t, ops, lines, index, sl);
            case ".rept":
                return Repeat(t, ops, lines, index, sl, macroDepth, word);
            case ".endr":
                throw new AsmException("'.endr' without '.rept'", word.Column);
            case ".endmacro" or ".endm":
                throw new AsmException($"'{word.Text}' without '.macro'", word.Column);
            case ".error":
                throw new AsmException(ops.Count == 1 ? StringOperand(t, ops[0]) : "error", word.Column);
            case ".warning":
                Diagnostics.Warning(Code, ops.Count == 1 ? StringOperand(t, ops[0]) : "warning", sl.File, sl.Line, word.Column);
                break;
            default:
                throw new AsmException($"unknown directive '{word.Text}'", word.Column);
        }
        return index;
    }

    private static void Need(List<(int, int)> ops, int min, int max, Token word)
    {
        if (ops.Count < min || ops.Count > max)
            throw new AsmException(min == max
                ? $"{word.Text} takes {min} operand{(min == 1 ? "" : "s")}"
                : $"{word.Text} takes {min} to {max} operands", word.Column);
    }

    private void NoBss(Token word)
    {
        if (CurrentSection.IsBss)
            throw new AsmException($"{word.Text} puts contents into BSS segment {CurrentSection.Name}; use .res there", word.Column);
    }

    private static string OperandName(List<Token> t, (int Start, int End) op)
    {
        if (op.End - op.Start == 1 && t[op.Start].Kind is TokenKind.Ident or TokenKind.String)
            return t[op.Start].Text;
        throw new AsmException("a name is expected", t[op.Start].Column);
    }

    private static string StringOperand(List<Token> t, (int Start, int End) op)
    {
        if (op.End - op.Start == 1 && t[op.Start].Kind == TokenKind.String) return t[op.Start].Text;
        throw new AsmException("a string is expected", t[op.Start].Column);
    }

    private string SymbolOperand(List<Token> t, (int Start, int End) op)
    {
        if (op.End - op.Start == 1 && t[op.Start].Kind == TokenKind.Ident && !t[op.Start].Text.StartsWith('@'))
            return t[op.Start].Text;
        throw new AsmException("a global symbol name is expected", t[op.Start].Column);
    }

    private string ResolveInclude(string name, SourceLine sl, Token tok)
    {
        var candidates = new List<string>();
        if (Path.IsPathRooted(name)) candidates.Add(name);
        else
        {
            var dir = Path.GetDirectoryName(Path.GetFullPath(sl.File));
            if (dir is not null) candidates.Add(Path.Combine(dir, name));
            candidates.Add(Path.GetFullPath(name));
            candidates.AddRange(_opt.IncludePaths.Select(p => Path.Combine(p, name)));
        }
        return candidates.FirstOrDefault(File.Exists) ?? throw new AsmException($"file '{name}' not found", tok.Column);
    }

    private void Data(int unit, List<Token> t, List<(int Start, int End)> ops, SourceLine sl, Token word, bool allowStrings)
    {
        if (ops.Count == 0) throw new AsmException($"{word.Text} needs values", word.Column);
        NoBss(word);
        var items = new List<object>();
        foreach (var op in ops)
        {
            if (op.End - op.Start == 1 && t[op.Start].Kind == TokenKind.String)
            {
                if (!allowStrings) throw new AsmException($"strings are only allowed in .byte", t[op.Start].Column);
                items.Add(t[op.Start].Bytes!);
            }
            else items.Add(ParseExpr(t, op.Start, op.End, sl));
        }
        AddStmt(new DataStmt { Src = sl, Sec = CurrentSection, Unit = unit, Items = items });
    }

    // ------------------------------------------------------------------ macros

    private int DefineMacro(List<Token> t, List<(int Start, int End)> ops, IReadOnlyList<SourceLine> lines, int index, SourceLine sl)
    {
        // .macro NAME p1, p2   (the name is the first token after .macro)
        if (t[1].Kind != TokenKind.Ident) throw new AsmException(".macro needs a name", t[0].Column);
        var name = t[1].Text;
        if (Isa.ByMnemonic.ContainsKey(name) || name.StartsWith('.') || IsPseudo(name))
            throw new AsmException($"'{name}' cannot be a macro name", t[1].Column);
        var pars = new List<string>();
        if (t[2].Kind != TokenKind.End)
        {
            foreach (var (a, b) in SplitOperands(t, 2))
            {
                if (b - a != 1 || t[a].Kind != TokenKind.Ident) throw new AsmException("parameter name expected", t[a].Column);
                pars.Add(t[a].Text);
            }
        }
        var body = new List<string>();
        int depth = 0;
        for (int i = index + 1; i < lines.Count; i++)
        {
            var first = FirstWord(lines[i].Text);
            if (first is ".macro") depth++;
            else if (first is ".endmacro" or ".endm")
            {
                if (depth == 0)
                {
                    if (_macros.ContainsKey(name)) throw new AsmException($"macro '{name}' is already defined", t[1].Column);
                    _macros[name] = new Macro(name, pars, body, sl);
                    for (int k = index + 1; k <= i; k++) _listing.Add((lines[k], []));
                    return i;
                }
                depth--;
            }
            body.Add(lines[i].Text);
        }
        throw new AsmException($"'.macro {name}' without '.endmacro'", t[0].Column);
    }

    /// <summary>.rept count ... .endr: the lines between, count times; \@ is the repetition (0, 1, ...).</summary>
    private int Repeat(List<Token> t, List<(int Start, int End)> ops, IReadOnlyList<SourceLine> lines,
                       int index, SourceLine sl, int depth, Token word)
    {
        Need(ops, 1, 1, word);
        long count = EvalConstNow(ParseExpr(t, ops[0].Start, ops[0].End, sl), sl);
        if (count is < 0 or > 100_000) throw new AsmException(".rept count must be 0 .. 100000", t[ops[0].Start].Column);
        var body = new List<SourceLine>();
        int nest = 0;
        for (int i = index + 1; i < lines.Count; i++)
        {
            var first = FirstWord(lines[i].Text);
            if (first is ".rept") nest++;
            else if (first is ".endr")
            {
                if (nest == 0)
                {
                    for (int k = index + 1; k <= i; k++) _listing.Add((lines[k], []));
                    if (depth >= MaxMacroDepth) throw new AsmException(".rept nested too deep", word.Column);
                    for (long n = 0; n < count; n++)
                        ProcessLines(body.Select(b => b with { Text = b.Text.Replace("\\@", n.ToString()), Macro = b.Macro ?? ".rept" }).ToList(), depth + 1);
                    return i;
                }
                nest--;
            }
            body.Add(lines[i]);
        }
        throw new AsmException("'.rept' without '.endr'", word.Column);
    }

    private static string? FirstWord(string line)
    {
        var m = Regex.Match(line, @"^\s*(?:[A-Za-z_.@][\w.@$]*\s*:\s*)?([.\w@$]+)");
        return m.Success ? m.Groups[1].Value.ToLowerInvariant() : null;
    }

    private void ExpandMacro(Macro m, List<Token> t, List<(int Start, int End)> ops, SourceLine sl, int depth)
    {
        if (depth >= MaxMacroDepth) throw new AsmException($"macros nested too deep (in '{m.Name}')");
        if (ops.Count > m.Params.Count)
            throw new AsmException($"macro '{m.Name}' takes {m.Params.Count} argument(s), got {ops.Count}");
        var args = ops.Select(o => sl.Text[(t[o.Start].Column - 1)..(t[o.End].Column - 1)].Trim()).ToList();
        int id = ++_macroCounter;
        var expanded = new List<SourceLine>();
        foreach (var line in m.Body)
        {
            var text = line.Replace("\\@", id.ToString());
            for (int i = 0; i < m.Params.Count; i++)
            {
                var arg = i < args.Count ? args[i] : "";
                text = Regex.Replace(text, $@"(?<![\w.@$])\\?{Regex.Escape(m.Params[i])}(?![\w.@$])", _ => arg);
            }
            expanded.Add(new SourceLine(sl.File, sl.Line, text, m.Name));
        }
        ProcessLines(expanded, depth + 1);
    }

    private static bool IsPseudo(string name) =>
        name.ToUpperInvariant() is "LIT" or "CALL" or "B" or "JMP" or "LEA" or "NEXT";

    // ------------------------------------------------------------------ instructions

    private void Instruction(Token word, List<Token> t, List<(int Start, int End)> ops, SourceLine sl)
    {
        var mn = word.Text.ToUpperInvariant();
        if (CurrentSection.IsBss)
            throw new AsmException($"instruction in BSS segment {CurrentSection.Name}", word.Column);

        switch (mn)
        {
            case "LIT":
                Need(ops, 1, 1, word);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Mode = InstrMode.LitAuto, Form = OperandForm.Imm, Size = 2,
                    Operand = ParseExpr(t, ops[0].Start, ops[0].End, sl),
                });
                return;
            case "CALL":
                Need(ops, 1, 1, word);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Mode = InstrMode.CallAuto, Form = OperandForm.Rel, Size = 2,
                    Operand = ParseExpr(t, ops[0].Start, ops[0].End, sl),
                });
                return;
            case "LEA":
                Need(ops, 1, 1, word);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Mode = InstrMode.Lea, Form = OperandForm.Imm, Size = 6,
                    Operand = ParseExpr(t, ops[0].Start, ops[0].End, sl),
                });
                return;
            case "B" or "JMP":
            {
                int cond = Isa.Conditions["A"];
                var target = ops.Count > 0 ? ops[^1] : default;
                if (mn == "B")
                {
                    Need(ops, 2, 2, word);
                    cond = ParseCondition(t, ops[0]);
                }
                else Need(ops, 1, 1, word);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Mode = InstrMode.BranchAuto, Form = OperandForm.CondRel, Size = 3,
                    Cond = cond, Operand = ParseExpr(t, target.Start, target.End, sl),
                });
                return;
            }
        }

        if (mn == "NEXT")
        {
            Need(ops, 2, 2, word);
            AddStmt(new InstrStmt
            {
                Src = sl, Sec = CurrentSection, Mode = InstrMode.NextAuto, Form = OperandForm.RegRel, Size = 3,
                Register = ParseCounter(t, ops[0], "NEXT"), Operand = ParseExpr(t, ops[1].Start, ops[1].End, sl),
            });
            return;
        }

        if (!Isa.ByMnemonic.TryGetValue(mn, out var op))
            throw new AsmException($"unknown instruction '{word.Text}'", word.Column);

        switch (op.Form)
        {
            case OperandForm.None:
                Need(ops, 0, 0, word);
                AddStmt(new InstrStmt { Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length });
                break;
            case OperandForm.Imm:
            case OperandForm.Rel:
                Need(ops, 1, 1, word);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length,
                    Operand = ParseExpr(t, ops[0].Start, ops[0].End, sl),
                });
                break;
            case OperandForm.CondLocal:
            case OperandForm.CondRel:
                Need(ops, 2, 2, word);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length,
                    Cond = ParseCondition(t, ops[0]),
                    Operand = ParseExpr(t, ops[1].Start, ops[1].End, sl),
                });
                break;
            case OperandForm.RegMove:
            {
                Need(ops, 2, 2, word);
                int dst = ParseRegister(t, ops[0]);
                int src = ParseRegister(t, ops[1]);
                int dir, reg;
                if (src == Isa.RegT) { dir = 0; reg = dst; }       // MOVR reg, T
                else if (dst == Isa.RegT) { dir = 1; reg = src; }  // MOVR T, reg
                else throw new AsmException($"{op.Mnemonic}: one of the operands must be T", t[ops[0].Start].Column);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length,
                    Direction = dir, Register = reg,
                });
                break;
            }
            case OperandForm.RegReg:
            {
                Need(ops, 2, 2, word);
                int dst = ParseRegister(t, ops[0]);
                int src = ParseRegister(t, ops[1]);
                if (Isa.IsStage3(dst) && Isa.IsStage3(src))
                    throw new AsmException($"{op.Mnemonic}: at most one of PSP, RSP, FP, TMPL, TMPH, ST, HLIM, VEC", t[ops[0].Start].Column);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length,
                    Register = dst, Register2 = src,
                });
                break;
            }
            case OperandForm.Mov2:
            {
                Need(ops, 2, 2, word);
                int dst = ParseRegister(t, ops[0]);
                int src = ParseRegister(t, ops[1]);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length,
                    Register = dst, Register2 = src,
                });
                break;
            }
            case OperandForm.Mem:
            {
                Need(ops, 2, 2, word);
                int data = ParseRegister(t, ops[0]);
                int addr = ParseRegister(t, ops[1]);
                if (!Isa.IsFileReg(data))
                    throw new AsmException($"{op.Mnemonic}: the data register must be r0..r31, T, S, R or L", t[ops[0].Start].Column);
                if (!Isa.IsFileReg(addr) && (addr & 0x1F) is not (0x04 or 0x05 or 0x06 or 0x07))
                    throw new AsmException($"{op.Mnemonic}: the address register must be r0..r31, T, S, R, L, PSP, RSP, FP or PC", t[ops[1].Start].Column);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length,
                    Register = data, Register2 = addr,
                });
                break;
            }
            case OperandForm.Mem3:
            {
                Need(ops, 3, 3, word);
                int data = ParseRegister(t, ops[0]);
                int bas = ParseRegister(t, ops[1]);
                bool store = op.Opcode == 0xC5;
                if (!Isa.IsFileReg(data))
                    throw new AsmException($"{op.Mnemonic}: the data register must be r0..r31, T, S, R or L", t[ops[0].Start].Column);
                // the offset: a register, or an expression (an 8-bit signed constant)
                int ofsReg = -1;
                if (ops[2].End - ops[2].Start == 1 && t[ops[2].Start].Kind == TokenKind.Ident &&
                    Isa.TryParseRegister(t[ops[2].Start].Text, out var r3))
                {
                    ofsReg = r3;
                    if (r3 == (0x20 | Isa.SpecialRegisters["PC"]))
                        throw new AsmException($"{op.Mnemonic}: the offset register cannot be PC", t[ops[2].Start].Column);
                    if (Isa.IsStage3(bas) && Isa.IsStage3(r3))
                        throw new AsmException($"{op.Mnemonic}: at most one of base and offset of PSP, RSP, FP, TMPL, TMPH, ST, HLIM, VEC", t[ops[1].Start].Column);
                    if (store && Isa.IsFileReg(bas) && Isa.IsFileReg(r3))
                        throw new AsmException($"{op.Mnemonic}: data, base and offset cannot all be r0..r31, T, S, R, L (two read ports)", t[ops[1].Start].Column);
                }
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length,
                    Register = data, Register2 = bas, Register3 = ofsReg,
                    Operand = ofsReg < 0 ? ParseExpr(t, ops[2].Start, ops[2].End, sl) : null,
                });
                break;
            }
            case OperandForm.UImm:
                Need(ops, 1, 1, word);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length,
                    Operand = ParseExpr(t, ops[0].Start, ops[0].End, sl),
                });
                break;
            case OperandForm.RegStep:
                Need(ops, 1, 1, word);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length,
                    Register = ParseRegister(t, ops[0]),
                });
                break;
            case OperandForm.MovImm:
                Need(ops, 2, 2, word);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length,
                    Register = ParseRegister(t, ops[0]),
                    Operand = ParseExpr(t, ops[1].Start, ops[1].End, sl),
                });
                break;
            case OperandForm.ShiftImm:
                Need(ops, 1, 1, word);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length,
                    Operand = ParseExpr(t, ops[0].Start, ops[0].End, sl),
                });
                break;
            case OperandForm.Tag:
                Need(ops, 2, 2, word);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length,
                    Operand = ParseExpr(t, ops[0].Start, ops[0].End, sl),
                    Operand2 = ParseExpr(t, ops[1].Start, ops[1].End, sl),
                });
                break;
            case OperandForm.Local:
                Need(ops, 1, 1, word);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length,
                    Operand = ParseExpr(t, ops[0].Start, ops[0].End, sl),
                });
                break;
            case OperandForm.RegRel:
                Need(ops, 2, 2, word);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length,
                    Register = ParseCounter(t, ops[0], op.Mnemonic),
                    Operand = ParseExpr(t, ops[1].Start, ops[1].End, sl),
                });
                break;
            case OperandForm.Cond:                                  // SET, SETB
                Need(ops, 1, 1, word);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length,
                    Cond = ParseCondition(t, ops[0]),
                });
                break;
            case OperandForm.RegCond:                               // SET2, SETB2
                Need(ops, 2, 2, word);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length,
                    Register = ParseFileRegister(t, ops[0], op.Mnemonic), Cond = ParseCondition(t, ops[1]),
                });
                break;
            case OperandForm.RegImm8:                               // ADDI2, CMPI2
            {
                Need(ops, 2, 2, word);
                int reg = ParseRegister(t, ops[0]);
                if (reg == (0x20 | Isa.SpecialRegisters["PC"]))
                    throw new AsmException($"{op.Mnemonic}: the register cannot be PC", t[ops[0].Start].Column);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length,
                    Register = reg, Operand = ParseExpr(t, ops[1].Start, ops[1].End, sl),
                });
                break;
            }
            case OperandForm.Unary:                                 // ABS, CLZ, PCNT: dst, src / reg / (T)
            {
                Need(ops, 0, 2, word);
                int dst = ops.Count > 0 ? ParseFileRegister(t, ops[0], op.Mnemonic) : Isa.RegT;
                int src = ops.Count > 1 ? ParseFileRegister(t, ops[1], op.Mnemonic) : dst;
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length,
                    Register = dst, Register2 = src,
                });
                break;
            }
            case OperandForm.FileRegReg:
            {
                Need(ops, 2, 2, word);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length,
                    Register = ParseFileRegister(t, ops[0], op.Mnemonic),
                    Register2 = ParseFileRegister(t, ops[1], op.Mnemonic),
                });
                break;
            }
            case OperandForm.FileRegRegReg:
            {
                Need(ops, 3, 3, word);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length,
                    Register = ParseFileRegister(t, ops[0], op.Mnemonic),
                    Register2 = ParseFileRegister(t, ops[1], op.Mnemonic),
                    Register3 = ParseFileRegister(t, ops[2], op.Mnemonic),
                });
                break;
            }
            case OperandForm.RegRegReg:
            {
                Need(ops, 3, 3, word);
                int dst = ParseRegister(t, ops[0]);
                int src1 = ParseRegister(t, ops[1]);
                int src2 = ParseRegister(t, ops[2]);
                if (Isa.IsStage3(src1) && Isa.IsStage3(src2))
                    throw new AsmException($"{op.Mnemonic}: at most one source of PSP, RSP, FP, TMPL, TMPH, ST, HLIM, VEC", t[ops[1].Start].Column);
                if (op.Mnemonic == "CMP3" && dst == (0x20 | Isa.SpecialRegisters["PC"]))
                    throw new AsmException("CMP3: the destination cannot be PC", t[ops[0].Start].Column);
                AddStmt(new InstrStmt
                {
                    Src = sl, Sec = CurrentSection, Op = op, Form = op.Form, Size = op.Length,
                    Register = dst, Register2 = src1, Register3 = src2,
                });
                break;
            }
        }
    }

    private static int ParseCondition(List<Token> t, (int Start, int End) op)
    {
        if (op.End - op.Start == 1 && t[op.Start].Kind == TokenKind.Ident &&
            Isa.Conditions.TryGetValue(t[op.Start].Text, out var c))
            return c;
        throw new AsmException("condition expected: EQ NE CS/HS CC/LO MI PL VS VC HI LS GE LT GT LE A TZ", t[op.Start].Column);
    }

    /// <summary>The counter of NEXT2 / NEXT3: a register of the register file (r0..r31, T, S, R, L).</summary>
    private static int ParseCounter(List<Token> t, (int Start, int End) op, string mnemonic)
    {
        int r = ParseRegister(t, op);
        if (!Isa.IsFileReg(r))
            throw new AsmException($"{mnemonic}: the counter must be r0..r31, T, S, R or L", t[op.Start].Column);
        return r;
    }

    private static int ParseRegister(List<Token> t, (int Start, int End) op)
    {
        if (op.End - op.Start == 1 && t[op.Start].Kind == TokenKind.Ident &&
            Isa.TryParseRegister(t[op.Start].Text, out var r))
            return r;
        throw new AsmException("register expected: r0..r31, T, S, R, L, PSP, RSP, FP, PC, TMPL, TMPH, ST, HLIM, VEC, PSPL, PSPH, RSPL, RSPH", t[op.Start].Column);
    }

    /// <summary>A register of the register file (r0..r31, T, S, R, L): the register shifts, MIN .. MAXU, ABS, CLZ, PCNT, SET2.</summary>
    private static int ParseFileRegister(List<Token> t, (int Start, int End) op, string mnemonic)
    {
        int r = ParseRegister(t, op);
        if (!Isa.IsFileReg(r))
            throw new AsmException($"{mnemonic}: the registers must be r0..r31, T, S, R or L", t[op.Start].Column);
        return r;
    }

    // ------------------------------------------------------------------ checks after pass 1

    private void CheckSymbols()
    {
        foreach (var s in _symbols.Values)
        {
            if (s.GlobalDecl)
            {
                if (s.State == SymbolState.Undefined) s.State = SymbolState.Import;
                else if (s.State != SymbolState.Import) s.Export = true;
            }
            if (s.Export && s.State == SymbolState.Undefined)
                Report(s.FirstUse, $"exported symbol '{s.Name}' is not defined");
            else if (s.Export && s.State == SymbolState.Import)
                Report(s.FirstUse, $"symbol '{s.Name}' is both imported and exported");
            else if (s.State == SymbolState.Undefined && s.FirstUse is not null)
                Report(s.FirstUse, $"undefined symbol '{s.Name}' (use .import for a symbol of another module)");
        }
    }

    // ------------------------------------------------------------------ layout and relaxation

    private void Layout()
    {
        foreach (var s in _sections) { s.Pos = 0; s.Pending.Clear(); }
        foreach (var st in _stmts)
        {
            var sec = st.Sec;
            switch (st)
            {
                case LabelStmt l:
                    sec.Pending.Add(l.Symbol);
                    break;
                case InstrStmt i:
                {
                    int inLine = sec.Pos % Isa.LineSize;
                    if (i.Mode == InstrMode.Lea)
                        // two instructions: LIT24 must not cross the line, nor ADDR after it
                        i.Pad = inLine > 12 ? Isa.LineSize - inLine : inLine == 11 ? 1 : 0;
                    else
                        i.Pad = inLine + i.Size > Isa.LineSize ? Isa.LineSize - inLine : 0;
                    Place(st, sec.Pos + i.Pad, i.Size);
                    break;
                }
                case DataStmt d:
                    Place(st, sec.Pos, d.Size);
                    break;
                case BytesStmt b:
                    Place(st, sec.Pos, b.Bytes.Length);
                    break;
                case ResStmt r:
                {
                    var v = TryEval(r.Count, r.Src);
                    r.Size = v is { IsConstant: true, Num: >= 0 and <= 0x1000_0000 } ? (int)v.Value.Num : r.Size;
                    Place(st, sec.Pos, r.Size);
                    break;
                }
                case AlignStmt a:
                    a.Pad = (a.Align - sec.Pos % a.Align) % a.Align;
                    a.Addr = sec.Pos;
                    sec.Pos += a.Pad;
                    break;
            }
        }
        foreach (var s in _sections)
        {
            foreach (var p in s.Pending) p.Offset = s.Pos;
            s.Pending.Clear();
            s.Size = s.Pos;
        }
    }

    private static void Place(Stmt st, int addr, int size)
    {
        var sec = st.Sec;
        st.Addr = addr;
        foreach (var p in sec.Pending) p.Offset = addr;
        sec.Pending.Clear();
        sec.Pos = addr + size;
    }

    private void Relax()
    {
        _strict = false;
        for (int pass = 0; pass < 1000; pass++)
        {
            Layout();
            bool changed = false;
            foreach (var st in _stmts)
            {
                if (st is not InstrStmt { Mode: not (InstrMode.Fixed or InstrMode.Lea) } i) continue;
                int need = NeededSize(i);
                if (need > i.Size) { i.Size = need; changed = true; }
            }
            if (!changed) return;
        }
        Diagnostics.Error(Code, "the layout does not settle (relaxation did not converge)");
    }

    private int NeededSize(InstrStmt i)
    {
        var v = TryEval(i.Operand!, i.Src);
        switch (i.Mode)
        {
            case InstrMode.LitAuto:
                if (v is not { IsConstant: true } c) return 4;
                long n = Isa.ToSigned32(c.Num);
                return Isa.FitsSigned(n, 8) ? 2 : Isa.FitsSigned(n, 16) ? 3 : 4;
            case InstrMode.CallAuto:
                for (int len = 2; len <= 3; len++)
                    if (RelFits(v, i, len, (len - 1) * 8)) return len;
                return 4;
            case InstrMode.BranchAuto:
                return RelFits(v, i, 3, 12) ? 3 : 4;
            case InstrMode.NextAuto:
                return RelFits(v, i, 3, 8) ? 3 : 4;
            default:
                return i.Size;
        }
    }

    /// <summary>Would a relative field of this length reach the target (as laid out now)?</summary>
    private static bool RelFits(Value? v, InstrStmt i, int len, int bits)
    {
        if (v is not { } val) return false;
        if (val.IsConstant) return Isa.FitsSigned(val.Num, bits);
        if (!ReferenceEquals(val.Base, i.Sec)) return false;
        // the target is in this section: measured on the current layout. Lengths
        // only grow, so the last layout (where nothing had to grow) is the final one.
        return Isa.FitsSigned(val.Num - (i.Addr + len), bits);
    }

    private Value? TryEval(Expr e, SourceLine sl)
    {
        _evalLine = sl;
        try { return Evaluator.Eval(e, this); }
        catch (AsmException) { return null; }
    }

    // IEvalContext
    Value IEvalContext.Symbol(string name, int column)
    {
        if (!_symbols.TryGetValue(name, out var s) || s.State == SymbolState.Undefined)
            throw new AsmException($"undefined symbol '{name}'", column);
        switch (s.State)
        {
            case SymbolState.Label:
                return new Value(s.Offset, s.Section);
            case SymbolState.Import:
                return new Value(0, s);
            default:
                if (s.Evaluating) throw new AsmException($"symbol '{name}' is defined in terms of itself", column);
                s.Evaluating = true;
                try { return Evaluator.Eval(s.Equate!, this); }
                finally { s.Evaluating = false; }
        }
    }

    Value IEvalContext.Pc(int column) => throw new AsmException("'*' cannot be used here", column);

    // ------------------------------------------------------------------ final pass

    private void Emit()
    {
        foreach (var s in _sections)
        {
            s.Data = s.IsBss ? [] : new byte[s.Size];
            s.Relocs.Clear();
        }
        AssignObjIndices();

        foreach (var st in _stmts)
        {
            try
            {
                _evalLine = st.Src;
                switch (st)
                {
                    case InstrStmt i: EmitInstr(i); break;
                    case DataStmt d: EmitData(d); break;
                    case BytesStmt b: b.Bytes.CopyTo(b.Sec.Data, b.Addr); break;
                    case ResStmt r: EmitRes(r); break;
                    case AlignStmt a:
                        if (!a.Sec.IsBss) Array.Fill(a.Sec.Data, a.Fill, a.Addr, a.Pad);
                        break;
                }
            }
            catch (AsmException ex)
            {
                Report(st.Src, ex.Message, ex.Column);
            }
        }
    }

    private void EmitRes(ResStmt r)
    {
        var v = Evaluator.Eval(r.Count, this);
        if (!v.IsConstant || v.Num < 0) throw new AsmException(".res needs a constant count of 0 or more", r.Count.Column);
        if (r.Fill is null || r.Sec.IsBss) return;
        var f = Evaluator.Eval(r.Fill, this);
        if (!f.IsConstant || f.Num is < 0 or > 255) throw new AsmException("fill must be a constant byte", r.Fill.Column);
        Array.Fill(r.Sec.Data, (byte)f.Num, r.Addr, r.Size);
    }

    private void EmitData(DataStmt d)
    {
        int pos = d.Addr;
        var type = d.Unit switch { 1 => RelocType.Abs8, 2 => RelocType.Abs16, _ => RelocType.Abs32 };
        foreach (var item in d.Items)
        {
            if (item is byte[] b)
            {
                b.CopyTo(d.Sec.Data, pos);
                pos += b.Length;
                continue;
            }
            var e = (Expr)item;
            var v = Evaluator.Eval(e, this);
            if (v.IsConstant)
            {
                var err = Fields.Apply(d.Sec.Data, pos, type, v.Num, 0);
                if (err is not null) throw new AsmException(err, e.Column);
            }
            else AddReloc(d.Sec, pos, type, v, d.Src);
            pos += d.Unit;
        }
    }

    private void EmitInstr(InstrStmt i)
    {
        var data = i.Sec.Data;
        int a = i.Addr;
        switch (i.Form)
        {
            case OperandForm.None:
                data[a] = i.Op!.Opcode;
                return;
            case OperandForm.RegMove:
                data[a] = i.Op!.Opcode;
                data[a + 1] = (byte)((i.Direction << 6) | i.Register);
                return;
            case OperandForm.RegReg:
                data[a] = i.Op!.Opcode;
                data[a + 1] = (byte)i.Register;              // opx 00
                data[a + 2] = (byte)i.Register2;
                return;
            case OperandForm.Mem:
            {
                var (size, sgn) = Isa.MemBits(i.Op!.Mnemonic);
                data[a] = i.Op.Opcode;
                data[a + 1] = (byte)(size | i.Register);
                data[a + 2] = (byte)(sgn | i.Register2);
                return;
            }
            case OperandForm.Mem3 when i.Register3 >= 0:              // offset register
            {
                var (size, sgn) = Isa.MemBits(i.Op!.Mnemonic);
                data[a] = i.Op.Opcode;
                data[a + 1] = (byte)(size | i.Register);
                data[a + 2] = (byte)(sgn | i.Register2);           // bit 6 = 0
                data[a + 3] = (byte)i.Register3;
                return;
            }
            case OperandForm.RegStep:
                data[a] = i.Op!.Opcode;
                data[a + 1] = (byte)(Isa.StepBits(i.Op.Mnemonic) | i.Register);
                return;
            case OperandForm.Mov2:
                data[a] = i.Op!.Opcode;
                data[a + 1] = (byte)i.Register;              // bit 7 = 0: MOV2
                data[a + 2] = (byte)i.Register2;
                return;
            case OperandForm.RegRegReg:
            case OperandForm.FileRegRegReg:
                data[a] = i.Op!.Opcode;
                data[a + 1] = (byte)i.Register;              // opx 00
                data[a + 2] = (byte)i.Register2;
                data[a + 3] = (byte)i.Register3;
                return;
            case OperandForm.FileRegReg:
                data[a] = i.Op!.Opcode;
                data[a + 1] = (byte)i.Register;              // opx 00
                data[a + 2] = (byte)i.Register2;
                return;
            case OperandForm.Unary:
                data[a] = i.Op!.Opcode;
                data[a + 1] = (byte)(Isa.UnaryBits(i.Op.Mnemonic) | i.Register);
                data[a + 2] = (byte)i.Register2;
                return;
            case OperandForm.Cond:
                data[a] = i.Op!.Opcode;
                data[a + 1] = (byte)((i.Cond << 4) | Isa.SetOneBit(i.Op.Mnemonic));
                return;
            case OperandForm.RegCond:
                data[a] = i.Op!.Opcode;
                data[a + 1] = (byte)i.Register;              // opx 00
                data[a + 2] = (byte)((i.Cond << 4) | Isa.SetOneBit(i.Op.Mnemonic));
                return;
        }

        var v = Evaluator.Eval(i.Operand!, this);
        int col = i.Operand!.Column;
        int len = i.Size;
        if (i.Mode == InstrMode.Lea)
        {
            data[a] = 0xC0;                                    // LIT24
            data[a + 4] = 0x50;                                // ADDR
            data[a + 5] = (byte)(0x40 | Isa.RegT | Isa.SpecialRegisters["PC"]); // T, PC
            if (v.IsConstant)
                throw new AsmException("LEA needs an address (a label); use LIT for a constant", col);
            if (ReferenceEquals(v.Base, i.Sec))
            {
                var err = Fields.Apply(data, a, RelocType.Lea24, v.Num, a);
                if (err is not null) throw new AsmException(err, col);
            }
            else AddReloc(i.Sec, a, RelocType.Lea24, v, i.Src);
            return;
        }
        switch (i.Form)
        {
            case OperandForm.UImm:                                  // ENTER, ENTER2, ENTER3; INTR, EXC
            {
                int bits = 8 * (len - 1);
                string what = i.Op!.Mnemonic.StartsWith("ENTER", StringComparison.OrdinalIgnoreCase)
                    ? "the size (in words)" : "the number";
                if (!v.IsConstant)
                    throw new AsmException($"{i.Op!.Mnemonic}: {what} must be a constant", col);
                if (v.Num < 0 || v.Num >= (1L << bits))
                    throw new AsmException($"{i.Op!.Mnemonic}: {Fields.Format(v.Num)} out of range 0..{Fields.Format((1L << bits) - 1)}", col);
                data[a] = i.Op!.Opcode;
                for (int k = 1; k < len; k++) data[a + k] = (byte)(v.Num >> (8 * (k - 1)));
                return;
            }
            case OperandForm.Mem3:                                  // imm8 offset
            {
                if (!v.IsConstant)
                    throw new AsmException($"{i.Op!.Mnemonic}: the offset must be a constant", col);
                if (!Isa.FitsSigned(v.Num, 8))
                    throw new AsmException($"{i.Op!.Mnemonic}: offset {Fields.Format(v.Num)} out of range -$80..$7F", col);
                var (size, sgn) = Isa.MemBits(i.Op!.Mnemonic);
                data[a] = i.Op.Opcode;
                data[a + 1] = (byte)(size | i.Register);
                data[a + 2] = (byte)(sgn | 0x40 | i.Register2);    // bit 6 = 1: imm8
                data[a + 3] = (byte)v.Num;
                return;
            }
            case OperandForm.ShiftImm:
                if (!v.IsConstant)
                    throw new AsmException($"{i.Op!.Mnemonic}: the count must be a constant", col);
                if (v.Num is < 0 or > 31)
                    throw new AsmException($"{i.Op!.Mnemonic}: count {Fields.Format(v.Num)} out of range 0..31", col);
                data[a] = i.Op!.Opcode;
                data[a + 1] = (byte)(Isa.ShiftBits(i.Op.Mnemonic) | (int)v.Num);
                return;
            case OperandForm.Tag:
            {
                var v2 = Evaluator.Eval(i.Operand2!, this);
                if (!v.IsConstant || !v2.IsConstant)
                    throw new AsmException("TTAG: the mask and the value must be constants", col);
                if (v.Num is < 0 or > 255)
                    throw new AsmException($"TTAG: mask {Fields.Format(v.Num)} out of range 0..$FF", col);
                if (v2.Num is < 0 or > 255)
                    throw new AsmException($"TTAG: value {Fields.Format(v2.Num)} out of range 0..$FF", i.Operand2!.Column);
                data[a] = i.Op!.Opcode;
                data[a + 1] = (byte)v.Num;
                data[a + 2] = (byte)v2.Num;
                return;
            }
            case OperandForm.RegImm8:
                if (!v.IsConstant)
                    throw new AsmException($"{i.Op!.Mnemonic} needs a constant, not an address", col);
                if (!Isa.FitsSigned(v.Num, 8))
                    throw new AsmException($"{i.Op!.Mnemonic}: constant {Fields.Format(v.Num)} out of range -$80..$7F", col);
                data[a] = i.Op!.Opcode;
                data[a + 1] = (byte)(Isa.Imm8Bits(i.Op.Mnemonic) | i.Register);
                data[a + 2] = (byte)v.Num;
                return;
            case OperandForm.MovImm:
                // the constant is in byte 2, where no relocation can go: it must be known here
                if (!v.IsConstant)
                    throw new AsmException("MOVI2 needs a constant, not an address", col);
                if (!Isa.FitsSigned(v.Num, 8))
                    throw new AsmException($"MOVI2: constant {Fields.Format(v.Num)} out of range -$80..$7F", col);
                data[a] = i.Op!.Opcode;
                data[a + 1] = (byte)(0x80 | i.Register);     // bit 7 = 1: MOVI2
                data[a + 2] = (byte)v.Num;
                return;
            case OperandForm.Imm:
            {
                data[a] = len switch { 2 => 0x40, 3 => 0x80, _ => 0xC0 };
                var type = len switch { 2 => RelocType.Lit8, 3 => RelocType.Lit16, _ => RelocType.Lit24 };
                if (v.IsConstant)
                {
                    var err = Fields.Apply(data, a, type, v.Num, 0);
                    if (err is not null)
                        throw new AsmException(i.Mode == InstrMode.LitAuto
                            ? $"constant {Fields.Format(v.Num)} does not fit in 24 bits: no LIT can load it" : err, col);
                }
                else AddReloc(i.Sec, a, type, v, i.Src);
                return;
            }
            case OperandForm.CondLocal:
            {
                data[a] = 0x41;
                data[a + 1] = (byte)(i.Cond << 4);
                if (v.IsConstant)
                {
                    if (v.Num is < 0 or > 15) throw new AsmException("CJMPL offset in the line must be 0 .. 15", col);
                    data[a + 1] |= (byte)v.Num;
                }
                else if (ReferenceEquals(v.Base, i.Sec))
                {
                    var err = Fields.Apply(data, a, RelocType.Cjmpl4, v.Num, a);
                    if (err is not null) throw new AsmException(err, col);
                }
                else AddReloc(i.Sec, a, RelocType.Cjmpl4, v, i.Src);
                return;
            }
            case OperandForm.CondRel:
            {
                int bits = len == 3 ? 12 : 20;
                var type = len == 3 ? RelocType.Cbr12 : RelocType.Cbrl20;
                data[a] = len == 3 ? (byte)0x81 : (byte)0xC1;
                data[a + 1] = (byte)(i.Cond << 4);
                Relative(i, v, type, bits, col);
                return;
            }
            case OperandForm.Local:                                 // UNEXT
            {
                data[a] = 0x48;
                data[a + 1] = 0;
                if (v.IsConstant)
                {
                    if (v.Num is < 0 or > 15) throw new AsmException("UNEXT offset in the line must be 0 .. 15", col);
                    data[a + 1] = (byte)v.Num;
                }
                else if (ReferenceEquals(v.Base, i.Sec))
                {
                    var err = Fields.Apply(data, a, RelocType.Cjmpl4, v.Num, a);
                    if (err is not null) throw new AsmException(err, col);
                }
                else AddReloc(i.Sec, a, RelocType.Cjmpl4, v, i.Src);
                return;
            }
            case OperandForm.RegRel:                                // NEXT2, NEXT3
            {
                data[a] = len == 3 ? (byte)0x88 : (byte)0xC8;
                data[a + 1] = (byte)i.Register;                     // opx 00
                Relative(i, v, len == 3 ? RelocType.Next8 : RelocType.Next16, len == 3 ? 8 : 16, col);
                return;
            }
            case OperandForm.Rel:
            {
                data[a] = len switch { 2 => 0x42, 3 => 0x82, _ => 0xC2 };
                var type = len switch { 2 => RelocType.Rel8, 3 => RelocType.Rel16, _ => RelocType.Rel24 };
                Relative(i, v, type, (len - 1) * 8, col);
                return;
            }
        }
    }

    /// <summary>A branch or call: a number is the offset itself, a label in this section is resolved here.</summary>
    private void Relative(InstrStmt i, Value v, RelocType type, int bits, int col)
    {
        var data = i.Sec.Data;
        int a = i.Addr;
        if (v.IsConstant)
        {
            if (!Isa.FitsSigned(v.Num, bits))
                throw new AsmException($"offset {v.Num} does not fit in {bits} bits", col);
            if (type is RelocType.Cbr12 or RelocType.Cbrl20) Fields.PutBranchOffset(data, a, v.Num, bits);
            else if (type is RelocType.Next8 or RelocType.Next16) Fields.WriteLe(data, a + 2, v.Num, bits / 8);
            else Fields.WriteLe(data, a + 1, v.Num, bits / 8);
        }
        else if (ReferenceEquals(v.Base, i.Sec))
        {
            var err = Fields.Apply(data, a, type, v.Num, a);
            if (err is not null) throw new AsmException(err, col);
        }
        else AddReloc(i.Sec, a, type, v, i.Src);
    }

    private void AddReloc(Section sec, int offset, RelocType type, Value v, SourceLine src)
    {
        int symIndex = v.Base switch
        {
            Section s => s.SymbolIndex,
            Symbol s => s.ObjIndex,
            _ => throw new AsmException("internal error: relocation without a base"),
        };
        sec.Relocs.Add(new ObjReloc
        {
            Offset = offset, Type = type, SymbolIndex = symIndex, Addend = v.Num,
            SourceFile = src.File, SourceLine = src.Line,
        });
    }

    // ------------------------------------------------------------------ object module

    private List<ObjSymbol> _objSymbols = [];

    private void AssignObjIndices()
    {
        _objSymbols = [];
        foreach (var s in _sections)
        {
            s.SymbolIndex = _objSymbols.Count;
            _objSymbols.Add(new ObjSymbol { Name = s.Name, Kind = SymbolKind.Section, SectionIndex = s.Index });
        }
        foreach (var s in _symbols.Values.Where(s => s.State == SymbolState.Import).OrderBy(s => s.Name, StringComparer.Ordinal))
        {
            s.ObjIndex = _objSymbols.Count;
            _objSymbols.Add(new ObjSymbol { Name = s.Name, Kind = SymbolKind.Import });
        }
    }

    private ObjectModule? BuildObject(string name)
    {
        var m = new ObjectModule { Name = name };
        foreach (var s in _sections)
        {
            var os = new ObjSection { Name = s.Name, Align = s.Align, IsBss = s.IsBss, Size = s.Size, Data = s.Data };
            os.Relocs.AddRange(s.Relocs);
            m.Sections.Add(os);
        }
        m.Symbols.AddRange(_objSymbols);
        foreach (var s in _symbols.Values.Where(s => s.Export).OrderBy(s => s.Name, StringComparer.Ordinal))
        {
            _evalLine = s.DefinedAt;
            try
            {
                var v = ((IEvalContext)this).Symbol(s.Name, 0);
                if (v.Base is Symbol) throw new AsmException($"exported symbol '{s.Name}' is an alias of an imported symbol");
                m.Symbols.Add(new ObjSymbol
                {
                    Name = s.Name, Kind = SymbolKind.Global,
                    SectionIndex = v.Base is Section sec ? sec.Index : -1, Value = v.Num,
                });
            }
            catch (AsmException ex) { Report(s.DefinedAt, ex.Message); }
        }
        return Diagnostics.HasErrors ? null : m;
    }

    // ------------------------------------------------------------------ listing

    private string MakeListing()
    {
        var sb = new StringBuilder();
        string? lastFile = null;
        foreach (var (line, stmts) in _listing)
        {
            if (line.File != lastFile)
            {
                sb.AppendLine($"; {line.File}");
                lastFile = line.File;
            }
            var bytes = new List<byte>();
            Stmt? first = null;
            int pad = 0;
            foreach (var st in stmts)
            {
                switch (st)
                {
                    case InstrStmt i:
                        first ??= st; pad += i.Pad;
                        bytes.AddRange(i.Sec.Data.AsSpan(i.Addr, i.Size).ToArray());
                        break;
                    case DataStmt d:
                        first ??= st;
                        bytes.AddRange(d.Sec.Data.AsSpan(d.Addr, d.Size).ToArray());
                        break;
                    case BytesStmt b:
                        first ??= st; bytes.AddRange(b.Bytes);
                        break;
                    case ResStmt r:
                        first ??= st;
                        if (!r.Sec.IsBss) bytes.AddRange(r.Sec.Data.AsSpan(r.Addr, r.Size).ToArray());
                        break;
                    case LabelStmt l when !l.Symbol.Hidden:
                        first ??= st;
                        break;
                }
            }
            string addr = first is null ? new string(' ', 15) : $"{first.Sec.Name,-6}:{AddrOf(first):X8}";
            var hex = string.Join(' ', bytes.Take(6).Select(b => b.ToString("X2")));
            if (bytes.Count > 6) hex += " ..";
            var padNote = pad > 0 ? $"+{pad}" : "";
            var marker = line.Macro is null ? " " : "+";
            sb.AppendLine($"{addr} {padNote,3} {hex,-20}{marker} {line.Text}");
        }
        sb.AppendLine();
        sb.AppendLine("; symbols");
        foreach (var s in _symbols.Values.Where(s => !s.Hidden && s.State != SymbolState.Undefined).OrderBy(s => s.Name, StringComparer.Ordinal))
        {
            string val;
            _evalLine = s.DefinedAt;
            var v = TryEval(new SymbolExpr(s.Name, 0), s.DefinedAt!);
            val = v switch
            {
                null => "?",
                { IsConstant: true } c => $"${c.Num:X8}",
                { Base: Section sec } r => $"{sec.Name}+${r.Num:X}",
                _ => "import",
            };
            var flags = s.Export ? " export" : "";
            sb.AppendLine($"; {s.Name,-32} {val}{flags}");
        }
        return sb.ToString();
    }

    private static int AddrOf(Stmt st) => st switch
    {
        LabelStmt l => l.Symbol.Offset,
        _ => st.Addr,
    };

    // ------------------------------------------------------------------ errors

    private void Report(SourceLine? sl, string message, int column = 0)
    {
        sl ??= _evalLine;
        if (sl is null) { Diagnostics.Error(Code, message); return; }
        var msg = sl.Macro is null ? message : $"{message} (in macro '{sl.Macro}')";
        Diagnostics.Error(Code, msg, sl.File, sl.Line, sl.Macro is null ? column : 0);
    }
}
