#!/usr/bin/env python3
"""heads.py: check (or fix) the headers of the FORTH kernel's words in forth.s.

  python tools/heads.py forth.s           check: every HEAD (USERV, GLOBV) links to the
                                          word before it, and its length is the name's
  python tools/heads.py --fix forth.s     write them in (prev and len may be _ )

Each word's header is one macro line,

    HEAD   xt, prev, "NAME", len, flags, inl
    USERV  xt, prev, "NAME", len, offset
    GLOBV  xt, prev, "NAME", len, offset

prev is the xt of the word before it in the file (0 for the first), len the number
of bytes of NAME. The assembler cannot work them out itself (a .res cannot depend on
a label difference), so this script does. It also checks the line

    KERNEL_LAST = xt

after the last word: where the FORTH word list starts after COLD.
"""
import re
import sys

MACROS = ("HEAD", "USERV", "GLOBV")
LINE = re.compile(r'^(\s*)(HEAD|USERV|GLOBV)(\s+)(.*)$')
LAST = re.compile(r'^(\s*KERNEL_LAST\s*=\s*)(\S+)(.*)$')


def split_args(s):
    """The arguments of a macro line, and its comment (from the ; on, or "")."""
    args, cur, q, esc = [], "", False, False
    for k, c in enumerate(s):
        if q:
            cur += c
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                q = False
        elif c == '"':
            q = True
            cur += c
        elif c == ",":
            args.append(cur.strip())
            cur = ""
        elif c == ";":
            args.append(cur.strip())
            return args, s[k:]
        else:
            cur += c
    args.append(cur.strip())
    return args, ""


def name_len(lit):
    body = lit[1:-1]
    n, i = 0, 0
    while i < len(body):
        if body[i] == "\\":
            i += 2 if body[i + 1] != "x" else 4
        else:
            i += 1
        n += 1
    return n


def main():
    fix = "--fix" in sys.argv
    files = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not files:
        sys.exit(__doc__)
    path = files[0]
    lines = open(path, encoding="utf-8").read().split("\n")
    prev, errors, words, last_line = "0", 0, 0, None
    in_macro = False
    for i, line in enumerate(lines):
        first = line.split(";")[0].split()
        if first and first[0].lower() == ".macro":
            in_macro = True
            continue
        if first and first[0].lower() in (".endmacro", ".endm"):
            in_macro = False
            continue
        if in_macro:
            continue
        m = LINE.match(line)
        if m:
            args, comment = split_args(m.group(4))
            xt, p, name, ln = args[0], args[1], args[2], args[3]
            want = str(name_len(name))
            if p != prev or ln != want:
                if fix:
                    args[1], args[3] = prev, want
                    lines[i] = m.group(1) + m.group(2) + m.group(3) + ", ".join(args) + \
                        (("    " + comment) if comment else "")
                else:
                    errors += 1
                    print("%s(%d): %s: prev %s (should be %s), len %s (should be %s)"
                          % (path, i + 1, name, p, prev, ln, want))
            prev = xt
            words += 1
            continue
        m = LAST.match(line)
        if m:
            last_line = i
    if last_line is None:
        print("%s: no KERNEL_LAST = <xt> line" % path)
        errors += 1
    else:
        m = LAST.match(lines[last_line])
        if m.group(2) != prev:
            if fix:
                lines[last_line] = m.group(1) + prev + m.group(3)
            else:
                errors += 1
                print("%s(%d): KERNEL_LAST = %s (should be %s)" % (path, last_line + 1,
                                                                   m.group(2), prev))
    if fix:
        open(path, "w", encoding="utf-8", newline="\n").write("\n".join(lines))
        print("heads: %d words in %s" % (words, path))
        return 0
    if errors:
        print("heads: %d error(s); python tools/heads.py --fix %s" % (errors, path))
        return 1
    print("heads: %d words, all linked" % words)
    return 0


if __name__ == "__main__":
    sys.exit(main())
