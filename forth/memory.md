# The memory of the mp32 FORTH machine

After boot the mp32 is a FORTH machine: it waits for words from the serial port and
from the keyboard. Both feed **one** input queue, so `KEY` does not know (and does not
care) where a character came from. `EMIT` writes to the screen and to the serial port.

It runs several FORTH tasks, as polyFORTH does (`tasks.md`): the terminal task
OPERATOR, which runs the interpreter after COLD, and any number of tasks made with
`TASK` / `TERMINAL`. Each task has its own **user area** and its own **two
stacks**; the dictionary, the queues and the devices are shared.

The compiled code is **subroutine threaded, with inlining**: a colon definition is
mp32 code, `JSR` to other words, with the primitives (`DUP`, `DROP`, `+`, ... one
byte each) put in place instead of called.

The numbers are in `memmap.inc`; the kernel and every later program include it.

## Two base registers

| register | value | what |
|---|---|---|
| r30 = GP | `$0077_0080` | the system's variables, `$0077_0000 - $0077_03FF` (`G_...`) |
| r31 = UP | the running task + `$80` | its user area (`U_...`); PAUSE changes it |

With the `$80` bias one `LDR3` / `STR3` (offset -128 .. 127) reaches the first 256
bytes of each. Interrupt handlers use GP only, never UP: they may come while PAUSE
has r31 half way to the next task.

The other registers (`forth.s`):

| registers | what |
|---|---|
| T, S, R | the tops of the two stacks |
| r0 .. r23 | scratch: free in every word, not kept across a call (r13 is the scratch of the macro `LDA`) |
| r24 .. r29 | the interrupt handlers' own: no other code touches them, so a handler saves nothing but the flags (`PUSHF` / `POPF`). The keyboard's handler needs more and keeps r0 .. r7 in DRIVERS while it runs |
| r30, r31 | GP, UP |

## The whole map

| address | size | what |
|---|---|---|
| `0000_0000 - 0000_03FF` | 1 KB | the vector table (VEC = 0), the first part of the image |
| `0000_0400 - ...` | ~16..32 KB | the kernel: primitives and the core words, headers and code |
| `HERE - 001F_FFFF` | ~2 MB | **the dictionary** grows up from the end of the kernel; the task areas of `TASK` / `TERMINAL` are allotted in it |
| `0020_0000 - 0076_FFFF` | 5.4 MB | free memory: `ALLOCATE` and the CONS heap (L, HLIM), split later |
| `0077_0000 - 0077_FFFF` | 64 KB | **the system area**: the globals, the queues, OPERATOR's task area and its stacks. Fixed addresses, not in the image; COLD clears and fills it |
| `0078_0000 - 007F_FFFF` | 512 KB | the screen (write-through): text at `0078_0000`, pixels at `0079_0000` |
| `F000_0000 - F000_1FFF` | 8 KB | the boot loader (block RAM), as before |
| `FFFF_0000 - FFFF_FFFF` | | the I/O, as before (`../computer/README.md`) |

The image is loaded at 0, as `os.s` is: one contiguous program from the vector table
on, and the dictionary right after it. The fixed part lives at the top of the RAM,
below the screen, where it needs no room in the image (the BSS is not loaded, and
the loader does not clear it). Its address hardly matters: the code reaches it
through GP and UP, and only COLD names `SYSTEM` (`$770000`, one `LIT24`). To move
it, change `SYSTEM` in `memmap.inc`.

## The system area (`0077_0000 - 0077_FFFF`)

| SYSTEM + | size | what |
|---|---|---|
| `0000 - 03FF` | 1 KB | the **globals** (GP): the queues' pointers, the cursor, the facilities, ... |
| `0400 - 07FF` | 1 KB | the **input queue**: a ring of 1024 bytes. The serial port's handler (vector 19) and the keyboard's (vector 20, key codes to characters) put characters in, `KEY` takes them out |
| `0800 - 0BFF` | 1 KB | the serial port's **output queue**: `EMIT` puts in, the handler (TXIE) sends |
| `0C00 - 0FFF` | 1 KB | the drivers' state: the keyboard (shift, caps, dead keys), the screen |
| `1000 - 1FFF` | 4 KB | **OPERATOR's task area** (below) |
| `2000 - 20FF` | 256 B | `LEAVES`: the compiler's LEAVE stack (the `LEAVE`s of the loops being compiled) |
| `2100 - 21FF` | 256 B | `SBUF`: the string of `S"` while interpreting |
| `2200 - 61FF` | 16 KB | `BUFS`: the four block buffers (`BLOCK`), 4 KB each |
| `6200 - 621F` | 32 B | `BTAB`: for each buffer its block (-1: none) and its state (bit 0 changed, 2: a damaged source block) |
| `6220 - 661F` | 1 KB | `CRC_TAB`: the CRC-32 table (`crc_init` at `COLD`) |
| `6620 - 7FFF` | 6.5 KB | free for now |
| `8000 - BFFF` | 16 KB | OPERATOR's **return stack**: 4096 cells |
| `C000 - FFFF` | 16 KB | OPERATOR's **parameter stack**: 4096 cells |

