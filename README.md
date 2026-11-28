# mp32

A 32-bit computer of my own, in Verilog, for one small FPGA board: the Sipeed Tang Nano 20K.

The processor is new: a pipelined 32-bit CPU with 1 to 4 byte opcodes, 32 registers and a stack machine's T, S and R, made for FORTH, C and LISP. Around it: the board's 8 MB SDRAM behind a cache, an HDMI picture of 640 x 480, a USB keyboard and mouse, sound, a serial port, the microSD card and the SPI flash. After the boot loader, the computer is a FORTH machine that takes its words from the keyboard or the serial port alike.

It grew out of the book and video series *Our Own 6502, Gate by Gate* by Yves Robert, and reuses some of its code (below).

## Where it stands

On the board, the computer boots over the serial port and runs FORTH:

```
mp32 boot
flash: no image
sd card: no card
serial port: send the image
loading 000034CC bytes to 00000000 ok, start at 00000000
mp32 FORTH, 2080656 bytes free
> : SQ DUP * ;  ok
> 7 SQ . 49  ok
>
```

## What is where

| Folder | What |
|---|---|
| `cpu` | The processor: one folder per pipeline stage (`stage1` fetch ... `stage5`), the interrupt controller, the instruction set (`isa.md`) and its design (`cpu.md`) |
| `cache` | The cache and the SDRAM controller, with a model of the SDRAM |
| `decode` | The instruction decoder |
| `display2` | The video unit: 80 x 60 cells, each 8 x 8 block text or 8-bit graphics, a 256-colour palette, four fonts, lines read from the SDRAM in bursts |
| `display` | The first video unit, kept for reference |
| `keyboard` | USB keyboard and mouse through a CH9350 module, both ways (the LEDs go back to the keyboard) |
| `audio` | Sound through the board's I2S amplifier: two banks of samples, an interrupt when one is played |
| `uart` | The serial port |
| `sdcard` | The microSD card, with a model of the card |
| `timer` | Two timers, one for slow and one for fast events |
| `leds` | The board's LEDs |
| `computer` | The whole computer: the top of the design, the address map, the boot loader (`boot.s`) and a first OS |
| `forth` | The FORTH kernel: subroutine threaded with inlining, tasks, 4 KB blocks on the SD card |
| `toolchain` | Assembler, librarian, linker and boot image maker in C# (.NET 10, Visual Studio 2026) |

Each folder has its own test benches and Makefile; the bigger ones have their own README.

## What you need

- A Sipeed Tang Nano 20K and a USB-C cable, an HDMI monitor, a microSD card.
- For the keyboard and mouse: a CH9350 module and a 2.2k / 3.3k divider on its TX (`keyboard/README.md`).
- The OSS CAD Suite (Yosys, nextpnr, `gowin_pack`, openFPGALoader, Icarus Verilog): https://github.com/YosysHQ/oss-cad-suite-build/releases/latest
- The .NET 10 SDK for the toolchain, `make` and Python 3.

## How to use it

On Windows, in the MinGW64 shell. Some folders hold `Makefile.txt`: rename it to `Makefile` first.

```
source ~/oss-cad-suite/environment       # once in each terminal
cd toolchain && make publish && cd ..    # mp32as, mp32ar, mp32ld, mp32img into toolchain/bin
cd computer && make test                 # the whole computer in simulation
make flash                               # the bitstream into the board
cd ../forth && make boot-serial PORT=COM4   # boot FORTH over the serial port and talk to it
```

## How it is written

I write this code with the help of Claude, the AI model made by Anthropic. What goes on the board has run on my own Tang Nano 20K.

## License

MIT: the text is in the `LICENSE` file.

Code from other people keeps its own terms:

- `computer/raster.v`, `computer/tmds.v`, `computer/serializer.v` and font 3 are copies from *Our Own 6502, Gate by Gate* (https://yvesrobert.com/6502), MIT, copyright (c) 2026 Yves Robert. Other parts start from the book's code too.
- `display2/font8x8_ext_latin.h` (font 0, Latin-1) is public domain, by Daniel Hepper after Marcel Sondaar and the IBM VGA fonts.
- Fonts 1 and 2 recreate the PETSCII character sets of the Commodore PET. They are not covered by the MIT license; their rights, if any remain, belong to their owners.
