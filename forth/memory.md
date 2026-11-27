# The memory of the mp32 FORTH machine

After boot the mp32 is a FORTH machine: it waits for words from the serial port and
from the keyboard. Both feed **one** input queue, so `KEY` does not know (and does not
care) where a character came from. `EMIT` writes to the screen and to the serial port.

The numbers in this file are in `memmap.inc`; the kernel and every later program
include that file, so a change is made there and nowhere else.

## The whole map

| address | size | what |
|---|---|---|
| `0000_0000 - 0000_FFFF` | 64 KB | **page zero**: the system's variables, the queues and buffers, the two stacks. Fixed addresses, not in the image; COLD clears and fills it |
| `0001_0000 - 0001_03FF` | 1 KB | the vector table (VEC), the first part of the image |
| `0001_0400 - ...` | ~16..32 KB | the kernel: primitives and the core words, headers and code, as the image brings them |
| `HERE - 001F_FFFF` | ~1.9 MB | **the dictionary** grows up from the end of the kernel, to `DICT_END` |
| `0020_0000 - 0077_FFFF` | 5.5 MB | free memory: `ALLOCATE` and the CONS heap (L, HLIM), split later |
| `0078_0000 - 007F_FFFF` | 512 KB | the screen (write-through): text at `0078_0000`, pixels at `0079_0000` |
| `F000_0000 - F000_1FFF` | 8 KB | the boot loader (block RAM), as before |
| `FFFF_0000 - FFFF_FFFF` | | the I/O, as before (`../computer/README.md`) |

### Why the image moves to `0001_0000`

The image is now loaded at `$10000` (`mp32img --load $10000`; the loader sets VEC to
it), not at 0. That frees the first 64 KB for things at **fixed** addresses, which
do not have to travel in the image (the serial port would otherwise carry 64 KB of
zeros, about 6 s). And it is our 6502's zero page again:

- everything below `$8000` fits a `LIT16` (`DUP LIT16 addr`, 4 bytes, not 5);
- the hot variables (the first 256 bytes) are reached with one `LDR3` / `STR3` off
  a base register: **r31 = UP = `$0080`**, offsets -128 .. 127 cover `$0000 - $00FF`.

## Page zero

| address | size | what |
|---|---|---|
| `0000 - 03FF` | 1 KB | the **user area**: the system's variables, 256 cells (below) |
| `0400 - 07FF` | 1 KB | the **input queue**: a ring of 1024 bytes. The serial port's handler (vector 19) and the keyboard's (vector 20, key codes to characters) both put characters in, `KEY` takes them out |
| `0800 - 0BFF` | 1 KB | the serial port's **output queue**: `EMIT` puts in, the handler (TXIE) sends |
| `0C00 - 0FFF` | 1 KB | **TIB**, the terminal input buffer of `ACCEPT` / `QUERY` (a line may be pasted, so it is longer than 80) |
| `1000 - 10FF` | 256 B | the buffer of `WORD` (a counted string) |
| `1100 - 11FF` | 256 B | pictured numeric output: `HLD` grows down from `$1200` (`<# # #S #>`) |
| `1200 - 13FF` | 512 B | `PAD` |
| `1400 - 1FFF` | 3 KB | the drivers' state: the keyboard (shift, caps, dead keys), the screen (cursor), ... |
| `2000 - 7FFF` | 24 KB | free for now: block buffers for the card (`BLOCK`, 1 KB each), a file system, the user areas of more tasks |
| `8000 - BFFF` | 16 KB | the **return stack**: 4096 cells |
| `C000 - FFFF` | 16 KB | the **parameter stack**: 4096 cells |

### The user area (`0000 - 03FF`)

The first 32 cells are the ones the kernel uses all the time (`UP` + offset, one
`LDR3`):