### The globals (SYSTEM + `0000 - 03FF`, r30 = `$0077_0080`)

| SYSTEM + | GP + | name | what |
|---|---|---|---|
| `0000` | -128 | `IN-HEAD` | the input queue: where the handlers write |
| `0004` | -124 | `IN-TAIL` | where `KEY` reads |
| `0008` | -120 | `OUT-HEAD` | the output queue: where `EMIT` writes |
| `000C` | -116 | `OUT-TAIL` | where the handler reads |
| `0010` | -112 | `IN-WAIT` | the task asleep in `KEY`, woken by the input handlers |
| `0014` | -108 | `OUT-WAIT` | the task asleep in `EMIT` (queue full), woken by the TX handler |
| `0018` | -104 | `COL` | the cursor: column (0 .. 79) |
| `001C` | -100 | `ROW` | the cursor: row (0 .. 59) |
| `0020` | -96 | `COLOURS` | the text cell's upper bytes: font, paper, ink |
| `0024` | -92 | `FRAMES` | counted by the frame interrupt (vector 17) |
| `0028` | -88 | `TICKS` | milliseconds, for `MS` (later) |
| `002C` | -84 | `HEAP` | the start of the free memory |
| `0030` | -80 | `DICT-END` | the end of the dictionary |
| `0034` | -76 | `BOOTED` | where the image came from (1 flash, 2 card, 3 serial) |
| `0038` | -72 | `FORTH-WORDLIST` | its newest word |
| `003C` | -68 | `SCREEN` | facility: the task that owns it, 0 = free (`GET`, `RELEASE`) |
| `0040` | -64 | `SERIAL` | facility: the serial port's output |
| `0044` | -60 | `KEYS` | facility: the input |
| `0048` | -56 | `G_UART` | `$FFFF_0000`: the device addresses and constants, put here by COLD, so a handler gets one with one `LDR3` (it may not use T for a `LIT`) |
| `004C` | -52 | `G_IRQC` | `$FFFF_0400` |
| `0050` | -48 | `G_VIDEO` | `$FFFF_A000` |
| `0054` | -44 | `G_KBD` | `$FFFF_0600` |
| `0058` | -40 | `G_INQB` | the input queue's address |
| `005C` | -36 | `G_OUTQB` | the output queue's |
| `0060` | -32 | `G_QMASK` | 1023: a queue's index, round |
| `0064` | -28 | `G_DRV` | DRIVERS |
| `0068` | -24 | `G_LAST` | the compiler: the newest header's xt (`IMMEDIATE`, `RECURSE`, `;`) |
| `006C` | -20 | `G_LSP` | the LEAVE stack's pointer |
| `0070 - 0078` | -16 .. -8 | `G_CALLAT`, `G_CALLEND`, `G_CALLXT` | the last call compiled: where, HERE after it, what it calls (`;` makes it a jump) |
| `007C` | -4 | `G_LABEL` | the last place a branch goes to: no tail call there |
| `0080` | 0 | `G_CRLF` | `ACCEPT` ended at a CR: an LF right after it is not a line |
| `0084` | 4 | `G_CURSOR` | the cursor is shown (`KEY` waits) |
| `0088`, `008C` | 8, 12 | `G_ERRADDR`, `G_ERRLEN` | the word an error is about |
| `0090` | 16 | `G_ABORTMSG` | `ABORT"`: its message |
| `0094` | 20 | `G_EXCPC` | an exception: where it happened |
| `0098` | 24 | `G_LEDS` | `$FFFF_0200` |
| `009C` | 28 | `G_KTAB` | the keyboard's table |
| `00A0` | 32 | `G_SD` | `$FFFF_0100`: the SD card |
| `00A4` | 36 | `G_SDHC` | the card: -1 not started yet, 0 byte addresses (SDSC), 1 block addresses |
| `00A8` | 40 | `G_BNEXT` | the buffer taken next (in turn) |
| `00AC` | 44 | `G_BCUR` | the buffer of the last `BLOCK` / `BUFFER` (`UPDATE`) |
| `00B0` | 48 | `G_SCR` | `SCR` |
| `00B4` | 52 | `G_BLK` | `BLK`: the block `LOAD` interprets, 0 none |
| `00B8` | 56 | `G_SDBLKS` | the card's capacity in blocks of 512 bytes (from its CSD), 0 not known |
| `00BC` | 60 | `G_WTOP` | the text window's first row (`TEXT-WINDOW`) |
| `00C0` | 64 | `G_WROWS` | its rows |
| `00C4` | 68 | `G_WOFF` | how far it has scrolled: the video unit's SCROLL OFFSET |
| `00C8 - 03FF` | | | free |

