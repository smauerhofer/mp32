# The keyboard and the mouse

A USB keyboard and a USB mouse for the mp32 computer, through a CH9350L module (a
generic one, below; the book's chapter 21 uses the KAmod USB HID Extender from Kamami),
on its lower side.
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
| `ch9350.v` | the module for the test bench: sends frames, takes our keep-alives and checks them (no answer, as the chip); `57 AB 80 3N` when the test bench says |
| `keyboard_tb.v` | the test bench |

The receiver and the transmitter are the serial port's: `../uart/uart_rx.v` and
`../uart/uart_tx.v`.

## Wiring

The module: a generic "CH9350 module" (Fruugo, part I500792981): a 5-way DIP switch,
a 5-pin header (5V, TX, RX, 485 control, GND) and a stacked double USB-A socket.

The row of twenty holes along the board's edge on the side of S2, from the USB-C end:
5V, GND, 76, 80, 42, 41, ... Six header pins in the first six holes, then:

| board | module |
|---|---|
| hole 1, 5V | 5V |
| hole 2, GND | GND |
| hole 5, pin 42 (`kbd_rx`) | TX, **through a divider** (below) |
| hole 6, pin 41 (`kbd_tx`) | RX |
| - | 485控制 (TNOW, the RS-485 direction): not connected |

The chip runs on the 5 V of the header (the module has no 3.3 V regulator), so TX
swings to 5 V, and the GW2AR's pins take 3.3 V at most. Measure TX at rest: if it is
about 5 V, put a divider before pin 42:

```
module TX ---[ 2k2 ]---+--- pin 42
                       |
                     [ 3k3 ]
                       |
                      GND
```

(5 V x 3.3 / 5.5 = 3.0 V; 1k / 2k works too.) Built this way, the keyboard works on
the board. Pin 41 at 3.3 V into RX is high enough for the chip at 5 V.

The DIP switch, read at power-up only (change it with the power off). A switch that is
ON ties its pin to GND: ON = 0, OFF = 1 (the board marks 0 above, 1 below).

| switch | pin | position | |
|---|---|---|---|
| 1 | SEL | OFF (1) | the lower computer: the chip is the USB host of the keyboard and mouse |
| 2 | BA1 | OFF (1) | 115,200 baud (the default, BA1 = BA0 = 1) |
| 3 | BA0 | OFF (1) | |
| 4 | S1 | OFF (1) | working state 2: keyboard + relative mouse |
| 5 | S0 | ON (0) | |

So only switch 5 is ON. (S1 = 1, S0 = 0 is the KAmod's STAT1 off, STAT0 on.)

The keyboard and the mouse go into the two USB-A sockets, either one into either
(upper: DM/DP, lower: HM/HP); both are host ports on the lower computer.

Pins 42 and 41 go only to the LCD connector, which stays empty. Both are in
`../computer/top.cst`.

## The registers

At `$FFFF_0600`, interrupt line 4 (vector 20). `keyboard.v` describes every bit.

| offset | name | |
|---|---|---|
| +0 | STATUS | bit 0 KEY (a report waits), 1 MOUSE (the mouse moved), 2 TXBUSY, 3 LOST, 4 GONE (a device plugged in or out), 5 FERR, 6 SYNC; bits 15..8 ECHO (the chip's last `57 AB 80`: `FF` at start, then `3N`, N the lock keys held down: Caps Lock held `32`, let go `30`); bits 19..16 the reports waiting. Write 1 to clear bits 3..6 |
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

The chip passes the LEDs on to the keyboard and does **not** answer. The datasheet
gives the LED byte (bit 0 Num, 1 Caps, 2 Scroll) but not the rest of the frame in
state 2; the bytes after it are those a real upper chip was seen to send.

The chip's own `57 AB 80 3N` (ECHO) comes when a lock key goes down or up on the
keyboard: N the lock keys held, in the same bits. On the board (2026-11-28): ECHO is
`30`, `32` while Caps Lock is held, `30` again when it is let go; writing LEDS leaves
it alone.

## Not yet

- on the board (2026-11-28): the keyboard, the keyboard's LEDs (written with LEDS)
  and ECHO work, with the divider above; the mouse is not tried yet
