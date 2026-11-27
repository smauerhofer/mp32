# The mp32 computer on the Tang Nano 20K

The whole computer: the processor (`../cpu`), its memory (block RAM, cache, the 8 MB
SDRAM inside the chip), a serial port, the microSD card, the SPI flash, the sound (the
board's MAX98357A and a speaker), a USB keyboard and mouse (through a CH9350L module)
and the picture (HDMI, 640 x 480), with a boot loader and a first operating system for
it to load.

```
make test       the boot loader and the operating system, then the whole computer in
                simulation: it boots from the flash, the card and the serial port
make board      build/top.fs for the board
make flash      load it into the board (until power-off)
make burn       write it into the board's flash
make os         build/os.img, the operating system's image
make os-burn    write build/os.img into the board's flash at $400000
make os-send PORT=/dev/ttyS3
                send build/os.img over the serial port (COM4 is /dev/ttyS3)
make boot-serial PORT=/dev/ttyS3
                start the board again (the bitstream into it, as make flash) and
                boot build/os.img over the serial port; shows what the board says
                until Ctrl-C
```

Rename `Makefile.txt` to `Makefile` first. The assembler, the linker and `mp32img`
come from `../toolchain/bin`.

## What is where

| file | what |
|---|---|
| `top.v` | the board: the clocks, reset, buttons, LEDs, the keyboard's wire, the HDMI serializers and pairs |
| `pll.v` | 126 MHz (HDMI), 25.2 MHz (pixels), 42 MHz (processor; the rPLL's `CLKOUTD3`) |
| `computer.v` | the computer: processor, memory system, I/O decoder, devices, picture |
| `iodec.v` | the address map of the I/O devices, and the interrupt controller |
| `boot.s`, `boot.cfg` | the boot loader (in the block RAM) and its linker configuration |
| `os.s`, `os.cfg` | a first operating system (in the SDRAM from 0) and its linker configuration |
| `top.cst` | the pins |
| `computer_tb.v` | the whole computer in simulation, with the models of the SDRAM, the flash (`flash_model.v`) and the card (`../sdcard/sd_model.v`) |
| `raster.v`, `tmds.v`, `serializer.v` | copies of the book's (6502-gate-by-gate, chapter 23) |

## The address map

| address | what |
|---|---|
| `0000_0000 - 007F_FFFF` | SDRAM, 8 MB (through the cache; `0078_0000 - 007F_FFFF` write-through: the screen) |
| `0000_0000 - 0000_03FF` | the operating system's vector table (VEC after the boot loader): entry n at 4n |
| `0078_0000` | the screen's text: 60 rows of 80 words (code, font, paper, ink) |
| `0079_0000` | the screen's pixels: 480 lines of 640 bytes |
| `F000_0000 - F000_1FFF` | block RAM, 8 KB: the boot loader (loaded with the FPGA) |
| `F000_0000 - F000_00BF` | its vector table (VEC after reset): entry n at `F000_0000 + 4n` (0 reset, 1 undefined opcode, the rest: "unexpected") |
| `FFFF_0000` | serial port: +0 DATA, +4 STATUS, +8 DIV, +12 CTRL (`../uart/uart.v`) |
| `FFFF_0100` | microSD: +0 DATA, +4 DATA32, +8 CTRL, +12 DATA32LE (`../sdcard/sdcard.v`) |
| `FFFF_0200` | +0 LEDS (bits 5..0, 1 = lit), +4 BUTTONS (bit 0 S1, bit 1 S2), +8 TICKS, +12 CTRL (the buttons: bit 0 S1INT, 1 S1IE, 2 S2IE, 8 S1F, 9 S2F; see below) |
| `FFFF_0300` | sound: +0 DATA, +4 STATUS, +8 CTRL, +12 DIV, +16 TONE, +20 LEN, +24 BSTATUS, +28 BLEN, +32 READY (`../audio/audio.v`) |
| `FFFF_0400` | interrupt controller: +0 PENDING (read), +4 MASK, +8 NUMBER (read), +12 ISR (read) / EOI (write) (`../cpu/irqc.v`) |
| `FFFF_0500` | SPI flash: +0 DATA, +4 DATA32, +8 CTRL, +12 DATA32LE (`../sdcard/sdcard.v` again, 21 MHz) |
| `FFFF_0600` | keyboard and mouse: +0 STATUS, +4 KEYS0, +8 KEYS1, +12 MOUSE, +16 BUTTONS, +20 LEDS, +24 CTRL (`../keyboard/keyboard.v`) |
| `FFFF_0700` | two timers: +0 T0CTRL, +4 T0PERIOD, +8 T0COUNT, +16 T1CTRL, +20 T1PERIOD, +24 T1COUNT, +32 FREQ (`../timer/timer.v`) |
| `FFFF_8000 - FFFF_9FFF` | the video unit's font RAM (4 fonts) |
| `FFFF_A000 - FFFF_AFFF` | its registers: `A020` text_base, `A024` pixel_base, `A028` IRQ_LINE, `A02C` IRQ_CTRL, `A030` IRQ_STATUS, `A034` LINE, `A400 - A7FF` palette |
| `FFFF_B000 - FFFF_BFFF` | its mode RAM (which blocks are graphics) |
| `FFFF_C000 - FFFF_CFFF` | the sound's sample memory: bank 0 at `C000`, bank 1 at `C800`, 1024 samples each, two to a word (write only) |

## The boot loader

`boot.s`, in the block RAM: the processor starts it after reset (and after S1). It
loads the operating system into the SDRAM and starts it, in four phases; the LEDs
(LED0 is the one nearest the USB-C port) and the speaker say how far it got:

| phase | what | LEDs | sound | failed |
|---|---|---|---|---|
| 0 | | all off | | |
| 1 | initialize the processor: stacks, registers, screen | LED0 | a short beep (0.1 s) | |
| 2 | find a boot method: the first place with an image whose header is good | LED0, LED1 | | LED1 blinks at 1 Hz, 2 long beeps |
| 3 | load the operating system: copy it, check its sum | LED0, LED1; LED2 blinks at 2 Hz while loading, then stays on | | LED2 blinks at 1 Hz, 3 long beeps |
| 4 | jump to it | LED0 .. LED2 (until it changes them) | | |

A long beep is 0.5 s, while the LED is on. After a failure the loader stops for
good: the LED goes on blinking (the beeps only the first times), until S1 or a new
bitstream starts it again.

The places it looks in phase 2, in this order:

1. **the SPI flash**, at `$400000` (`FLASH_IMAGE`; the bitstream is at 0, 8 MB in all)
2. **the microSD card**, from block 0 (`SD_LBA`): the raw card, no file system. SDHC,
   SDXC and SDSC cards; it starts the card at 396 kHz, then reads at 21 MHz
3. **the serial port**: it says `serial port: send the image` and waits as long as it
   takes; whatever comes before the image's first word is skipped

A place with no image, or one with a bad header, is passed over: the next one is
tried. Only the serial port, the last place, fails phase 2 (with a bad header). The
place with a good header is the boot method: if loading from it fails in phase 3
(`bad checksum`, `read error`), the loader stops; it does not try the next place.

It says what it does on the serial port (115,200 baud) and on the screen, e.g.

```
mp32 boot
flash: no image
sd card: loading 00000660 bytes to 00000000 ok, start at 00000000
```

(and `bad header`, `bad checksum`, `read error`, `no card`; a dot for every 64 KB).
All six LEDs at once: an undefined opcode, an exception or an interrupt in the loader
itself.

### The image

`mp32img` (`../toolchain`) puts a header of 8 little-endian words in front of the
program (the linker's raw `bin` output, see `os.cfg`):

| offset | word |
|---|---|
| +0 | `mp32` (`$3233706D`) |
| +4 | load: where the payload goes, 1 KB aligned (VEC = load) |
| +8 | size: the payload's bytes, a multiple of 4, not 0 |
| +12 | entry: where it starts (normally load: the reset entry of the vector table) |
| +16 | sum: the payload's words added up |
| +20, +24 | 0 |
| +28 | check: makes the eight words add up to 0 |

The loader checks the header (and that the payload ends below the screen, `$780000`,
and that entry is in it), copies the payload, adds its words up and compares. A bad
image is reported, and the next place is tried.

### Putting the image there

- **flash:** `make os-burn`, i.e. `openFPGALoader -b tangnano20k --external-flash -o
  0x400000 --file-type bin build/os.img`. The bitstream (`make burn`) stays at 0. The
  flash's pins (59 .. 62) belong to the FPGA only after configuration, and only with
  `gowin_pack --mspi_as_gpio` (in the Makefile). With Gowin's programmer: External
  Flash Mode, exFlash C Bin Erase, Program, address `0x400000`.
- **card:** the image raw from block 0, e.g. as administrator in the MinGW shell
  `dd if=build/os.img of=/dev/sdX` (find X with `cat /proc/partitions`; this
  overwrites the card's partition table), or with a raw disk writer.
- **serial port:** `make boot-serial PORT=/dev/ttyS3` (COM4) does it all: it loads
  the bitstream into the board (which starts the loader again), waits until the
  loader asks for the image, sends it and then shows what the board says (Ctrl-C to
  stop). It needs the flash empty at `$400000` and the card slot empty, so the loader
  gets to the serial port; no terminal program may have the port open. By hand:
  press S1, wait for `serial port: send the image`, then `make os-send
  PORT=/dev/ttyS3`, or from cmd: `mode COM4 BAUD=115200 PARITY=n DATA=8 STOP=1` and
  `copy /b build\os.img COM4`. 1 MB takes about 90 s at 115,200 baud.

### The handover

With a good image the loader waits until the serial port has sent everything, then:
VEC = load, r1 = where it came from (1 the flash, 2 the card, 3 the serial port), r2 =
size, and it jumps to entry. I = 0, and no device has its interrupt on. The stacks
(PSP, RSP) still point into the block RAM: the operating system sets up its own
first. The loader does not clear the operating system's BSS. INTR 0 then starts the
operating system again (its entry 0), not the loader; S1 starts the loader.

Errors that should not happen in the loader (an undefined opcode, an exception, an
interrupt) are caught by its own vector table: it says so and stops.

## The operating system

`os.s`, the demo that used to be the boot program, linked with `os.cfg` to run from
0: its vector table first (256 entries), then the code. It clears the screen (blue),
writes `mp32 ready` on it and to the serial port, beeps (442 Hz, 0.1 s: a speaker on
the board's 2-pin header), then echoes what comes in on the serial port (115,200 baud,
8N1) to both; the LEDs count the bytes. On the PC: any terminal on the board's COM
port.

It also sets up the LISP heap (L, HLIM: 1 MB to 7.5 MB of the SDRAM). Its vector table
sends an undefined opcode, a full heap (there is no garbage collector yet) and any
interrupt it does not expect to small handlers that say so on the serial port and the
screen and stop.

The echo runs on interrupts: the serial port's handler (vector 19) puts every byte
that comes into a ring buffer of 256 bytes, the main loop takes them out. The
display's frame interrupt (vector 17) counts the frames in the word `frames`.

## Interrupts

The interrupt controller (`../cpu/irqc.v`, in `iodec.v`) has 8 lines; line k is
vector 16 + k, and the lower the line, the higher its priority:

| line | vector | device | how its handler serves it |
|------|--------|--------|---------------------------|
| 0 | 16 | the display's line interrupt | write 1 to IRQ_STATUS bit 0 |
| 1 | 17 | the display's frame interrupt | write 2 to IRQ_STATUS (bit 1) |
| 2 | 18 | the sound | fill the bank, write READY, clear DONE |
| 3 | 19 | the serial port | read the bytes (RXIE), or fill the queue (TXIE) |
| 4 | 20 | the keyboard and the mouse | read the reports (KIE: KEYS0, then KEYS1), or MOUSE (MIE) |
| 5 | 21 | the buttons S1, S2 | write 1 to CTRL's S1F (bit 8) or S2F (bit 9) |
| 6 | 22 | timer 0, the fast one | write CTRL with F (bit 8, and OVR bit 9) set |
| 7 | 23 | timer 1, the slow one | the same, its CTRL |

A line asks while its device's irq is 1. With its bit in MASK set it interrupts the
processor when I = 1, unless a line of the same or a higher priority is in service.
The handler ends with EOI (a write to +12) and RTI; a handler that sets I again in
between can be interrupted, but only by a more urgent line. See `../cpu/isa.md`,
Interrupts and exceptions.

The display: the line interrupt comes at the end of the visible pixels of line
IRQ_LINE (or of every line, with IRQ_CTRL bit 2), in time to change the palette or a
base for the next line in the horizontal blank (6.35 us); the frame interrupt at the
end of line 479, at the start of the vertical blank. Each has a flag in IRQ_STATUS
that holds it until the handler clears it. See `../display2/video.v`.

## The buttons

CTRL, at `FFFF_020C` (in `iodec.v`), says what S1 and S2 do. After reset it is 0: S1
is the hardware reset, and neither button interrupts.

| bit | name | what |
|-----|------|------|
| 0 | S1INT | 0: S1 is the reset (held, it resets the whole computer; nothing switches that off but S1INT). 1: S1 is a button that can interrupt, and resets nothing |
| 1 | S1IE | S1 interrupts when pressed; only with S1INT = 1 (written with S1INT = 0, it stays 0) |
| 2 | S2IE | S2 interrupts when pressed |
| 8 | S1F | S1 was pressed (with S1INT = 1); write 1 to clear |
| 9 | S2F | S2 was pressed; write 1 to clear |

A press counts when the button has been down for 12.5 ms in a row (debounced), and
sets its flag whatever the enables say: clear the flags before enabling. The buttons'
irq is `(S1F & S1IE) | (S2F & S2IE)`, line 5 of the interrupt controller (vector 21).
BUTTONS (`FFFF_0204`) still shows both buttons as they are.

With S1INT = 1, S1 no longer starts the boot loader: only a reset of the FPGA (power,
a new bitstream) brings S1 back as the reset, unless the program writes S1INT = 0.

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
line 2 of the interrupt controller: vector 18. All the registers are described in `audio.v`.

## The timers

`../timer/timer.v`: two timers, the same but for their lines, the two least urgent:
timer 0 (line 6, vector 22) for the fast events (e.g. every millisecond), timer 1
(line 7, vector 23) for the slow ones (e.g. every 100 ms). Each counts the
processor's ticks down from PERIOD - 1 to 0, sets its flag F, and starts again: an
event every PERIOD ticks exactly, however late its handler comes (a lost one sets
OVR). ONESHOT stops it after one. FREQ (+32) reads the ticks per second (42,000,000),
so a program gets 1 ms as FREQ / 1000 without knowing the clock.

    T0PERIOD = FREQ / 1000      ; 1 ms
    T0CTRL   = 3                ; EN, IE; MASK bit 6 on, SEI
    handler: T0CTRL = $303 (clear F, OVR; EN, IE kept), EOI, RTI

## The keyboard and the mouse

A USB keyboard and a USB mouse plug into a CH9350L module (Kamami's KAmod USB HID
Extender, its DEVICE side), as in chapter 21 of the book, but wired both ways: the
module's TXD to pin 42 (`kbd_rx`), its RXD to pin 41 (`kbd_tx`), 5V and GND to its J4.
Jumpers: SEL off, STAT0 on, STAT1 off, BAUD0 and BAUD1 off (state 2, 115,200 baud),
and **no** jumper between GND and RXD: that wire is now ours. `../keyboard/keyboard.v`
cuts the module's frames by their length, keeps the keyboard's reports in a queue of 8
(repeats dropped), adds up the mouse's movements, and sends the module the keyboard's
LEDs (LEDS, with CTRL bit 2 TXEN) in the frame an upper CH9350L sends, about once a
second and at each write. All the registers are described in `keyboard.v`;
`../keyboard/README.md` has the wiring.

## Not yet

- a handler for the sound's interrupt in the operating system
- a driver in the operating system for the keyboard and the mouse (the device is
  there, `../keyboard`): key codes to characters, as chapter 22 of the book does
- the keyboard and the mouse on the board: the frames and the LEDs are tried in
  simulation only (`../keyboard/ch9350.v`, a model of the chip on both wires)
- a garbage collector, a monitor
- a file system on the card: the loader reads the raw card
- the flash is only read: writing it (erase, page program) is up to a program
- the flash's pins on the board: tried in simulation only. If the loader always says
  `flash: no image` with an image at `$400000`, check `--mspi_as_gpio` and the pins
- the SDRAM pins in `top.cst` are taken from another open-source project that uses
  the same chip (see the file); if the SDRAM does not answer on the board, they are
  the first thing to check
