# The mp32 computer on the Tang Nano 20K

The whole computer: the processor (`../cpu`), its memory (block RAM, cache, the 8 MB
SDRAM inside the chip), a serial port, the microSD card, the sound (the board's
MAX98357A and a speaker) and the picture (HDMI, 640 x 480), with a first boot program.

```
make test       the boot program, then the whole computer in simulation
make board      build/top.fs for the board
make flash      load it into the board (until power-off)
make burn       write it into the board's flash
```

Rename `Makefile.txt` to `Makefile` first. The assembler and linker come from
`../toolchain/bin`.

## What is where

| file | what |
|---|---|
| `top.v` | the board: the clocks, reset, buttons, LEDs, the HDMI serializers and pairs |
| `pll.v` | 126 MHz (HDMI), 25.2 MHz (pixels), 42 MHz (processor; the rPLL's `CLKOUTD3`) |
| `computer.v` | the computer: processor, memory system, I/O decoder, devices, picture |
| `iodec.v` | the address map of the I/O devices, and the interrupt controller |
| `boot.s`, `boot.cfg` | the boot program and its linker configuration |
| `top.cst` | the pins |
| `computer_tb.v` | the whole computer in simulation, with the SDRAM model |
| `raster.v`, `tmds.v`, `serializer.v` | copies of the book's (6502-gate-by-gate, chapter 23) |

## The address map

| address | what |
|---|---|
| `0000_0000 - 007F_FFFF` | SDRAM, 8 MB (through the cache; `0078_0000 - 007F_FFFF` write-through: the screen) |
| `0078_0000` | the screen's text: 60 rows of 80 words (code, font, paper, ink) |
| `0079_0000` | the screen's pixels: 480 lines of 640 bytes |
| `F000_0000 - F000_1FFF` | block RAM, 8 KB: the boot program (loaded with the FPGA) |
| `F000_0000 - F000_00BF` | its vector table (VEC after reset): entry n at `F000_0000 + 4n` (0 reset, 1 undefined opcode, 4 heap full, 16 serial port, 17 sound) |
| `FFFF_0000` | serial port: +0 DATA, +4 STATUS, +8 DIV, +12 CTRL (`../uart/uart.v`) |
| `FFFF_0100` | microSD: +0 DATA, +4 DATA32, +8 CTRL (`../sdcard/sdcard.v`) |
| `FFFF_0200` | +0 LEDS (bits 5..0, 1 = lit), +4 BUTTONS (bit 0 S1, bit 1 S2), +8 TICKS |
| `FFFF_0300` | sound: +0 DATA, +4 STATUS, +8 CTRL, +12 DIV, +16 TONE, +20 LEN, +24 BSTATUS, +28 BLEN, +32 READY (`../audio/audio.v`) |
| `FFFF_0400` | interrupt controller: +0 PENDING (read), +4 MASK, +8 NUMBER (read) (`iodec.v`) |
| `FFFF_8000 - FFFF_9FFF` | the video unit's font RAM (4 fonts) |
| `FFFF_A000 - FFFF_AFFF` | its registers: `A020` text_base, `A024` pixel_base, `A400 - A7FF` palette |
| `FFFF_B000 - FFFF_BFFF` | its mode RAM (which blocks are graphics) |
| `FFFF_C000 - FFFF_CFFF` | the sound's sample memory: bank 0 at `C000`, bank 1 at `C800`, 1024 samples each, two to a word (write only) |

## The boot program

Clears the screen (blue), writes `mp32 ready` on it and to the serial port, beeps
(442 Hz, 0.1 s: a speaker on the board's 2-pin header), then echoes what comes in on the serial port (115,200 baud, 8N1) to both; the LEDs count
the bytes. On the PC: any terminal on the board's COM port. Hold S1 to start again.

It also sets up the LISP heap (L, HLIM: 1 MB to 7.5 MB of the SDRAM). Its vector table
sends an undefined opcode, a full heap (there is no garbage collector yet) and any
interrupt to small handlers that say so on the serial port and the screen and stop.

## Interrupts

The interrupt controller (in `iodec.v`) has 8 lines: 0 the serial port's irq, 1 the
sound's. A line asks while its device's irq is 1, until the handler has served the
device (e.g. the sound: fill the bank, write READY, clear DONE). With its bit in MASK
set it interrupts the processor: `irq` = 1, `irq_num` = 16 + the lowest such line, and
the processor takes it when its I flag is 1 (SEI). The handler is entry 16 + line of
the vector table; it returns with RTI. See `../cpu/isa.md`, Interrupts and
exceptions.

After reset MASK = 0 and I = 0: the boot program does not use interrupts yet.

## The sound

The board's MAX98357A: a DAC and a 3 W amplifier for a 4 or 8 ohm speaker on its
2-pin header, fed with I2S (pins 51 `pa_en`, 54 `hp_din`, 55 `hp_ws`, 56 `hp_bck`).
`../audio/audio.v` sends it 16-bit samples at 46,875 Hz (the chip's 48 kHz; the
processor's 42 MHz / 896), the same sample on both channels. Three sources, added:

- the queue: samples written to DATA one by one (64 wait; the write waits while it is full)
- the sample memory: two banks of block RAM, 1024 samples each. The sound plays a
  bank to its end (BLEN samples), then the other one by itself, while the program
  fills the one not playing and marks it READY. A bank lasts 21.8 ms.
- the tone: a square wave from TONE and LEN, made in the hardware (the boot beep)

CTRL bit 0 switches the amplifier on, bit 2 plays the banks. When a bank has been
played to its end, its DONE bit in BSTATUS goes to 1 and, with CTRL bit 3 (BIE), the
sound's irq: the handler fills that bank, writes READY and clears DONE. The irq is
line 1 of the interrupt controller: vector 17. All the registers are described in `audio.v`.

## Not yet

- handlers for the interrupts of the serial port and the sound in the boot program
- the keyboard and the mouse
- a garbage collector, a monitor, loading programs over the serial port or from the card
- the SDRAM pins in `top.cst` are taken from another open-source project that uses
  the same chip (see the file); if the SDRAM does not answer on the board, they are
  the first thing to check
