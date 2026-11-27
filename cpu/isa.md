# mp32 instruction set

## Format

An instruction is 1 to 4 bytes, little-endian: the first byte is the one at the PC.
The first byte is the opcode byte:

    bit   7 6    5 4 3 2 1 0
          size   opcode

| size bits | length  | opcode bytes |
|-----------|---------|--------------|
| 00        | 1 byte  | 0x00 .. 0x3F |
| 01        | 2 bytes | 0x40 .. 0x7F |
| 10        | 3 bytes | 0x80 .. 0xBF |
| 11        | 4 bytes | 0xC0 .. 0xFF |

So each length has 64 opcodes.

A register is selected with 6 bits: bit 5 = 0 for r0 .. r31 (bits 4..0), 1 for a
special register (bits 1..0: 00 = T, 01 = S, 10 = R, 11 = L). The special registers
are reached only by special opcodes.

## Operand bytes

The usual layout, for instructions with registers:

    byte 0   size(7..6)  opcode(5..0)
    byte 1   opx(7..6)   destination register (5..0)
    byte 2   ..(7..6)    source register 1 (5..0)
    byte 3   ..(7..6)    source register 2 (5..0)

- **Byte 1** holds the **destination register** in bits 5..0. The exception is an
  instruction with only one source register and no destination register, e.g. PUSH:
  there byte 1 holds that **source register**.
- **Bits 7..6 of byte 1** are more opcode bits ("opx"). An instruction of 2 to 4
  bytes is told apart by byte 0 bits 5..0 together with byte 1 bits 7..6: 256
  opcodes for each of these lengths.
- **Byte 2** holds **source register 1** in bits 5..0.
- **Byte 3** holds **source register 2** in bits 5..0.
- A register is the 6-bit selector described above.

Some instructions use **immediate values**; for them bytes 1 .. 3 can mean something
else (the immediate, or part of it). Their layouts are given with each opcode.

An immediate may use the whole of byte 1, bits 7..6 included: such an instruction
has no opx bits, and byte 0 alone is its opcode. LIT8, LIT16 and LIT24 (0x40, 0x80,
0xC0) are like that.

*Still open: bits 7..6 of bytes 2 and 3.*

### The status register ST

ST (special register 01010, selector 0x2A) holds the flags in its low four bits,
in the order CMP3 writes them, and shows the interrupt flag I in bit 4:

    bit 0 C    bit 1 Z    bit 2 N    bit 3 V    bit 4 I (read only)    bits 31..5: read as 0

I is changed only by CLI, SEI, RTI, POPF and a device's interrupt (see Interrupts and
exceptions): a write to ST leaves it as it is, so a handler that saves ST and puts it
back does not turn interrupts on early. PUSHF and POPF save and restore the whole of
ST, I with it (see PUSHF, POPF).

Any instruction that names a register can use it: `MOVR T, ST` reads the flags,
`MOVR ST, T` sets all four from T's bits 3..0 (the bits above are dropped),
`ORR ST, T` / `ANDR ST, T` set / clear flags, and a saved ST can be put back after an
interrupt or a call. When an instruction writes ST, that write sets the flags: it
wins over what the instruction's ALU op would set (`ADDR ST, T` leaves ST = ST + T,
not the flags of the add). Reading ST gives the flags as they were before the
instruction.

    MOVR T, ST      ; T = the flags
    LIT8 1
    ORR  ST, T      ; set C (SEC)
    LIT8 -2
    ANDR ST, T      ; clear C (CLC)

ST is a register of stage 3, so the limits of the others hold for it: in ADD2 ..
CMP3 at most one operand (source) of PSP, RSP, FP, TMPL, TMPH, ST, HLIM, VEC, PSPL,
PSPH, RSPL, RSPH.

## Opcodes

| opcode | length | mnemonic | operation |
|--------|--------|----------|-----------|
| 0x00   | 1      | NOP      | no operation |
| 0x01   | 1      | RET      | PC = R, pop the return stack into R |
| 0x02   | 1      | DUP      | push S onto the parameter stack, then S = T |
| 0x03   | 1      | DROP     | T = S, then pop the parameter stack into S |
| 0x04   | 1      | SWAP     | exchange S and T |
| 0x05   | 1      | OVER     | push S onto the parameter stack, then exchange S and T |
| 0x06   | 1      | DIP      | push S onto the parameter stack; S and T unchanged |
| 0x07   | 1      | NIP      | pop the parameter stack into S; T unchanged |
| 0x08   | 1      | TUCK     | push T onto the parameter stack; S and T unchanged |
| 0x09   | 1      | DRIP     | pop the parameter stack into T; S unchanged |
| 0x0A   | 1      | PUSH     | push R onto the return stack, R = T |
| 0x0B   | 1      | POP      | T = R, pop the return stack into R |
| 0x0C   | 1      | PUSHS    | push R onto the return stack, R = S |
| 0x0D   | 1      | POPS     | S = R, pop the return stack into R |
| 0x0E   | 1      | ROT      | ( a b c -- b c a ), two steps |
| 0x0F   | 1      | DROT     | ( a b c -- c a b ), Forth's -ROT, two steps |
| 0x10   | 1      | ADD      | T = S + T, pop the parameter stack into S; flags C Z N V |
| 0x11   | 1      | ADC      | T = S + T + C, pop the parameter stack into S; flags C Z N V |
| 0x12   | 1      | SUB      | T = S - T, pop the parameter stack into S; flags C Z N V (6502) |
| 0x13   | 1      | SBC      | T = S - T - (1 - C), pop the parameter stack into S; flags C Z N V (6502) |
| 0x14   | 1      | CSUB     | T = T - S if that needs no borrow, else T unchanged; flags C Z N V |
| 0x15   | 1      | DIVS     | one step of a 64 / 32 division on {C, T, TMPL} by S: subtract if it fits, then shift; flag C |
| 0x16   | 1      | MUL      | {S, T} = S * T, unsigned, 64 bits (S = high word, T = low word); flags Z N |
| 0x17   | 1      | SMUL     | {S, T} = S * T, signed, 64 bits (S = high word, T = low word); flags Z N |
| 0x18   | 1      | AND      | T = S & T, pop the parameter stack into S; flags C Z N V (V = bit 30) |
| 0x19   | 1      | OR       | T = S \| T, pop the parameter stack into S; flags C Z N V (V = bit 30) |
| 0x1A   | 1      | XOR      | T = S ^ T, pop the parameter stack into S; flags C Z N V (V = bit 30) |
| 0x1B   | 1      | INV      | T = ~T (invert all bits); flags Z N V (V = bit 30), C unchanged |
| 0x1C   | 1      | NEG      | T = 0 - T; flags C Z N V (6502) |
| 0x1D   | 1      | MULS     | one step of a 32 x 32 multiply on {T, TMPL} by S: add if TMPL[0], then shift right; no flags |
| 0x1E   | 1      | CMP      | flags of S - T as SUB (C Z N V, 6502); S, T and the stacks unchanged |
| 0x1F   | 1      | EXEC     | exchange R and PC: PC = R, R = the next instruction |
| 0x20   | 1      | ASL      | T = T << 1, bit 31 kept; flags C Z N V (V = 2* overflows) |
| 0x21   | 1      | ASR      | T = T >> 1, bit 31 kept; flags C Z N V (C = the bit out, V = 0) |
| 0x22   | 1      | LSL      | T = T << 1, 0 into bit 0; flags C Z N V (C = the bit out, V as ASL) |
| 0x23   | 1      | LSR      | T = T >> 1, 0 into bit 31; flags C Z N V (C = the bit out, V = 0) |
| 0x24   | 1      | ROL      | T rotated left by 1; flags C Z N V (C = the bit rotated, V = 0) |
| 0x25   | 1      | ROR      | T rotated right by 1; flags C Z N V (C = the bit rotated, V = 0) |
| 0x26   | 1      | ROLC     | T rotated left through C (33 bits); flags C Z N V (V = 0) |
| 0x27   | 1      | RORC     | T rotated right through C (33 bits); flags C Z N V (V = 0) |
| 0x28   | 1      | INC      | T = T + 1; flags C Z N V (as ADD) |
| 0x29   | 1      | DEC      | T = T - 1; flags C Z N V (as SUB, 6502: C = no borrow) |
| 0x2A   | 1      | INCW     | T = T + 4 (the next word); flags C Z N V (as ADD) |
| 0x2B   | 1      | DECW     | T = T - 4 (the word before); flags C Z N V (as SUB) |
| 0x2C   | 1      | CAR      | T = the word at T - 1 (the car of a cons: tag 01); no flags |
| 0x2D   | 1      | CDR      | T = the word at T + 3 (the cdr); no flags |
| 0x2E   | 1      | RPLACA   | the word at T - 1 = S (set the car); the stack unchanged |
| 0x2F   | 1      | RPLACD   | the word at T + 3 = S (set the cdr); the stack unchanged |
| 0x30   | 1      | LEAVE    | RSP = FP, then pop FP from the return stack (FP = R, R = pop); drops ENTER's frame |
| 0x31   | 1      | CONS     | ( car cdr -- cell ): a cell at L, L = L + 8, four steps; if L > HLIM: exception 4 (EXC 4 at the CONS: its handler returns to the CONS) |
| 0x32   | 1      | TADD     | as ADD; V also when S or T is not a fixnum (low bits not 00); flags C Z N V |
| 0x33   | 1      | TSUB     | as SUB; V also when S or T is not a fixnum; flags C Z N V |
| 0x34   | 1      | CLI      | I = 0: no interrupts from devices |
| 0x35   | 1      | SEI      | I = 1: interrupts from devices on |
| 0x36   | 1      | RTI      | the end of an interrupt handler: RET, and I = 1 |
| 0x37   | 1      | WAIT     | wait until a device asks for an interrupt (whatever I is), then go on; with I = 1 the interrupt is taken right after |
| 0x38   | 1      | PUSHF    | push R onto the return stack, R = ST (the flags and I) |
| 0x39   | 1      | POPF     | ST = R, the flags and I (bit 4); pop the return stack into R |
| 0x40   | 2      | LIT8     | T = an 8-bit signed constant (byte 1) |
| 0x41   | 2      | CJMPL    | if the condition (byte 1 bits 7..4) holds: PC[3:0] = byte 1 bits 3..0 (a jump within the line) |
| 0x42   | 2      | JSRS     | call: push R onto the return stack, R = the next instruction, jump to it + an 8-bit signed offset |
| 0x43   | 2      | MOVR     | copy T into a register (r0 .. r31, S, R, L, PSP, RSP, FP, PC, TMPL, TMPH, ST, HLIM, VEC), or a register into T |
| 0x44   | 2      | INCR     | byte 1 = 00 reg: reg = reg + 1; flags C Z N V |
| 0x44   | 2      | DECR     | byte 1 = 10 reg: reg = reg - 1; flags C Z N V (6502) |
| 0x44   | 2      | INCWR    | byte 1 = 01 reg: reg = reg + 4; flags C Z N V |
| 0x44   | 2      | DECWR    | byte 1 = 11 reg: reg = reg - 4; flags C Z N V (6502) |
| 0x45   | 2      | LITH     | T[31:24] = an 8-bit constant (byte 1); T[23:0], the stacks and the flags stay |
| 0x46   | 2      | ENTER    | push FP onto the return stack (push R, R = FP), FP = RSP, RSP = RSP - 4n (n words: byte 1, unsigned) |
| 0x47   | 2      | LSLI .. RORI | SHI: T shifted / rotated by a constant 0 .. 31 (byte 1: op in bits 7..5, count in 4..0); flags C Z N V |
| 0x49   | 2      | INTR     | interrupt n (byte 1, 0 .. 255): push R onto the return stack, R = the next instruction, jump to VEC + 4n |
| 0x4A   | 2      | EXC      | exception n (byte 1): push R onto the return stack, R = this instruction, jump to VEC + 4n |
| 0x4B   | 2      | SET      | byte 1 = cond (7..4), 0 (3..1), 0 (0): T = -1 if the condition holds, else 0; no flags |
| 0x4B   | 2      | SETB     | as SET with byte 1 bit 0 = 1: T = 1 if the condition holds, else 0 |
| 0x48   | 2      | UNEXT    | if R != 0: R = R - 1 and jump within the line (PC[3:0] = byte 1 bits 3..0); else drop R (pop the return stack into R); no flags |
| 0x50   | 2      | ADDR     | add T to a register, or a register to T (the register named as in MOVR); flags C Z N V |
| 0x51   | 2      | ADCR     | as ADDR, with the carry: + C; flags C Z N V |
| 0x52   | 2      | SUBR     | T = T - register, or register = register - T (as ADDR); flags C Z N V (6502) |
| 0x53   | 2      | SBCR     | as SUBR, with the borrow: - (1 - C); flags C Z N V (6502) |
| 0x54   | 2      | ANDR     | T = T & register, or register = register & T (as ADDR); flags Z N V (V = bit 30), C unchanged |
| 0x55   | 2      | ORR      | as ANDR, with \|; flags Z N V (V = bit 30), C unchanged |
| 0x56   | 2      | XORR     | as ANDR, with ^; flags Z N V (V = bit 30), C unchanged |
| 0x57   | 2      | CMPR     | flags of the destination - the other (T - register, or register - T) as SUB; nothing written |
| 0x80   | 3      | LIT16    | T = a 16-bit signed constant (bytes 1, 2) |
| 0x81   | 3      | CBR      | if the condition (byte 1 bits 7..4) holds: jump to the next instruction + a 12-bit signed offset |
| 0x82   | 3      | JSR      | call, as JSRS, with a 16-bit signed offset |
| 0x84   | 3      | LDR      | load: reg = memory at the address in a register; byte 1 bits 7..6 the size (LDRB 00, LDRH 01, LDR 10), byte 2 bit 7 signed (LDRSB, LDRSH); no flags |
| 0x85   | 3      | STR      | store: memory at the address in a register = reg; the size as LDR (STRB, STRH, STR); no flags |
| 0x83   | 3      | MOV2     | byte 1 bit 7 = 0: dst = src, any two registers; no flags |
| 0x83   | 3      | MOVI2    | byte 1 bit 7 = 1: dst = a signed 8-bit constant (byte 2); no flags |
| 0x86   | 3      | ENTER2   | ENTER with a 16-bit unsigned n words (bytes 1, 2) |
| 0x87   | 3      | TTAG     | Z = ((T & mask) == value), mask byte 1, value byte 2 (the low 8 bits of T); only Z changes |
| 0x88   | 3      | NEXT2    | if reg != 0 (byte 1): reg = reg - 1 and jump to the next instruction + an 8-bit signed offset (byte 2); else for R drop R; no flags |
| 0x89   | 3      | ABS      | byte 1 = 00 dst: dst = \|src\| (byte 2); flags Z N V (V: 0x8000_0000), C unchanged |
| 0x89   | 3      | CLZ      | byte 1 = 01 dst: dst = the number of leading 0 bits of src (32 for 0); flags Z N |
| 0x89   | 3      | PCNT     | byte 1 = 10 dst: dst = the number of 1 bits of src; flags Z N |
| 0x8A   | 3      | ADDI2    | byte 1 = 00 reg: reg = reg + a signed 8-bit constant (byte 2); flags C Z N V |
| 0x8A   | 3      | CMPI2    | byte 1 = 01 reg: the flags of reg - the constant, as CMP; nothing written |
| 0x8B   | 3      | SET2     | byte 1 = 00 reg, byte 2 = cond (7..4), 0 (3..1), 0 (0): reg = -1 if the condition holds, else 0 (TZ: reg == 0); no flags |
| 0x8B   | 3      | SETB2    | as SET2 with byte 2 bit 0 = 1: reg = 1 or 0 |
| 0x90   | 3      | ADD2     | dst = dst + src: any two registers (byte 1 the destination and source 1, byte 2 source 2); flags C Z N V |
| 0x91   | 3      | ADC2     | dst = dst + src + C, as ADD2; flags C Z N V |
| 0x92   | 3      | SUB2     | dst = dst - src, as ADD2; flags C Z N V (6502) |
| 0x93   | 3      | SBC2     | dst = dst - src - (1 - C), as ADD2; flags C Z N V (6502) |
| 0x94   | 3      | AND2     | dst = dst & src, as ADD2; flags Z N V (V = bit 30), C unchanged |
| 0x95   | 3      | OR2      | dst = dst \| src, as ADD2; flags Z N V (V = bit 30), C unchanged |
| 0x96   | 3      | XOR2     | dst = dst ^ src, as ADD2; flags Z N V (V = bit 30), C unchanged |
| 0x97   | 3      | CMP2     | flags of dst - src as SUB; nothing written |
| 0x98   | 3      | LSL2     | dst = dst << src[4:0] (byte 1 dst, byte 2 src: r0 .. r31, T, S, R, L); flags as LSLI |
| 0x99   | 3      | LSR2     | dst = dst >> src[4:0], 0s in; flags as LSRI |
| 0x9A   | 3      | ASR2     | dst = dst >> src[4:0], the sign kept; flags as ASRI |
| 0x9B   | 3      | ROL2     | dst rotated left by src[4:0]; flags as ROLI |
| 0x9C   | 3      | ROR2     | dst rotated right by src[4:0]; flags as RORI |
| 0xA0   | 3      | MIN2     | dst = the smaller of dst, src (signed); flags Z N |
| 0xA1   | 3      | MAX2     | dst = the larger of dst, src (signed); flags Z N |
| 0xA2   | 3      | MINU2    | dst = the smaller of dst, src (unsigned); flags Z N |
| 0xA3   | 3      | MAXU2    | dst = the larger of dst, src (unsigned); flags Z N |
| 0xC0   | 4      | LIT24    | T = a 24-bit signed constant (bytes 1 .. 3) |
| 0xC1   | 4      | CBRL     | if the condition (byte 1 bits 7..4) holds: jump to the next instruction + a 20-bit signed offset |
| 0xC2   | 4      | JSRL     | call, as JSRS, with a 24-bit signed offset |
| 0xC4   | 4      | LDR3     | load from base + offset (byte 3: an offset register, or with byte 2 bit 6 a signed 8-bit offset); sizes and signed as LDR (LDRB3, LDRSB3, LDRH3, LDRSH3, LDR3); no flags |
| 0xC5   | 4      | STR3     | store to base + offset, as LDR3 (STRB3, STRH3, STR3); no flags |
| 0xC6   | 4      | ENTER3   | ENTER with a 24-bit unsigned n words (bytes 1 .. 3) |
| 0xC8   | 4      | NEXT3    | NEXT2 with a 16-bit signed offset (bytes 2, 3) |
| 0xD0   | 4      | ADD3     | dst = src1 + src2: any three registers (byte 1 the destination, byte 2 source 1, byte 3 source 2); flags C Z N V |
| 0xD1   | 4      | ADC3     | dst = src1 + src2 + C, as ADD3; flags C Z N V |
| 0xD2   | 4      | SUB3     | dst = src1 - src2, as ADD3; flags C Z N V (6502) |
| 0xD3   | 4      | SBC3     | dst = src1 - src2 - (1 - C), as ADD3; flags C Z N V (6502) |
| 0xD4   | 4      | AND3     | dst = src1 & src2, as ADD3; flags Z N V (V = bit 30), C unchanged |
| 0xD5   | 4      | OR3      | dst = src1 \| src2, as ADD3; flags Z N V (V = bit 30), C unchanged |
| 0xD6   | 4      | XOR3     | dst = src1 ^ src2, as ADD3; flags Z N V (V = bit 30), C unchanged |
| 0xD7   | 4      | CMP3     | flags of src1 - src2 as SUB, and dst = those flags {V, N, Z, C} (bits 3..0, 0 above) |
| 0xD8   | 4      | LSL3     | dst = src1 << src2[4:0] (byte 1 dst, byte 2 src1, byte 3 src2: r0 .. r31, T, S, R, L); flags as LSLI |
| 0xD9   | 4      | LSR3     | dst = src1 >> src2[4:0], 0s in |
| 0xDA   | 4      | ASR3     | dst = src1 >> src2[4:0], the sign kept |
| 0xDB   | 4      | ROL3     | dst = src1 rotated left by src2[4:0] |
| 0xDC   | 4      | ROR3     | dst = src1 rotated right by src2[4:0] |
| 0xE0   | 4      | MIN3     | dst = the smaller of src1, src2 (signed); flags Z N |
| 0xE1   | 4      | MAX3     | dst = the larger of src1, src2 (signed); flags Z N |
| 0xE2   | 4      | MINU3    | dst = the smaller of src1, src2 (unsigned); flags Z N |
| 0xE3   | 4      | MAXU3    | dst = the larger of src1, src2 (unsigned); flags Z N |

