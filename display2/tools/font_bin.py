"""Turns a font RAM file (words, one a line, as fonts.hex and petscii.hex hold them)
into raw bytes, the way the font RAM holds them: 2,048 bytes a font, 8 a character,
the top row first, bit 7 the pixel on the left. For the SD card: FORTH reads such a
file from it into a font of the font RAM ($FFFF_8000 + 2048 * the font).

Usage: python3 tools/font_bin.py fonts.hex fonts.bin
"""
import sys

words = [int(l, 16) for l in open(sys.argv[1]) if l.strip()]
data = b"".join(w.to_bytes(4, "little") for w in words)
assert len(data) % 2048 == 0, len(data)
with open(sys.argv[2], "wb") as f:
    f.write(data)
print(f"{sys.argv[2]}: {len(data)} bytes, {len(data) // 2048} fonts")
