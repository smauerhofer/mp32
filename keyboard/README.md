# The keyboard and the mouse

A USB keyboard and a USB mouse for the mp32 computer, through a CH9350L module: the
KAmod USB HID Extender from Kamami, its DEVICE side, as in chapter 21 of the book.
The chip is the USB host of the keyboard and the mouse, and talks to us on a serial
line at 115,200 baud. Unlike the book, the line goes **both ways**: the module sends
the reports of the keyboard and the mouse, and we send back the state of the
keyboard's LEDs (Num Lock, Caps Lock, Scroll Lock), which the chip passes on to the
keyboard.

```
make test       the test bench: keyboard.v at 42 MHz against ch9350.v, a model of
                the module on both wires (about 2 minutes)
make size       synthesize the device alone and count what it takes
make clean      throw away what the build made
```

| file | what |
|---|---|
| `keyboard.v` | the device: the receiver, the frames, the report queue, the mouse's sums, the transmitter of the LEDs, the registers |
| `ch9350.v` | the module for the test bench: sends frames, takes our keep-alives, checks them and answers `57 AB 80 3N` |
| `keyboard_tb.v` | the test bench |

The receiver and the transmitter are the serial port's: `../uart/uart_rx.v` and
`../uart/uart_tx.v`.

## Wiring

The row of twenty holes along the board's edge on the side of S2, from the USB-C end:
5V, GND, 76, 80, 42, 41, ... Six header pins in the first six holes, then:

| board | module |
|---|---|
| hole 1, 5V | J4 5VOUT |
| hole 2, GND | J4 GND |
| hole 5, pin 42 (`kbd_rx`) | J1 TXD |
| hole 6, pin 41 (`kbd_tx`) | J1 RXD |

Jumpers on the module:

| jumper | |
|---|---|
| SEL, row P1 | off: the DEVICE side (the chip is the keyboard's host) |
| STAT0 on, STAT1 off, row P1 | working state 2: keyboard + relative mouse |
| BAUD0, BAUD1 off, row P1 | 115,200 baud |
| GND - RXD, row P3 | **off**. In the book it makes the line one way; here RXD is our wire. With the jumper on, pin 41 would drive a wire tied to GND. |

The keyboard goes into USB 2 (KEYBOARD), the mouse into USB 1. Nothing goes into the
module's USB-C socket. As in the book, measure TXD (3.3 V at rest) before it touches
pin 42.

Pins 42 and 41 go only to the LCD connector, which stays empty. Both are in
`../computer/top.cst`.

## The registers

At `$FFFF_0600`, interrupt line 4 (vector 20). `keyboard.v` describes every bit.

| offset | name | |
|---|---|---|
| +0 | STATUS | bit 0 KEY (a report waits), 1 MOUSE (the mouse moved), 2 TXBUSY, 3 LOST, 4 GONE (a device plugged in or out), 5 FERR, 6 SYNC; bits 15..8 ECHO (the chip's last `57 AB 80`: `FF`, then `3N`); bits 19..16 the reports waiting. Write 1 to clear bits 3..6 |
| +4 | KEYS0 | the first report: modifiers (7..0), reserved, key 1, key 2 |
| +8 | KEYS1 | keys 3 to 6; reading it takes the report (read KEYS0 first) |
| +12 | MOUSE | sum of dx (15..0), sum of dy (31..16) since the last read, signed; reading takes them |
| +16 | BUTTONS | the buttons now (7..0), sum of the wheel (15..8); reading takes the wheel |
| +20 | LEDS | bit 0 Num Lock, 1 Caps Lock, 2 Scroll Lock; a write sends them |
| +24 | CTRL | bit 0 KIE, 1 MIE, 2 TXEN (send to the module) |

A program that reads the keyboard:

```
loop:   read STATUS; if KEY is 0, go on with something else
        k0 = KEYS0          modifiers, 0, key 1, key 2
        k1 = KEYS1          key 3 .. key 6, and the report leaves the queue
        compare with the report before: a code that is new went down, a code that
        is gone came up (chapter 22 of the book)
```

and turns on Caps Lock's LED:

```
        CTRL = 4            TXEN, once at start (with KIE/MIE if wanted)
        LEDS = 2            Caps Lock: goes out at once, then once a second
```

The LEDs are only a picture: the keyboard does not light them by itself, the program
decides (on Caps Lock's code, $39, it flips bit 1 of LEDS).

## What goes on the wire

The module sends frames that begin `57 AB`, then a byte for the kind, then exactly
that many bytes: `01` + 8 (the keyboard's report), `02` + 4 (the mouse: buttons, dx,
dy, wheel), `80` + 1 (status), `86`, `87`, `89` (nothing more). Frames are cut by
their length, not by looking for `57 AB`, which a mouse's bytes can hold. In state 2
the chip sends each keyboard report 3 or 4 times; a report equal to the last one is
dropped.

We send what an upper CH9350L sends, as kvm-serial saw it on the wire between two
chips (`docs/CH9350L_PROTO.md` of github.com/sjmf/kvm-serial):

```
57 AB 12  00 00  00 00  LED  07  AC 20
```

and the chip answers `57 AB 80 3N`, N the LEDs it set (ECHO). The datasheet gives
the LED byte (bit 0 Num, 1 Caps, 2 Scroll) but not the rest of the frame in state 2;
the bytes after it are those a real upper chip was seen to send.

## Not yet

- tried in simulation only: on the board, check ECHO after writing LEDS. If it stays
  `FF` or `30`, the chip does not take our keep-alive: look at the wiring of RXD first
- no driver in the operating system yet
