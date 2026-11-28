# FORTH on the mp32

After the boot loader (`../computer/boot.s`) the mp32 is a FORTH machine: `forth.s` is
the kernel, loaded into the SDRAM at 0 like any image the loader loads. It takes
words from the serial port and the keyboard alike, and answers on the screen and the
serial port.

```
make            build/forth.img (rename Makefile.txt to Makefile first)
make test       boot it on the whole computer in simulation and talk to it (forth_tb.v)
make boot-serial PORT=COM4
                load the bitstream (../computer/build/top.fs), boot build/forth.img
                over the serial port, then a terminal: type to FORTH (Ctrl-] stops)
make term PORT=COM4
                only the terminal (FORTH already runs)
make burn       build/forth.img into the flash at $400000: the loader boots it by
                itself from then on (and make term to talk to it)
```

For `boot-serial` the flash must hold no image at `$400000` and the card slot be empty,
so the loader gets to the serial port (as `../computer`'s `make boot-serial`). The
terminal sends each key as you press it in cmd, PowerShell, Windows Terminal, or the
MinGW shell through winpty: `make boot-serial PORT=COM4 PYTHON="winpty python"`.
Without winpty (plain mintty) it sends a line at a time. Any terminal program at
115,200 baud 8N1 works as well (PuTTY, Tera Term), once the image is in.

On the board:

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

LED0 .. LED2 are the loader's phases; LED3 goes on when FORTH runs.

## What is where

| file | what |
|---|---|
| `forth.s` | the kernel: the vector table, the interrupt handlers, COLD, the words |
| `memmap.inc` | the memory's numbers, the globals' and the user area's offsets (the kernel includes it) |
| `forth.cfg` | the linker's configuration: the image at 0 |
| `memory.md` | the memory: the system area, the globals, a task's area, the stacks |
| `dictionary.md` | the headers, compiling, inlining, the line rule, the control structures |
| `tasks.md` | the tasks and PAUSE |
| `forth_tb.v` | the test bench: the whole computer boots the kernel from the flash's model |
| `tools/heads.py` | fills in and checks the headers' links and lengths in `forth.s` |

## The kernel

- **Subroutine threaded, with inlining.** A colon definition is mp32 code: calls
  (`JSRS`, `JSR`, `JSRL`, the shortest that reaches) of the words it uses, the
  primitives copied in (`DUP`, `+`, `@`, `>R`, `I`, a `VARIABLE`, a `CONSTANT`, ...),
  literals as `DUP LIT8 / LIT16 / LIT24 (+ LITH)`. `;` makes a last call a jump.
- **Every word's code starts at a 16-byte line**, the header right in front of it
  (`dictionary.md`); the compiler keeps the line rule.
- **The stacks**: T, S and R are registers; the hardware checks both stacks against
  their limits, so an underflow or overflow is an ordinary `THROW` (-4, -3, -6, -5),
  even in the middle of a word. OPERATOR has 4096 cells of each.
- **Input**: one queue of 1 KB that the serial port's interrupt (vector 19) and the
  keyboard's (vector 20: USB key codes to characters, the **US layout**, Shift, Caps
  Lock, Ctrl) fill. `KEY` takes from it; with nothing there the task sleeps in
  `PAUSE`, and with no task awake the processor `WAIT`s for an interrupt.
