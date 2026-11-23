# mp32 toolchain

An assembler, a librarian and a linker for the mp32 processor, written in C#
(.NET 10, Visual Studio 2026). The instruction set they know is the one in
`cpu/isa.md`.

| tool     | project             | does |
|----------|---------------------|------|
| `mp32as` | `src/Mp32.Assembler` | assembles a source file (`.s`) into an object module (`.o`) |
| `mp32ar` | `src/Mp32.Librarian` | collects object modules into a library (`.lib`) |
| `mp32ld` | `src/Mp32.Linker`    | links object modules and libraries into a memory image, e.g. the `$readmemh` file for the block RAM |
|          | `src/Mp32.Core`      | shared: the instruction set table, the relocations, the object and library formats |
|          | `tests/Mp32.Tests`   | xUnit tests of all three |

The flow is the same as with cc65's `ca65`, `ar65` and `ld65` in the 6502 book:

    mp32as -o build/main.o main.s
    mp32as -o build/udiv.o udiv.s
    mp32ar a build/math.lib build/udiv.o
    mp32ld -C mp32.cfg -o build/boot.hex -m build/boot.map build/main.o build/math.lib

`examples/hello` is a complete example with its `Makefile.txt`.

## Building

In Visual Studio 2026: open `Mp32.Toolchain.slnx`, build, and run the tests in the
Test Explorer. To debug a tool, set its project as the startup project and give it
arguments under *Debug > Properties*.

From the MinGW shell (rename `Makefile.txt` to `Makefile` first):

    make build      # dotnet build
    make test       # dotnet test
    make publish    # mp32as.exe, mp32ar.exe, mp32ld.exe into bin/
    make example    # publish, then build examples/hello

## The assembler: mp32as

    mp32as [-o file.o] [-l file.lst] [-I dir] [-D name[=value]] source.s

Errors come as `file(line,col): error AS: message`, which Visual Studio and
MSBuild understand.

### Source lines

    label:  MNEMONIC operand, operand     ; comment
    name = expression

- Mnemonics, directives, register and condition names are case-insensitive;
  labels and symbols are not.
- A label that starts with `@` is local: it belongs to the global label before
  it, so `@loop` can be used again after the next global label.
- Numbers: `123`, `$7F`, `0x7F`, `%1010`, `0b1010`, `'A'` (with `\n \t \0 \\ \' \xHH`).
  Write the modulo operator with spaces (`a % b`), so `%101` stays binary.
