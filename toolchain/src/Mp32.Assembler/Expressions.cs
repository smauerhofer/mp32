namespace Mp32.Assembler;

public abstract record Expr(int Column);
public sealed record NumberExpr(long Value, int Col) : Expr(Col);
public sealed record SymbolExpr(string Name, int Col) : Expr(Col);
public sealed record PcExpr(int Col) : Expr(Col);
public sealed record UnaryExpr(string Op, Expr Operand, int Col) : Expr(Col);
public sealed record BinaryExpr(string Op, Expr Left, Expr Right, int Col) : Expr(Col);

/// <summary>
/// The value of an expression: a number, or a number relative to a base (a
/// section of this module, or an imported symbol) that only the linker knows.
/// </summary>
public readonly record struct Value(long Num, object? Base = null)
{
    public bool IsConstant => Base is null;
}

public interface IEvalContext
{
    Value Symbol(string name, int column);
    Value Pc(int column);
}

public static class Evaluator
{
    public static Value Eval(Expr e, IEvalContext ctx)
    {
        switch (e)
        {
            case NumberExpr n: return new Value(n.Value);
            case SymbolExpr s: return ctx.Symbol(s.Name, s.Column);
            case PcExpr p: return ctx.Pc(p.Column);
            case UnaryExpr u:
            {
                var a = Eval(u.Operand, ctx);
                if (u.Op == "+") return a;
                RequireConstant(a, u);
                return new Value(u.Op switch
                {
                    "-" => -a.Num,
                    "~" => ~a.Num & 0xFFFF_FFFFL,
                    "!" => a.Num == 0 ? 1 : 0,
                    _ => throw new AsmException($"unknown operator {u.Op}", u.Column),
                });
            }
            case BinaryExpr b:
            {
                var l = Eval(b.Left, ctx);
                var r = Eval(b.Right, ctx);
                switch (b.Op)
                {
                    case "+":
                        if (l.Base is not null && r.Base is not null)
                            throw new AsmException("cannot add two relocatable values", b.Column);
                        return new Value(l.Num + r.Num, l.Base ?? r.Base);
                    case "-":
                        if (r.Base is null) return new Value(l.Num - r.Num, l.Base);
                        if (ReferenceEquals(l.Base, r.Base)) return new Value(l.Num - r.Num);
                        throw new AsmException("cannot subtract values in different sections", b.Column);
                    case "==" or "!=" when ReferenceEquals(l.Base, r.Base):
                        return new Value((l.Num == r.Num) == (b.Op == "==") ? 1 : 0);
                }
                RequireConstant(l, b);
                RequireConstant(r, b);
                long x = l.Num, y = r.Num;
                return new Value(b.Op switch
                {
                    "*" => x * y,
                    "/" => y == 0 ? throw new AsmException("division by zero", b.Column) : x / y,
                    "%" => y == 0 ? throw new AsmException("division by zero", b.Column) : x % y,
                    "&" => x & y,
                    "|" => x | y,
                    "^" => x ^ y,
                    "<<" => y is < 0 or > 63 ? 0 : x << (int)y,
                    ">>" => y is < 0 or > 63 ? 0 : x >> (int)y,
                    "==" => x == y ? 1 : 0,
                    "!=" => x != y ? 1 : 0,
                    "<" => x < y ? 1 : 0,
                    ">" => x > y ? 1 : 0,
                    "<=" => x <= y ? 1 : 0,
                    ">=" => x >= y ? 1 : 0,
                    "&&" => x != 0 && y != 0 ? 1 : 0,
                    "||" => x != 0 || y != 0 ? 1 : 0,
                    _ => throw new AsmException($"unknown operator {b.Op}", b.Column),
                });
            }
            default:
                throw new AsmException("bad expression", e.Column);
        }
    }

    private static void RequireConstant(Value v, Expr e)
    {
        if (!v.IsConstant)
            throw new AsmException("operator needs constant operands (an address is only known after linking)", e.Column);
    }
}

/// <summary>Parses an expression from a slice of tokens, with C precedence.</summary>
public sealed class ExprParser
{
    private readonly List<Token> _t;
    private int _i;
    private readonly int _end;
    private readonly Func<string, string> _mangle;

    private static readonly string[][] Levels =
    [
        ["||"], ["&&"], ["|"], ["^"], ["&"], ["==", "!="], ["<", ">", "<=", ">="], ["<<", ">>"], ["+", "-"], ["*", "/", "%"],
    ];

    private ExprParser(List<Token> tokens, int start, int end, Func<string, string> mangle)
    {
        _t = tokens; _i = start; _end = end; _mangle = mangle;
    }

    /// <summary>Parses tokens[start..end) as one whole expression.</summary>
    public static Expr Parse(List<Token> tokens, int start, int end, Func<string, string> mangle)
    {
        if (start >= end) throw new AsmException("expression expected", tokens[Math.Min(start, tokens.Count - 1)].Column);
        var p = new ExprParser(tokens, start, end, mangle);
        var e = p.Level(0);
        if (p._i < end) throw new AsmException($"unexpected {tokens[p._i]} in expression", tokens[p._i].Column);
        return e;
    }

    private Token Peek => _i < _end ? _t[_i] : new Token(TokenKind.End, "", 0, _t[Math.Min(_i, _t.Count - 1)].Column);

    private Expr Level(int level)
    {
        if (level == Levels.Length) return Unary();
        var left = Level(level + 1);
        while (Peek.Kind == TokenKind.Punct && Levels[level].Contains(Peek.Text))
        {
            var op = _t[_i++];
            var right = Level(level + 1);
            left = new BinaryExpr(op.Text, left, right, op.Column);
        }
        return left;
    }

    private Expr Unary()
    {
        var t = Peek;
        if (t.Kind == TokenKind.Punct && t.Text is "-" or "+" or "~" or "!")
        {
            _i++;
            return new UnaryExpr(t.Text, Unary(), t.Column);
        }
        return Primary();
    }

    private Expr Primary()
    {
        var t = Peek;
        switch (t.Kind)
        {
            case TokenKind.Number:
                _i++;
                return new NumberExpr(t.Value, t.Column);
            case TokenKind.Ident:
                _i++;
                return new SymbolExpr(_mangle(t.Text), t.Column);
            case TokenKind.Punct when t.Text == "*":
                _i++;
                return new PcExpr(t.Column);
            case TokenKind.Punct when t.Text == "(":
            {
                _i++;
                var e = Level(0);
                if (!Peek.Is(")")) throw new AsmException("')' expected", Peek.Column);
                _i++;
                return e;
            }
            default:
                throw new AsmException($"unexpected {t} in expression", t.Column);
        }
    }
}
