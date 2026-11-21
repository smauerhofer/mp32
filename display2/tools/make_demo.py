"""Writes text.hex, pixels.hex and modes.hex: a screen to look at before any
processor writes.

They go into the SDRAM at the video unit's text_base and pixel_base (0x780000 and
0x790000 by default; video_tb.v loads them there, on the board the processor has
to write them). See video.v:
    text.hex     19,200 bytes: 60 rows of 80 words: code, font, paper, ink
    pixels.hex  307,200 bytes: 480 lines of 640 bytes, one color number each
    modes.hex       180 words: the mode RAM, 3 words a row, 1 bit a block

The demo's blocks:
    row 0         text: a status line
    rows 1 - 49   graphics in columns 0 - 59, a text window in columns 60 - 79,
                  and a caption of text cut into the graphics (rows 45 - 47)
    rows 50 - 59  text: the fonts and the palette, with a small picture of
                  graphics in rows 54 - 58, columns 68 - 77
Every block has both its text and its pixels; the ones not shown in the demo have
something in them too, so a frame of all text or all graphics shows something.

Usage: python3 tools/make_demo.py text.hex pixels.hex modes.hex
"""
import math, sys

TEXT, PIXELS, SIZE = 0, 19200, 326400     # the two, one after the other, here
scr = bytearray(SIZE)

# ---------------------------------------------------------------- pixels
def plot(x, y, c):
    if 0 <= x < 640 and 0 <= y < 480:
        scr[PIXELS + y * 640 + x] = c

def cube(r, g, b):                         # palette entry of the 6x6x6 cube
    return 16 + 36 * r + 6 * g + b

for y in range(480):                       # background: a dark blue-green gradient
    for x in range(640):
        plot(x, y, cube(0, (y * 3) // 480, 1 + (x * 2) // 640))
for y in range(0, 8):                      # under row 0: stripes
    for x in range(640):
        plot(x, y, 232 + (x // 16) % 24)
for y in range(16, 144):                   # all 256 colors, 16 x 16 squares of 8 x 8
    for x in range(16, 144):
        plot(x, y, ((y - 16) // 8) * 16 + (x - 16) // 8)
for y in range(16, 376):                   # red-green plane of the cube, blue = 2
    for x in range(160, 340):
        plot(x, y, cube(min(5, (x - 160) // 30), min(5, (y - 16) // 60), 2))
for y in range(8, 400):                    # a disc in rings of color
    for x in range(360, 620):
        d = math.hypot(x - 490, y - 200)
        if d < 120:
            plot(x, y, 16 + int(d) % 216)
for x in range(640):                       # a sine wave in yellow, 3 pixels thick
    yy = int(340 + 40 * math.sin(x / 40))
    for d in range(3):
        plot(x, yy + d, cube(5, 5, 0))
for x in range(640):                       # a white frame around lines 8 - 399
    plot(x, 8, 1); plot(x, 399, 1)
for y in range(8, 400):
    plot(0, y, 1); plot(639, y, 1)
for y in range(400, 480):                  # under rows 50 - 59: diagonal stripes
    for x in range(640):
        plot(x, y, 232 + ((x + y) // 8) % 24)

# ---------------------------------------------------------------- text
def cell(r, c, code, font=0, paper=6, ink=1):
    a = TEXT + (r * 80 + c) * 4
    scr[a:a + 4] = bytes([code, font, paper, ink])

def text(r, c, s, font=0, paper=6, ink=1):
    for i, ch in enumerate(s):
        cell(r, c + i, ord(ch), font, paper, ink)

for r in range(60):                        # every row: blank, white on blue
    text(r, 0, " " * 80)
for r in range(1, 50):                     # rows 1 - 49 (shown as graphics in the demo)
    text(r, 0, f"text row {r:2d}: only seen when this row is text ".ljust(80, "."),
         paper=0, ink=12)
text(0, 0, " mp32 display: 8 bits a pixel, 256 colors".ljust(80), paper=13, ink=0)
text(0, 50, "row 0 text | rows 1-49 graphics", paper=13, ink=0)
text(50, 2, "Font 0: The quick brown fox jumps over the lazy dog. 0123456789", font=0, ink=7)
text(51, 2, "Font 1: The quick brown fox jumps over the lazy dog. 0123456789", font=1, ink=7)
text(52, 2, "Font 2: The quick brown fox jumps over the lazy dog. 0123456789", font=2, ink=7)
text(53, 2, "Font 3: The quick brown fox jumps over the lazy dog. 0123456789", font=3, ink=7)
for code in range(128):                    # all characters, ink of the cube
    cell(55 + code // 64, 2 + code % 64, code, paper=0, ink=16 + (code * 7) % 216)
for n in range(64):                        # paper colors 16 - 79 and 80 - 143
    cell(57, 2 + n, ord(" "), paper=16 + n)
    cell(58, 2 + n, ord(" "), paper=80 + n)
text(59, 2, "Bases 0x30020/24, mode RAM 0x31000, palette 0x30400: 32 bits", ink=14)

# The text window in rows 1 - 49, columns 60 - 79.
for r in range(1, 50):
    text(r, 60, " " * 20, paper=236, ink=1)
text(2, 61, "A text window", paper=236, ink=226)
text(3, 61, "in the graphics:", paper=236, ink=226)
text(5, 61, "Each 8x8 block has", paper=236, ink=15)
text(6, 61, "a bit in the mode", paper=236, ink=15)
text(7, 61, "RAM: 1 graphics,", paper=236, ink=15)
text(8, 61, "0 text.", paper=236, ink=15)
for n in range(18):
    text(10 + n, 61, f"line {n + 1:2d} ", font=n % 4, paper=236, ink=16 + 12 * n)

# The caption: rows 45 - 47, columns 4 - 31.
for r in range(45, 48):
    text(r, 4, " " * 28, paper=0, ink=1)
text(46, 5, "A caption cut into the", paper=0, ink=226)
text(47, 5, "picture: its blocks are 0", paper=0, ink=226)

# The small picture in the text: rows 54 - 58, columns 68 - 77 (pixels 544 - 623,
# lines 432 - 471): a little color wheel.
for y in range(432, 472):
    for x in range(544, 624):
        a = math.atan2(y - 452, x - 584)
        plot(x, y, 16 + int((a + math.pi) / (2 * math.pi) * 215) % 216
                   if math.hypot(x - 584, y - 452) < 19 else 232)

# ---------------------------------------------------------------- modes
graphics = set()
for r in range(1, 50):
    for c in range(60):
        graphics.add((r, c))
for r in range(45, 48):
    for c in range(4, 32):
        graphics.discard((r, c))
for r in range(54, 59):
    for c in range(68, 78):
        graphics.add((r, c))
modes = [0] * 180
for (r, c) in graphics:
    modes[r * 3 + c // 32] |= 1 << (c % 32)

for name, part in ((sys.argv[1], scr[TEXT:PIXELS]), (sys.argv[2], scr[PIXELS:])):
    with open(name, "w") as f:
        f.writelines(f"{b:02X}\n" for b in part)
    print(f"{name}: {len(part)} bytes")
with open(sys.argv[3], "w") as f:
    f.writelines(f"{w:08X}\n" for w in modes)
print(f"{sys.argv[3]}: {len(modes)} words")