- Expressions use C's operators and precedence: `+ - * / % & | ^ ~ ! << >> == !=
  < > <= >= && ||` and parentheses. `*` alone is the address of the statement.
- An address is only known after linking, so with addresses only `+` and `-` of a
  constant, and the difference of two labels in the same segment, are allowed.

### Instructions

All the opcodes of `cpu/isa.md`, with the syntax given there:

    NOP RET DUP DROP SWAP OVER DIP NIP TUCK DRIP PUSH POP PUSHS POPS ROT DROT
    ADD ADC SUB SBC CSUB DIVS MUL SMUL AND OR XOR INV NEG MULS CMP EXEC
    CLI SEI RTI             I = 0 / I = 1 / RET and I = 1 (interrupts)
    INTR n      EXC n       interrupt / exception n (0..255): a call to VEC + 4n;
                            R = the next instruction (INTR) or the EXC itself
    ASL ASR LSL LSR ROL ROR ROLC RORC
    INC DEC INCW DECW
    ENTER n  ENTER2 n  ENTER3 n     a stack frame: push FP on the return stack, FP =
                                    RSP, RSP -= 4n (n words, unsigned: 8 / 16 / 24 bits)
    LEAVE                           RSP = FP, pop FP
    INCR reg    DECR reg    INCWR reg    DECWR reg      (any register, by 1 / 4)
    LIT8 n      LIT16 n      LIT24 n
    CJMPL cond, label-or-offset
    CBR cond, label-or-offset           CBRL cond, label-or-offset
    UNEXT label-or-offset   if R != 0: R -= 1, jump within the line; else drop R
    NEXT2 reg, label-or-offset          NEXT3 reg, label-or-offset
                            if reg != 0: reg -= 1, branch (8 / 16-bit offset);
                            else for R drop R (reg: r0..r31 T S R L)
    JSRS label-or-offset    JSR label-or-offset     JSRL label-or-offset
    MOVR dst, src           ADDR dst, src           ADCR dst, src
    SUBR dst, src           SBCR dst, src           ANDR dst, src
    ORR dst, src            XORR dst, src           CMPR dst, src
                                                    (one of them is T)
    LDR LDRH LDRSH LDRB LDRSB reg, addr     load a word / halfword / byte from the
                            address in register addr (S: sign-extended)
    STR STRH STRB reg, addr store a word / halfword / byte
                            (reg: r0..r31 T S R L; addr: those, PC, PSP, RSP, FP)
    LDR3 LDRH3 LDRSH3 LDRB3 LDRSB3 reg, base, offset    load from base + offset
    STR3 STRH3 STRB3 reg, base, offset                  store to base + offset
                            (offset: a register, not PC, or a constant -$80..$7F;
                            at most one of base and offset of PSP RSP FP TMPL TMPH
                            ST HLIM; STR3: not all three of r0..r31 T S R L)
    MOV2 dst, src           dst = src, any two registers, no flags
    MOVI2 dst, imm8         dst = imm8 (a constant, -$80..$7F), no flags
    ADD2 dst, src           dst = dst + src, any two registers (at most one of
                            PSP RSP FP TMPL TMPH ST HLIM)
    ADC2 SUB2 SBC2 AND2 OR2 XOR2 CMP2 dst, src      as ADD2: dst = dst op src
                            (CMP2: only the flags of dst - src)
    ADD3 ADC3 SUB3 SBC3 AND3 OR3 XOR3 CMP3 dst, src1, src2
                            dst = src1 op src2, any three registers (at most one
                            source of PSP RSP FP TMPL TMPH ST HLIM);
                            CMP3: dst = the flags {V, N, Z, C} of src1 - src2,
                            not into PC
    CAR CDR RPLACA RPLACD   LISP: the car / cdr of the cons in T (tag 01: at T - 1,
                            T + 3); RPLACA / RPLACD store S there
    CONS                    ( car cdr -- cell ): a cell at L, L += 8; traps to the
                            GC vector when L > HLIM
    TADD TSUB               ADD / SUB for fixnums: V also if a tag is not 00
    LSLI LSRI ASRI ROLI RORI n      T shifted / rotated by a constant n, 0..31
    TTAG mask, value        Z = ((T & mask) == value), constants 0..$FF

Conditions: `EQ NE CS/HS CC/LO MI PL VS VC HI LS GE LT GT LE A TZ`.
Registers for MOVR, ADDR .. CMPR, ADD2 .. CMP2 and ADD3 .. CMP3: `r0`..`r31`, `T S R L PSP RSP FP PC TMPL TMPH ST HLIM VEC` (ST: the flags, bits 3..0 = V N Z C, bit 4
the interrupt flag I; HLIM: the heap limit of CONS; VEC: the vector table, 1 KB
aligned). EXEC was called EXC before; EXC is now the exception.

For a branch or call, a label is turned into the offset from the next
instruction (for CJMPL and UNEXT: the label's offset in the line); a plain number is put
into the field as it is.

Pseudo-instructions, which pick their length:

| write          | becomes |
|----------------|---------|
| `LIT n`        | the shortest of LIT8, LIT16, LIT24; LIT24 for an address |
| `CALL label`   | the shortest of JSRS, JSR, JSRL; JSRL for a label in another segment or module |
| `B cond, label`| CBR, or CBRL when CBR does not reach |
| `JMP label`    | `B A, label` |
| `NEXT reg, label` | NEXT2, or NEXT3 when NEXT2 does not reach |
| `LEA label`    | `LIT24 offset` + `ADDR T, PC`: T = the address of the label, PC-relative (6 bytes) |

`LEA` is there because the block RAM is at `$F0000000`: its addresses do not fit
in the 24 signed bits of a LIT. `LIT label` for a label in the block RAM is a link
error that says so.

### The 16-byte line rule

Fetch reads 16-byte lines, and bytes past the end of a line read as 0. So the
assembler never lets an instruction cross a line: when one would, it puts NOPs
(0x00) in front of it. A label in front of such an instruction gets the address
after the NOPs. Every segment starts on a 16-byte boundary, so the lines the
assembler sees are the lines in memory. (isa.md allows a crossing when the bytes
in the next line happen to be 0; the assembler does not use that.)

The listing (`-l`) shows the NOPs put in, as `+n` before the bytes.

### Directives

| directive | does |
|-----------|------|
| `.code` `.rodata` `.data` `.bss` | switch to the segment CODE, RODATA, DATA, BSS |
| `.segment "NAME"[, bss]` | switch to any segment (the linker configuration must know it) |
| `.byte` / `.db` | bytes; strings allowed |
| `.half` / `.dh` | 16-bit halfwords, little-endian |
| `.word` / `.dw` | 32-bit words, little-endian; addresses allowed |
| `.ascii "s"` `.asciiz "s"` | a string, without / with a 0 at the end |
| `.res n[, fill]` / `.space` / `.ds` | n bytes (the only thing allowed in BSS) |
| `.align n[, fill]` | to a multiple of n (a power of two) |
| `.incbin "file"` | the bytes of a file |
| `.include "file"` | another source file (looked for next to the source, then `-I`) |
| `.import` / `.extern` `a, b` | symbols another module defines |
| `.export` `a, b` | symbols other modules may use |
| `.global a, b` | export what is defined here, import the rest |
| `name = expr`, `name .equ expr` | a constant (or an alias of an address) |
| `.macro NAME p1, p2` ... `.endmacro` / `.endm` | a macro; `\@` in it is a number unique to each use |
| `.rept n` ... `.endr` | the lines between, n times; `\@` is 0, 1, ... |
| `.if expr` `.elseif expr` `.else` `.endif` | conditional assembly |
| `.ifdef name` `.ifndef name` | ... on whether a symbol is defined so far (or with `-D`) |
| `.error "text"` `.warning "text"` | stop with an error / print a warning |

## The librarian: mp32ar

    mp32ar a lib.lib a.o b.o      add or replace members (makes the library if needed)
    mp32ar d lib.lib a.o          delete members
    mp32ar l lib.lib              list the members
    mp32ar t lib.lib              list the members with their exports and imports
    mp32ar x lib.lib [a.o]        extract members (all if none is named)

## The linker: mp32ld

    mp32ld [-C config] [-o name] [-m map] [-L dir] [-D name=value] files...

Object files are always linked. From a library, only the members that define a
symbol still needed are taken (again and again, until nothing more is needed),
so the order of the files does not matter. Two definitions of one symbol are an
error.

The configuration says where the segments go, in the style of ld65:

    MEMORY {
        BRAM:  start = $F0000000, size = $2000, file = "%O", fill = yes, format = hex;
        SDRAM: start = $00000000, size = $800000;
    }
    SEGMENTS {
        CODE:   load = BRAM, type = ro;
        RODATA: load = BRAM, type = ro;
        DATA:   load = BRAM, type = rw;
        BSS:    load = BRAM, type = bss, define = yes;
        HEAP:   load = SDRAM, type = bss, define = yes;
    }

That is also the built-in configuration, used without `-C` (`mp32ld
--print-config` prints it): everything in the block RAM the processor boots
from, written as the `$readmemh` file for `BRAM_INIT` of `cpu/stage4/membus.v`.

Memory areas: `start`, `size` (also `8K`, `8M`), `file` (`%O` is the `-o` name; an
area without a file is not written), `fill = yes` (write the whole area, not only
up to the last byte used), `fillval`, `format`, `define = yes`.

Formats: `hex`, one 16-byte line per row as 32 hex digits, byte 15 first: what
`bram.v` loads; `hex32`, one word per row; `bin`, raw bytes. Without `format`
the file name decides: `.hex` and `.mem` are `hex`, anything else `bin`.

Segments, placed in the order of the configuration: `load` (the memory area),
`type` (`ro`, `rw`, `bss`), `align` (at least 16, except for BSS), `start` (a fixed
address), `define = yes` (defines `__NAME_START__`, `__NAME_SIZE__` and
`__NAME_END__`, which a program can `.import`).

The map file (`-m`) shows the memory areas, the segments, where each module went
and every global symbol by name and by address.

## The object and library formats

Binary, little-endian, written with `BinaryWriter`; see `ObjectModule.cs` and
`Library.cs`. An object module holds its sections (name, alignment, contents),
its symbols (one for the start of each section, the exports, the imports) and
for each section its relocations: offset, kind, symbol, addend and the source
line, so the linker can say where a field that does not fit came from.

The relocation kinds (`Relocations.cs`) are the fields of the instruction set:
`Abs8/16/32` for data, `Lit8/16/24`, `Rel8/16/24` (JSRS / JSR / JSRL), `Cbr12`,
`Cbrl20`, `Cjmpl4` (CJMPL and UNEXT, checked to stay in its line), `Lea24`, and
`Next8`, `Next16` (NEXT2 / NEXT3: the offset in byte 2 / bytes 2, 3).

## When the instruction set grows

New opcodes go into the table in `src/Mp32.Core/Isa.cs`. One that fits an
existing operand form (no operands, a constant, a condition and an offset, a
register move) needs nothing else. A new form needs its parsing in
`Assembler.Instruction`, its encoding in `Assembler.EmitInstr`, and, if it can
hold an address, a relocation kind in `Relocations.cs`.

Open: loads and stores are not in `isa.md` yet, so neither are they here.