### DUP (0x02)

    byte 0   0x02           no operands

Duplicates the top of the parameter stack: T is the top, S the second, the rest is
in memory at the parameter stack.

    mem[PSP] = S        the store: PSP points to the next free word
    PSP = PSP - 4       post-decrement
    S = T               T stays as it is

    before:  ... x   S=a  T=b
    after:   ... x a S=b  T=b

Through the pipeline it is one store that also writes a register:

| stage           | what DUP does |
|-----------------|---------------|
| 2 decode        | reads S on port A and T on port B |
| 3 execute       | `stackregs`: `sel` = PSP, `op` = PUSH: the address is PSP, PSP - 4 at the edge; `x_store` = 1, `x_size` = word, `x_wdata` = S; `x_wen` = 1, `x_rd` = S (`100001`), `x_result` = T |
| 4 memory access | stores S at the old PSP; passes T on (`m_data` = `x_result`) |
| 5 writeback     | writes T into S |

An instruction right after DUP that reads S gets the new S by forwarding
(`stage3/forward.v`): S is only written in stage 5.

### DROP (0x03)

    byte 0   0x03           no operands

Drops the top of the parameter stack: S moves up into T, and the word on top of the
stack in memory comes up into S.

    T = S
    PSP = PSP + 4       pre-increment: PSP points to the next free word
    S = mem[PSP]        the load

    before:  ... x a S=b  T=c
    after:   ... x   S=a  T=b

DROP writes two registers: S on the main write port W, T on the second write port
W2 (special registers only). Through the pipeline it is one load with a second
write:

| stage           | what DROP does |
|-----------------|----------------|
| 2 decode        | reads S on port A |
| 3 execute       | `stackregs`: `sel` = PSP, `op` = POP: the address is PSP + 4, PSP + 4 at the edge; `x_load` = 1, `x_size` = word; `x_wen` = 1, `x_rd` = S (`100001`); `x2_wen` = 1, `x2_sel` = T (`00`), `x2_data` = S |
| 4 memory access | loads the word into `m_data`; passes `x2_*` on as `m2_*` |
| 5 writeback     | writes the word into S (W) and the old S into T (W2) |

An instruction right after DROP that reads S waits a tick (load-use) and then gets
it by forwarding; one that reads T gets it by forwarding at once.

### SWAP (0x04)

    byte 0   0x04           no operands

Exchanges the two top entries of the parameter stack. The stack in memory and PSP
do not change.

    T = old S
    S = old T

    before:  ... x  S=a  T=b
    after:   ... x  S=b  T=a

Through the pipeline it is one instruction with two register writes and no memory
access:

| stage           | what SWAP does |
|-----------------|----------------|
| 2 decode        | reads S on port A and T on port B |
| 3 execute       | `x_wen` = 1, `x_rd` = T (`100000`), `x_result` = S; `x2_wen` = 1, `x2_sel` = S (`01`), `x2_data` = T; no load or store |
| 4 memory access | passes both writes on |
| 5 writeback     | writes the old S into T (W) and the old T into S (W2) |

Both new values are forwarded, so the next instruction can use T and S at once, with
no wait.

### OVER (0x05)

    byte 0   0x05           no operands

Copies the second entry of the parameter stack over the top: ( a b -- a b a ).

    mem[PSP] = S        the store: PSP points to the next free word
    PSP = PSP - 4       post-decrement
    T = old S
    S = old T

    before:  ... x    S=a  T=b
    after:   ... x a  S=b  T=a

Through the pipeline it is one store with two register writes:

| stage           | what OVER does |
|-----------------|----------------|
| 2 decode        | reads S on port A and T on port B |
| 3 execute       | `stackregs`: `sel` = PSP, `op` = PUSH: the address is PSP, PSP - 4 at the edge; `x_store` = 1, `x_size` = word, `x_wdata` = S; `x_wen` = 1, `x_rd` = T (`100000`), `x_result` = S; `x2_wen` = 1, `x2_sel` = S (`01`), `x2_data` = T |
| 4 memory access | stores S at the old PSP; passes both writes on |
| 5 writeback     | writes the old S into T (W) and the old T into S (W2) |

Both new values are forwarded, so the next instruction can use T and S at once, with
no wait.

### DIP (0x06)

    byte 0   0x06           no operands

Pushes a copy of S onto the parameter stack: ( a b -- a a b ). S and T keep their
values.

    mem[PSP] = S        the store: PSP points to the next free word
    PSP = PSP - 4       post-decrement

    before:  ... x    S=a  T=b
    after:   ... x a  S=a  T=b

Through the pipeline it is a plain store, with no register write:

| stage           | what DIP does |
|-----------------|---------------|
| 2 decode        | reads S on port A |
| 3 execute       | `stackregs`: `sel` = PSP, `op` = PUSH: the address is PSP, PSP - 4 at the edge; `x_store` = 1, `x_size` = word, `x_wdata` = S; `x_wen` = 0, `x2_wen` = 0 |
| 4 memory access | stores S at the old PSP |
| 5 writeback     | nothing |

### NIP (0x07)

    byte 0   0x07           no operands

Drops the second entry of the parameter stack: ( a b c -- a c ). The word on top of
the stack in memory comes up into S; T keeps its value.

    PSP = PSP + 4       pre-increment: PSP points to the next free word
    S = mem[PSP]        the load

    before:  ... x a  S=b  T=c
    after:   ... x    S=a  T=c

Through the pipeline it is one load into S:

| stage           | what NIP does |
|-----------------|---------------|
| 2 decode        | reads nothing |
| 3 execute       | `stackregs`: `sel` = PSP, `op` = POP: the address is PSP + 4, PSP + 4 at the edge; `x_load` = 1, `x_size` = word; `x_wen` = 1, `x_rd` = S (`100001`); `x2_wen` = 0 |
| 4 memory access | loads the word into `m_data` |
| 5 writeback     | writes the word into S (W) |

An instruction right after NIP that reads S waits a tick (load-use) and then gets it
by forwarding.

### TUCK (0x08)

    byte 0   0x08           no operands

Puts a copy of the top under the second entry: ( a b -- b a b ). T is pushed onto
the parameter stack in memory; S and T keep their values.

    mem[PSP] = T        the store: PSP points to the next free word
    PSP = PSP - 4       post-decrement

    before:  ... x    S=a  T=b
    after:   ... x b  S=a  T=b

Through the pipeline it is a plain store, with no register write:

| stage           | what TUCK does |
|-----------------|----------------|
| 2 decode        | reads T on port B |
| 3 execute       | `stackregs`: `sel` = PSP, `op` = PUSH: the address is PSP, PSP - 4 at the edge; `x_store` = 1, `x_size` = word, `x_wdata` = T; `x_wen` = 0, `x2_wen` = 0 |
| 4 memory access | stores T at the old PSP |
| 5 writeback     | nothing |

### DRIP (0x09)

    byte 0   0x09           no operands

The opposite of TUCK: the word on top of the stack in memory comes up into T
(the old T is lost); S keeps its value.

    PSP = PSP + 4       pre-increment: PSP points to the next free word
    T = mem[PSP]        the load

    before:  ... x a  S=b  T=c
    after:   ... x    S=b  T=a

Through the pipeline it is one load into T:

| stage           | what DRIP does |
|-----------------|----------------|
| 2 decode        | reads nothing |
| 3 execute       | `stackregs`: `sel` = PSP, `op` = POP: the address is PSP + 4, PSP + 4 at the edge; `x_load` = 1, `x_size` = word; `x_wen` = 1, `x_rd` = T (`100000`); `x2_wen` = 0 |
| 4 memory access | loads the word into `m_data` |
| 5 writeback     | writes the word into T (W) |

An instruction right after DRIP that reads T waits a tick (load-use) and then gets
it by forwarding.

### PUSH (0x0A)

    byte 0   0x0A           no operands

Copies T to the return stack. R is the top of the return stack, the rest of it is in
memory at RSP. T and S keep their values.

    mem[RSP] = R        push R onto the return stack
    RSP = RSP - 4
    R = T

    before:  pstack ... x  S=a  T=b     rstack ... y    R=d
    after:   pstack ... x  S=a  T=b     rstack ... y d  R=b

Forth's `>R` is **PUSH DROP**: PUSH copies T to the return stack, DROP removes it
from the parameter stack.

    >R:      pstack ... x a  S=b  T=c   rstack ... y    R=d
    PUSH     pstack ... x a  S=b  T=c   rstack ... y d  R=c
    DROP     pstack ... x    S=a  T=b   rstack ... y d  R=c

Through the pipeline it is a store with one register write, like DUP on the return
stack:

| stage           | what PUSH does |
|-----------------|----------------|
| 2 decode        | reads R on port A and T on port B |
| 3 execute       | `stackregs`: `sel` = RSP, `op` = PUSH: the address is RSP, RSP - 4 at the edge; `x_store` = 1, `x_size` = word, `x_wdata` = R; `x_wen` = 1, `x_rd` = R (`100010`), `x_result` = T; `x2_wen` = 0 |
| 4 memory access | stores R at the old RSP |
| 5 writeback     | writes the old T into R (W) |

### POP (0x0B)

    byte 0   0x0B           no operands

Moves the top of the return stack into T (the old T is lost); the word on top of
the return stack in memory comes up into R. S keeps its value.

    T = R
    RSP = RSP + 4       pop the return stack into R
    R = mem[RSP]

    before:  pstack ... x  S=a  T=b     rstack ... y d  R=c
    after:   pstack ... x  S=a  T=c     rstack ... y    R=d

Forth's `R>` is **DUP POP**: DUP makes room on the parameter stack, POP moves R
into it.

    R>:      pstack ... x    S=a  T=b   rstack ... y d  R=c
    DUP      pstack ... x a  S=b  T=b   rstack ... y d  R=c
    POP      pstack ... x a  S=b  T=c   rstack ... y    R=d

Through the pipeline it is a load with a second write, like DROP on the return
stack:

| stage           | what POP does |
|-----------------|---------------|
| 2 decode        | reads R on port A |
| 3 execute       | `stackregs`: `sel` = RSP, `op` = POP: the address is RSP + 4, RSP + 4 at the edge; `x_load` = 1, `x_size` = word; `x_wen` = 1, `x_rd` = R (`100010`); `x2_wen` = 1, `x2_sel` = T (`00`), `x2_data` = R |
| 4 memory access | loads the word into `m_data` |
| 5 writeback     | writes the word into R (W) and the old R into T (W2) |

An instruction right after POP that reads R waits a tick (load-use); T comes by
forwarding at once.

### PUSHS (0x0C)

    byte 0   0x0C           no operands

PUSH for S: copies S to the return stack. T and S keep their values.

    mem[RSP] = R        push R onto the return stack
    RSP = RSP - 4
    R = S

    before:  pstack ... x  S=a  T=b     rstack ... y    R=d
    after:   pstack ... x  S=a  T=b     rstack ... y d  R=a

| stage           | what PUSHS does |
|-----------------|-----------------|
| 2 decode        | reads R on port A and S on port B |
| 3 execute       | `stackregs`: `sel` = RSP, `op` = PUSH: the address is RSP, RSP - 4 at the edge; `x_store` = 1, `x_size` = word, `x_wdata` = R; `x_wen` = 1, `x_rd` = R (`100010`), `x_result` = S; `x2_wen` = 0 |
| 4 memory access | stores R at the old RSP |
| 5 writeback     | writes the old S into R (W) |

### POPS (0x0D)

    byte 0   0x0D           no operands

POP for S: moves the top of the return stack into S (the old S is lost); the word
on top of the return stack in memory comes up into R. T keeps its value.

    S = R
    RSP = RSP + 4       pop the return stack into R
    R = mem[RSP]

    before:  pstack ... x  S=a  T=b     rstack ... y d  R=c
    after:   pstack ... x  S=c  T=b     rstack ... y    R=d

| stage           | what POPS does |
|-----------------|----------------|
| 2 decode        | reads R on port A |
| 3 execute       | `stackregs`: `sel` = RSP, `op` = POP: the address is RSP + 4, RSP + 4 at the edge; `x_load` = 1, `x_size` = word; `x_wen` = 1, `x_rd` = R (`100010`); `x2_wen` = 1, `x2_sel` = S (`01`), `x2_data` = R |
| 4 memory access | loads the word into `m_data` |
| 5 writeback     | writes the word into R (W) and the old R into S (W2) |

An instruction right after POPS that reads R waits a tick (load-use); S comes by
forwarding at once.

### ROT (0x0E)

    byte 0   0x0E           no operands

Rotates the third entry of the parameter stack to the top: ( a b c -- b c a ).

    before:  ... x a  S=b  T=c
    after:   ... x b  S=c  T=a

ROT needs a load and a store (a comes out of memory, b goes in) and a third place
for a value in between, so decode issues it as **two steps**, one after the other
(`stage2/sequencer.v`). The internal scratch register **TMP** carries c from the
first step to the second. TMP is not visible: no instruction can name it.

| step | what it does |
|------|--------------|
| 0    | `TMP = T`, `PSP = PSP + 4`, `T = mem[PSP]` |
| 1    | `mem[PSP] = S`, `PSP = PSP - 4`, `S = TMP` |

    step 0   ... x    S=b  T=a     TMP=c
    step 1   ... x b  S=c  T=a

| stage           | step 0 | step 1 |
|-----------------|--------|--------|
| 2 decode        | reads T on port B | reads S on port A |
| 3 execute       | `TMP` = T; `stackregs`: `sel` = PSP, `op` = POP; `x_load` = 1, `x_size` = word; `x_wen` = 1, `x_rd` = T (`100000`) | `stackregs`: `sel` = PSP, `op` = PUSH; `x_store` = 1, `x_size` = word, `x_wdata` = S; `x_wen` = 1, `x_rd` = S (`100001`), `x_result` = TMP |
| 4 memory access | loads the word | stores S at the old PSP |
| 5 writeback     | writes the word into T (W) | writes TMP's value into S (W) |

Step 1 does not read T, so it never waits for step 0's load: ROT takes 2 ticks.
Nothing can come between the two steps, not even an interrupt (the sequencer holds
fetch), so TMP never needs saving.

### DROT (0x0F)

    byte 0   0x0F           no operands

Forth's `-ROT` (the name keeps special characters out of mnemonics): rotates the
top of the parameter stack down to the third place: ( a b c -- c a b ).

    before:  ... x a  S=b  T=c
    after:   ... x c  S=a  T=b

Two steps, like ROT, with TMP carrying b:

| step | what it does |
|------|--------------|
| 0    | `TMP = S`, `PSP = PSP + 4`, `S = mem[PSP]` |
| 1    | `mem[PSP] = T`, `PSP = PSP - 4`, `T = TMP` |

    step 0   ... x    S=a  T=c     TMP=b
    step 1   ... x c  S=a  T=b

| stage           | step 0 | step 1 |
|-----------------|--------|--------|
| 2 decode        | reads S on port A | reads T on port B |
| 3 execute       | `TMP` = S; `stackregs`: `sel` = PSP, `op` = POP; `x_load` = 1, `x_size` = word; `x_wen` = 1, `x_rd` = S (`100001`) | `stackregs`: `sel` = PSP, `op` = PUSH; `x_store` = 1, `x_size` = word, `x_wdata` = T; `x_wen` = 1, `x_rd` = T (`100000`), `x_result` = TMP |
| 4 memory access | loads the word | stores T at the old PSP |
| 5 writeback     | writes the word into S (W) | writes TMP's value into T (W) |

Step 1 does not read S, so it never waits for step 0's load: DROT takes 2 ticks.

### LIT8 (0x40), LIT16 (0x80), LIT24 (0xC0)

    LIT8    byte 0   0x40
            byte 1   n, 8 bits                    -0x80     .. 0x7F
    LIT16   byte 0   0x80
            byte 1   n bits 7..0
            byte 2   n bits 15..8                 -0x8000   .. 0x7FFF
    LIT24   byte 0   0xC0
            byte 1   n bits 7..0
            byte 2   n bits 15..8
            byte 3   n bits 23..16                -0x800000 .. 0x7FFFFF

