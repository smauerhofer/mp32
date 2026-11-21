using System.Text;

namespace Mp32.Assembler;

public enum TokenKind { Ident, Number, String, Punct, End }

public readonly record struct Token(TokenKind Kind, string Text, long Value, int Column, byte[]? Bytes = null)
{
    public bool Is(string punct) => Kind == TokenKind.Punct && Text == punct;
    public bool IsIdent(string name) => Kind == TokenKind.Ident && string.Equals(Text, name, StringComparison.OrdinalIgnoreCase);
    public override string ToString() => Kind switch
    {
        TokenKind.End => "end of line",
        TokenKind.String => $"\"{Text}\"",
        _ => $"'{Text}'",
    };
}

public sealed class AsmException(string message, int column = 0) : Exception(message)
{
    public int Column { get; } = column;
}

/// <summary>Splits one source line into tokens. A ';' starts a comment.</summary>
public static class Lexer
{
    private static readonly string[] TwoCharPuncts = ["<<", ">>", "<=", ">=", "==", "!=", "&&", "||"];

    public static bool IsIdentStart(char c) => char.IsLetter(c) || c is '_' or '.' or '@';
    public static bool IsIdentPart(char c) => char.IsLetterOrDigit(c) || c is '_' or '.' or '@' or '$';

    public static List<Token> Tokenize(string line)
    {
        var tokens = new List<Token>();
        int i = 0;
        while (i < line.Length)
        {
            char c = line[i];
            if (c == ';') break;
            if (char.IsWhiteSpace(c)) { i++; continue; }
            int start = i;

            if (IsIdentStart(c))
            {
                i++;
                while (i < line.Length && IsIdentPart(line[i])) i++;
                tokens.Add(new Token(TokenKind.Ident, line[start..i], 0, start + 1));
                continue;
            }
            if (char.IsDigit(c))
            {
                tokens.Add(LexNumber(line, ref i));
                continue;
            }
            if (c == '$' && i + 1 < line.Length && Uri.IsHexDigit(line[i + 1]))
            {
                i++;
                tokens.Add(Digits(line, ref i, 16, start));
                continue;
            }
            // %0101 is binary where an operand is expected, or after a space with none
            // after it ("LIT %101"); write the modulo operator with spaces: a % b
            if (c == '%' && i + 1 < line.Length && line[i + 1] is '0' or '1' &&
                (!PrevIsOperand(tokens) || (i > 0 && char.IsWhiteSpace(line[i - 1]))))
            {
                i++;
                tokens.Add(Digits(line, ref i, 2, start));
                continue;
            }
            if (c == '\'')
            {
                i++;
                if (i >= line.Length) throw new AsmException("unterminated character constant", start + 1);
                int ch = ReadChar(line, ref i, '\'', start);
                if (i >= line.Length || line[i] != '\'') throw new AsmException("unterminated character constant", start + 1);
                i++;
                tokens.Add(new Token(TokenKind.Number, line[start..i], ch, start + 1));
                continue;
            }
            if (c == '"')
            {
                i++;
                var bytes = new List<byte>();
                while (true)
                {
                    if (i >= line.Length) throw new AsmException("unterminated string", start + 1);
                    if (line[i] == '"') { i++; break; }
                    int ch = ReadChar(line, ref i, '"', start);
                    if (ch > 0xFF)
                        bytes.AddRange(Encoding.UTF8.GetBytes(char.ConvertFromUtf32(ch)));
                    else
                        bytes.Add((byte)ch);
                }
                var raw = line[(start + 1)..(i - 1)];
                tokens.Add(new Token(TokenKind.String, raw, 0, start + 1, bytes.ToArray()));
                continue;
            }
            if (i + 1 < line.Length && TwoCharPuncts.Contains(line.Substring(i, 2)))
            {
                tokens.Add(new Token(TokenKind.Punct, line.Substring(i, 2), 0, start + 1));
                i += 2;
                continue;
            }
            if ("+-*/%&|^~!(),:=<>#".Contains(c))
            {
                tokens.Add(new Token(TokenKind.Punct, c.ToString(), 0, start + 1));
                i++;
                continue;
            }
            throw new AsmException($"unexpected character '{c}'", start + 1);
        }
        tokens.Add(new Token(TokenKind.End, "", 0, i + 1));
        return tokens;
    }

    private static bool PrevIsOperand(List<Token> tokens) =>
        tokens.Count > 0 && (tokens[^1].Kind is TokenKind.Ident or TokenKind.Number || tokens[^1].Is(")"));

    private static Token LexNumber(string line, ref int i)
    {
        int start = i;
        if (line[i] == '0' && i + 1 < line.Length && (line[i + 1] is 'x' or 'X'))
        {
            i += 2;
            return Digits(line, ref i, 16, start);
        }
        if (line[i] == '0' && i + 2 < line.Length && (line[i + 1] is 'b' or 'B') && line[i + 2] is '0' or '1')
        {
            i += 2;
            return Digits(line, ref i, 2, start);
        }
        return Digits(line, ref i, 10, start);
    }

    private static Token Digits(string line, ref int i, int radix, int start)
    {
        long v = 0;
        int n = 0;
        while (i < line.Length)
        {
            char c = line[i];
            if (c == '_') { i++; continue; }
            int d = c >= '0' && c <= '9' ? c - '0' :
                    c >= 'a' && c <= 'f' ? c - 'a' + 10 :
                    c >= 'A' && c <= 'F' ? c - 'A' + 10 : 99;
            if (d >= radix)
            {
                if (char.IsLetterOrDigit(c)) throw new AsmException($"bad digit '{c}' in number", i + 1);
                break;
            }
            v = checked(v * radix + d);
            n++;
            i++;
        }
        if (n == 0) throw new AsmException("number has no digits", start + 1);
        if (v > 0xFFFF_FFFFL) throw new AsmException("number does not fit in 32 bits", start + 1);
        return new Token(TokenKind.Number, line[start..i], v, start + 1);
    }

    private static int ReadChar(string line, ref int i, char quote, int start)
    {
        char c = line[i++];
        if (c != '\\') return char.IsHighSurrogate(c) && i < line.Length ? char.ConvertToUtf32(c, line[i++]) : c;
        if (i >= line.Length) throw new AsmException("bad escape", start + 1);
        char e = line[i++];
        switch (e)
        {
            case 'n': return '\n';
            case 'r': return '\r';
            case 't': return '\t';
            case '0': return 0;
            case 'e': return 27;
            case '\\': return '\\';
            case '\'': return '\'';
            case '"': return '"';
            case 'x':
            {
                int v = 0, n = 0;
                while (n < 2 && i < line.Length && Uri.IsHexDigit(line[i])) { v = v * 16 + Convert.ToInt32(line[i].ToString(), 16); i++; n++; }
                if (n == 0) throw new AsmException("\\x needs hex digits", start + 1);
                return v;
            }
            default: throw new AsmException($"unknown escape '\\{e}'", start + 1);
        }
    }
}
