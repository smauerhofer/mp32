"""Writes petscii.hex: the font RAM the computer starts with, a PETSCII font as font 0
and fonts 1 .. 3 empty (for fonts loaded later, e.g. by FORTH from the SD card).

The 256 characters are in the order of the Commodore PET's screen codes (its
character ROM, the graphics set), so the code byte of a text cell is a screen code:

    $00 - $1F   @ A .. Z [ (pound) ] (up arrow) (left arrow)
    $20 - $3F   space ! " # $ % & ' ( ) * + , - . / 0 .. 9 : ; < = > ?
    $40 - $7F   the 64 graphics characters: lines, corners, blocks, the card suits,
                circles, pi, triangles, checkerboards
    $80 - $FF   the same 128, inverted (reverse video; $A0 is a solid block: the cursor)

From ASCII to a screen code: below $40 it is the same; from $40 on it is the code AND
$1F (so @ A .. Z and ` a .. z alike become $00 .. $1A: on the screen there are capitals
only, as on the PET; \\ ^ _ show as pound, up arrow, left arrow).

The letters, digits and signs are taken from font.hex (font8x8_basic, Daniel Hepper,
public domain); the pound sign, the arrows and the 64 graphics characters are drawn
here. They follow the PET's set in what each character is, not its ROM bit for bit.

2,048 bytes a font, bit 7 the pixel on the left, the top row first. petscii.hex holds
words, one a line, the way the font RAM holds them: 4 rows of a character a word, the
top row in bits 7..0 (512 words a font, 2,048 for the 4 fonts).

Usage: python3 tools/make_petscii.py font.hex petscii.hex [petscii.bin]
       petscii.bin: font 0 alone as 2,048 raw bytes (for the SD card)
"""
import sys

ascii_font = [int(l, 16) for l in open(sys.argv[1]) if l.strip()]
assert len(ascii_font) == 2048, len(ascii_font)


def from_ascii(c):
    return ascii_font[8 * c: 8 * c + 8]


def picture(*rows):
    """8 strings of 8 characters, '#' for a pixel."""
    assert len(rows) == 8 and all(len(r) == 8 for r in rows), rows
    return [int(r.replace('#', '1').replace('.', '0'), 2) for r in rows]


def cells(test):
    """A character from a test on (row, column)."""
    return [sum(0x80 >> c for c in range(8) if test(r, c)) for r in range(8)]


def hline(*rows):  return cells(lambda r, c: r in rows)
def vline(*cols):  return cells(lambda r, c: c in cols)
def orr(*chars):   return [a | b for a, b in zip(*chars)] if len(chars) == 2 else orr(chars[0], orr(*chars[1:]))


CH, CV = (3, 4), (3, 4)                 # the middle: rows / columns 3 and 4
mid_h = hline(*CH)
mid_v = vline(*CV)
top_half_v = cells(lambda r, c: c in CV and r <= 4)
bot_half_v = cells(lambda r, c: c in CV and r >= 3)
left_half_h = cells(lambda r, c: r in CH and c <= 4)
right_half_h = cells(lambda r, c: r in CH and c >= 3)

# ---------------------------------------------------------------- $00 - $3F
chars = [None] * 128
chars[0x00] = from_ascii(ord('@'))
for i in range(26):
    chars[0x01 + i] = from_ascii(ord('A') + i)
chars[0x1B] = from_ascii(ord('['))
chars[0x1C] = picture(                  # pound
    "..###...",
    ".##.##..",
    ".##.....",
    "####....",
    ".##.....",
    ".##...#.",
    "######..",
    "........")
chars[0x1D] = from_ascii(ord(']'))
chars[0x1E] = picture(                  # up arrow
    "...##...",
    "..####..",
    ".######.",
    "...##...",
    "...##...",
    "...##...",
    "...##...",
    "........")
chars[0x1F] = picture(                  # left arrow
    "........",
    "..#.....",
    ".##.....",
    "#######.",
    "#######.",
    ".##.....",
    "..#.....",
    "........")
for c in range(0x20, 0x40):
    chars[c] = from_ascii(c)

# ---------------------------------------------------------------- $40 - $7F
g = {}
g[0x40] = mid_h                                         # horizontal line, middle
g[0x41] = picture(                                      # spade
    "...##...",
    "..####..",
    ".######.",
    "########",
    "########",
    "...##...",
    "..####..",
    "........")
g[0x42] = mid_v                                         # vertical line, middle
g[0x43] = hline(2, 3)                                   # horizontal lines, a little up ...
g[0x44] = hline(1, 2)
g[0x45] = hline(0, 1)
g[0x46] = hline(4, 5)                                   # ... and down
g[0x47] = vline(2, 3)                                   # vertical lines, a little left ...
g[0x48] = vline(4, 5)                                   # ... and right
g[0x49] = picture(                                      # rounded corner: left to bottom
    "........",
    "........",
    "........",
    "#####...",
    "######..",
    "....##..",
    "...##...",
    "...##...")
g[0x4A] = picture(                                      # rounded corner: top to right
    "...##...",
    "...##...",
    "..##....",
    "..######",
    "...#####",
    "........",
    "........",
    "........")
g[0x4B] = picture(                                      # rounded corner: top to left
    "...##...",
    "...##...",
    "....##..",
    "######..",
    "#####...",
    "........",
    "........",
    "........")
g[0x4C] = orr(vline(0, 1), hline(6, 7))                 # corner at the bottom left
g[0x4D] = cells(lambda r, c: c == r or c == r - 1)      # diagonal \
g[0x4E] = cells(lambda r, c: c == 7 - r or c == 8 - r)  # diagonal /
g[0x4F] = orr(vline(0, 1), hline(0, 1))                 # corner at the top left
g[0x50] = orr(vline(6, 7), hline(0, 1))                 # corner at the top right
g[0x51] = picture(                                      # filled circle
    "........",
    "..####..",
    ".######.",
    ".######.",
    ".######.",
    ".######.",
    "..####..",
    "........")
