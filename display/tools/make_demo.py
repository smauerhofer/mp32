"""Writes vram.hex: a mixed screen to look at before any processor writes to it.

The layout it is made for (the parameters of video.v in the demo):
    row 0         text: a status line                       text row 0
    rows 1 - 49   graphics: 640 x 392 pixels, lines 8 - 399
    rows 50 - 59  text: the character set and the colors    text rows 1 - 10
    ROW_MODES  = 64'h0003_FFFF_FFFF_FFFE   (bits 1 - 49 set)
    TEXT_BASE  = 32000    (= 0x7D00: the bytes of lines 400 - 410, never shown as graphics)
    COLOR_BASE = 32880    (= 0x8070)

Usage: python3 tools/make_demo.py vram.hex
"""
import math, sys

SIZE = 38912
TEXT_BASE, COLOR_BASE = 32000, 32880
vram = bytearray(SIZE)

# ---------------------------------------------------------------- graphics
def plot(x, y):
    if 0 <= x < 640 and 8 <= y < 400:
        vram[y * 80 + x // 8] |= 0x80 >> (x % 8)

for x in range(640):                       # a frame
    plot(x, 8); plot(x, 399)
for y in range(8, 400):
    plot(0, y); plot(639, y)
for y in range(16, 400, 24):               # a dotted grid
    for x in range(0, 640, 4):
        plot(x, y)
for x in range(16, 640, 32):
    for y in range(8, 400, 4):
        plot(x, y)
for y in range(8, 400):                    # a filled disc
    for x in range(120, 280):
        if (x - 200) ** 2 + (y - 200) ** 2 < 70 ** 2:
            plot(x, y)
for t in range(4000):                      # a Lissajous figure
    a = t / 4000 * 2 * math.pi
    plot(int(460 + 140 * math.sin(3 * a)), int(200 + 140 * math.sin(2 * a + 0.5)))
for x in range(640):                       # a sine wave, three pixels thick
    y = int(340 + 40 * math.sin(x / 40))
    for d in range(3):
        plot(x, y + d)

# ---------------------------------------------------------------- text
def text(k, col, s, ink=1, paper=6):
    for i, ch in enumerate(s):
        vram[TEXT_BASE + k * 80 + col + i] = ord(ch) if isinstance(ch, str) else ch
        vram[COLOR_BASE + k * 80 + col + i] = (ink << 4) | paper

for k in range(11):                        # 11 text rows: blank, white on blue
    text(k, 0, " " * 80)
text(0, 0, " mp32 display" + " " * 67, ink=0, paper=13)
text(0, 15, "row 0 text  |  rows 1-49 graphics, 1 bit  |  rows 50-59 text", ink=0, paper=13)
text(1, 2, "All 256 characters (128-255 are 0-127 inverted):", ink=7)
for code in range(256):
    k, c = 2 + code // 64, 2 + code % 64
    vram[TEXT_BASE + k * 80 + c] = code
for n in range(16):
    text(7, 2 + n * 4, f"{n:2d} ", ink=n, paper=0)
    text(8, 2 + n * 4, "   ", ink=0, paper=n)
text(10, 2, "Row modes at 0x30010, text_base at 0x30020, color_base at 0x30022", ink=14)

with open(sys.argv[1], "w") as f:
    f.writelines(f"{b:02X}\n" for b in vram)
print(f"{sys.argv[1]}: {SIZE} bytes")
