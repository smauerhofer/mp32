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
| r30 = GP | `$0080` | the system's variables, `$0000 - $03FF` (`G_...`) |
| r31 = UP | the running task + `$80` | its user area (`U_...`); PAUSE changes it |

With the `$80` bias one `LDR3` / `STR3` (offset -128 .. 127) reaches the first 256
bytes of each. Interrupt handlers use GP only, never UP: they may come while PAUSE
has r31 half way to the next task.

## The whole map

| address | size | what |
|---|---|---|
| `0000_0000 - 0000_FFFF` | 64 KB | **page zero**: the globals, the queues, OPERATOR's task area and its stacks. Fixed addresses, not in the image; COLD clears and fills it |
| `0001_0000 - 0001_03FF` | 1 KB | the vector table (VEC), the first part of the image |
| `0001_0400 - ...` | ~16..32 KB | the kernel: primitives and the core words, headers and code |
| `HERE - 001F_FFFF` | ~1.9 MB | **the dictionary** grows up from the end of the kernel; the task areas of `TASK` / `TERMINAL` are allotted in it |
| `0020_0000 - 0077_FFFF` | 5.5 MB | free memory: `ALLOCATE` and the CONS heap (L, HLIM), split later |
| `0078_0000 - 007F_FFFF` | 512 KB | the screen (write-through): text at `0078_0000`, pixels at `0079_0000` |
| `F000_0000 - F000_1FFF` | 8 KB | the boot loader (block RAM), as before |
| `FFFF_0000 - FFFF_FFFF` | | the I/O, as before (`../computer/README.md`) |

### Why the image moves to `0001_0000`

The image is loaded at `$10000` (`mp32img --load $10000`; the loader sets VEC to
it), not at 0. That frees the first 64 KB for things at **fixed** addresses, which
need not travel in the image (64 KB of zeros would take about 6 s on the serial
port). Below `$8000` an address fits a `LIT16` (`DUP LIT16 addr`, 4 bytes, not 5):
the 6502's zero page again. The loader needs no change.

## Page zero

| address | size | what |
|---|---|---|
| `0000 - 03FF` | 1 KB | the **globals** (GP): the queues' pointers, the cursor, the facilities, ... |
| `0400 - 07FF` | 1 KB | the **input queue**: a ring of 1024 bytes. The serial port's handler (vector 19) and the keyboard's (vector 20, key codes to characters) put characters in, `KEY` takes them out |
| `0800 - 0BFF` | 1 KB | the serial port's **output queue**: `EMIT` puts in, the handler (TXIE) sends |
| `0C00 - 0FFF` | 1 KB | the drivers' state: the keyboard (shift, caps, dead keys), the screen |
| `1000 - 1FFF` | 4 KB | **OPERATOR's task area** (below) |
| `2000 - 7FFF` | 24 KB | free for now: block buffers for the card (`BLOCK`, 1 KB each), a file system |
| `8000 - BFFF` | 16 KB | OPERATOR's **return stack**: 4096 cells |
| `C000 - FFFF` | 16 KB | OPERATOR's **parameter stack**: 4096 cells |

### The globals (`0000 - 03FF`, r30 = `$0080`)

| address | GP + | name | what |
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
| `0048 - 03FF` | | | free |

## A task area

Every task, OPERATOR too, has the same **user area** (512 bytes, UP = its start +
`$80`). A terminal task (one that runs the interpreter) has buffers as well; a
background task has only the user area and its stacks.

| part | OPERATOR | `TERMINAL` | `TASK` (background) |
|---|---|---|---|
| user area | `1000 - 11FF` | 512 B | 512 B |
| TIB | `1200 - 15FF` (1 KB) | 256 B | - |
| WORD's buffer | `1600 - 16FF` | 256 B | - |
| HOLD (`HLD` grows down) | `1700 - 17FF` | 256 B | - |
| PAD | `1800 - 19FF` | 256 B | - |
| return stack | `8000 - BFFF` (16 KB) | 1 KB (default) | 1 KB (default) |
| parameter stack | `C000 - FFFF` (16 KB) | 1 KB | 1 KB |

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

For OPERATOR: PSPH `$FFFD`, PSPL `$BFFD`, RSPH `$BFFD`, RSPL `$80FD`.

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
with the image at `$10400`.., the new ones follow at `HERE`, up to `DICT_END`
(`$200000`). Headers and code are together: each word's code right after its
header. Task areas are allotted in it, between the words.

`H` is a user variable, as in polyFORTH: today only OPERATOR compiles; a second
terminal task would get its own part of the dictionary.

New code goes through the cache like data: a word compiled now can be run at once.
Only the 16-byte instruction buffer of fetch can hold old bytes, and a jump or a call
to the new word reloads it.

## The free memory (`0020_0000 - 0077_FFFF`)

5.5 MB, for `ALLOCATE` / `FREE` and for the CONS heap of the LISP opcodes (L, HLIM).
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

## Changes to what is there

- the image is loaded at `$10000`, not 0: `mp32img --load $10000` and `forth.cfg`.
- r30 and r31 are reserved (GP, UP): no handler and no code word may use them for
  anything else.
- the LISP heap of `os.s` (1 MB .. 7.5 MB) moves to the free memory above the
  dictionary.