g[0x52] = hline(5, 6)                                   # horizontal line, low
g[0x53] = picture(                                      # heart
    ".##.##..",
    "#######.",
    "#######.",
    "#######.",
    ".#####..",
    "..###...",
    "...#....",
    "........")
g[0x54] = vline(1, 2)                                   # vertical line, left
g[0x55] = picture(                                      # rounded corner: right to bottom
    "........",
    "........",
    "........",
    "...#####",
    "..######",
    "..##....",
    "...##...",
    "...##...")
g[0x56] = orr(g[0x4D], g[0x4E])                         # cross of the diagonals
g[0x57] = picture(                                      # circle
    "........",
    "..####..",
    ".##..##.",
    ".#....#.",
    ".#....#.",
    ".##..##.",
    "..####..",
    "........")
g[0x58] = picture(                                      # club
    "...##...",
    "..####..",
    "..####..",
    "##.##.##",
    "########",
    "##.##.##",
    "...##...",
    "..####..")
g[0x59] = vline(5, 6)                                   # vertical line, right
g[0x5A] = picture(                                      # diamond
    "...##...",
    "..####..",
    ".######.",
    "########",
    ".######.",
    "..####..",
    "...##...",
    "........")
g[0x5B] = orr(mid_h, mid_v)                             # cross
g[0x5C] = cells(lambda r, c: c < 4 and (r + c) % 2 == 0)   # checkerboard, left half
g[0x5D] = mid_v                                         # vertical line, middle (again)
g[0x5E] = picture(                                      # pi
    "........",
    "........",
    "#######.",
    ".##.##..",
    ".##.##..",
    ".##.##..",
    ".##..##.",
    "........")
g[0x5F] = cells(lambda r, c: c >= r)                    # triangle, upper right
g[0x60] = cells(lambda r, c: False)                     # (shifted) space
g[0x61] = cells(lambda r, c: c < 4)                     # left half
g[0x62] = cells(lambda r, c: r >= 4)                    # lower half
g[0x63] = hline(0)                                      # top line
g[0x64] = hline(7)                                      # bottom line
g[0x65] = vline(0)                                      # left line
g[0x66] = cells(lambda r, c: (r + c) % 2 == 0)          # checkerboard
g[0x67] = vline(7)                                      # right line
g[0x68] = cells(lambda r, c: r >= 4 and (r + c) % 2 == 0)  # checkerboard, lower half
g[0x69] = cells(lambda r, c: c <= 7 - r)                # triangle, upper left
g[0x6A] = cells(lambda r, c: c >= 6)                    # right quarter
g[0x6B] = orr(mid_v, right_half_h)                      # tee: right
g[0x6C] = cells(lambda r, c: r >= 4 and c >= 4)         # quadrant, lower right
g[0x6D] = orr(top_half_v, right_half_h)                 # corner: top and right
g[0x6E] = orr(bot_half_v, left_half_h)                  # corner: left and bottom
g[0x6F] = cells(lambda r, c: r >= 6)                    # lower quarter
g[0x70] = orr(bot_half_v, right_half_h)                 # corner: right and bottom
g[0x71] = orr(mid_h, top_half_v)                        # tee: up
g[0x72] = orr(mid_h, bot_half_v)                        # tee: down
g[0x73] = orr(mid_v, left_half_h)                       # tee: left
g[0x74] = cells(lambda r, c: c < 2)                     # left quarter
g[0x75] = cells(lambda r, c: c < 3)                     # left three eighths
g[0x76] = cells(lambda r, c: c >= 5)                    # right three eighths
g[0x77] = cells(lambda r, c: r < 2)                     # upper quarter
g[0x78] = cells(lambda r, c: r < 3)                     # upper three eighths
g[0x79] = cells(lambda r, c: r >= 5)                    # lower three eighths
g[0x7A] = orr(vline(6, 7), hline(6, 7))                 # corner at the bottom right
g[0x7B] = cells(lambda r, c: r >= 4 and c < 4)          # quadrant, lower left
g[0x7C] = cells(lambda r, c: r < 4 and c >= 4)          # quadrant, upper right
g[0x7D] = orr(top_half_v, left_half_h)                  # corner: top and left
g[0x7E] = cells(lambda r, c: r < 4 and c < 4)           # quadrant, upper left
g[0x7F] = orr(g[0x7E], g[0x6C])                         # quadrants upper left, lower right
for c, rows in g.items():
    chars[c] = rows

assert all(ch is not None and len(ch) == 8 for ch in chars), [i for i, ch in enumerate(chars) if ch is None]

font0 = [b for ch in chars for b in ch]
font0 += [b ^ 0xFF for b in font0]                      # $80 - $FF: reverse video
assert len(font0) == 2048

fonts = font0 + [0] * (3 * 2048)                        # fonts 1 .. 3: empty
words = [fonts[i] | fonts[i + 1] << 8 | fonts[i + 2] << 16 | fonts[i + 3] << 24
         for i in range(0, len(fonts), 4)]
with open(sys.argv[2], "w") as f:
    f.writelines(f"{w:08X}\n" for w in words)
print(f"{sys.argv[2]}: {len(words)} words, font 0 PETSCII, fonts 1 .. 3 empty")

if len(sys.argv) > 3:
    with open(sys.argv[3], "wb") as f:
        f.write(bytes(font0))
    print(f"{sys.argv[3]}: {len(font0)} bytes")