### The drivers' state (SYSTEM + `0C00`, `G_DRV`)

| + | what |
|---|---|
| `00` | the keyboard: the last report's key codes (8 bytes as KEYS0, KEYS1 give them) |
| `08` | Caps Lock: 0 or 1 |
| `10 - 2F` | r0 .. r7 while the keyboard's handler runs |
| `30` | the report being looked at (8 bytes) |
| `40 - 4F` | `SD_CSD`: the card's CSD (`SD-CSD`) |
| `50 - 5F` | `SD_CID`: its CID (`SD-CID`) |

## A task area

Every task, OPERATOR too, has the same **user area** (512 bytes, UP = its start +
`$80`). A terminal task (one that runs the interpreter) has buffers as well; a
background task has only the user area and its stacks.

| part | OPERATOR | `TERMINAL` | `TASK` (background) |
|---|---|---|---|
| user area | +`1000 - 11FF` | 512 B | 512 B |
| TIB | +`1200 - 15FF` (1 KB) | 256 B | - |
| WORD's buffer | +`1600 - 16FF` | 256 B | - |
| HOLD (`HLD` grows down) | +`1700 - 17FF` | 256 B | - |
| PAD | +`1800 - 19FF` | 256 B | - |
| return stack | +`8000 - BFFF` (16 KB) | 1 KB (default) | 1 KB (default) |
| parameter stack | +`C000 - FFFF` (16 KB) | 1 KB | 1 KB |

