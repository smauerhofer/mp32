"""Turns font8x8_basic.h (Daniel Hepper, public domain) into font.hex for the font RAM.

256 characters x 8 rows, one byte per line of font.hex, bit 7 the pixel on the left.
Codes 0-127 come from the font; 128-255 are the same characters, inverted
(handy for a cursor or for reverse video).
Usage: python3 tools/make_font.py font8x8_basic.h font.hex
"""
import re, sys

src, out = sys.argv[1], sys.argv[2]
rows = [int(v, 16) for v in re.findall(r"0x([0-9A-Fa-f]{2})", open(src).read())]
assert len(rows) == 128 * 8, len(rows)

def flip(b):            # the source has the left pixel in bit 0
    return int(f"{b:08b}"[::-1], 2)

font = [flip(b) for b in rows]
font += [b ^ 0xFF for b in font]
with open(out, "w") as f:
    f.writelines(f"{b:02X}\n" for b in font)
print(f"{out}: {len(font)} bytes")