- **Output**: `EMIT` writes to the screen and into a 1 KB queue that the serial port's
  TX interrupt empties. The screen goes on below the loader's lines (the row the
  loader would write next) and scrolls at the bottom of the text window; green on
  black, font 0 Latin-1
  (the byte as it is). The cursor (the cell's ink and paper swapped) shows while
  `KEY` waits. Fonts 1 and 2 are PETSCII (capitals and graphics, small letters), font
  3 the book's font (`../computer/README.md`, the fonts).
- **The text window**: `top rows TEXT-WINDOW` makes rows top .. top + rows - 1 the
  rows that scroll (then `PAGE`: the window blank, the cursor at its top);
  `TEXT-WINDOW@ ( -- top rows )`. After a boot it is the whole screen (0 60); COLD keeps
  the window the video unit has (the loader sets none: after a reset). Scrolling
  is done by the video unit: its SCROLL register makes the window's rows go round by
  an offset, so a scroll writes the register and blanks one row (80 words) instead of
  copying the screen (19,200 bytes). The rows outside the window keep their text and
  do not scroll (`AT-XY` reaches them): graphics rows (the mode RAM), a status line.
  `PAGE` clears only the window.
- **Errors**: `QUIT` runs each line under `CATCH`; an error says what it was (`FOO ?`,
  `stack underflow`, `division by zero`, `I compile only`, an `ABORT"` message),
  empties the stack, and FORTH goes on. An undefined opcode, a full CONS heap or an
  unexpected interrupt is a `THROW` too, with the address where it happened.
- **The SD card** is FORTH's own, and never goes into a PC: the card's 512-byte
  blocks with `SD-READ` / `SD-WRITE`, and FORTH's blocks on it, of **4 KB** each (not
  the traditional 1 KB): block u is the card's blocks 8u .. 8u + 7, as many as the
  card holds (`BLOCKS`). Four buffers. Block 0 is the **volume block**, with the
  ranges (below): the boot image, the fonts, the source blocks, data. The card is
  started when it is first used (SDHC, SDXC or SDSC, as the loader does; it reads
  its CSD and CID then) and again after an error. A card that the boot loader left in
  the middle of a block (loaders before this one read only block 0's header) still
  sends the rest of it: FORTH repeats CMD0 until the card answers.
- **The prompt**: `> ` in front of every line, ` ok` at its end.
- **Comments**: `( ... )` (FORTH's own, within a line), `// ...` to the end of the
  line (as in C++; in a block: to the end of its 72-character line) and `/* ... */`
  (as in C), which may go over lines: in a block over its lines, at the terminal
  FORTH reads more lines until the `*/` comes. (`\` is `//` here.)
- **Numbers**: in `BASE`, with `$` (hex), `#` (decimal), `%` (binary) in front, `-`,
  or `'c'` for a character. Division is symmetric (`/MOD`, `SM/REM`); `FM/MOD` floors.

## The words

| | |
|---|---|
| stacks | `DUP DROP SWAP OVER NIP TUCK ROT -ROT 2DUP 2DROP 2SWAP 2OVER ?DUP PICK DEPTH >R R> R@ 2>R 2R>` |
| arithmetic | `+ - AND OR XOR INVERT NEGATE 1+ 1- 2* 2/ CELL+ CELLS CHAR+ CHARS ABS MIN MAX LSHIFT RSHIFT * UM* M* S>D UM/MOD SM/REM FM/MOD /MOD / MOD */MOD */` |
| comparisons | `= <> < > <= >= U< U> U<= U>= 0= 0<> 0< 0> 0<= 0>= WITHIN TRUE FALSE BL` |
| memory | `@ ! C@ C! +! 2@ 2! COUNT /STRING CMOVE CMOVE> MOVE FILL` |
| variables | `BASE STATE >IN FRAMES HEX DECIMAL PAD SOURCE` |
| dictionary | `HERE ALLOT ALIGN ALIGNED , C, UNUSED >BODY EXECUTE` |
| tasks | `PAUSE STOP WAKE SLEEP` |
| terminal | `EMIT KEY KEY? TYPE CR SPACE SPACES PAGE AT-XY TEXT-WINDOW TEXT-WINDOW@ ACCEPT` (and `(EMIT) (KEY)`, the vectors' defaults) |
| numbers out | `HOLD <# # #S #> SIGN . U. .R U.R ? .S DUMP` |
| numbers in, parsing | `NUMBER? PARSE-NAME PARSE WORD CHAR ( // /* .(` |
| finding | `(FIND) FIND ' WORDS` |
| interpreter | `INTERPRET EVALUATE CATCH THROW ABORT QUIT COLD` |
| defining | `HEADER : ; IMMEDIATE CREATE VARIABLE CONSTANT DOES>` |
| compiling | `[ ] COMPILE, LITERAL RECURSE ['] [CHAR] POSTPONE EXIT` |
| control | `IF ELSE THEN BEGIN UNTIL AGAIN WHILE REPEAT DO ?DO LEAVE LOOP +LOOP UNLOOP I J FOR NEXT` |
| strings | `S" ." ABORT"` |
| the SD card | `SD-INIT SD-INFO SD-BLOCKS BLOCKS SD-CSD SD-CID SD-READ SD-WRITE BLOCK BUFFER UPDATE SAVE-BUFFERS EMPTY-BUFFERS FLUSH BLK SCR NEW-SOURCE LINE LOAD THRU LIST FONT` |
| source blocks | `TITLE CHAIN SHADOW DOC INDEX` |
| the volume | `NEW-VOLUME VOLUME RANGE SET-RANGE STARTUP RECEIVE INSTALL` |

`SD-INFO` says what the card is:

    > SD-INFO
    SDHC/SDXC card, 15193 MB: 31116288 blocks of 512 bytes, 3889536 FORTH blocks of 4 KB
    maker 03, OEM SD, product SU16G, revision 8.0, serial 1A2B3C4D, made 2017-10

`SD-BLOCKS` ( -- u ) is the capacity in the card's blocks of 512 bytes (0: no card),
`BLOCKS` ( -- u ) in FORTH's blocks, `SD-CSD` and `SD-CID` ( -- addr ) the card's two
registers (16 bytes each, as the card sends them, the highest bits first), `SD-INIT`
( -- ior ) starts the card again (after it was changed).

`SD-READ` and `SD-WRITE` ( addr lba -- ior ) move one 512-byte block of the card;
ior is 0 when it went well. `FONT` ( n f -- ) puts the card's font n (from the range
`FONTS`) into font f of the font RAM: `1 1 FONT`, then a cell with 1 in its byte 1
shows bold.

**Source blocks.** A block of 4,096 bytes that holds FORTH text is a source block:

| bytes | what |
|---|---|
| 0 .. 3 | the magic word `$900DF00D` (little-endian: `0D F0 0D 90`) |
| 4 .. 35 | the title (`TITLE`) |
| 36 .. 39 | the next block: `LOAD` goes on there (`CHAIN`; 0 none) |
| 40 .. 43 | the shadow block, which documents this one (`SHADOW`, `DOC`; 0 none) |
| 44 .. 47 | the version: + 1 each time the block is written |
| 48 .. 51 | the CRC-32 of the text, written with it, checked when it is read |
| 52 .. 63 | not defined yet (0) |
| 64 .. 4095 | the text: 56 lines of 72 characters |

56 lines of 72 fit the screen (80 x 60): `LIST` shows the whole block at once, each
line after its number. `LOAD` and `LIST` take only source blocks (else `not a source
block`). `NEW-SOURCE` ( u -- ) makes block u a new source block (the magic, the header
0, the text blank), marked to be written, and makes it SCR; `LINE` ( n -- addr ) is
the address of line n (0 .. 55) of the block SCR. The errors: `block read error (no card?)` (-33), `block write error` (-34),
`invalid block number` (-35).

    1024 NEW-SOURCE                   // a new source block (SCR 1024)
    S" : HI 42 . ;" 0 LINE SWAP MOVE  S" hello" TITLE  FLUSH
    1024 LIST  1024 LOAD  HI          // 42

On the words for the header (all on the block SCR): `TITLE` ( addr n -- ), `CHAIN`
( u -- ), `SHADOW` ( u -- ); `DOC` ( u -- ) lists block u's shadow block, `INDEX`
( from to -- ) the source blocks from .. to, each with its title. `LIST` shows the
header in its first line: `[1024] hello  version 1`. A block whose CRC does not match
the text is **damaged**: `LIST` and `LOAD` refuse it (`source block damaged (its
CRC)`).

**The volume.** `S" mycard" NEW-VOLUME` writes block 0 (do it once, on a new card):
the name and the ranges (`memory.md`, the SD card):

    > VOLUME
    volume mycard                           startup 0
      BOOT              1        255
      FONTS           256        256
      SYSTEM          512        512
      SOURCE         1024      64512
      DATA          65536  125108224

`RANGE SOURCE` ( -- u n ) gives a range, `700 10 SET-RANGE GAMES` adds one (or changes
it). `1024 STARTUP` makes `COLD` (and so every reset) load block 1024 (0: none); S2
held at reset skips it (`S2: no startup block`), and the loader then passes over the
flash and the card.

**The boot image and the fonts go onto the card from FORTH**, over the serial port:
`INSTALL` takes an image (`send the image`, as the loader asks) into the range
`BOOT`, header and all: the loader boots it from the card from then on. `u RECEIVE`
puts an image's payload into blocks u, u + 1, ... (`256 RECEIVE`: the fonts). The PC
side is `boot_serial.py --terminal-only --send FILE`: it sends FILE whenever the board
asks (a file that is not an image gets a header of its own):

    make install PORT=COM4     // the terminal; type INSTALL: build/forth.img goes
    make fonts PORT=COM4       // the terminal; type 256 RECEIVE: fonts.bin goes

The errors: `no such range` (-260), `source block damaged (its CRC)` (-261), `no
volume (NEW-VOLUME makes one)` (-262), `bad image` (-263), `no shadow block` (-264).

`FRAMES` counts the display's frames (60 a second). `FOR ... NEXT` runs its body n + 1
times, with `R@` the count going down to 0, as the processor's `NEXT` does.

## Not yet

- the multitasking words: `TASK`, `TERMINAL`, `ACTIVATE`, `GET`, `RELEASE`, ...
  (`tasks.md`); `MS` on the timers
- an editor for the blocks; `ALLOCATE`
- the card's waits (a write can take up to a second) do not `PAUSE` yet
- word lists (`WORDLIST`, `SET-ORDER`): the search order is there, with FORTH alone
- doubles beyond `UM*`, `UM/MOD`, `M*`, `S>D`; `VALUE`, `CASE`, `:NONAME`
- other keyboard layouts (the table `kbd_table` at the end of `forth.s`)
