"""Writes palette.hex: the 256 colors the video unit starts with, one word a line,
00BBGGRR (red in bits 7..0), as the processor writes them.

    0 - 15     the 16 colors of the Commodore 64 (the book's palette)
    16 - 231   a cube of 6 x 6 x 6 colors: 16 + 36*r + 6*g + b, each 0 - 5
    232 - 255  24 grays, from near black to near white

The processor can change any entry (see video.v); this is only where it starts.
Usage: python3 tools/make_palette.py palette.hex
"""
import sys

C64 = [0x000000, 0xFFFFFF, 0x880000, 0xAAFFEE, 0xCC44CC, 0x00CC55, 0x0000AA, 0xEEEE77,
       0xDD8855, 0x664400, 0xFF7777, 0x333333, 0x777777, 0xAAFF66, 0x0088FF, 0xBBBBBB]
LEVELS = [0x00, 0x5F, 0x87, 0xAF, 0xD7, 0xFF]

pal = list(C64)
for r in range(6):
    for g in range(6):
        for b in range(6):
            pal.append((LEVELS[r] << 16) | (LEVELS[g] << 8) | LEVELS[b])
for n in range(24):
    v = 8 + 10 * n
    pal.append((v << 16) | (v << 8) | v)
assert len(pal) == 256

with open(sys.argv[1], "w") as f:
    f.writelines(f"00{c & 0xFF:02X}{(c >> 8) & 0xFF:02X}{c >> 16:02X}\n" for c in pal)
print(f"{sys.argv[1]}: 256 colors")
