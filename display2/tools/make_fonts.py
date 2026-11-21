"""Writes fonts.hex: 4 fonts for the font RAM, made from font.hex (see make_font.py).

    font 0   font.hex as it is
    font 1   bold: each row ORed with itself one pixel to the right
    font 2   italic: the top rows moved right, the bottom rows left
    font 3   underlined: the bottom row of every character set

2,048 bytes a font, bit 7 the pixel on the left. fonts.hex holds them as words, one
a line, the way the font RAM holds them: 4 rows of a character a word, the top row
in bits 7..0 (512 words a font).
Usage: python3 tools/make_fonts.py font.hex fonts.hex
"""
import sys

base = [int(l, 16) for l in open(sys.argv[1]) if l.strip()]
assert len(base) == 2048, len(base)

def bold(b, row):      return b | (b >> 1)
def italic(b, row):    return [(b >> 1), (b >> 1), (b >> 1), b, b, (b << 1) & 0xFF,
                               (b << 1) & 0xFF, (b << 1) & 0xFF][row]
def underline(b, row): return 0xFF if row == 7 else b

fonts = list(base)
for style in (bold, italic, underline):
    fonts += [style(b, i % 8) for i, b in enumerate(base)]

words = [fonts[i] | fonts[i + 1] << 8 | fonts[i + 2] << 16 | fonts[i + 3] << 24
         for i in range(0, len(fonts), 4)]
with open(sys.argv[2], "w") as f:
    f.writelines(f"{w:08X}\n" for w in words)
print(f"{sys.argv[2]}: {len(words)} words, {len(fonts) // 2048} fonts")
