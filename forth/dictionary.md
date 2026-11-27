# The dictionary of the mp32 FORTH machine

The code is **subroutine threaded, with inlining**: a word's code is mp32 code, a
colon definition calls other words with `JSRS` / `JSR` / `JSRL` and ends with `RET`,
and short words (the primitives) are copied into the caller instead of called.

**Every word's code starts at a 16-byte boundary**, the start of a cache line and of
fetch's instruction buffer. A call to a word fetches exactly the line its code starts
in, and a word of up to 15 bytes plus `RET` is one line. The dictionary is built
around that boundary.

The memory around it is in `memory.md`, the numbers in `memmap.inc`.

## A word

The header is right in front of the code: the name, then one cell, the **header
cell**, which ends exactly at the boundary where the code begins. Padding goes in
front of the name.

    ... code of the word before ... RET | pad | name | header cell | code ... RET | pad | ...
                                                                    ^
                                                                    xt: 16-byte boundary

    xt - 4         the header cell
    xt - 4 - len   the name (len bytes, in order)
    xt             the code
    xt + 16        the body of a CREATE'd word (its data)

So everything is a fixed offset from the xt: there is no code field and no pointer
from the header to the code.

| from | to | how |
|---|---|---|
| xt | header cell | `xt - 4` |
| xt | name | `xt - 4 - len` (len from the header cell) |
| xt | body | `xt + 16` (`>BODY`, a CREATE'd word) |
| header cell | next older word | its LINK field |
| a word list | its newest word | the word list's cell holds an xt |

The padding is at most 15 bytes a word: `:` puts HERE so that `HERE + len + 4` is a
multiple of 16.

## The header cell

One 32-bit cell holds everything but the name:

    bits 31..27  LEN    the name's length, 0 .. 31 (FORTH 2012 needs 31)
    bits 26..23  INL    0: a call; 1 .. 15: inline this many bytes of the code
    bits 22..4   LINK   the next older word's xt, bits 22..4 (0: the end of the list)
    bits  3..0   FLAGS  bit 0 IMMEDIATE    runs while compiling
                        bit 1 COMPILE-ONLY  only while compiling (IF, ;, ...)
                        bit 2 HIDDEN        not found: while it is being defined
                        bit 3 CREATED       has a body at xt + 16 (CREATE, VARIABLE,
                                            DOES>): >BODY checks it

LINK can drop bits 3..0 because every xt has them 0, and bits 31..23 because the
SDRAM is 8 MB: an xt is below `$80_0000`. So `LINK = cell & $7F_FFF0`, and the four
flags sit in the bits the alignment frees.

All fields add up without overlapping, so the assembler writes a header cell as a sum
(a relocatable symbol plus constants):

    .word  prev_xt + (len << 27) + (inl << 23) + flags

## Finding a word

A word list is one cell: the xt of its newest word. `FIND` walks LINK from it:

    xt = the word list's cell
    while xt != 0:
        h = mem[xt - 4]
        if (h >> 27) == len and not HIDDEN and the len bytes at xt - 4 - len match:
            found: xt, IMMEDIATE from h
        xt = h & $7F_FFF0

The length is in the same cell as the link, so a word with the wrong length costs
one load and a compare. Names are kept in capitals and compared without case: the
screen shows capitals only (PETSCII), the serial port may send small letters.

The search order (`CONTEXT`, `#ORDER`) and `CURRENT` are in the user area; FORTH
2012's word lists (`WORDLIST`, `SET-ORDER`, ...) fit as they are.

## Compiling

### Calls

A word that is not inlined is called with the shortest call that reaches it:
`JSRS` (2 bytes, -128 .. 127), `JSR` (3 bytes, 32 KB), `JSRL` (4 bytes, 8 MB).

`;` compiles `RET`, or, when the last thing compiled is a call and nothing jumps to the
place after it, turns that call into a jump (a tail call): `JSR` -> `B A` (`CBR`, also
3 bytes), `JSRL` -> `CBRL` (4 bytes), `JSRS` -> `CBR`.

### Inlining

A word with INL = n > 0 is copied: the first n bytes of its code (all but its `RET`)
go into the caller. Such code must not depend on where it is: no calls, and no branch
out of the n bytes. The compiler copies it **instruction by instruction** (the length
is in bits 7..6 of each opcode byte) and keeps the line rule.

Examples (bytes of code, `RET` not counted):

| word | code | INL |
|---|---|---|
| `DUP` `DROP` `SWAP` `OVER` `+` `AND` ... | the opcode | 1 |
| `>R` | `PUSH DROP` | 2 |
| `R>` | `DUP POP` | 2 |
| `2DUP` | `OVER OVER` | 2 |
| a `VARIABLE` | `DUP LIT24 addr` | 5 |
| a `CONSTANT` (fits 24 bits) | `DUP LIT24 n` | 5 |
| a `CONSTANT` (32 bits) | `DUP LIT24 low LITH high` | 7 |

So a variable or a constant compiles as its literal, with no call.

### The line rule

Bytes past the end of a 16-byte line read as 0 (`../cpu/isa.md`). The compiler
looks at each instruction before it lays it down: if it would cross the end of the
line (and the bytes that would land in the next line are not all 0), it pads to the
line's end with `NOP`s (`0x00`) first.

### Literals

| value | code |
|---|---|
| -128 .. 127 | `DUP LIT8 n` (3 bytes) |
| -32768 .. 32767 | `DUP LIT16 n` (4 bytes) |
| +-8 M | `DUP LIT24 n` (5 bytes) |
| the rest (32 bits) | `DUP LIT24 low LITH high` (7 bytes): LIT24 the low 24 bits, `LITH` the top byte (`../cpu/isa.md`) |

## Defining words

| word | its code at the xt | body |
|---|---|---|
| `:` | the compiled code, `RET` | - |
| `CREATE` | `DUP LIT24 xt+16 RET`: 6 bytes, one line | xt + 16 on |
| `VARIABLE` | as `CREATE`, INL 5 | one cell at xt + 16 |
| `CONSTANT` | `DUP LIT24 n RET`, INL 5; beyond 24 bits `DUP LIT24 low LITH high RET`, INL 7 | - |
| `DOES>` | the `CREATE`d word's line becomes `DUP LIT24 xt+16`, then a jump to the code after `DOES>` | xt + 16 on |

`CREATE`'s code always fits the first line, so the body can always start at xt + 16,
and `DOES>` can rewrite the line in place, whatever the word was before.

`:` lays down the name and the header cell with HIDDEN set and makes the word the
newest of `CURRENT` (so `RECURSE` knows its xt); `;` clears HIDDEN.

## Loops in a line

`UNEXT` loops back within the line it is in (a 4-bit target, no memory fetch:
`../cpu/isa.md`). Since every word starts at a line, the compiler knows where the
lines are: a `FOR ... NEXT` whose body fits in the rest of the line becomes
`UNEXT`; otherwise `NEXT2` / `NEXT3`.

## The kernel's own words

The kernel (`forth.s`) is assembled, and its words get the same headers, from a
macro (the assembler has `.macro`, `.align`, `.set`):

    .macro  WORD  label, name, len, flags, inl
            .align  16
            .res    (12 - len) & 15         ; pad: name + header cell end at a line
            .ascii  name
            .word   _prev + (len << 27) + (inl << 23) + flags
    label:                                  ; the xt: a 16-byte boundary
    _prev   .set    label
    .endmacro

            WORD    dup, "DUP", 3, 0, 1
            DUP
            RET

(the exact form is settled with the kernel's first words). The newest kernel word is
where the `FORTH` word list starts after COLD; new words follow at HERE, right after
the kernel's BSS.