Write a signed constant into T: ( x -- n ). The old T is lost; S and the stack in
memory do not change. The constant is little-endian in the bytes after the opcode,
like everything else, and sign-extended to 32 bits. These opcodes have no opx bits:
byte 1 is all constant.

    T = n

    before:  ... x  S=a  T=b
    after:   ... x  S=a  T=n

To push a constant (Forth's literal, ( -- n )), a DUP goes first: **DUP LIT**.

    DUP LIT n:  ... x    S=a  T=b
    DUP         ... x a  S=b  T=b
    LIT n       ... x a  S=b  T=n

| stage           | what LIT does |
|-----------------|---------------|
| 2 decode        | makes the constant: sign-extends it to 32 bits and passes it on port A, as a value, as if it came from a register, with `d_a_use` = 0 |
| 3 execute       | `x_wen` = 1, `x_rd` = T (`100000`), `x_result` = operand A; no load or store |
| 4 memory access | passes the write on |
| 5 writeback     | writes n into T (W) |

`d_a_use` = 0 says that operand A does not come from a register: forwarding leaves
the value alone. So a constant needs no path of its own between decode and execute.
The new T is forwarded, so the next instruction can use it at once.

There is no LIT for a 32-bit constant: an instruction is at most 4 bytes, and LIT24
already uses all of them. LIT24 followed by LITH loads any 32-bit constant in 6 bytes
(see LITH).

The line rule applies: bytes past the end of a 16-byte line are read as 0, so a LIT
may only cross the end of a line if the bytes it puts into the next line are 0
(e.g. LIT16 5 at offset 14: its byte 2 is 0x00). Otherwise the assembler pads with
NOPs, or picks a shorter LIT when the constant fits.

### ADD (0x10)

    byte 0   0x10           no operands

Forth's `+`: ( a b -- a+b ). The carry in is 0. Sets all four flags (as ADC).

    T = S + T           ALU op ADD, carry in 0
    PSP = PSP + 4       pop the parameter stack into S
    S = mem[PSP]

    before:  ... x a  S=b  T=c
    after:   ... x    S=a  T=b+c

    flags:   C = the carry out of bit 31
             Z = (T == 0)
             N = bit 31 of T
             V = signed overflow

Through the pipeline it is DROP with the ALU's sum on the second write:

| stage           | what ADD does |
|-----------------|---------------|
| 2 decode        | reads S on port A and T on port B |
| 3 execute       | ALU: `op` = ADD, `a` = S, `b` = T, `cin` = 0; flags mask = 1111 (C Z N V); `stackregs`: `sel` = PSP, `op` = POP: the address is PSP + 4, PSP + 4 at the edge; `x_load` = 1, `x_size` = word; `x_wen` = 1, `x_rd` = S (`100001`); `x2_wen` = 1, `x2_sel` = T (`00`), `x2_data` = ALU `y` |
| 4 memory access | loads the word into `m_data`; passes the sum on |
| 5 writeback     | writes the word into S (W) and the sum into T (W2) |

The flags are written as ADD leaves execute, so the next instruction sees them at
once. The new T is forwarded at once; an instruction right after ADD that reads S
waits a tick (load-use), as after DROP.

### ADC (0x11)

    byte 0   0x11           no operands

ADD with the carry: ( a b -- a+b+C ). The carry in is the C flag, so a sum wider
than 32 bits can be added a word at a time, ADD for the lowest word, ADC for the
others. Sets all four flags.

    T = S + T + C       ALU op ADC, carry in = C
    PSP = PSP + 4       pop the parameter stack into S
    S = mem[PSP]

    before:  ... x a  S=b  T=c
    after:   ... x    S=a  T=b+c+C

    flags:   C = the carry out of bit 31
             Z = (T == 0)
             N = bit 31 of T
             V = signed overflow

Through the pipeline it is ADD with ALU `op` = ADC and `cin` = the C flag; all the
rest is the same (flags mask 1111). The C flag is read in execute, where the flags
live, so an ADC right after an ADD or ADC gets the new C at once.

### SUB (0x12)

    byte 0   0x12           no operands

Forth's `-`: ( a b -- a-b ), the second entry minus the top. Done as on the 6502,
by adding the inverted T with carry in 1. Sets all four flags as the 6502 does.

    T = S + ~T + 1      = S - T; ALU op SUB, carry in = 1
    PSP = PSP + 4       pop the parameter stack into S
    S = mem[PSP]

    before:  ... x a  S=b  T=c
    after:   ... x    S=a  T=b-c

    flags:   C = the carry out of bit 31: 1 = no borrow (S >= T, unsigned),
                 0 = borrow (S < T)
             Z = (T == 0), i.e. S == T
             N = bit 31 of T
             V = signed overflow: S and T have different signs and the sign of
                 the result differs from the sign of S

Through the pipeline it is ADD with ALU `op` = SUB (`a` = S, `b` = T; the ALU makes
the carry in 1 itself for SUB); all the rest is the same (flags mask 1111).

After a SUB, the flags compare S with T as on the 6502: unsigned S >= T is C = 1,
S == T is Z = 1, signed S < T is N != V.

### SBC (0x13)

    byte 0   0x13           no operands

SUB with the carry, as the 6502's SBC: ( a b -- a-b-(1-C) ). The carry in is the C
flag, which here means "no borrow": C = 1 subtracts nothing more, C = 0 subtracts
one more. So a difference wider than 32 bits can be taken a word at a time, SUB for
the lowest word, SBC for the others. Sets all four flags as the 6502 does.

    T = S + ~T + C      = S - T - (1 - C); ALU op SBC, carry in = C
    PSP = PSP + 4       pop the parameter stack into S
    S = mem[PSP]

    before:  ... x a  S=b  T=c
    after:   ... x    S=a  T=b-c-(1-C)

    flags:   C = the carry out of bit 31: 1 = no borrow, 0 = borrow
             Z = (T == 0)
             N = bit 31 of T
             V = signed overflow, as SUB

Through the pipeline it is ADD with ALU `op` = SBC and `cin` = the C flag; all the
rest is the same (flags mask 1111). The C flag is read in execute, where the flags
live, so an SBC right after a SUB or SBC gets the new C at once.

### CSUB (0x14)

    byte 0   0x14           no operands

Conditional subtract, the step of a division: subtract S from T when it fits (no
borrow), otherwise leave T alone. S and the stack in memory do not change.

    d = T + ~S + 1      = T - S; ALU op CSUB, carry in 1
    if the carry of d is 1 (no borrow, T >= S unsigned):  T = d
    else:                                                  T unchanged

    before:  ... x  S=a  T=b
    after:   ... x  S=a  T=b-a   if b >= a (unsigned)
             ... x  S=a  T=b     if b <  a

    flags:   C = 1 if the subtraction was taken, 0 if not
             Z = (T == 0), the new T
             N = bit 31 of the new T
             V = signed overflow of the subtraction when taken, 0 when not

| stage           | what CSUB does |
|-----------------|----------------|
| 2 decode        | reads T on port A and S on port B |
| 3 execute       | ALU: `op` = CSUB, `a` = T, `b` = S (the ALU makes the carry in 1 itself); flags mask = 1111; `x_wen` = 1, `x_rd` = T (`100000`), `x_result` = ALU `y`; no load or store |
| 4 memory access | passes the write on |
| 5 writeback     | writes the new T (W) |

C is the quotient bit: in a division loop the 64-bit value {TMPH, TMPL} = {remainder,
dividend} is shifted left through the carry (ROL64), so the quotient bits come in at
the bottom while the dividend goes out at the top, and CSUB takes the divisor off
the remainder whenever it fits. (Shifted this way, the divisor must be below 2^31.)

### DIVS (0x15)

    byte 0   0x15           no operands

One step of an unsigned 64 / 32 division: first the conditional subtract, then the
shift (as everywhere, the shift comes after the arithmetic). S is the divisor, T the
remainder so far, TMPL the rest of the dividend; C holds the bit the shift before
pushed out of T, so the remainder has 33 bits and nothing is lost. The quotient bits
come into TMPL from the bottom as the dividend goes out at the top. S and the stack
in memory do not change.

    r    = {C, T}                   33 bits
    q    = (r >= S)                 the divisor fits
    d    = q ? r - S : r            (always below S: 32 bits)
    {C, T, TMPL} = {d, TMPL, q} shifted left by one:
        C    = d[31]                the bit shifted out
        T    = {d[30:0], TMPL[31]}
        TMPL = {TMPL[30:0], q}      the quotient bit in at the bottom

    flags:   C = the bit shifted out of T (only C is changed)

A whole division: T = the high word of the dividend (it must be below S, or the
quotient does not fit in 32 bits: check it with a SUB or CSUB first), TMPL = the low
word, C = 0, S = the divisor, then **33** DIVS. The first step never subtracts (the
high word is below S): it only does the first shift. After the last step, its shift
has moved the remainder one bit up:

    before:  S = d   C = 0   T = hi   TMPL = lo
    33 DIVS
    after:   TMPL = {hi, lo} / d                       the quotient
             {C, T} >> 1 = {hi, lo} mod d              the remainder (T bit 0 is 0)

Any 32-bit divisor works. If only the quotient is needed, nothing more is to do; for
the remainder, {C, T} is shifted right by one (an opcode for that is still open).

| stage           | what DIVS does |
|-----------------|----------------|
| 2 decode        | reads T on port A and S on port B |
| 3 execute       | ALU: `op` = DIVS, `a` = T, `b` = S, `cin` = the C flag; flags mask = 0001 (C); `tmplh`: `sh_l` = 1, `sh_bit` = the ALU's `y2[0]` (the quotient bit); `x_wen` = 1, `x_rd` = T (`100000`), `x_result` = ALU `y` with TMPL[31] in bit 0; no load or store |
| 4 memory access | passes the write on |
| 5 writeback     | writes the new T (W) |

TMPL and C change in execute, so the next DIVS sees them at once, and the new T is
forwarded: the 33 steps take 33 ticks.

### MUL (0x16)

    byte 0   0x16           no operands

Unsigned 32 x 32 multiply with the full 64-bit product: the high word goes into S
and the low word into T. The stack in memory does not change. (Forth's UM* leaves
the high word on top: MUL SWAP.)

    {S, T} = S * T      64 bits: S = the high word, T = the low word

    before:  ... x  S=a  T=b
    after:   ... x  S=hi(a*b)  T=lo(a*b)

    flags:   Z = the 64-bit product is 0
             N = bit 63 of the product
             C, V unchanged

It uses the on-chip multiplier: one MULT36X36 of the GW2AR (`stage3/mul.v`), with its
registers bypassed, so the product is ready in the same tick.

| stage           | what MUL does |
|-----------------|---------------|
| 2 decode        | reads S on port A and T on port B |
| 3 execute       | ALU: `op` = MUL, `a` = S, `b` = T; flags mask = 0110 (Z N); `x_wen` = 1, `x_rd` = T (`100000`), `x_result` = ALU `y` (the low word); `x2_wen` = 1, `x2_sel` = S (`01`), `x2_data` = ALU `y2` (the high word); no load or store |
| 4 memory access | passes both writes on |
| 5 writeback     | writes the low word into T (W) and the high word into S (W2) |

Both new values are forwarded, so the next instruction can use them at once.

### SMUL (0x17)

    byte 0   0x17           no operands

MUL for signed (two's complement) numbers: the 64-bit signed product, high word in
S, low word in T. Everything else is as MUL: same flags (Z, N of the 64-bit
product; C, V unchanged), same multiplier (`mul.v` with `sgn` = 1), same pipeline
(ALU `op` = SMUL). The low word is the same as MUL's; only the high word differs.

    {S, T} = S * T      signed, 64 bits

    before:  ... x  S=a  T=b
    after:   ... x  S=hi(a*b)  T=lo(a*b)

(Forth's M* leaves the high word on top: SMUL SWAP.)

### AND (0x18), OR (0x19), XOR (0x1A)

    byte 0   0x18 / 0x19 / 0x1A     no operands

Bitwise AND, OR, exclusive OR, as Forth's AND, OR, XOR: ( a b -- a&b ), ( a b -- a|b ),
( a b -- a^b ).

    T = S & T  /  S | T  /  S ^ T       ALU op AND / OR / XOR
    PSP = PSP + 4                        pop the parameter stack into S
    S = mem[PSP]

    before:  ... x a  S=b  T=c
    after:   ... x    S=a  T=b&c   (b|c, b^c)

    flags:   C = unchanged (the ALU gives the carry in; carry in = the C flag)
             Z = (T == 0)
             N = bit 31 of T
             V = bit 30 of T            (as the 6502's BIT puts bit 6 into V)

Through the pipeline they are ADD with ALU `op` = AND / OR / XOR and `cin` = the C
flag; all the rest is the same (flags mask 1111).

### ASL (0x20)

    byte 0   0x20           no operands

Arithmetic shift left: 2* for signed numbers, the sign bit stays. Only T changes.

    T = {T[31], T[29:0], 0}             ALU op ASL

    before:  ... x  S=a  T=b
    after:   ... x  S=a  T=2*b   (bit 31 as before)

    flags:   C = T[30], the bit pushed out (the one before the shift)
             Z = (T == 0), the new T
             N = bit 31 of T (unchanged by the shift)
             V = 1 if 2*T would overflow (signed): T[31] != T[30] before the shift

| stage           | what ASL does |
|-----------------|---------------|
| 2 decode        | reads T on port A |
| 3 execute       | ALU: `op` = ASL, `a` = T; flags mask = 1111; `x_wen` = 1, `x_rd` = T (`100000`), `x_result` = ALU `y`; no load or store |
| 4 memory access | passes the write on |
| 5 writeback     | writes the new T (W) |

When V = 0 the result is exactly 2*T. When V = 1 it is not (2*T does not fit in 32
bits); the sign is kept anyway.

### ASR (0x21)

    byte 0   0x21           no operands

Arithmetic shift right: 2/ for signed numbers (rounding down), the sign bit stays.
Only T changes.

    T = {T[31], T[31:1]}                ALU op ASR, by 1

    before:  ... x  S=a  T=b
    after:   ... x  S=a  T=b>>1   (bit 31 as before)

    flags:   C = T[0], the bit shifted out (the one before the shift)
             Z = (T == 0), the new T
             N = bit 31 of T (unchanged by the shift)
             V = 0

| stage           | what ASR does |
|-----------------|---------------|
| 2 decode        | reads T on port A; passes the constant 1 on port B (`d_b_use` = 0) |
| 3 execute       | ALU: `op` = ASR, `a` = T, `b` = 1; flags mask = 1111; `x_wen` = 1, `x_rd` = T (`100000`), `x_result` = ALU `y`; no load or store |
| 4 memory access | passes the write on |
| 5 writeback     | writes the new T (W) |

The ALU's ASR shifts by `b[4:0]`; decode makes the shift amount 1 a constant on port
B, as LIT does with its constant, so ASR needs nothing new in the ALU.

### LSL (0x22)

    byte 0   0x22           no operands

Logical shift left by one: all 32 bits move up, 0 comes into bit 0 (as in ASL), bit
31 goes out into C. 2* for unsigned numbers. Only T changes.

    T = {T[30:0], 0}                    ALU op LSL, by 1

    before:  ... x  S=a  T=b
    after:   ... x  S=a  T=b<<1

    flags:   C = T[31], the bit shifted out (the one before the shift)
             Z = (T == 0), the new T
             N = bit 31 of the new T
             V = as ASL: 1 if 2*T would overflow (signed), T[31] != T[30] before
                 the shift

| stage           | what LSL does |
|-----------------|---------------|
| 2 decode        | reads T on port A; passes the constant 1 on port B (`d_b_use` = 0) |
| 3 execute       | ALU: `op` = LSL, `a` = T, `b` = 1; flags mask = 1111; `x_wen` = 1, `x_rd` = T (`100000`), `x_result` = ALU `y`; no load or store |
| 4 memory access | passes the write on |
| 5 writeback     | writes the new T (W) |

As ASR: the ALU's LSL shifts by `b[4:0]`, and decode makes the 1 a constant on port
B. The ALU's V for LSL is "a << n overflows (signed)", i.e. the top n + 1 bits of a
are not all equal; for n = 1 that is ASL's V.

LSL and ASL give the same V and the same bits 30..0. They differ in bit 31 (LSL
takes bit 30 up, ASL keeps the sign), so in N and maybe Z, and in C (LSL: the old
bit 31, ASL: the old bit 30).

### LSR (0x23)

    byte 0   0x23           no operands

Logical shift right by one: all 32 bits move down, 0 comes into bit 31, bit 0 goes
out into C. 2/ for unsigned numbers (rounding down). Only T changes.

    T = {0, T[31:1]}                    ALU op LSR, by 1

    before:  ... x  S=a  T=b
    after:   ... x  S=a  T=b>>1

    flags:   C = T[0], the bit shifted out (the one before the shift)
             Z = (T == 0), the new T
             N = 0 (bit 31 of the new T)
             V = 0

| stage           | what LSR does |
|-----------------|---------------|
| 2 decode        | reads T on port A; passes the constant 1 on port B (`d_b_use` = 0) |
| 3 execute       | ALU: `op` = LSR, `a` = T, `b` = 1; flags mask = 1111; `x_wen` = 1, `x_rd` = T (`100000`), `x_result` = ALU `y`; no load or store |
| 4 memory access | passes the write on |
| 5 writeback     | writes the new T (W) |

As ASR and LSL: the ALU's LSR shifts by `b[4:0]`, and decode makes the 1 a constant
on port B, so nothing new is needed in the ALU.

### ROL (0x24), ROR (0x25), ROLC (0x26), RORC (0x27)

    byte 0   0x24 / 0x25 / 0x26 / 0x27     no operands

Rotates of T by one bit. Only T and the flags change. ROL and ROR rotate the 32 bits
of T; ROLC and RORC rotate the 33 bits {C, T}, through the carry (as the 6502's ROL
and ROR).

    ROL    T = {T[30:0], T[31]}        C = T[31], the bit that went round
    ROR    T = {T[0], T[31:1]}         C = T[0],  the bit that went round
    ROLC   T = {T[30:0], C}            C = T[31], the bit shifted out
    RORC   T = {C, T[31:1]}            C = T[0],  the bit shifted out

    flags:   C as above (T before the rotate)
             Z = (T == 0), the new T
             N = bit 31 of the new T
             V = 0

| stage           | ROL / ROR | ROLC / RORC |
|-----------------|-----------|-------------|
| 2 decode        | reads T on port A; the constant 1 on port B (`d_b_use` = 0) | reads T on port A |
| 3 execute       | ALU: `op` = ROL / ROR, `a` = T, `b` = 1 | ALU: `op` = ROLC / RORC, `a` = T, `cin` = the C flag |
|                 | flags mask = 1111; `x_wen` = 1, `x_rd` = T (`100000`), `x_result` = ALU `y`; no load or store | the same |
| 4 memory access | passes the write on | the same |
| 5 writeback     | writes the new T (W) | the same |

ROL and ROR rotate by `b[4:0]` in the ALU (ROL on the shared shifter, as LSL);
decode makes the 1 a constant on port B. ROLC and RORC are one-bit ops of the ALU.


### INC (0x28), DEC (0x29), INCW (0x2A), DECW (0x2B)

    byte 0   0x28 / 0x29 / 0x2A / 0x2B      no operands

    INC     T = T + 1
    DEC     T = T - 1
    INCW    T = T + 4       (to the next word: an address in T steps one word on)
    DECW    T = T - 4

The stacks do not change. All four flags are set, as ADD (INC, INCW) and SUB (DEC,
DECW) set them: C = the carry out of bit 31 (for DEC, DECW: C = 1 means no borrow,
as the 6502's SBC), Z, N of the result, V = signed overflow ($7FFFFFFF + 1, $80000000
- 1). Unlike the 6502's INC and DEC, C changes.

| stage           | what they do |
|-----------------|--------------|
| 2 decode        | reads T on port A; operand B = 1 or 4 (opcode bit 1), a constant |
| 3 execute       | ALU `ADD` (carry in 0) or `SUB` (opcode bit 0), flags mask = 1111; T = y |
| 4, 5            | the write of T goes on, as a shift |

One pass, as the shifts by one.
### INV (0x1B)

    byte 0   0x1B           no operands

Inverts all 32 bits of T: Forth's INVERT. Only T and the flags change.

    T = ~T                              ALU op NOT

    before:  ... x  S=a  T=b
    after:   ... x  S=a  T=~b

    flags:   C = unchanged
             Z = (T == 0), the new T
             N = bit 31 of the new T
             V = bit 30 of the new T    (as AND, OR, XOR)

| stage           | what INV does |
|-----------------|---------------|
| 2 decode        | reads T on port A |
| 3 execute       | ALU: `op` = NOT, `a` = T; flags mask = 1110 (Z N V); `x_wen` = 1, `x_rd` = T (`100000`), `x_result` = ALU `y`; no load or store |
| 4 memory access | passes the write on |
| 5 writeback     | writes the new T (W) |

### NEG (0x1C)

    byte 0   0x1C           no operands

Negates T (two's complement): Forth's NEGATE. Only T and the flags change.

    T = 0 - T  = 0 + ~T + 1             ALU op SUB, a = 0, b = T

    before:  ... x  S=a  T=b
    after:   ... x  S=a  T=-b

    flags (as SUB, 6502):
             C = 1 only if T was 0 (no borrow), else 0
             Z = (T == 0), the new T
             N = bit 31 of the new T
             V = 1 only if T was 0x80000000 (-2^31 has no positive counterpart:
                 T stays 0x80000000)

| stage           | what NEG does |
|-----------------|---------------|
| 2 decode        | passes the constant 0 on port A (`d_a_use` = 0); reads T on port B |
| 3 execute       | ALU: `op` = SUB, `a` = 0, `b` = T; flags mask = 1111; `x_wen` = 1, `x_rd` = T (`100000`), `x_result` = ALU `y`; no load or store |
| 4 memory access | passes the write on |
| 5 writeback     | writes the new T (W) |

NEG needs nothing new in the ALU: it is SUB with the constant 0 from decode.

### MULS (0x1D)

    byte 0   0x1D           no operands

One step of an unsigned 32 x 32 -> 64 multiply (shift and add): first the add, then
the shift (as DIVS: the shift comes after the arithmetic). S is the multiplicand, T
the high word of the product so far, TMPL the rest of the multiplier; the low word
of the product comes into TMPL from the top as the multiplier goes out at the
bottom. S and the stack in memory do not change.

    if TMPL[0] = 1:  w = T + S          33 bits, carry in 0
    else:            w = T
    {w, TMPL} shifted right by one (65 bits):
        T    = w[32:1]                  the add's carry comes into bit 31
        TMPL = {w[0], TMPL[31:1]}       T's low bit into bit 31 of TMPL

    flags:   none changed

A whole multiply: T = 0, TMPL = the multiplier, S = the multiplicand, then 32 MULS:

    before:  S = a   T = 0          TMPL = b
    32 MULS
    after:   S = a   T = hi(a * b)  TMPL = lo(a * b)

T need not start at 0: with T = c at the start, the 32 MULS give a * b + c (a
multiply and add; the sum always fits in 64 bits).

| stage           | what MULS does |
|-----------------|----------------|
| 2 decode        | reads T on port A and S on port B |
| 3 execute       | ALU: `op` = MULS, `a` = T, `b` = S, `cin` = TMPL[0]; flags mask = 0000; `tmplh`: `sh_r` = 1, `sh_bit` = the ALU's `y2[0]`; `x_wen` = 1, `x_rd` = T (`100000`), `x_result` = ALU `y`; no load or store |
| 4 memory access | passes the write on |
| 5 writeback     | writes the new T (W) |

TMPL is shifted in execute, so the next MULS sees it at once, and the new T is
forwarded: the 32 steps take 32 ticks. MUL does the same in one tick on the on-chip
multiplier; MULS is there for programs that build their own wider multiplies.

### CMP (0x1E)

    byte 0   0x1E           no operands

Compares S with T: works out S - T as SUB does and sets the flags from it, but
writes nothing: S, T and the stacks do not change.

    flags of S + ~T + 1 = S - T         ALU op SUB, carry in 1

    before:  ... x  S=a  T=b
    after:   ... x  S=a  T=b

    flags (as SUB, 6502):
             C = 1: no borrow, S >= T (unsigned); 0: S < T
             Z = 1: S == T
             N = bit 31 of S - T
             V = signed overflow of S - T

So after a CMP, as on the 6502: unsigned S >= T is C = 1, S == T is Z = 1, signed
S < T is N != V.

| stage           | what CMP does |
|-----------------|---------------|
| 2 decode        | reads S on port A and T on port B |
| 3 execute       | ALU: `op` = SUB, `a` = S, `b` = T; flags mask = 1111; `x_wen` = 0, `x2_wen` = 0; no load or store |
| 4 memory access | nothing (a bubble with no write) |
| 5 writeback     | nothing |

The flags are written as CMP leaves execute, so the next instruction (a branch, say)
sees them at once.

### LITH (0x45)

    byte 0   0x45
    byte 1   n, 8 bits (0 .. 255)

Puts n into the top byte of T. Nothing else changes: T[23:0], S, the stacks and the
flags stay as they are. Like the LITs it pushes nothing (`DUP` pushes).

    T = {n, T[23:0]}

With LIT24 before it, it loads a 32-bit constant in 6 bytes: LIT24 the low 24 bits
(sign-extended, which LITH then overwrites), LITH the high 8.

    LIT24   $345678     ; T = $00345678
    LITH    $12         ; T = $12345678

    DUP LIT24 LITH:  ... x    S=a  T=b
    DUP              ... x a  S=b  T=b
    LIT24 $345678    ... x a  S=b  T=$00345678
    LITH  $12        ... x a  S=b  T=$12345678

The assembler's `LIT` does this by itself for a constant that does not fit in 24 bits
(signed): `LIT $CAFEBABE` is `C0 BE BA FE 45 CA`. It keeps the 6 bytes in one line (it
pads to the next line first if they would cross its end).

| stage           | what LITH does |
|-----------------|----------------|
| 2 decode        | reads T on port A; the constant {n, 24'h0} on operand B (`b_const`); ALU op HIB; flags mask 0 |
| 3 execute       | the ALU: y = {b[31:24], a[23:0]} (op HIB, 31); `x_wen` = 1, `x_rd` = T, `x_result` = y |
| 4 memory access | passes the write on |
| 5 writeback     | writes the new T |

T comes through forwarding like any operand, so LITH can follow LIT24, a load into T
or a MOVR into T at once (`stage2/lith_tb.v`).

### CJMPL (0x41)

    byte 0   0x41
    byte 1   bits 7..4: the condition    bits 3..0: the target, an offset in the line

Conditional jump local: when the condition holds, the jump goes to the byte at that
offset in the same 16-byte line as the CJMPL, i.e. PC = {PC of the CJMPL [31:4],
target}. Otherwise the program goes on after the CJMPL. Nothing else changes: no
register, no flag, no stack.

Because the target is in the same line, it is in fetch's instruction buffer: a taken
CJMPL never makes fetch read memory. (Loops of a few instructions fit in a line.)

The conditions: the 6502's eight, the six compares that come after a CMP (or a
SUB), always, and TZ: T is 0 (a test of T itself, not of the flags, so a loop can
count T down without a CMP). From 0x0 to 0xD each odd code is the opposite of the
even one before it.

| cond | name     | holds when        | 6502 | after CMP (S - T)   |
|------|----------|-------------------|------|---------------------|
| 0x0  | EQ       | Z = 1             | BEQ  | S == T              |
| 0x1  | NE       | Z = 0             | BNE  | S != T              |
| 0x2  | CS = HS  | C = 1             | BCS  | S >= T unsigned     |
| 0x3  | CC = LO  | C = 0             | BCC  | S <  T unsigned     |
| 0x4  | MI       | N = 1             | BMI  |                     |
| 0x5  | PL       | N = 0             | BPL  |                     |
| 0x6  | VS       | V = 1             | BVS  |                     |
| 0x7  | VC       | V = 0             | BVC  |                     |
| 0x8  | HI       | C = 1 and Z = 0   |      | S >  T unsigned     |
| 0x9  | LS       | C = 0 or  Z = 1   |      | S <= T unsigned     |
| 0xA  | GE       | N = V             |      | S >= T signed       |
| 0xB  | LT       | N != V            |      | S <  T signed       |
| 0xC  | GT       | Z = 0 and N = V   |      | S >  T signed       |
| 0xD  | LE       | Z = 1 or  N != V  |      | S <= T signed       |
| 0xE  | A        | always            |      |                     |
| 0xF  | TZ       | T = 0, whatever the flags |  |                  |

For the unsigned compares there are names that say what they mean: **HS** (higher or
same) is the same code as CS, **LO** (lower) the same as CC. So the unsigned set is
HI, HS, LO, LS and the signed set GT, GE, LT, LE. The assembler takes either name.

| stage           | what CJMPL does |
|-----------------|-----------------|
| 2 decode        | takes the condition from byte 1; makes the target address {PC[31:4], target} and passes it on port A as a constant (`d_a_use` = 0); reads T on port B (for TZ) |
| 3 execute       | `cond.v`: the condition against the flags (TZ: operand B == 0); when it holds: redirect fetch to operand A; no write, no load or store |
| 4 memory access | nothing (a bubble with no write) |
| 5 writeback     | nothing |

The flags are read in execute, so a CJMPL right after the instruction that set them
(CMP, SUB, ...) sees the new flags. T is read on port B and forwarded like any
operand, so TZ sees the T just written (right after a load into T, it waits a tick,
as any instruction reading T does). A jump not taken costs nothing. A jump taken
throws away the two instructions behind it (in decode and in fetch's output): it
costs 2 ticks, but no memory access.

Byte 1 is all condition and target (no opx bits), as in the LITs. A CJMPL at offset
15 would get its byte 1 from the next line, which reads as 0 (EQ, offset 0): the
assembler must not put one there.

### CBR (0x81)

    byte 0   0x81
    byte 1   bits 7..4: the condition    bits 3..0: offset bits 3..0
    byte 2   offset bits 11..4

Conditional branch relative: when the condition holds, the program goes on at the
next instruction + the offset, a 12-bit signed number of bytes (-2048 .. +2047),
as on the 6502. Otherwise it goes on with the next instruction. Nothing else
changes: no register, no flag, no stack.

    if the condition holds:  PC = PC of the CBR + 3 + offset

The conditions are those of CJMPL (EQ, NE, CS = HS, CC = LO, MI, PL, VS, VC, HI, LS,
GE, LT, GT, LE, A, TZ). CBR A is an unconditional relative jump.

| stage           | what CBR does |
|-----------------|---------------|
| 2 decode        | takes the condition from byte 1; makes the target address (PC + 3 + the sign-extended offset) and passes it on port A as a constant (`d_a_use` = 0); reads T on port B (for TZ) |
| 3 execute       | `cond.v`: the condition against the flags (TZ: operand B == 0); when it holds: redirect fetch to operand A; no write, no load or store |
| 4 memory access | nothing (a bubble with no write) |
| 5 writeback     | nothing |

Decode has the PC of each instruction (from fetch), so it works out the target with
its own adder; execute only checks the condition and redirects, the same for CBR and
CJMPL. A branch not taken costs nothing; a branch taken costs 2 ticks (the two
instructions behind it are thrown away) and, when the target is in another line,
the fill of that line.

Byte 1 and byte 2 are all condition and offset (no opx bits). The line rule applies:
a CBR may only cross the end of a line if the bytes it puts into the next line are
0, so a CBR at offset 14 or 15 is only possible when those bytes happen to be 0.

### CBRL (0xC1)

    byte 0   0xC1
    byte 1   bits 7..4: the condition    bits 3..0: offset bits 3..0
    byte 2   offset bits 11..4
    byte 3   offset bits 19..12

Conditional branch long: CBR with one more byte of offset, a 20-bit signed number
of bytes (-524288 .. +524287, i.e. +-512 KB), counted from the next instruction.

    if the condition holds:  PC = PC of the CBRL + 4 + offset

Everything else is as CBR: the same conditions (TZ included), the same pipeline
(decode makes the target address and passes it on port A, reads T on port B;
execute checks the condition and redirects), the same cost. The assembler picks CBR
when the offset fits in 12 bits, CBRL when it does not.

The line rule applies: a CBRL may only cross the end of a line if the bytes it puts
into the next line are 0.

### Assembler syntax of the branches

    CJMPL <cond>, <label-or-offset>
    CBR   <cond>, <label-or-offset>
    CBRL  <cond>, <label-or-offset>

`<cond>` is one of the condition names: EQ, NE, CS or HS, CC or LO, MI, PL, VS, VC,
HI, LS, GE, LT, GT, LE, A, TZ.

`<label-or-offset>`:

- a **label**: the assembler works out the field from the label's address. For CBR
  and CBRL that is the label's address minus the address of the next instruction;
  for CJMPL it is the label's offset in the line (bits 3..0 of its address).
- a **number**: put into the field as it is. For CBR and CBRL it is the signed
  offset from the next instruction; for CJMPL the offset in the line, 0 .. 15.

The assembler reports an error when the target does not fit: for CJMPL a label in
another line or a number above 15, for CBR an offset outside -2048 .. +2047, for
CBRL outside -524288 .. +524287.

    loop:   ...
            CMP
            CBR   NE, loop          ; back to loop while S != T
            CJMPL A, 3              ; to offset 3 of this line
            CBRL  TZ, -1000         ; 1000 bytes back from the next instruction, if T == 0

### UNEXT (0x48), NEXT2 (0x88), NEXT3 (0xC8)

    UNEXT   byte 0   0x48
            byte 1   bits 7..4: 0    bits 3..0: the target, an offset in the line

    NEXT2   byte 0   0x88
            byte 1   opx 00 (7..6)   the counter register (5..0)
            byte 2   offset bits 7..0

    NEXT3   byte 0   0xC8
            byte 1   opx 00 (7..6)   the counter register (5..0)
            byte 2   offset bits 7..0
            byte 3   offset bits 15..8

Counted loops, as Forth's FOR .. NEXT (and the F18's `next` / `unext`): the loop
branches back while its counter is not 0, and counts it down as it does.

    if counter != 0:  counter = counter - 1, jump to the target
    else:             no jump; if the counter is R: R = pop (the return stack)

The test is of the counter before it is counted down, so a count of n runs the body
**n + 1 times**, and a count of 0 runs it once. When the loop ends the counter is 0;
when it is R it is dropped, so what was below it on the return stack is R again.
No flags change (a loop does not disturb a compare made in its body).

- **UNEXT**: the counter is R, the target in the same 16-byte line as the UNEXT
  (`{PC of the UNEXT [31:4], byte 1 bits 3..0}`, as CJMPL). The body is in fetch's
  instruction buffer: the loop never makes fetch read memory. Byte 1 bits 7..4 must
  be 0 (otherwise the instruction does nothing). At offset 15 its byte 1 would come
  from the next line (read as 0): the assembler must not put one there.
- **NEXT2**, **NEXT3**: the counter is any register of the register file (r0 ..
  r31, T, S, R, L; with another one the instruction does nothing), the target the
  next instruction + a signed offset: 8 bits (-128 .. +127) for NEXT2, 16 bits
  (-32768 .. +32767) for NEXT3. Byte 1 bits 7..6 (opx) must be 00. With R as the
  counter they drop R at the end as UNEXT does; with another register they leave it
  at 0.

        LIT8  9
        PUSH                ; R = 9 (the old R below it)
    l:  ...                 ; 10 times
        NEXT2 R, l          ; at the end R is the old R again

        MOVI2 r4, 99
    m:  ...                 ; 100 times
        NEXT  r4, m         ; NEXT2 or NEXT3, whichever reaches

| stage           | what UNEXT, NEXT2, NEXT3 do |
|-----------------|-----------------------------|
| 2 decode        | the counter on port B, the constant 1 on port A; the ALU op RSB (B - A = counter - 1); the target into `d_imm` (UNEXT: `{PC[31:4], target}`; NEXT2, NEXT3: next + the offset, from the adder of CBR); the register write counter = r; for R also a pop of the return stack (the load and the `stackregs` op POP); `d_loop` = 1 |
| 3 execute       | `ltake` = the counter (operand B) != 0, the same `tz` compare as the condition TZ. When it holds: redirect fetch to `e_imm`, write counter - 1 (ALU y), no load, no `stackregs` op. When it does not: no redirect; the write only with the load (R = the word popped), else nothing |
| 4 memory access | the pop's load, when the loop ends with R; else the write of counter - 1 |
| 5 writeback     | the counter's new value |

The branch is decided on operand B itself, not on the result of the decrement, so
the adder is not in the path to `redirect` (the same path as CJMPL TZ). A branch
taken costs 2 ticks, as CJMPL, CBR (the two instructions behind it are thrown away),
and for NEXT2, NEXT3 to another line the fill of the line. The counter is read on
port B and forwarded like any operand, so it may be written by the instruction right
before the loop instruction.

Assembler syntax:

    UNEXT <label-or-offset>             the label in the same line, or 0 .. 15
    NEXT2 <reg>, <label-or-offset>      offset from the next instruction
    NEXT3 <reg>, <label-or-offset>
    NEXT  <reg>, <label>                pseudo: NEXT2, or NEXT3 when NEXT2 does not reach

### RET (0x01)

    byte 0   0x01           no operands

Return from a subroutine: R is the return address (the top of the return stack);
the program goes on there, and the word below it on the return stack comes up into
R. The parameter stack and the flags do not change.

    PC = R
    RSP = RSP + 4       pop the return stack into R
    R = mem[RSP]

    before:  rstack ... y d  R=ret
    after:   rstack ... y    R=d        PC = ret

| stage           | what RET does |
|-----------------|---------------|
| 2 decode        | reads R on port A |
| 3 execute       | redirect fetch to operand A (always); `stackregs`: `sel` = RSP, `op` = POP: the address is RSP + 4, RSP + 4 at the edge; `x_load` = 1, `x_size` = word; `x_wen` = 1, `x_rd` = R (`100010`); `x2_wen` = 0 |
| 4 memory access | loads the word into `m_data` |
| 5 writeback     | writes the word into R (W) |

It is POP without the write to T, with a jump to the old R: the jump goes out from
execute as for the branches, and R is forwarded like any operand, so a RET right
after an instruction that changes R (PUSH, POP, ...) returns to the new R (right
after a load into R, it waits a tick). A RET costs 2 ticks (the two instructions
behind it are thrown away) and, when the return address is in another line, the
fill of that line.

### JSRS (0x42), JSR (0x82), JSRL (0xC2)

    JSRS    byte 0   0x42
            byte 1   offset, 8 bits                           -128      .. +127
    JSR     byte 0   0x82
            byte 1   offset bits 7..0
            byte 2   offset bits 15..8                         -32768    .. +32767
    JSRL    byte 0   0xC2
            byte 1   offset bits 7..0
            byte 2   offset bits 15..8
            byte 3   offset bits 23..16                        -8388608  .. +8388607 (+-8 MB)

Jump to a subroutine: R is pushed onto the return stack, the return address (the
next instruction) goes into R, and the program goes on at the destination: the next
instruction + the signed offset (counted as in CBR). RET (0x01) comes back. The
parameter stack and the flags do not change.

    mem[RSP] = R        push R onto the return stack
    RSP = RSP - 4
    R = PC + len        the return address: the next instruction
    PC = PC + len + offset

    before:  rstack ... y    R=d
    after:   rstack ... y d  R=ret      PC = destination

| stage           | what JSRS / JSR / JSRL does |
|-----------------|-----------------------------|
| 2 decode        | makes the return address (PC + len) and the destination (PC + len + offset); **redirects fetch to the destination itself** when it issues the call; passes the return address on port A as a constant (`d_a_use` = 0); reads R on port B |
| 3 execute       | `stackregs`: `sel` = RSP, `op` = PUSH: the address is RSP, RSP - 4 at the edge; `x_store` = 1, `x_size` = word, `x_wdata` = R (operand B); `x_wen` = 1, `x_rd` = R (`100010`), `x_result` = operand A (the return address); `x2_wen` = 0 |
| 4 memory access | stores the old R at the old RSP |
| 5 writeback     | writes the return address into R (W) |

In execute it is PUSH, with the return address in place of T. A call needs three
values (the destination, the old R and the return address), and only two go from
decode to execute; the destination is known in decode, and a call always jumps, so
decode redirects fetch itself. That makes a call cheaper than a taken branch: only
the instruction waiting in fetch's output is thrown away, so it costs 1 tick (and,
when the destination is in another line, the fill of that line).

When execute redirects in the same tick (an older branch or RET taken), execute
wins: the call is thrown away, and so is its redirect.

The assembler syntax: `JSRS <label-or-offset>`, `JSR <label-or-offset>`,
`JSRL <label-or-offset>`; a label gives the offset from the next instruction, a
number is the offset itself. The assembler picks the shortest that fits.

### EXEC (0x1F)

    byte 0   0x1F           no operands

(Called EXC before; EXC is now the exception, 0x4A.)

Exchanges R and the PC: the program goes on at the address in R, and the address
of the next instruction (after the EXEC) goes into R. The stacks and the flags do
not change: nothing is pushed or popped.

    PC = R
    R  = PC + 1         the next instruction

    before:  R=a                 PC = the EXEC
    after:   R=after the EXEC    PC = a

Uses: a call through an address (put the address into R, EXEC; the routine comes
back with RET or EXEC), and coroutines: two routines that hand over to each other
with EXEC, each going on where it stopped.

| stage           | what EXEC does |
|-----------------|---------------|
| 2 decode        | reads R on port A; passes the address of the next instruction (PC + 1) on port B as a constant (`d_b_use` = 0) |
| 3 execute       | redirect fetch to operand A (always); `x_wen` = 1, `x_rd` = R (`100010`), `x_result` = operand B; no load or store |
| 4 memory access | passes the write on |
| 5 writeback     | writes the return address into R (W) |

The jump goes out from execute, as for RET, not from decode: R may still be on its
way (written by an instruction just ahead), and only execute has it forwarded. So
EXEC costs 2 ticks (and the fill when the target is in another line); right after a
load into R it waits a tick.

### MOVR (0x43)

    byte 0   0x43
    byte 1   bit 7: 0
             bit 6: the direction: 0 = T into the register, 1 = the register into T
             bit 5: 0 = r0 .. r31 (bits 4..0 the number), 1 = a special register
             bits 4..0: the register (see below)

Moves a value between T and another register. The stacks and the flags do not
change; the source keeps its value.

    bit 6 = 0:   register = T           assembler: MOVR <reg>, T
    bit 6 = 1:   T = register           assembler: MOVR T, <reg>

The assembler syntax is destination first, source second.

    MOVR T, r5      ; T   = r5
    MOVR r5, T      ; r5  = T
    MOVR L, T       ; L   = T
    MOVR T, PSP     ; T   = PSP
    MOVR FP, T      ; FP  = T
    MOVR PC, T      ; jump to the address in T
    MOVR T, PC      ; T   = the address of the next instruction

The special registers (bit 5 = 1). Bits 4..2 say where the register is, the low
bits are the select signal of the module that holds it:

| bits 4..0 | register | where                         | low bits |
|-----------|----------|-------------------------------|----------|
| 00000     | T        | register file (stage 2)       | as the register file's selector |
| 00001     | S        | register file                 | |
| 00010     | R        | register file                 | |
| 00011     | L        | register file                 | |
| 00100     | PSP      | stage 3, `stackregs`          | `sel` = 00 |
| 00101     | RSP      | stage 3, `stackregs`          | `sel` = 01 |
| 00110     | FP       | stage 3, `stackregs`          | `sel` = 10 |
| 00111     | PC       | fetch (a jump / the next address) | (`sel` = 11: none in `stackregs`) |
| 01000     | TMPL     | stage 3, `tmplh`              | bit 0 = 0 |
| 01001     | TMPH     | stage 3, `tmplh`              | bit 0 = 1 |
| 01010     | ST       | stage 3, the flags (`flags.v`) | the status register: bits 3..0 = V N Z C |
| 01011     | HLIM     | stage 3, `execute.v`          | the heap limit of CONS (see LISP) |
| 01100     | VEC      | stage 3, `execute.v`          | the vector table (see Interrupts and exceptions); bits 9..0 are 0 |
| 01101     | PSPL     | stage 3, `execute.v`          | the lowest PSP may take; bit 0 = its check on (see The stack limits) |
| 01110     | PSPH     | stage 3, `execute.v`          | the highest PSP may take; bit 0 = its check on |
| 01111     | RSPL     | stage 3, `execute.v`          | the lowest RSP may take; bit 0 = its check on |
| 10000     | RSPH     | stage 3, `execute.v`          | the highest RSP may take; bit 0 = its check on |
| others    | (free)   |                               | |

So the full byte 1 of `MOVR T, PSP` is 0110 0100 = 0x64, of `MOVR PSP, T` 0010 0100
= 0x24.

**Registers in the register file** (r0 .. r31, T, S, R, L): bits 5..0 are the
register file's 6-bit selector; decode reads the source on port A, execute writes
the destination through the result.

| stage           | MOVR <reg>, T | MOVR T, <reg> |
|-----------------|---------------|---------------|
| 2 decode        | reads T on port A | reads the register on port A |
| 3 execute       | `x_wen` = 1, `x_rd` = byte 1 bits 5..0, `x_result` = operand A | `x_wen` = 1, `x_rd` = T (`100000`), `x_result` = operand A |
| 4, 5            | the write goes on and is done in writeback | the same |

**Registers in stage 3** (PSP, RSP, FP, TMPL, TMPH, ST, HLIM, VEC, PSPL .. RSPH): decode sends no value for them
(the register is not in the register file); stage 3 reads or writes it where it
is. Their selector never goes to the register file.

| stage           | MOVR <reg>, T | MOVR T, <reg> |
|-----------------|---------------|---------------|
| 2 decode        | reads T on port A | reads nothing (`d_a_use` = 0) |
| 3 execute       | PSP / RSP / FP: `stackregs` `sel` = bits 1..0, `op` = SET, `w_data` = operand A; TMPL / TMPH: `tmplh` `we_l` / `we_h`, `d` = operand A; `x_wen` = 0 | `x_result` = `stackregs` `value` (sel = bits 1..0), or TMPL, or TMPH; `x_wen` = 1, `x_rd` = T |
| 4, 5            | nothing more | the write of T goes on |

These registers live in execute, so a MOVR right after an instruction that changed
one of them (a push, a DIVS, ...) sees the new value: no forwarding.

**PC**: `MOVR PC, T` is a jump to the address in T: decode reads T on port A,
execute redirects fetch to operand A (as RET), so it costs 2 ticks; nothing is
written. `MOVR T, PC` puts the address of the next instruction (the MOVR's address +
2) into T: decode passes it on port A as a constant (`d_a_use` = 0), execute writes
it into T.

No ALU work, no load or store: one pass. Byte 1 has no opx bits; bit 7 must be 0
(kept free).

### INCR, DECR, INCWR, DECWR (0x44)

    byte 0   0x44
    byte 1   bit 7: 0 = increment, 1 = decrement
             bit 6: 0 = by 1, 1 = by 4 (a word)
             bits 5..0: the register (any MOVR names)

INC, DEC, INCW, DECW for any register, not only T:

    INCR  reg       ; reg = reg + 1         byte 1 = 00 reg
    DECR  reg       ; reg = reg - 1         byte 1 = 10 reg
    INCWR reg       ; reg = reg + 4         byte 1 = 01 reg
    DECWR reg       ; reg = reg - 4         byte 1 = 11 reg

    INCR  r3        ; a loop counter
    DECWR FP        ; FP one word down
    INCWR PSP       ; drop one word of the parameter stack (without loading it)

The flags are set as by INC .. DECW (C Z N V, as ADD and SUB). The stacks do not
change (`INCWR PSP` only moves the pointer). With PC the result is a jump (to the
next instruction + 1 or 4, or - 1 or 4); with ST the result goes into the flags.

| stage           | what they do |
|-----------------|--------------|
| 2 decode        | the register on operand B (register file port B; PC: the next address; a register of stage 3: `d_b_s3`), the constant 1 or 4 on operand A; ALU `ADD` (A + B) for an increment, `RSB` (B - A) for a decrement |
| 3 execute       | flags mask = 1111; the result y goes to the register: register file (`x_rd`), `stackregs` (SET), `tmplh`, ST, or PC (redirect to y) |
| 4, 5            | as ADDR |

The register is on operand B so that the registers of stage 3 work too (they only
come into the ALU on input b); that is why a decrement is the ALU's reverse subtract.

### ADDR (0x50)

    byte 0   0x50
    byte 1   as MOVR: bit 7: 0; bit 6: the destination: 0 = the register, 1 = T;
             bits 5..0: the register (r0 .. r31, or a special register numbered as
             in MOVR: T, S, R, L, PSP, RSP, FP, PC, TMPL, TMPH)

Add register: one of the two addends is always T, the other the named register;
the destination is one of them. The ALU does an ADD (carry in 0) and sets all four
flags as ADD does. Nothing is pushed or popped.

    bit 6 = 0:   register = register + T     assembler: ADDR <reg>, T
    bit 6 = 1:   T = T + register            assembler: ADDR T, <reg>

As in MOVR, the destination comes first.

    ADDR T, r5      ; T   = T + r5
    ADDR r5, T      ; r5  = r5 + T
    ADDR PSP, T     ; PSP = PSP + T     (e.g. drop T/4 words of the stack at once)
    ADDR FP, T      ; FP  = FP + T
    ADDR T, PC      ; T   = T + the address of the next instruction (a PC-relative
                    ;       address, e.g. of a table after the code)
    ADDR PC, T      ; jump to the next instruction + T (a computed relative jump)

    flags:   C = the carry out of bit 31
             Z = (result == 0)
             N = bit 31 of the result
             V = signed overflow

| stage           | what ADDR does |
|-----------------|----------------|
| 2 decode        | reads T on port A; the register on port B: from the register file for r0 .. r31, T, S, R, L; nothing for PSP, RSP, FP, TMPL, TMPH (`d_b_use` = 0, stage 3 has them); for PC the address of the next instruction as a constant |
| 3 execute       | ALU: `op` = ADD, `a` = operand A (T), `b` = operand B, or for PSP / RSP / FP / TMPL / TMPH the register itself from stage 3; flags mask = 1111; the result (ALU `y`) goes to the destination: T or a register-file register through `x_rd`, `x_result` (`x_wen` = 1); PSP / RSP / FP through `stackregs` (`op` = SET, `w_data` = `y`), TMPL / TMPH through `tmplh` (`x_wen` = 0); PC: redirect fetch to `y` (`x_wen` = 0) |
| 4 memory access | passes the write on (if any) |
| 5 writeback     | writes the destination (W), if it is in the register file |

One pass, no load or store. The new value is forwarded (register file) or written
in execute (stage 3 registers), so the next instruction can use it at once.
ADDR PC, T jumps from execute, so it costs 2 ticks, as RET.

### ADCR (0x51), SUBR (0x52), SBCR (0x53)

    byte 0   0x51 / 0x52 / 0x53
    byte 1   as ADDR (and MOVR): bit 7: 0; bit 6: the destination: 0 = the register,
             1 = T; bits 5..0: the register

The other arithmetic ops of ADDR: add with carry, subtract, subtract with borrow,
between T and a register. As in ADDR, one operand is always T, the destination comes
first, and the destination is also the first operand of a subtraction:

    bit 6 = 1:   T        = T        op register     assembler: xxxR T, <reg>
    bit 6 = 0:   register = register op T            assembler: xxxR <reg>, T

    ADCR T, r5      ; T   = T + r5 + C
    ADCR r5, T      ; r5  = r5 + T + C
    SUBR T, r5      ; T   = T - r5
    SUBR r5, T      ; r5  = r5 - T
    SUBR PSP, T     ; PSP = PSP - T     (e.g. reserve T/4 words on the stack at once)
    SUBR T, PSP     ; T   = T - PSP
    SBCR T, r5      ; T   = T - r5 - (1 - C)
    SBCR r5, T      ; r5  = r5 - T - (1 - C)

With ADDR and ADCR (and SUBR, SBCR) a 64-bit value in two registers can be added to
(subtracted from) one in T and S without touching the stacks:

    ; {r1, r0} = {r1, r0} + {S, T}
    ADDR r0, T      ; r0 = r0 + T, C = the carry
    DROP            ; T = S
    ADCR r1, T      ; r1 = r1 + T + C

The flags are those of ADC, SUB and SBC (C Z N V); for the subtractions C = 1 means
no borrow, as on the 6502. SBCR with C = 1 is SUBR. The register can be any MOVR
names: r0 .. r31, T, S, R, L, PSP, RSP, FP, PC, TMPL, TMPH. `SUBR PC, T` jumps to the
next instruction - T, `SUBR T, PC` gives T - the next instruction.

| stage           | what they do |
|-----------------|--------------|
| 2 decode        | as ADDR: T on port A, the register on port B (or nothing for PSP .. TMPH, the next address for PC); the ALU op: ADCR `ADC` (carry in C); SUBR `SUB`, SBCR `SBC` when T is the destination (T - register = A - B); when the register is the destination (register - T = B - A), SUBR `RSB`, SBCR `RSC`: the ALU subtracts the other way round |
| 3 execute       | as ADDR, with that ALU op; flags mask = 1111 |
| 4, 5            | as ADDR |

Why RSB and RSC: the registers of stage 3 (PSP, RSP, FP, TMPL, TMPH, ST) only come into
the ALU on input b. So operand A stays T and operand B the register, as in ADDR, and
for `register - T` the ALU inverts its input a instead of b: b - a = ~a + b + 1
(alu.v). One pass, as ADDR;
SUBR PC, T and SBCR PC, T cost 2 ticks, as ADDR PC, T.

### Why 0x00 is a good NOP

- Bytes past the end of a 16-byte line are read as 0, and padding to the next line is
  done with 0x00: both are NOPs.
- Memory that was never written (0 after loading the FPGA) runs as NOPs.

### ENTER (0x46), ENTER2 (0x86), ENTER3 (0xC6), LEAVE (0x30)

    ENTER   byte 0 0x46, byte 1      n words, 8 bits unsigned (0 .. $FF)
    ENTER2  byte 0 0x86, bytes 1, 2  n words, 16 bits unsigned (0 .. $FFFF)
    ENTER3  byte 0 0xC6, bytes 1..3  n words, 24 bits unsigned (0 .. $FFFFFF)
    LEAVE   byte 0 0x30

Make and drop a **stack frame** on the return stack, as a C compiler needs one: a
function starts with ENTER n (n **words** of local variables, 4n bytes) and ends with
LEAVE, RET. Decode multiplies n by 4 (two 0 bits below it) as it makes the constant,
so RSP stays word-aligned.

    ENTER n:   push FP onto the return stack     the word at RSP = R, RSP = RSP - 4,
                                                 R = FP
               FP = RSP                          the frame
               RSP = RSP - 4n                    n words for the locals

    LEAVE:     RSP = FP                          drop the locals
               pop FP from the return stack      FP = R, RSP = RSP + 4,
                                                 R = the word at RSP

R is the top of the return stack, so pushing FP onto it means: the old R goes to
memory and R = FP; popping it: FP = R and R comes back from memory. ENTER's FP = RSP
is what makes LEAVE's RSP = FP drop exactly the frame. After LEAVE, R, RSP and FP
are as before the ENTER, so the RET that follows returns:

    f:  ENTER 4             ; 4 words (16 bytes) of locals; R = the caller's FP, the
                            ; return address in memory
        STR3  r1, FP, -12   ; a local: the word at FP - 12 (the words FP - 12 .. FP)
        ...
        LEAVE               ; R = the return address again, FP = the caller's FP
        RET

The frame, after `ENTER n` (addresses grow upward; the return stack grows down):

    FP + 4                the word that was in R (the return address, right
                          after a call)
    FP - 4n + 4 .. FP + 3 the 4n bytes for the locals (the words FP - 4n + 4 .. FP)
    RSP = FP - 4n         the next free word of the return stack

(R holds the caller's FP.) No flags change. ENTER and LEAVE are **one pass** each: `stackregs` writes RSP and FP in
the same tick (its ops ENTER and LEAVE), so nothing, not even an interrupt, comes
between their parts.

| stage           | ENTER | LEAVE |
|-----------------|-------|-------|
| 2 decode        | R on operand A (the data to store), 4n on operand B (`stackregs` offset; n with two 0 bits below), `stackregs` op ENTER; R = the old FP (`d_s3` = 6, FP's own output) | R on operand A (the new FP, as `w_data`), `stackregs` op LEAVE, a load into R |
| 3 execute       | the store address = RSP; RSP = RSP - 4 - 4n, FP = RSP - 4 | the load address = FP + 4; RSP = FP + 4, FP = R |
| 4 memory access | stores the old R | loads the word |
| 5 writeback     | R = the old FP | R = the word loaded |

### LDR (0x84), STR (0x85)

    byte 0   0x84 LDR / 0x85 STR
    byte 1   bits 7..6: the size: 00 = byte, 01 = halfword (16 bits), 10 = word
                        (32 bits); 11 is free (the instruction does nothing)
             bits 5..0: the data register: the destination of LDR, the source of STR
    byte 2   bit 7:     LDR: 1 = sign-extend the byte or halfword to 32 bits, 0 = zero-
                        extend (no meaning for a word); STR: 0
             bit 6:     0 (kept free: with 1 the instruction does nothing)
             bits 5..0: the address register

Load and store with the address in a register; no flags change, the stacks do not
move.

| mnemonic | opcode | byte 1 bits 7..6 | byte 2 bit 7 | does |
|----------|--------|------------------|--------------|------|
| LDRB     | 0x84   | 00               | 0            | reg = the byte at addr, zero-extended |
| LDRSB    | 0x84   | 00               | 1            | reg = the byte at addr, sign-extended |
| LDRH     | 0x84   | 01               | 0            | reg = the halfword at addr, zero-extended |
| LDRSH    | 0x84   | 01               | 1            | reg = the halfword at addr, sign-extended |
| LDR      | 0x84   | 10               | 0            | reg = the word at addr |
| STRB     | 0x85   | 00               | 0            | the byte at addr = reg bits 7..0 |
| STRH     | 0x85   | 01               | 0            | the halfword at addr = reg bits 15..0 |
| STR      | 0x85   | 10               | 0            | the word at addr = reg |

    LDR   r1, r2        ; r1 = the word at r2
    LDRSB T, FP         ; T  = the byte at FP, sign-extended
    STRH  S, PSP        ; the halfword at PSP = S
    LDR   r0, PC        ; r0 = the word right after this instruction (a constant in
                        ;      the code, e.g. after an unconditional jump)

**Alignment.** For a halfword, bit 0 of the address is ignored and taken as 0; for a
word, bits 1..0. Memory access (stage 4) sets them to 0 on the bus, so the memory and
the I/O always see an aligned address. A byte may be at any address.

**The registers.** The data register must be in the register file: r0 .. r31, T, S,
R, L (a load's data only arrives in stages 4, 5, and a store's data is an operand).
The address register can be r0 .. r31, T, S, R, L, PC (the address of the next
instruction), PSP, RSP or FP; not TMPL, TMPH or ST. The assembler gives an error
for any other; in the processor such an instruction does nothing.

| stage           | what they do |
|-----------------|--------------|
| 2 decode        | the address goes through `stackregs`' address output (`d_addr` = 0, `op` BASE): for a register file register or PC, `sel` = none (address = 0 + offset) with the register (port B) or the next address as the offset; for PSP, RSP, FP, `sel` = that register with offset 0. LDR: `d_load`, the size, `d_signed`, destination = the data register. STR: `d_store`, the size, the data register on operand A (`d_wdata` = 0) |
| 3 execute       | `x_addr` = the address, `x_wdata` = operand A; no ALU work, flags mask 0 |
| 4 memory access | the access, with the low address bits of a halfword / word set to 0; the byte lanes (`d_be`); a load takes its lane and extends it |
| 5 writeback     | LDR writes the data register |

A load or store stalls the pipeline for at least one tick (memory access waits for
the memory); an instruction that uses a register just loaded waits for it.

### LDR3 (0xC4), STR3 (0xC5)

    byte 0   0xC4 LDR3 / 0xC5 STR3
    byte 1   as LDR / STR: bits 7..6 the size (00 byte, 01 halfword, 10 word; 11
             does nothing), bits 5..0 the data register
    byte 2   bit 7: LDR3: 1 = sign-extend; STR3: 0
             bit 6: 1 = byte 3 is a signed 8-bit offset, 0 = byte 3 names a register
             bits 5..0: the base register
    byte 3   bit 6 = 1: the offset, -$80 .. $7F
             bit 6 = 0: bits 5..0 the offset register (bits 7..6 ignored; the
                        assembler writes 0)

LDR and STR with an offset: the address is base + offset.

    LDR3  r1, r2, 8     ; r1 = the word at r2 + 8          (C4 81 42 08)
    LDR3  r1, r2, r3    ; r1 = the word at r2 + r3         (C4 81 02 03)
    LDRSB3 T, FP, -1    ; T  = the byte at FP - 1, sign-extended
    LDRH3 r0, PC, r5    ; r0 = the halfword at the next instruction + r5 (a table)
    STR3  r1, FP, -8    ; the word at FP - 8 = r1 (a local variable)
    STRB3 r1, PSP, r3   ; the byte at PSP + r3 = r1

The mnemonics follow LDR / STR, with a 3: LDRB3, LDRSB3, LDRH3, LDRSH3, LDR3, STRB3,
STRH3, STR3. The assembler picks byte 2 bit 6 from the third operand: a register
name, or an expression (a constant). Alignment as LDR / STR (the low bits of a
halfword or word address are set to 0). No flags change.

**The registers.**

- The data register must be in the register file (r0 .. r31, T, S, R, L), as for
  LDR / STR.
- The base can be any register (PC: the address of the next instruction); the
  offset register any but PC.
- At most one of base and offset may be a register of stage 3 (PSP, RSP, FP, TMPL,
  TMPH, ST): it comes into the ALU on input b.
- STR3 reads three values (the data, the base, the offset). The register file has
  two read ports, so data, base and offset cannot **all three** be register file
  registers: `STR3 r1, r2, r3` is not allowed (`STR3 r1, r2, 8`, `STR3 r1, PSP, r3`
  and `STR3 r1, r2, TMPL` are).

The assembler gives an error for each; in the processor such an instruction does
nothing.

| stage           | what they do |
|-----------------|--------------|
| 2 decode        | the address is the ALU's sum (`d_addr` = 1): the register of stage 3 (base or offset), if one is, on ALU input b (`d_b_s3`), the other on operand A (a register on port A, PC's next address or the offset as a constant). LDR3 otherwise: base on A, offset on B. STR3 otherwise: the constant part (PC's next address, the imm8, or both added in decode) on ALU input b through `d_imm` (`d_b_imm`), the one register on operand A. STR3: the data on operand B (`d_wdata` = 1) |
| 3 execute       | ALU `ADD` (flags mask 0): `x_addr` = y |
| 4, 5            | as LDR / STR |

### MOV2, MOVI2 (0x83)

    byte 0   0x83
    byte 1   bit 7: 0 = MOV2, 1 = MOVI2
             bit 6: 0 (kept free: with 1 the instruction does nothing)
             bits 5..0: the destination (a register, as MOVR names it)
    byte 2   MOV2:  bits 5..0 the source register (bits 7..6 ignored; the
                    assembler writes 0)
             MOVI2: a signed 8-bit constant, -$80 .. $7F

Move and move immediate, between any registers (neither has to be T):

    MOV2  dst, src      ; dst = src
    MOVI2 dst, imm8     ; dst = imm8, sign-extended to 32 bits

No flags change and the stacks do not move. (As always, a write to ST sets the flags:
that is its destination, not a side effect.)

    MOV2  r1, r2        ; r1   = r2
    MOV2  FP, RSP       ; FP   = RSP
    MOV2  TMPL, PSP     ; TMPL = PSP
    MOV2  r0, PC        ; r0   = the address of the next instruction
    MOV2  PC, r3        ; jump to the address in r3
    MOVI2 r5, -1        ; r5   = $FFFFFFFF
    MOVI2 ST, 0         ; clear all four flags

Only the source is read, so the two registers can be any, both in stage 3 too (PSP,
RSP, FP are read from `stackregs`' own outputs, `d_s3` = 4 .. 6, so `stackregs`'
`sel` is free for the write). MOVI2's constant must be known when
assembling (a number or an equate; not an address: byte 2 takes no relocation).

| stage           | what they do |
|-----------------|--------------|
| 2 decode        | the value on operand B: the source register from the register file, the next address for PC, nothing for a register of stage 3 (`d_b_s3`), or the constant (MOVI2); operand A = 0. ALU `ADD`, flags mask = 0 |
| 3 execute       | ALU y = 0 + B (the stage 3 value for PSP .. ST); the result y goes to the destination: register file (`x_rd`), `stackregs` (SET), `tmplh`, ST (`d_st_we`), or PC (redirect to y) |
| 4, 5            | as ADDR |

One pass; MOV2 PC, .. and MOVI2 PC, .. jump from execute (2 ticks).

### ADD2 (0x90)

    byte 0   0x90
    byte 1   bits 7..6: opx = 00
             bits 5..0: the destination, also source 1 (a register, as MOVR names it)
    byte 2   bits 7..6: (still open; the assembler writes 0, decode ignores them)
             bits 5..0: source 2

The first opcode with two register operands, in the usual layout (byte 1 the
destination, byte 2 a source): the destination is also the first source, so

    dst = dst + src             assembler: ADD2 dst, src

Neither has to be T, and the stacks do not change. The flags are those of ADD
(C Z N V).

    ADD2 r1, r2     ; r1  = r1 + r2
    ADD2 r0, r0     ; r0  = 2 * r0
    ADD2 T, S       ; T   = T + S (S stays; ADD pops it)
    ADD2 FP, r3     ; FP  = FP + r3
    ADD2 r3, PC     ; r3  = r3 + the address of the next instruction
    ADD2 PC, r4     ; jump to the next instruction + r4

The registers are r0 .. r31, T, S, R, L, PSP, RSP, FP, PC, TMPL, TMPH. **At most one
of them may be a register of stage 3** (PSP, RSP, FP, TMPL, TMPH, ST): those reach the
ALU only on input b. `ADD2 FP, PSP` is an error in the assembler; in the processor
it (like a register that does not exist, or opx not 00) does nothing.

| stage           | what ADD2 does |
|-----------------|----------------|
| 2 decode        | operand B: the register of stage 3, if one of them is (`d_b_s3`, nothing from the register file), else source 2; operand A: the other one. A register file register is read on its port (A or B), PC is the next address as a constant. ADD does not care about the order. |
| 3 execute       | ALU `ADD` (carry in 0), flags mask = 1111; the result goes to the destination: a register file register through `x_rd`, `x_result`; PSP / RSP / FP through `stackregs` (SET), TMPL / TMPH through `tmplh`; PC: redirect fetch to `y` |
| 4, 5            | as ADDR |

One pass, as ADDR; ADD2 PC, <src> costs 2 ticks, as ADDR PC, T. Byte 1 bits 7..6
are opx: 0x90 with opx 01, 10, 11 are 3 more opcodes, free for now (they do
nothing).

### ADC2 (0x91) .. CMP2 (0x97)

    byte 0   0x91 .. 0x97
    byte 1   as ADD2: opx = 00, the destination and source 1
    byte 2   as ADD2: source 2

The ops of ADCR .. CMPR (0x51 .. 0x57) with two operands, as ADD2 is ADDR's: opcode
bits 2..0 pick the op the same way. The destination comes first and is the first
operand of a subtraction:

    ADC2 dst, src   ; dst = dst + src + C
    SUB2 dst, src   ; dst = dst - src
    SBC2 dst, src   ; dst = dst - src - (1 - C)
    AND2 dst, src   ; dst = dst & src
    OR2  dst, src   ; dst = dst | src
    XOR2 dst, src   ; dst = dst ^ src
    CMP2 dst, src   ; the flags of dst - src; nothing written, nothing jumps

The flags are those of ADCR .. CMPR (and ADC, SUB, SBC, AND, OR, XOR, CMP): C Z N V
for the arithmetic, C = 1 meaning no borrow; Z N V (V = bit 30) with C unchanged for
the logic ops. The registers, the rule for the registers of stage 3 (at most one of
PSP, RSP, FP, TMPL, TMPH, ST) and the passes through the pipeline are as ADD2.

    ; {r1, r0} = {r1, r0} - {r3, r2}: a 64-bit subtract in four registers
    SUB2 r0, r2
    SBC2 r1, r3

    CMP2 r4, r5     ; then CBR HS: r4 >= r5 (unsigned), CBR LT: r4 < r5 (signed)

**The subtractions in decode.** The register of stage 3, if there is one, is on
operand B (it only comes into the ALU there), the other register on operand A. When
that register is the source (or there is none), dst - src = A - B: the ALU's `SUB` /
`SBC`. When it is the destination (`SUB2 PSP, r3`), dst - src = B - A: the ALU
subtracts the other way round, `RSB` / `RSC`, as SUBR does when the register is the
destination. CMP2 is SUB2 with the write (and for PC the jump) left out.

### ADD3 (0xD0) .. CMP3 (0xD7)

    byte 0   0xD0 .. 0xD7
    byte 1   bits 7..6: opx = 00
             bits 5..0: the destination
    byte 2   bits 7..6: (still open; the assembler writes 0, decode ignores them)
             bits 5..0: source 1
    byte 3   bits 7..6: (still open, as byte 2)
             bits 5..0: source 2

The ops of ADD2 .. CMP2 with three operands, in the usual layout: the destination
need not be a source.

    ADD3 dst, src1, src2    ; dst = src1 + src2
    ADC3 dst, src1, src2    ; dst = src1 + src2 + C
    SUB3 dst, src1, src2    ; dst = src1 - src2
    SBC3 dst, src1, src2    ; dst = src1 - src2 - (1 - C)
    AND3 dst, src1, src2    ; dst = src1 & src2
    OR3  dst, src1, src2    ; dst = src1 | src2
    XOR3 dst, src1, src2    ; dst = src1 ^ src2
    CMP3 dst, src1, src2    ; the flags of src1 - src2, and dst = those flags

The flags are those of ADD2 .. CMP2. **CMP3** sets the flags as CMP2 (of src1 - src2)
and also writes them into the destination as a number, in the order of the flags
register:

    dst = {28 zeros, V, N, Z, C}     bit 0 C, bit 1 Z, bit 2 N, bit 3 V

so a compare's result can be kept, tested later, or combined:

    CMP3 r0, r1, r2     ; r0 = the flags of r1 - r2
    LIT8 2
    AND3 T, r0, T       ; T = Z of it: 2 if r1 = r2, else 0

CMP3's destination cannot be PC (the assembler gives an error; in the processor it
does nothing): a jump takes its target from the ALU result, not the flags. The registers are those MOVR names (r0 .. r31,
T, S, R, L, PSP, RSP, FP, PC, TMPL, TMPH); a PC source is the next instruction's
address, a PC destination a jump (2 ticks).

    ADD3 r1, r2, r3     ; r1 = r2 + r3
    SUB3 T, r4, T       ; T  = r4 - T
    ADD3 FP, FP, r1     ; FP = FP + r1
    ADD3 r0, PSP, r1    ; r0 = PSP + r1 (an address in the parameter stack)
    ADD3 PC, r2, PC     ; jump to the next instruction + r2

One limit comes from stage 3: **at most one source** may be a register of stage 3
(PSP, RSP, FP, TMPL, TMPH, ST), as it only comes into the ALU on input b
(`ADD3 r1, PSP, FP` is not allowed). The destination can be any register:
`ADD3 FP, PSP, r1` sets FP = PSP + r1 in one instruction (PSP, RSP, FP are read from
`stackregs`' own outputs, so its `sel` is free for the write). The assembler gives an
error for two sources in stage 3; in the processor such an instruction (like one with
a register that does not exist, or opx not 00) does nothing.

| stage           | what they do |
|-----------------|--------------|
| 2 decode        | operand B: the source in stage 3, if one is (`d_b_s3`), else source 2; operand A: the other source. A subtraction is source 1 - source 2: when source 1 is on B (it is the one in stage 3), the ALU subtracts the other way round (`RSB`, `RSC`) |
| 3 execute       | the ALU op of opcode bits 2..0, flags mask = 1111; the result goes to the destination as in ADD2. CMP3: the result `r` is the ALU's new flags (`d_res` = 6: `{28'h0, alu_flags}`) |
| 4, 5            | as ADD2 |

### ANDR (0x54), ORR (0x55), XORR (0x56)

    byte 0   0x54 / 0x55 / 0x56
    byte 1   as ADDR

The logic ops between T and a register, as ADDR: the destination first.

    ANDR T, r5      ; T   = T & r5
    ANDR r5, T      ; r5  = r5 & T
    ORR  L, T       ; L   = L | T
    XORR T, S       ; T   = T ^ S (S stays; XOR pops it)

The flags are those of AND, OR, XOR: Z, N, and V = bit 30 of the result; C does not
change (the ALU passes the C flag through). Nothing is pushed or popped. Decode and
execute as ADDR, with the ALU op AND, OR or XOR (carry in: the C flag).

### CMPR (0x57)

    byte 0   0x57
    byte 1   as ADDR

Compare register: the flags of the destination minus the other, as SUB (C Z N V,
C = 1: no borrow, as the 6502); nothing is written, nothing jumps.

    CMPR T, r5      ; flags of T - r5
    CMPR r5, T      ; flags of r5 - T
    CMPR PSP, T     ; flags of PSP - T (e.g. is the stack below a limit in T?)

So a branch after `CMPR <a>, <b>` reads as "a cond b": `CMPR T, r5` then `CBR HS`
jumps if T >= r5 (unsigned), `CBR LT` if T < r5 (signed). Decode as SUBR, with the
write (and for PC the jump) left out: the ALU's `SUB` when T comes first, `RSB` when
the register does.

### SET, SETB (0x4B), SET2, SETB2 (0x8B)

    SET, SETB   byte 0   0x4B
                byte 1   bits 7..4: the condition (as CBR)
                         bits 3..1: 000 (else the instruction does nothing)
                         bit 0:     0 SET (true = -1), 1 SETB (true = 1)

    SET2, SETB2 byte 0   0x8B
                byte 1   bits 7..6: opx = 00
                         bits 5..0: the register (r0 .. r31, T, S, R, L)
                byte 2   as byte 1 of SET

A condition as a value: the register is "true" if the condition holds, else 0. SET
and SET2 give -1 (all bits 1: Forth's true), SETB and SETB2 give 1 (C's true). The
conditions are those of the branches (EQ NE CS/HS CC/LO MI PL VS VC HI LS GE LT GT LE
A TZ), on the flags as they are; TZ tests the register itself: T for SET, the
register for SET2. No flags change, the stacks do not move.

    CMP             ; ( a b ): the flags of a - b
    NIP
    SET     LT      ; T = -1 if a < b (signed), else 0: Forth's <  (with the NIP: ( a b -- f ))

    SET     TZ      ; T = -1 if T = 0, else 0: Forth's 0=, one instruction
    SETB2   r3, HS  ; r3 = 1 if the last compare was >= (unsigned), else 0: C's (a >= b)
    SETB2   r4, TZ  ; r4 = 1 if r4 = 0, else 0: C's !x

| stage           | what SET / SET2 does |
|-----------------|----------------------|
| 2 decode        | the true value (-1 or 1) on operand A, the register on B (for TZ); `d_cond` = the condition, `d_res` = SET (8) |
| 3 execute       | `cond.v` works out the condition (as for a branch, no jump); `r` = A if it holds, else 0 |
| 4, 5            | the write |

### ADDI2, CMPI2 (0x8A)

    byte 0   0x8A
    byte 1   bit 7:     0 (else the instruction does nothing)
             bit 6:     0 ADDI2, 1 CMPI2
             bits 5..0: the register (r0 .. r31, T, S, R, L, or one of stage 3; not PC)
    byte 2   a signed 8-bit constant k (-128 .. 127)

    ADDI2 reg, k    ; reg = reg + k; flags C Z N V (as ADD)
    CMPI2 reg, k    ; the flags of reg - k (as CMP); nothing written

A register and a small constant, without loading the constant first. The register
comes in on operand B, so it can be a register of stage 3 too:

    ADDI2   r1, -5      ; r1 = r1 - 5
    ADDI2   FP, -16     ; 4 words more below FP
    CMPI2   r2, 10      ; then B LT: r2 < 10 (signed)
    CMPI2   T, 0        ; T's flags (Z, N), C = 1

The constant is in byte 2: it must be known when the source is assembled (no address).

| stage           | what ADDI2 / CMPI2 does |
|-----------------|-------------------------|
| 2 decode        | k on operand A; the register on B (register file), or `d_b_s3` (stage 3); ALU `ADD` (ADDI2) or `RSB` (CMPI2: B - A); flags mask = 1111 |
| 3 execute       | ADDI2: the result to the register (stage 3 through `rs`); CMPI2: flags only |

### ABS, CLZ, PCNT (0x89)

    byte 0   0x89
    byte 1   bits 7..6: 00 ABS, 01 CLZ, 10 PCNT (11: the instruction does nothing)
             bits 5..0: the destination (r0 .. r31, T, S, R, L)
    byte 2   bits 5..0: the source (r0 .. r31, T, S, R, L)

    ABS  dst, src   ; dst = |src|; flags Z N V: V = 1 for src = 0x8000_0000, which stays
                    ; (-2^31 has no positive value); C unchanged
    CLZ  dst, src   ; dst = the number of 0 bits above the highest 1 of src, 0 .. 32
                    ; (32 for src = 0); flags Z N, C and V unchanged
    PCNT dst, src   ; dst = the number of 1 bits in src, 0 .. 32; flags Z N

The assembler takes one register for both (`CLZ r4` = `CLZ r4, r4`) and none for T
(`ABS` = `ABS T, T`).

    ABS                 ; Forth's ABS
    CLZ     r1, r2      ; 31 - CLZ: the number of the highest 1 bit (log2)
    PCNT    r3, r3      ; the bits that are set (e.g. in a bitmap of the GC)

| stage           | what they do |
|-----------------|--------------|
| 2 decode        | the source on operand A; ALU `ABS`, `CLZ` or `PCNT` (alu.v); flags mask 1110 (ABS) or 0110 |
| 3 execute       | the long part of the ALU (`y`), into the destination |

### LSL2 .. ROR2 (0x98 .. 0x9C), LSL3 .. ROR3 (0xD8 .. 0xDC)

    byte 0   0x98 LSL2, 0x99 LSR2, 0x9A ASR2, 0x9B ROL2, 0x9C ROR2
    byte 1   bits 7..6: opx = 00
             bits 5..0: the destination, also the value
    byte 2   bits 5..0: the count's register

    byte 0   0xD8 LSL3, 0xD9 LSR3, 0xDA ASR3, 0xDB ROL3, 0xDC ROR3
    byte 1   bits 7..6: opx = 00
             bits 5..0: the destination
    byte 2   bits 5..0: the value's register
    byte 3   bits 5..0: the count's register

The shifts of LSLI .. RORI with the count in a register: its low 5 bits (0 .. 31),
the bits above are ignored. All registers are r0 .. r31, T, S, R, L. The flags are
those of LSLI .. RORI: C the last bit shifted out (unchanged when the count is 0), Z
and N of the result, V of LSL as LSLI (the others 0).

    LSL2 dst, cnt         ; dst = dst << cnt[4:0]
    LSR3 dst, src, cnt    ; dst = src >> cnt[4:0]

    LSL3    T, S, T       ; Forth's LSHIFT ( x u -- x' ) with a NIP after it
    LSR3    T, S, T       ; RSHIFT
    ASR2    r1, r2        ; C's r1 >>= r2 (int)

| stage           | what they do |
|-----------------|--------------|
| 2 decode        | the value on operand A, the count on B; ALU `LSL` .. `ROR` (the shifter takes B[4:0], as for SHI); flags mask 1111 |
| 3 execute       | the shifter's result into the destination |

### MIN2 .. MAXU2 (0xA0 .. 0xA3), MIN3 .. MAXU3 (0xE0 .. 0xE3)

    byte 0   0xA0 MIN2, 0xA1 MAX2, 0xA2 MINU2, 0xA3 MAXU2
    byte 1   bits 7..6: opx = 00
             bits 5..0: the destination, also the first value
    byte 2   bits 5..0: the second value

    byte 0   0xE0 MIN3, 0xE1 MAX3, 0xE2 MINU3, 0xE3 MAXU3
    byte 1   bits 7..6: opx = 00
             bits 5..0: the destination
    byte 2, 3  bits 5..0: the two values

The smaller or larger of two registers, signed (MIN, MAX) or unsigned (MINU, MAXU).
All registers are r0 .. r31, T, S, R, L. Flags: Z and N of the result; C and V
unchanged.

    MIN2  dst, src        ; dst = min(dst, src), signed
    MAXU3 dst, a, b       ; dst = max(a, b), unsigned

    MIN3    T, S, T       ; Forth's MIN ( a b -- m ) with a NIP after it
    MAX3    T, S, T       ; MAX
    MAXU2   r1, r2        ; then MINU2 r1, r3: r1 clamped to r2 .. r3 (unsigned)

The ALU compares with its adder (a - b: the borrow for unsigned, N != V for signed)
and picks one of the two; on a tie the first.

| stage           | what they do |
|-----------------|--------------|
| 2 decode        | the first value on operand A, the second on B; ALU `MIN`, `MAX`, `MINU`, `MAXU`; flags mask 0110 |
| 3 execute       | the picked value into the destination |

**Why only r0 .. r31, T, S, R, L** for the register shifts, MIN .. MAXU, ABS, CLZ,
PCNT and SET2: their results come from the long part of the ALU (`y`), which does not
reach the registers of stage 3 (timing, see cpu.md), and the shifter takes its count
from operand B as it comes from the register file, not from stage 3. The assembler
gives an error for any other register; in the processor such an instruction does
nothing.

## Interrupts and exceptions

### The vector table and VEC

INTR n and EXC n are calls through a **vector table** of 256 entries of 4 bytes:
entry n is at **VEC + 4n**. Each entry is normally a jump to its handler (`B A,
handler`, a CBR, 3 bytes, padded to 4; or a CBRL).

**VEC** (special register 01100, selector 0x2C, in stage 3) holds the table's
address. It is 1 KB aligned: bits 9..0 are always 0 (a write drops them), so the
entry's address is VEC with 4n put into bits 9..0, no adder. After reset VEC is the
start of the boot RAM, 0xF000_0000 (`VEC_RESET`, a parameter of `cpu.v`, the same
as `RESET_PC`): entry 0 is the reset. A program moves the table with `MOVR VEC, T`
(e.g. to a table in the SDRAM) and reads it with `MOVR T, VEC`.

The numbers:

| n       | what |
|---------|------|
| 0       | reset: the processor starts here; INTR 0 jumps here too |
| 1       | exception: an undefined opcode |
| 2, 3    | free for exceptions |
| 4       | exception: CONS, the heap is full (L > HLIM) |
| 5 .. 7  | free for exceptions |
| 8       | exception: PSP overflow (a push below PSPL) |
| 9       | exception: PSP underflow (a pop above PSPH) |
| 10      | exception: RSP overflow (a push or ENTER below RSPL) |
| 11      | exception: RSP underflow (a pop or LEAVE above RSPH) |
| 12 .. 15| free for exceptions |
| 16 .. 23| interrupts from devices: 16 + the line of the interrupt controller (`irqc.v`; in the computer: 16 the display's line interrupt, 17 its frame interrupt, 18 the sound, 19 the serial port) |
| 24 .. 47| free for more lines |
| 48 .. 255 | free: system calls (INTR n from a program) |

### The interrupt flag I

**I = 1**: interrupts from devices are on. Reset clears I. CLI clears it, SEI and
RTI set it, and taking a device's interrupt clears it, so a handler is not
interrupted unless it sets I again itself. ST shows I in bit 4 (read only).
Software INTR, EXC and the exceptions do not change I.

### INTR (0x49)

    byte 0   0x49
    byte 1   n: 0 .. 255

A call through the vector table: push R onto the return stack, R = the return
address, jump to VEC + 4n. S, T and the flags do not change.

    the word at RSP = R, RSP = RSP - 4
    R  = PC + 2         the next instruction (an INTR in the program)
    PC = VEC + 4n

From a program INTR is a system call: the handler returns with RET to the
instruction after it.

**A device's interrupt is an INTR too.** While a device asks (the processor's `irq`
= 1, from the interrupt controller, with the vector in `irq_num`) and I = 1, fetch
hands decode `INTR irq_num` instead of the next instruction from memory, without
moving the PC. Its return address is that PC: the first instruction not done. All
the older instructions are already in the pipeline and finish; none of the younger
ones has been fetched. So the interrupt is **precise**: the handler returns with
**RTI** and the program goes on as if nothing had happened.

Such an INTR is checked again when it gets to execute, a few ticks later: in between
an older instruction may have cleared I (CLI) or served the device, or another device
with a lower line may have asked. It is taken only if irq is still 1, I is still 1 and
irq_num is still its number; then it also clears I. If not, it does nothing at all
and jumps back to its return address, where fetch goes on (and injects the right
INTR, if one is still wanted).

### EXC (0x4A)

    byte 0   0x4A
    byte 1   n: 0 .. 255

An **exception**: as INTR, but the return address is the EXC's own address:

    the word at RSP = R, RSP = RSP - 4
    R  = PC             this instruction
    PC = VEC + 4n

So a RET from the handler runs the failing instruction again (after the handler has
fixed what was wrong); a handler that wants to go on after it adds its length to R
first.

The processor raises exceptions itself, in the same way:

- **An undefined opcode** (byte 0 not in the table above): decode lets it through as
  a NOP and sends fetch back to it; fetch hands decode `EXC 1` there (before any
  interrupt). R = the address of the undefined instruction. (A defined opcode whose
  other bytes ask for something that does not exist, e.g. MOVR with a register
  number that is free, still does nothing.)
- **The heap is full** (CONS with L > HLIM): exception 4. Execute finds it (step 0
  of CONS) and sends fetch back to the CONS with the exception; fetch hands decode
  `EXC 4` there, as for an undefined opcode. R = the address of the CONS, which runs
  again after the RET. See LISP.
- **A stack limit** (exceptions 8 .. 11): a push, pop, ENTER or LEAVE that would take
  PSP or RSP past its limit. Execute finds it before the instruction changes anything
  and sends fetch back to it, as for CONS. See The stack limits.

So the processor raises an exception in one way, wherever it finds it: a redirect
back to the failing instruction with the exception's number (`redirect_exc`,
`redirect_exc_n` from decode or execute), and fetch injects `EXC n` there. Only the
EXC knows about the vector table.

An exception is found before the instruction changes anything, so it is precise too.

### CLI (0x34), SEI (0x35), RTI (0x36)

    byte 0   0x34 / 0x35 / 0x36     no operands

CLI: I = 0. SEI: I = 1. RTI: RET (PC = R, pop the return stack into R), and I = 1.

A device can only interrupt after the instruction that sets I = 1; an INTR already on
its way when CLI takes effect is turned down in execute, so nothing between CLI and
SEI is interrupted.

A routine that does not know whether its caller has interrupts on uses PUSHF, CLI ..
POPF instead of CLI .. SEI: POPF gives I back as it was, so critical sections nest.

### PUSHF (0x38), POPF (0x39)

    byte 0   0x38 / 0x39     no operands

The whole of ST, the flags and I, onto the return stack and back, as PUSHS / POPS do
with S (the top of the return stack is R):

    PUSHF   push R onto the return stack, R = ST    (bits 3..0 V N Z C, bit 4 I, 0 above)
    POPF    ST = R: the flags = R[3:0], I = R[4];   pop the return stack into R

POPF is the one instruction besides CLI, SEI and RTI that changes I; MOVR ST, T and
the other writes of ST leave it as it is. Like CLI it keeps fetch from injecting an
interrupt while it is in execute (`ie_off`), so a POPF that clears I is never
interrupted after it.

    critical:
            PUSHF               ; save the flags and I
            CLI
            ...                 ; nothing interrupts this
            POPF                ; I as it was: 1 only if it was 1 before

Both are checked against the stack limits of RSP (an overflow / underflow raises
exception 10 / 11).

| stage           | PUSHF | POPF |
|-----------------|-------|------|
| 2 decode        | R on port A, the push of RSP (`d_wdata` = A); `d_s3` = 3 (ST), the result R = s3 | R on port A, the pop of RSP into R; `d_st_we`, `d_ie` = 11 |
| 3 execute       | stores R, R = {I, V N Z C} | flags = A[3:0], I = A[4] (`rs`) |
| 4, 5            | the store; the write of R | the load into R |

### WAIT (0x37)

    byte 0   0x37

Waits until a device asks for an interrupt, then goes on with the next instruction.

- **I = 1**: the interrupt is taken right after the WAIT: the handler runs, and its
  RTI comes back to the instruction after the WAIT.
- **I = 0**: the WAIT ends all the same, but nothing is taken; the interrupt waits
  for SEI (or POPF, RTI). So a program can check and sleep without a race:

        idle:   CLI
                ...                 ; anything to do? then do it, B A, idle
                WAIT                ; nothing: wait (an interrupt that came after
                SEI                 ;  the check ends the WAIT at once); its handler
                B       A, idle     ;  runs here

"Asks" is the interrupt controller's request (`irq`): a line that asks, whose bit in
MASK is 1 and that is of a higher priority than every line in service. Execute holds
the WAIT (stage 4 gets bubbles, nothing behind it moves) until irq is 1, a tick
later; then the WAIT is a jump to the next instruction, so fetch starts again there
and injects the interrupt before it (with I = 1). A WAIT costs 2 ticks when a device
already asks.

| stage           | what WAIT does |
|-----------------|----------------|
| 2 decode        | the next address on operand A, a jump (always) to it; `d_wait` |
| 3 execute       | held while irq (through a register) is 0: `forward` holds stage 3 as for a load-use wait; then the jump |
| 4, 5            | nothing |

### The stack limits

Four registers of stage 3 hold the limits of the two stacks. Each is the lowest or
highest value its pointer may take; bit 0 turns its check on (the pointers are word
aligned, so bits 1..0 are not part of a limit):

| register | selector | the check (bit 0 = 1) | exception |
|----------|----------|-----------------------|-----------|
| PSPL     | 0x2D     | a push of PSP below PSPL: overflow  | 8  |
| PSPH     | 0x2E     | a pop of PSP above PSPH: underflow  | 9  |
| RSPL     | 0x2F     | a push of RSP (or ENTER) below RSPL: overflow | 10 |
| RSPH     | 0x30     | a pop of RSP (or LEAVE) above RSPH: underflow | 11 |

Reset clears all four: no checks. A program sets them with MOVR, MOV2, MOVI2, ADDI2,
... like any register of stage 3 (`MOVR PSPL, T`), and reads them back the same way.

A stack grows down: a push stores at the pointer and then takes 4 off it, a pop adds
4 and then loads. For a stack in the words from A up to B - 4, the pointer starts
at B - 4 (empty) and is never below A - 4 (full):

    PSPH = (B - 4) | 1          ; the highest PSP: the stack is empty
    PSPL = (A - 4) | 1          ; the lowest PSP: the stack is full

The check is made on the pointer as it is before the instruction:

| instruction | fails when | |
|-------------|-----------|-|
| a push (DUP, OVER, DIP, TUCK, PUSH, PUSHS, PUSHF, the calls) | ptr - 4 < LO | ptr[31:2] <= LO[31:2] |
| a pop (DROP, NIP, DRIP, ROT, DROT, ADD .. XOR, TADD, TSUB, CONS, POP, POPS, POPF, RET, RTI, UNEXT / NEXT R at the end of the loop) | ptr + 4 > HI | ptr[31:2] >= HI[31:2] |
| ENTER n | RSP - 4 - 4n < RSPL (or below 0) | |
| LEAVE | FP + 4 > RSPH | FP[31:2] >= RSPH[31:2] |

When the check fails, the instruction does **nothing at all** (no store, no load, no
register, flag or pointer changes) and the processor raises the exception there, as
CONS does: R = the address of the instruction, and a RET from the handler runs it
again. So a handler can grow the stack (move the limit, or the stack) and return, or
report the error and go elsewhere.

    povf:   ...                 ; exception 8: the parameter stack is full
            MOVI2   PSPL, 0     ; e.g.: the check off (or a lower limit)
            RET                 ; the instruction runs again

**INTR and EXC are never checked**, so a handler can always be entered (keep a few
words free below RSPL for that). ROT and DROT are checked at their first step (a pop),
CONS at its first step for the pop of its last one: none is stopped halfway. MOVR,
INCR, ADDI2, ... that write PSP or RSP directly are not checked either: that is how a
program switches stacks.

| stage           | what the check does |
|-----------------|---------------------|
| 2 decode        | `d_chk` bit 0 with each push and pop (not INTR, EXC, the second step of ROT / DROT); bit 1 for CONS's first step (its pop of PSP); ENTER puts 4n on `d_imm` |
| 3 execute       | compares PSP, RSP, FP and RSP - 4n with the limits; on a failure `act` = 0 (nothing is written or stored) and a redirect back to the instruction (`d_pc`) with the exception: fetch injects `EXC n` there |

### The interrupt controller: priorities and nesting

The devices' lines go to the interrupt controller (`irqc.v`, at 0xFFFF_0400 in the
computer). A device asks while its irq is 1 (a level), until its handler has served
it. Line k is vector 16 + k; **the lower the line, the higher its priority**.

- Of the lines that ask (and whose bit in MASK is 1), the controller offers the
  processor the one of the highest priority (`irq`, `irq_num`).
- When the processor takes a device's INTR it tells the controller (`irq_ack`,
  `irq_ack_num`): that line goes **in service** (its bit in ISR).
- While lines are in service, the controller offers only lines of a **higher priority
  than all of them**: never the handler's own line, nor any below it.
- The handler ends with **EOI** (a write to the controller's +12): the line of the
  highest priority in service is out of service again, which is the handler's own.

So a handler may set I again (SEI) as soon as it has saved what it must: from then on
only a more urgent device can interrupt it, and that one's handler nests inside it.
A handler that does not set I runs to its end uninterrupted, as before. Either way it
does the EOI with I = 0, just before RTI.

| +  | register | |
|----|----------|-|
| 0  | PENDING  | read: the lines that ask now |
| 4  | MASK     | bit k = 1: line k may interrupt; after reset 0 |
| 8  | NUMBER   | read: the vector offered now (16 + k), 0 if none |
| 12 | ISR / EOI | read: the lines in service; write (any value): EOI |

A device whose cause is only a moment (the display's line and frame interrupts) keeps
it in a flag of its own, which the handler clears; so every line is a level.

### A device's handler

The handler must keep what it changes. The return address is in R (the old R on the
return stack), S and T are the program's, and the flags must stay too, e.g. between a
CMP and its CBR:

    dev:    DUP                 ; keep T (and S)
            MOVR    T, ST       ; the flags
            PUSH                ; onto the return stack (R too)
            ...                 ; serve the device (it stops asking); registers it uses
                                ; must be its own, or saved
            SEI                 ; (if it may take long: more urgent devices may come in)
            ...
            CLI
            STR3    rX, rC, 12  ; EOI (rC: the controller)
            POP
            MOVR    ST, T       ; the flags back (I stays 0)
            DROP
            RTI                 ; back, I = 1

Or with PUSHF and POPF, which keep the flags (and I) on the return stack and leave T
and S alone:

    dev:    PUSHF               ; push R, R = ST: the flags, I = 0
            ...                 ; serve the device
            STR3    rX, rC, 12  ; EOI
            POPF                ; the flags back, I = 0 (as PUSHF found it)
            RTI                 ; back, I = 1

TMP needs no saving: nothing comes between the steps of ROT, DROT and CONS. TMPL and
TMPH do, if the handler uses MULS or DIVS.

| stage           | what INTR / EXC does |
|-----------------|----------------------|
| 1 fetch         | a device's INTR or an exception's EXC: made in `irq_sequence.v`, `f_inject` = 1, the PC does not move; after it fetch waits for the jump |
| 2 decode        | 4n on port A as a constant; R on port B (the data of the push); the return address in `d_imm`; `d_vec` = 1, `d_hw` = 1 for a device's INTR |
| 3 execute       | push R through `stackregs` (RSP), R = `d_imm` (`d_res` = 7); redirect to {VEC[31:10], 4n}. A device's INTR: the check (above), then I = 0; turned down: no push, no write, a jump to `d_imm` |
| 4 memory access | the store of the push |
| 5 writeback     | writes the return address into R |

INTR and EXC cost 2 ticks and a store (and the fill of the handler's line, and the
entry's jump). From a device asking to the INTR in execute: about 4 ticks.

## LISP

The opcodes in this part make the processor suitable for LISP: lists, allocation and
tagged values. They fix one representation of LISP values; the rest of the instruction
set does not depend on it.

### Tags

A LISP value is one 32-bit word. Its low 2 bits are its **tag**:

| tag | what | the word |
|-----|------|----------|
| 00  | fixnum | a 30-bit signed integer n, as n * 4: ADD, SUB, CMP and the compares work on it unchanged |
| 01  | cons | the address of a cons cell + 1 |
| 10  | other object | the address of an object with a header word + 2 (strings, vectors, symbols, closures, ...) |
| 11  | immediate | NIL, T, characters, ... (e.g. NIL = 3; a character c = c * 256 + $0B) |

A **cons cell** is 8 bytes, 8-aligned: the car is the word at the cell, the cdr the word
after it. With the tag, the car is at the pointer - 1 and the cdr at the pointer + 3.

**L is the allocation pointer**: the tagged address (+ 1) of the next free cons cell.
**HLIM** (special register 01011, selector 0x2B, in stage 3) is the **heap limit**: the
largest L at which CONS allocates. Reset clears HLIM to 0, so CONS traps until the
program has set up a heap (L, HLIM).

    LIT24 heap + 1
    MOVR  L, T          ; the first cell at `heap`
    LIT24 heap_end - 7
    MOVR  HLIM, T       ; the last cell at heap_end - 8

HLIM can be named wherever MOVR names a register (MOVR, ADDR .. CMPR, INCR .., MOV2,
MOVI2, ADD2 .., ADD3 ..). As the other registers of stage 3 it comes into the ALU on
input b only: in ADD2 .. CMP3, at most one operand of PSP, RSP, FP, TMPL, TMPH, ST, HLIM.

### CAR (0x2C), CDR (0x2D)

    byte 0   0x2C / 0x2D    no operands

    CAR     T = the word at T - 1       ( cons -- car )
    CDR     T = the word at T + 3       ( cons -- cdr )

Loads into T, with the address worked out from T as LDR3 does (`LDR3 T, T, -1` and
`LDR3 T, T, 3` do the same in 4 bytes). The tag is not checked: CAR of something that
is not a cons loads from wherever its word points. (Use TTAG first, or keep the check
in the compiler.) No flags change; the stacks do not move.

| stage           | what CAR / CDR does |
|-----------------|---------------------|
| 2 decode        | reads T on port A; the offset -1 / 3 as a constant on port B; ALU `ADD`, `d_addr` = 1 (the address is ALU y); a load, destination T |
| 3 execute       | `x_addr` = T - 1 / T + 3 |
| 4 memory access | loads the word |
| 5 writeback     | writes it into T |

An instruction right after CAR / CDR that reads T waits a tick (load-use), as after
any load. `CDR CAR` is CADR, `CDR CDR` CDDR, and so on.

### RPLACA (0x2E), RPLACD (0x2F)

    byte 0   0x2E / 0x2F    no operands

    RPLACA  the word at T - 1 = S       ( obj cons -- obj cons )
    RPLACD  the word at T + 3 = S

Store S into the car / the cdr of the cons in T. The stack does not change (drop what
is not needed after it, e.g. with NIP). As STR3 with an imm8 offset, the constant
part of the address goes on ALU input b (`d_b_imm`), so T (the base) and S (the
data) are both free on the two read ports. One pass, a store.

### CONS (0x31)

    byte 0   0x31           no operands

Makes a new cons cell: ( car cdr -- cell ). S is the car, T the cdr; the new cell
comes out in T, tagged (its address + 1).

    if L > HLIM (unsigned):   the trap (below)
    else:
        the word at L - 1 = S           the car
        the word at L + 3 = T           the cdr
        T = L                           the cell
        PSP = PSP + 4, S = the word at PSP     pop the parameter stack into S
        L = L + 8                       the next cell

    before:  ... x a  S=car  T=cdr
    after:   ... x    S=a    T=cell      the word at cell - 1 = car, at cell + 3 = cdr

**The trap.** When the heap is full (L > HLIM), CONS does not allocate: it raises
**exception 4** (see Interrupts and exceptions): `EXC 4` in its place, so entry 4 of
the vector table (VEC + 16; 0xF000_0010 after reset) is called. As for every
exception, R gets **the CONS's own address**, not the next instruction's: the
handler collects garbage (or gets more memory: it raises HLIM, or sets L to a free
area), then returns with RET, and the CONS runs again. S, T, the parameter stack and
the flags are as they were before the CONS, so the car and the cdr in S and T are
roots for the garbage collector. If the handler frees nothing, the CONS traps again:
the handler must decide what "out of memory" does.

    ; the vector table, in the boot RAM
            B     A, start          ; $F000_0000: 0, reset
            ...
            B     A, gc             ; $F000_0010: 4, CONS traps here
            ...
    gc:     ...
            RET                     ; the CONS again

CONS is issued as **four steps** by the sequencer (`stage2/sequencer.v`), each one
pass through the pipeline. Nothing can come between them, not even an interrupt.

| step | what it does |
|------|--------------|
| 0    | the check: the ALU works out HLIM - L (`RSB`, L on operand A, HLIM on input b); its borrow is the trap. **Trap**: exception 4: a redirect back to the CONS (its address in `d_imm`) with `redirect_exc` = 1, `redirect_exc_n` = 4, which throws away steps 1 .. 3; fetch then injects EXC 4 at the CONS. **No trap**: nothing (a bubble) |
| 1    | the word at L - 1 = S (L on operand A, -1 on input b through `d_imm`, S on operand B as the data) |
| 2    | the word at L + 3 = T, T = L |
| 3    | PSP = PSP + 4, S = the word at PSP (the pop, as NIP); L = L + 8 (the ALU, on the second write port W2) |

Step 0 writes nothing and stores nothing, trap or not (`d_trap`; see
`stage3/execute.v`): the push of R and R = the CONS's address are the EXC's.

A CONS that allocates takes 4 ticks and three memory accesses (two stores, a load);
one that traps costs the 2 ticks of the redirect back to it, then those of the EXC
(2 ticks and a store) and the fill of the handler's line.

### TADD (0x32), TSUB (0x33)

    byte 0   0x32 / 0x33    no operands

Tagged add and subtract, as SPARC's TADDcc / TSUBcc: ADD and SUB for fixnums.

    T = S + T  /  S - T, pop the parameter stack into S      ( a b -- a+b ) / ( a b -- a-b )

    flags:   C, Z, N as ADD / SUB
             V = signed overflow, **or** the low 2 bits of S or T are not 00 (one of
                 them is not a fixnum)

The result is computed and written whatever the tags are; V says whether it is a
fixnum sum. So the fast path of LISP's `+` is two instructions:

    TADD
    CBR  VS, generic_add     ; not both fixnums, or overflow: the slow path

The slow path finds S and T where they were not: the result in T and the pop are done.
When it must see the operands again, the compiler keeps a copy (`OVER OVER TADD`).

Through the pipeline they are ADD and SUB with ALU op `TADD` / `TSUB` (`stage3/alu.v`).

### LSLI, LSRI, ASRI, ROLI, RORI (SHI, 0x47)

    byte 0   0x47
    byte 1   bits 7..5: the op: 000 LSL, 001 LSR, 010 ASR, 011 ROL, 100 ROR
                        (101 .. 111: the instruction does nothing)
             bits 4..0: the count n, 0 .. 31

T shifted or rotated by a constant count: the ALU's 32-bit shifts, which shift by
`b[4:0]` (decode puts n on operand B, as the shifts by one put 1 there).

    LSLI n      T = T << n                     ; byte 1 = 000 n
    LSRI n      T = T >> n, 0s in              ; byte 1 = 001 n
    ASRI n      T = T >> n, the sign kept      ; byte 1 = 010 n
    ROLI n      T rotated left by n            ; byte 1 = 011 n
    RORI n      T rotated right by n           ; byte 1 = 100 n

    flags:   C = the last bit shifted out (unchanged when n = 0)
             Z, N of the new T
             V = LSLI: T << n overflows (signed), as LSL; the others 0

For LISP: `ASRI 2` untags a fixnum, `LSLI 2` tags one; `LSRI 8` gets a character's
code. For C: any shift by a constant in one instruction.

### TTAG (0x87)

    byte 0   0x87
    byte 1   the mask
    byte 2   the value

Tests the tag of T: Z = ((T & mask) == (value & mask)), on the low 8 bits of T. T and
the stacks do not change; only Z is set (C, N, V unchanged). Then CBR EQ / NE (or
CJMPL) branches on it.

    TTAG 3, 0       ; a fixnum?
    TTAG 3, 1       ; a cons?
    TTAG 3, 2       ; another object?
    TTAG $FF, $0B   ; a character (low byte $0B)?

| stage           | what TTAG does |
|-----------------|----------------|
| 2 decode        | reads T on port A; {mask, value} as a constant on port B; ALU op `TTAG`; flags mask = 0010 (Z) |
| 3 execute       | the ALU's y = (T ^ value) & mask (low 8 bits), Z = (y == 0); nothing written |

Byte 1 is all mask (no opx bits).

### LISP with the rest of the instruction set

| LISP | mp32 |
|------|------|
| `(car x)`, `(cdr x)`, `(cadr x)` | CAR, CDR, CDR CAR |
| `(cons a d)` | CONS |
| `(rplaca c v)` | (v c) RPLACA |
| `(+ a b)` on fixnums | TADD, CBR VS, slow |
| `(consp x)`, type dispatch | TTAG 3, 1 / CBR EQ; a jump table: LIT8 3, AND, ... ADDR PC, T |
| `(funcall f)`, a closure call | the code address in T: PUSH EXEC (push R, R = T; then PC = R, R = the return address) |
| a tail call | MOVR PC, T, or CBR A, f |
| `(eq a b)` | CMP, CBR EQ |
| `(null x)` | TTAG $FF, NIL (with NIL = 3) |
| fixnum to integer and back | ASRI 2, LSLI 2 |

## Sequences

Forth words made of several opcodes. The return stack ends as it started.

| word | stack effect          | opcodes |
|------|-----------------------|---------|
| >R   | ( a -- )  R: ( -- a ) | PUSH DROP |
| R>   | ( -- a )  R: ( a -- ) | DUP POP |
| n    | ( -- n )              | DUP LIT8 / LIT16 / LIT24 n |
| (funcall) | ( f -- f )  R: ( -- ret ) | PUSH EXEC (a call to the address in T) |
| FOR .. NEXT | ( n -- )  the body n + 1 times | PUSH DROP ... NEXT R, body (the body in one line: ... UNEXT body) |
| =    | ( a b -- f )          | CMP NIP SET EQ |
| <    | ( a b -- f )          | CMP NIP SET LT |
| U<   | ( a b -- f )          | CMP NIP SET LO |
| 0=   | ( a -- f )            | SET TZ |
| 0<   | ( a -- f )            | CMPI2 T, 0 SET MI (or ASRI 31) |
| ABS  | ( a -- u )            | ABS |
| MIN  | ( a b -- m )          | MIN3 T, S, T NIP |
| MAX  | ( a b -- m )          | MAX3 T, S, T NIP |
| LSHIFT | ( x u -- x' )       | LSL3 T, S, T NIP |
| RSHIFT | ( x u -- x' )       | LSR3 T, S, T NIP |
| 1+ .. n+ | ( a -- a+n )      | ADDI2 T, n (n = -128 .. 127) |

ROT and -ROT are single opcodes now (ROT, DROT). Without them they would take 4
opcodes, the shortest possible with the others: `PUSH DRIP DUP POPS` and
`PUSHS NIP TUCK POP`.