| address | UP + | name | what |
|---|---|---|---|
| `0000` | -128 | `STATE` | 0 interpreting, -1 compiling |
| `0004` | -124 | `BASE` | the number base |
| `0008` | -120 | `DP` | `HERE`: the next free byte of the dictionary |
| `000C` | -116 | `LATEST` | the newest word's header |
| `0010` | -112 | `>IN` | the offset into the input |
| `0014` | -108 | `#TIB` | the number of characters in TIB |
| `0018` | -104 | `SOURCE-ID` | 0 the user (TIB), -1 a string (`EVALUATE`) |
| `001C` | -100 | `'SOURCE` | the address of the input (TIB, or the string) |
| `0020` | -96 | `#SOURCE` | its length |
| `0024` | -92 | `HLD` | pictured numeric output |
| `0028` | -88 | `HANDLER` | `CATCH` / `THROW`: the frame on the return stack |
| `002C` | -84 | `CURRENT` | the word list new words go into |
| `0030` | -80 | `CONTEXT` | the search order (later: more cells) |
| `0034` | -76 | `IN-HEAD` | the input queue: where the handlers write |
| `0038` | -72 | `IN-TAIL` | where `KEY` reads |
| `003C` | -68 | `OUT-HEAD` | the output queue: where `EMIT` writes |
| `0040` | -64 | `OUT-TAIL` | where the handler reads |
| `0044` | -60 | `COL` | the cursor: column (0 .. 79) |
| `0048` | -56 | `ROW` | the cursor: row (0 .. 59) |
| `004C` | -52 | `COLOURS` | the text cell's upper bytes: font, paper, ink |
| `0050` | -48 | `FRAMES` | counted by the frame interrupt (vector 17) |
| `0054` | -44 | `DICT-END` | the end of the dictionary (`DICT_END`) |
| `0058` | -40 | `HEAP` | the start of the free memory |
| `005C` | -36 | `BOOTED` | where the image came from (r1 of the loader: 1 flash, 2 card, 3 serial) |
| `0060 - 007F` | | | free, for the kernel |
| `0080 - 00FF` | 0 .. 127 | | free, still in reach of one `LDR3` |
| `0100 - 03FF` | | | the rest: `VARIABLE`s of the kernel that are not hot |

## The stacks

T and S (the top two of the parameter stack) and R (the top of the return stack)
are registers; only the rest of each stack is in memory. A stack grows down: a push
stores at the pointer, then takes 4 off; a pop adds 4, then loads
(`../cpu/stage3/stackregs.v`).

**Empty** means the pointer is at the top of its stack (`$FFFC`, `$BFFC`), and T, S
(or R) hold nothing that counts. So

    DEPTH = (PSP0 - PSP) / 4

and the hardware does all the checking (`../cpu/isa.md`, The stack limits):

| register | value | exception | FORTH's `THROW` |
|---|---|---|---|
| `PSPH` | `$FFFC` \| 1 | 9, a pop on the empty stack | -4 stack underflow |
| `PSPL` | `$BFFC` \| 1 | 8, a push on the full stack | -3 stack overflow |
| `RSPH` | `$BFFC` \| 1 | 11 | -6 return stack underflow |
| `RSPL` | `$80FC` \| 1 | 10 | -5 return stack overflow |

Why it works out with T and S in registers: on the empty stack a `DROP` pops the
memory (S moves to T, the memory to S), and the pointer is at PSPH, so it is the
pop past the top: underflow, exactly at depth 0 -> -1. A push from depth 0 stores the
old S (nothing that counts) into memory: from then on each cell in memory is one of
depth.

The parameter stack starts right above the return stack's top word: nothing
between them, since the limits are checked by the hardware, not by guard words.

**Room for interrupts.** INTR and EXC are not checked, so a handler can always be
entered. RSPL is 64 words above the bottom of the return stack (`$8000 - $80FF`
stays free): an interrupt that comes when the return stack is full, and its
handler, still have room.

The handlers of the exceptions 8 .. 11 put the stacks back (ABORT does) and `THROW`
the codes above: `?` with the message, then `ok` again.

Frames (`ENTER` / `LEAVE`, FP) are on the return stack, for locals later.

## The dictionary

One linked list, newest first (`LATEST`), in one region: the kernel's words come with
the image at `$10400`.., the new ones follow at `HERE`, up to `DICT_END`
(`$200000`). Headers and code are together, each word's code right after its
header. (The header's layout and the threading, which decide what the code looks
like, are the next step.)

New code goes through the cache like data: a word compiled now can be run at once.
Only the 16-byte instruction buffer of fetch can hold old bytes, and a jump or a
call to the new word reloads it.

## The free memory (`0020_0000 - 0077_FFFF`)

5.5 MB, for `ALLOCATE` / `FREE` and for the CONS heap of the LISP opcodes (L, HLIM).
Where one ends and the other begins is not decided yet: COLD takes it from `HEAP`,
not from a constant in the code. `0078_0000` is where the screen starts.

## The screen (`0078_0000 - 007F_FFFF`, write-through)

| address | what |
|---|---|
| `0078_0000 - 0078_4AFF` | the text: 60 rows of 80 cells (19,200 bytes) |
| `0078_4B00 - 0078_FFFF` | free (45 KB): e.g. a second text page (text_base is a register: scrolling back, a second screen) |
| `0079_0000 - 007D_AFFF` | the pixels: 480 lines of 640 bytes |
| `007D_B000 - 007F_FFFF` | free (148 KB) |

## Changes to what is there

- the image is loaded at `$10000`, not 0: `mp32img --load $10000` and `forth.cfg`
  (RAM from `$10000`). The loader needs no change: it already takes the load address
  from the header, and VEC with it.
- the LISP heap of `os.s` (1 MB .. 7.5 MB) moves to the free memory above the
  dictionary.