(OPERATOR's addresses are SYSTEM + these: its UP is `$0077_1080`.)

The words find the buffers through the user area (`'TIB`, `'WORD`, `'HOLD`, `'PAD`),
not through constants: the same `ACCEPT`, `WORD`, `<#` work in every terminal task.
`TASK` and `TERMINAL` allot the area at `HERE`, in the dictionary, as polyFORTH does.

### The user area (UP = the area + `$80`)

| offset | UP + | name | what |
|---|---|---|---|
| `00` | -128 | `STATUS` | 0 asleep, 1 awake |
| `04` | -124 | `LINK` | the next task's UP: the tasks are a ring |
| `08` | -120 | (PSP) | PSP while the task does not run |
| `0C` | -116 | (RSP) | RSP while it does not run |
| `10` | -112 | (FP) | FP |
| `14 - 20` | -108 .. -96 | (limits) | the task's PSPL, PSPH, RSPL, RSPH |
| `24` | -92 | `S0` | PSP when empty |
| `28` | -88 | `R0` | RSP when empty |
| `2C` | -84 | `BASE` | |
| `30` | -80 | `STATE` | 0 interpreting, -1 compiling |
| `34` | -76 | `H` | the dictionary pointer: `HERE` |
| `38` | -72 | `>IN` | |
| `3C` | -68 | `#TIB` | |
| `40` | -64 | `'TIB` | the task's TIB |
| `44` | -60 | `SOURCE-ID` | 0 the user, -1 a string (`EVALUATE`) |
| `48` | -56 | `'SOURCE` | the input's address |
| `4C` | -52 | `#SOURCE` | its length |
| `50` | -48 | `HLD` | |
| `54` | -44 | `'HOLD` | where `HLD` starts |
| `58` | -40 | `'WORD` | WORD's buffer |
| `5C` | -36 | `'PAD` | |
| `60` | -32 | `HANDLER` | `CATCH` / `THROW` |
| `64` | -28 | `CURRENT` | |
| `68` | -24 | `#ORDER` | |
| `6C - 88` | -20 .. 11 | `CONTEXT` | the search order, 8 cells |
| `8C` | 12 | `'KEY` | the task's `KEY` (vectored: other terminals later) |
| `90` | 16 | `'EMIT` | the task's `EMIT` |
| `94` | 20 | `NAME` | the task's header, for `.TASKS` |
| `98 - 1FF` | 24 .. | | `USER` variables (`USER` allots them; up to `FF` in reach of one `LDR3`) |

## The stacks

T and S (the top two of the parameter stack) and R (the top of the return stack)
are registers; only the rest of each stack is in memory. A stack grows down: a push
stores at the pointer, then takes 4 off; a pop adds 4, then loads.

**Empty** means the pointer is at the top of its stack (`S0`, `R0`), and T, S (or R)
hold nothing that counts. So `DEPTH = (S0 - PSP) / 4`, and the hardware does all the
checking (`../cpu/isa.md`, The stack limits). A stack from A up to B - 4 (B = A +
its size):

| register | value | exception | FORTH's `THROW` |
|---|---|---|---|
| `PSPH` | (B - 4) \| 1 | 9, a pop on the empty stack | -4 stack underflow |
| `PSPL` | (A - 4) \| 1 | 8, a push on the full stack | -3 stack overflow |
| `RSPH` | (B - 4) \| 1 | 11 | -6 return stack underflow |
| `RSPL` | (A + 256 - 4) \| 1 | 10 | -5 return stack overflow |

For OPERATOR: PSPH `$0077_FFFD`, PSPL `$0077_BFFD`, RSPH `$0077_BFFD`, RSPL `$0077_80FD`.

With T and S in registers this works out: on the empty stack a `DROP` pops the
memory (S moves to T, the memory to S), and the pointer is at PSPH: underflow,
exactly at depth 0 -> -1. A push from depth 0 stores the old S (nothing that counts):
from then on each cell in memory is one of depth.

The limits are the task's: PAUSE loads them with its pointers (`tasks.md`).

**Room for interrupts.** An interrupt runs on the return stack of the task that
runs when it comes, and INTR / EXC are not checked. So **every** task keeps 64
words below RSPL free (the 256 in RSPL above): its return stack is at least 1 KB.

The handlers of the exceptions 8 .. 11 put the task's stacks back and `THROW` the
codes above: in OPERATOR `?` with the message, then `ok` again; a background task
that does not catch it is stopped.

Frames (`ENTER` / `LEAVE`, FP) are on the return stack, for locals later.

## The dictionary

One linked list per word list, newest first, in one region: the kernel's words come
with the image at `$400`.., the new ones follow at `HERE`, up to `DICT_END`
(`$200000`). Headers and code are together: each word's code right after its
header. Task areas are allotted in it, between the words.

`H` is a user variable, as in polyFORTH: today only OPERATOR compiles; a second
terminal task would get its own part of the dictionary.

New code goes through the cache like data: a word compiled now can be run at once.
Only the 16-byte instruction buffer of fetch can hold old bytes, and a jump or a call
to the new word reloads it.

## The free memory (`0020_0000 - 0076_FFFF`)

5.4 MB, for `ALLOCATE` / `FREE` and for the CONS heap of the LISP opcodes (L, HLIM).
Where one ends and the other begins is not decided yet: COLD takes it from `HEAP`.
L and HLIM are the same for all tasks; the tasks do not interrupt each other
(`tasks.md`), so a CONS is never cut in half by another task.

## The screen (`0078_0000 - 007F_FFFF`, write-through)

| address | what |
|---|---|
| `0078_0000 - 0078_4AFF` | the text: 60 rows of 80 cells (19,200 bytes) |
| `0078_4B00 - 0078_FFFF` | free (45 KB): e.g. a second text page (text_base is a register) |
| `0079_0000 - 007D_AFFF` | the pixels: 480 lines of 640 bytes |
| `007D_B000 - 007F_FFFF` | free (148 KB) |

## The SD card

FORTH's own: raw blocks of 512 bytes, no file system, never in a PC. FORTH's blocks
are 4 KB (`BLK_SIZE`): block u is the card's sectors 8u .. 8u + 7 (`BLK_LBA` 0), up to
the card's capacity (its CSD: `BLOCKS`). FORTH puts everything on the card itself,
the boot image and the fonts too (over the serial port: `INSTALL`, `RECEIVE`).
`NEW-VOLUME` lays it out:

| FORTH's blocks | the range | what |
|---|---|---|
| 0 | | the **volume block** (`NEW-VOLUME`): `VOL_MAGIC` `$900DCA4D`, the card's name, the startup block, the ranges |
| 1 .. 255 | `BOOT` | the boot image (`INSTALL`): the loader boots it from card sector 8 (`SD_LBA`) |
| 256 .. 511 | `FONTS` | the fonts (`RECEIVE`): font n in card sectors 8 * 256 + 4n .. + 3, two to a block |
| 512 .. 1023 | `SYSTEM` | the system's source blocks |
| 1024 .. 65535 | `SOURCE` | the user's source blocks |
| 65536 .. | `DATA` | data (the rest of the card); 4 MB = 1024 blocks is the card's erase unit: data rewritten often is best kept in whole 4 MB pieces, 1024-aligned |

The **volume block** (block 0):

| bytes | what |
|---|---|
| 0 .. 3 | `VOL_MAGIC` = `$900DCA4D` |
| 4 .. 7 | the layout's version (1) |
| 8 .. 11 | the startup block: `COLD` loads it (0: none; `STARTUP`) |
| 16 .. 47 | the card's name (32 characters) |
| 64 .. | the ranges, 16 bytes each, up to the first that begins with 0: the name (8 capitals, spaces after), the first block, how many blocks |

`RANGE name` ( -- u n ) gives a range, `SET-RANGE` ( u n "name" -- ) changes one or
adds one; `FONT` takes its fonts from `FONTS` (`FONT_BLOCK`, 256, on a card without a
volume), `INSTALL` its image to `BOOT`.

**S2** held at reset: the loader passes over the flash and the card (the serial port
boots), and `COLD` does not load the startup block: a way out of a bad image or a
startup block that hangs.

The screen starts with font 0, Latin-1; font 1 is PETSCII, font 2 PETSCII's text set
(small letters), font 3 the book's font (`../computer/README.md`, the fonts). `FONT`
loads one from the card over any of them:

    FONT ( n f -- )      font n of the card into font f of the font RAM
                         (card sectors 8 * FONTS + 4n .. + 3 to $FFFF_8000 + 2048 f)

    1 1 FONT            // bold (the card's font 1) into font 1
    0 0 FONT            // the old normal font instead of Latin-1

The fonts go onto the card once: `256 RECEIVE` at the terminal, then the PC sends
`fonts.bin` (`make fonts PORT=COM4`, or `boot_serial.py --terminal-only --send
../computer/build/fonts.bin`).

A cell shows font f with f in its byte 1 (`COLOURS`, the globals).

A **source block** (what `LOAD` and `LIST` take) is a header of 64 bytes, its first
word `SRC_MAGIC` = `$900DF00D`, then the text: 56 lines of 72 characters (`SRC_ROWS`,
`SRC_COLS`: 4,032 bytes), as many as fit the screen with a line number in front.
`NEW-SOURCE` makes one, `LINE` gives a line's address. The header:

| bytes | what |
|---|---|
| 0 .. 3 | `SRC_MAGIC` `$900DF00D` |
| 4 .. 35 | `SRC_TITLE`: the title, 32 characters (`TITLE`, `INDEX`) |
| 36 .. 39 | `SRC_NEXT`: `LOAD` goes on with this block (0: none; `CHAIN`) |
| 40 .. 43 | `SRC_SHADOW`: the block that documents this one (0: none; `SHADOW`, `DOC`) |
| 44 .. 47 | `SRC_VERSION`: + 1 every time the block is written |
| 48 .. 51 | `SRC_CRC`: the CRC-32 of the text (bytes 64 .. 4095), written with it |
| 52 .. 63 | 0, not defined yet |

A source block read with a CRC that does not match (version not 0) is **damaged**:
`LIST` and `LOAD` refuse it (`source block damaged (its CRC)`, -261) until it is
read again (`EMPTY-BUFFERS`).

`SD-READ` / `SD-WRITE` ( addr lba -- ior ) are the card's blocks themselves; `BLOCK`,
`BUFFER`, `UPDATE`, `SAVE-BUFFERS`, `EMPTY-BUFFERS`, `FLUSH`, `LOAD`, `THRU`, `LIST`
the standard words on FORTH's blocks, with the four buffers (`BUFS`, `BTAB`): a buffer
that is needed for another block is written back first if it was changed. The card
is started when it is first used, as the loader starts it (CMD0, CMD8, ACMD41,
CMD58 or CMD16), then its CSD (CMD9: the capacity) and its CID (CMD10: maker,
product, serial) are read, and it runs at 21 MHz; after an error it is started
again the next time. `SD-INFO` shows what the CSD and the CID say.

## Changes to what is there

- the image stays at 0, as `os.s`: `forth.cfg` links it there, `mp32img` without
  `--load`.
- r30 and r31 are reserved (GP, UP): no handler and no code word may use them for
  anything else (`os.s`'s handlers use them for `frames` and the video registers).
- the LISP heap of `os.s` (1 MB .. 7.5 MB) moves to the free memory above the
  dictionary.
