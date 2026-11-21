# mp32 CPU

A 32-bit pipelined processor for the Tang Nano 20K, in front of the cache in
`mp32/cache` (8 MB SDRAM, 16-byte lines).

## Address map

| addresses                 | what                                   |
|---------------------------|----------------------------------------|
| 0x0000_0000 - 0x007F_FFFF | SDRAM, 8 MB, through the cache          |
| 0xF000_0000 - 0xF000_1FFF | block RAM, 8 KB (`stage4/bram.v`)       |
| 0xFFFF_0000 - 0xFFFF_FFFF | I/O, 64 KB                              |
| anything else             | nothing: reads 0, writes ignored        |

The block RAM's base and size are parameters of `stage4/membus.v`.

## Registers

- 32 general registers, 32 bits each (r0 .. r31). r0 is a normal register.
- 4 special 32-bit registers: T, S, R and L, reached only by special opcodes.
  In an instruction (MOVR), the special registers are numbered: T, S, R, L 00000 ..
  00011 (register file); PSP, RSP, FP 00100 .. 00110, PC 00111, TMPL, TMPH 01000,
  01001, ST 01010, HLIM 01011 (stage 3 and fetch). All 5 bits count: two selectors name the same register
  exactly when they are equal. A special selector with bits 4..2 not 000 is not a
  register of the register file (it never writes one, and reads as 0): stage 3
  reads or writes the register itself, and decode sends no value for it
  (`d_*_use` = 0, so no forwarding).
  T is the top of the parameter stack and S the second (see DUP in `isa.md`); the
  rest of the parameter stack is in memory at PSP. R is the top of the return stack.
  **L is the allocation pointer of LISP**: the tagged address of the next free cons
  cell, which CONS gives out and steps by 8 (see LISP in `isa.md`).
- 3 stack and frame registers of 32 bits, in stage 3 (execute, `stage3/stackregs.v`).
  Instructions read them from the module's own outputs (`d_s3` = 4 .. 6), not through
  its `sel`, so one of them can be read while another is written (`MOV2 FP, PSP`):
  - **PSP**, the parameter stack pointer
  - **RSP**, the return stack pointer
  - **FP**, the frame pointer

  Only special opcodes reach them. Reset does not change them (0 after loading the
  FPGA). The stacks grow down one word (4 bytes) at a time and point to the next
  free word: push stores, then decrements; pop increments, then loads. Loads and
  stores can use any of them as a base with a signed offset.
- The flags C (carry), Z (zero), N (negative), V (overflow), in stage 3 next to the
  ALU (`stage3/flags.v`).
- **ST**, the status register (selector 0x2A), in stage 3: the four flags in its low
  bits, bit 0 C, bit 1 Z, bit 2 N, bit 3 V; bits 31..4 read as 0. A write to ST sets
  all four flags from bits 3..0 (bits 31..4 are dropped) and wins over the flags the
  same instruction's ALU op sets: `ADDR ST, T` makes ST = ST + T. It is read
  through `d_s3` = 3 and written with `d_st_we` (`stage3/execute.v`). Like the other
  registers of stage 3 it comes into the ALU on input b only. *(Bits 31..4 free for
  more status bits.)*
- **HLIM**, the heap limit (selector 0x2B), 32 bits, in stage 3 (`stage3/execute.v`):
  the largest L at which CONS allocates; when L > HLIM, CONS traps to the GC vector.
  Reset clears it (so CONS traps until a heap is set up). Like the other registers of
  stage 3 it comes into the ALU on input b only (`d_s3` = 7).
- TMPL and TMPH, 32 bits each (temp lo / temp hi), in stage 3 next to the ALU
  (`stage3/tmplh.v`): the 64-bit value {TMPH, TMPL} for the ALU's 64-bit shifts.
  Read and written by special opcodes.
- TMP, 32 bits, an internal scratch register in stage 3 (`stage3/scratch.v`). No
  instruction can name it; it carries a value from the first step of ROT or DROT to
  the second, and needs no saving (see the sequencer).
- PC, 32 bits, byte address of the next instruction to fetch. It lives in stage 1
  (`stage1/pc.v`).

## Instructions

- 1 to 4 bytes long, little-endian: the first byte is the one at the PC.
- The length is in the top 2 bits of the first byte:

  | first byte bits 7..6 | length  |
  |----------------------|---------|
  | 00                   | 1 byte  |
  | 01                   | 2 bytes |
  | 10                   | 3 bytes |
  | 11                   | 4 bytes |

- The opcodes are in `isa.md`. 0x00 is NOP.
- **Line boundary rule:** the fetch stage only sees one 16-byte line at a time.
  Bytes an instruction would take from past the end of its line are read as 0. The
  next instruction still starts at PC + length (in the next line). So an instruction
  may only cross the end of a line if the bytes it puts into the next line are 0;
  otherwise the assembler pads with NOPs (0x00) to the start of the next line.

## Pipeline

| stage | name   | folder   | status |
|-------|--------|----------|--------|
| 1     | fetch            | `stage1` | done, tested |
| 2     | decode           | `stage2` | done, tested (`decode.v`: register file, sequencer, decoder) |
| 3     | execute          | `stage3` | done, tested (`execute.v` and its parts) |
| 4     | memory access    | `stage4` | done, tested |
| 5     | writeback        | `stage5` | done, tested |

- **Fetch:** reads lines into the instruction buffer, keeps the PC, hands decode one
  instruction per tick (or the interrupt sequence).
- **Decode:** splits the instruction into its fields and reads the registers. Most
  instructions are one pass through the pipeline; ROT and DROT are issued as two
  steps, CONS as four, by the sequencer (`stage2/sequencer.v`). It holds the register file and T,
  S, R, L (`stage2/regfile.v`):
  - A register is selected with 6 bits: bit 5 = 0 for r0 .. r31 (bits 4..0), 1 for
    a special register (bits 4..0, all 5 counting: 00000 T, 00001 S, 00010 R,
    00011 L here; the others, in stage 3, are not in the register file: never
    written, read as 0). MOVR names them in byte 1; the other special opcodes
    reach them through the selector decode builds.
  - Two read ports (A, B) without a clock, and two write ports for writeback: W
    for any register, W2 for a special register only (`w2_sel`: 00 = T, 01 = S,
    10 = R, 11 = L), for instructions that write two registers, such as DROP. If
    both write the same register, W wins. A register written in the same tick reads
    as the new value.
  - r0 is a normal register. r0 .. r31 are not cleared by reset (0 after loading the
    FPGA); T, S, R, L are cleared by reset, and are also always on outputs t, s, r, l.
- **Execute:** the ALU; works out branch conditions and targets, and memory addresses.
  It holds PSP, RSP and FP, so the stack instructions can work out their memory
  address and step the stack pointer in the same stage, the ALU and its flags
  (`stage3/alu.v`, `stage3/flags.v`), TMPL and TMPH (`stage3/tmplh.v`), the scratch
  register TMP (`stage3/scratch.v`), and the forwarding (`stage3/forward.v`).
- **Memory access:** loads and stores to the SDRAM (through the cache), the mapped
  block RAM and the I/O range. Stage 3 supplies the address and, for a store, the
  data; the data a load reads goes to stage 5 for writeback. Stage 4 has priority
  over stage 1 on the memory bus.
- **Writeback:** writes results back into the register file in stage 2: r0 .. r31
  or a special register T, S, R, L, and a second special register on port W2.

### Stage 1: fetch (`stage1/fetch.v`, `stage1/pc.v`)

- After reset the PC is 0xF000_0000 (`RESET_PC` of `fetch.v`): the processor boots
  from the mapped block RAM, loaded with the FPGA (`BRAM_INIT` of `membus.v`).
- The PC register: at each edge it is reset, loaded (redirect) or stepped by the
  length of the instruction just fetched; load wins over step. `pc` is an output of
  the fetch stage.
- The PC is increased for the next instruction unless an interrupt is pending or
  being taken.
- **Interrupts:** when `irq_pending` is 1, stage 1 injects the interrupt sequence
  (`stage1/irq_sequence.v`, up to 16 instructions) into stage 2, one per tick, with
  `f_inject` = 1 and `f_pc` = the PC, without changing the PC. Then it fetches nothing
  until a redirect. The sequence must acknowledge the interrupt (or turn interrupts
  off) and end with a jump to the handler. A redirect from an older instruction in
  the middle of a sequence throws it away; if the interrupt is still pending the
  sequence starts again at the new PC. *The sequence itself is a placeholder until
  the instruction set is defined.*
- Loads a whole cache line into a 16-byte instruction buffer (IB).
- Gives decode `f_pc`, `f_instr` (4 bytes from the PC, 0 past the end of the line)
  and `f_len`, one instruction per tick while the PC stays in the IB's line.
- `stall` from decode holds the outputs; `redirect`/`redirect_pc` from a later stage
  moves the PC and throws away the instruction in the outputs.
- Line port: `line_sel`, `line_addr[31:4]` held until `line_ready`; `line_data` is
  128 bits, byte k of the line in bits 8k+7..8k.

Files: `pc.v`, `irq_sequence.v`, `fetch.v`. Tests: `stage1/pc_tb.v` and `stage1/fetch_tb.v`, run with `make test` in `stage1`. With a memory
of 1..8 ticks latency it runs at about 0.46 instructions per tick, because every new
line costs a fill.

### Stage 2: the decoder (`stage2/decode.v`)

The top of stage 2: the register file, the sequencer, and the decoder that turns
the instruction from fetch (`f_instr`, 1 to 4 bytes) into the two operands and the
control word of execute (see execute.v).

- **Operands:** each comes from a register (`d_*_use` = 1: the register file, read
  with `d_*_sel`, forwarded in execute) or is a value made here (`d_*_use` = 0): a
  LIT's constant (sign-extended), a jump's target, a return address, the PC, the
  shift amount 1, the 0 of NEG.
- **Addresses:** next = PC + length; one adder makes target = next + the offset of
  CBR, CBRL, JSRS, JSR, JSRL; CJMPL's target is {PC[31:4], the offset in the line}.
- **Calls** (JSRS, JSR, JSRL): decode redirects fetch itself as execute takes the
  call (1 tick); execute pushes R and writes the return address into R. When
  execute jumps in the same tick, execute's target wins and the call is thrown
  away. `redirect` / `redirect_pc` to fetch are execute's and decode's together.
- **MOVR / ADDR / ADCR / SUBR / SBCR:** byte 1 is decoded into the register file
  selector, or one of the stage 3 registers (PSP, RSP, FP, TMPL, TMPH: through
  `stackregs` / `tmplh`), or PC.
- **ADDR .. CMPR (0x50 .. 0x57):** the ALU op from opcode bits 2..0 (ADD, ADC, SUB,
  SBC, AND, OR, XOR, SUB for CMPR). SUBR, SBCR and CMPR with the register first
  (register - T) use the ALU's reverse subtract (RSB, RSC: b - a), as operand B is
  the register. CMPR writes nothing.
- **INCR .. DECWR (0x44):** byte 1 bit 7 = dec, bit 6 = by 4, bits 5..0 any register.
  The register on operand B, the constant on A: `ADD` or `RSB`, all flags.
- **ENTER, ENTER2, ENTER3 (0x46, 0x86, 0xC6), LEAVE (0x30):** one pass each, through
  the `stackregs` ops ENTER and LEAVE, which write RSP and FP in the same tick. ENTER:
  the word at RSP = R (operand A), R = the old FP (`d_s3` = 6), the size on operand B
  (the offset): n words, made 4n bytes in decode (two 0 bits below n). LEAVE: FP = R (operand A, as `w_data`), R = the word loaded
  from FP + 4.
- **LDR / STR (0x84 / 0x85):** byte 1 bits 7..6 the size, bits 5..0 the data register
  (register file only); byte 2 bit 7 signed (LDR), bits 5..0 the address register
  (register file, PC, PSP, RSP, FP). The address goes through `stackregs`' addr
  output: `sel` = none (3) gives 0 + offset, the offset being the register.
- **LDR3 / STR3 (0xC4 / 0xC5):** as LDR / STR, the address = base + offset (byte 2
  bit 6: byte 3 an imm8 or an offset register) through the ALU (`d_addr` = 1). For
  STR3 the constant part of the address can go on ALU input b through a new path
  (`d_b_imm`, `d_imm`), so both operands are free for the register part and the
  data. Not three register file registers in STR3 (two read ports).
- **MOV2 / MOVI2 (0x83):** byte 1 bit 7 picks MOV2 (byte 2 = the source register) or
  MOVI2 (byte 2 = a signed 8-bit constant); bit 6 must be 0. The value goes through
  the ALU as 0 + operand B with no flags, to any destination. Both registers may be
  in stage 3.
- **ADD2 .. CMP2 (0x90 .. 0x97):** the ops of ADDR .. CMPR (opcode bits 2..0) with
  two register selectors (byte 1 the destination and source 1, byte
  2 source 2). A register of stage 3 goes on operand B (the ALU's b), the other on
  A; at most one may be in stage 3. Opx (byte 1 bits 7..6) must be 00. A subtraction
  is reversed (RSB, RSC) when the destination is that stage 3 register.
- **ADD3 .. CMP3 (0xD0 .. 0xD7):** the same ops with three register selectors (byte 1
  the destination, bytes 2, 3 the sources). The source in stage 3 (at most one) goes
  on operand B, a subtraction is reversed when that is source 1. CMP3 writes the new flags {V, N, Z, C} into the destination (result
  source `d_res` = 6 in execute); its destination cannot be PC.
- **ROT, DROT:** two steps, by the sequencer (`d_step`).
- **LISP (0x2C .. 0x33, 0x47, 0x87):** CAR, CDR load into T from T - 1, T + 3 (the
  address through the ALU, as LDR3); RPLACA, RPLACD store S there (the offset on
  `d_imm`, as STR3). CONS is four steps (`d_step` 0 .. 3): 0 the check, L on A, HLIM
  on b (`d_s3` = 7), ALU `RSB`, with `d_trap` and a push of R / R = the CONS's PC
  (`d_imm`, `d_res` = 7) that execute only lets happen when it traps; 1, 2 the stores
  of S and T at L - 1, L + 3 (and T = L); 3 the pop into S and L = L + 8 on W2. TADD,
  TSUB are ADD, SUB with ALU ops `TADD`, `TSUB`. LSLI .. RORI (0x47): byte 1 bits 7..5
  the ALU's LSL, LSR, ASR, ROL, ROR, the count (4..0) on operand B. TTAG (0x87):
  {mask, value} on operand B, ALU `TTAG`, flags mask Z.
- Opcodes that are not defined, and MOVR / ADDR .. CMPR with a register that does not
  exist or byte 1 bit 7 set, do nothing (a NOP).
- Size: about 1,170 LUTs, 130 flip-flops and 16 RAM16SDP4 (r0 .. r31 with two read
  ports) (`make size` in `stage2`).

Test: `stage2/decode_tb.v`: the whole pipeline (fetch, decode, execute, memory
access, writeback) on 64 KB of random machine code (every defined opcode, random
operands, some undefined opcodes; the code keeps the line rule), with a code memory
of 1 .. 8 ticks and a data memory of 1 .. 4 ticks. A byte-level reference runs the
same code from PC 0, following every jump, for 40,000 instructions; every register
write, every store and every jump of the pipeline must be the reference's, in
order.

### Stage 2: the sequencer (`stage2/sequencer.v`)

- ROT (0x0E) and DROT (0x0F) are issued as two steps, CONS (0x31) as four, each one
  pass through the pipeline; every other instruction as one. `d_step` (0 .. 3) tells
  decode which step it issues, `d_last` whether it is the instruction's last.
- The instruction stays in fetch's `f_*` for all its steps: the sequencer holds fetch
  with `stall` while the steps before the last go out (and whenever stage 3 does not
  take an instruction, `hold`).
- **No interrupt between the steps:** fetch injects the interrupt sequence only when
  decode takes `f_*`, and it holds `f_*` while `stall` is 1. So TMP, which carries a
  value from step 0 to step 1, never has to be saved by an interrupt handler.
- A redirect starts again at step 0. Redirects come from execute, from the
  instruction just before the one in decode, which is never half issued. The one
  exception is on purpose: the trap of CONS comes from its step 0 and throws away its
  steps 1 .. 3.

Test: `stage2/sequencer_tb.v`, with the real fetch stage, random holds, redirects
and interrupts; checks that the steps of ROT, DROT and CONS always follow each other
directly, with nothing in between, even with an interrupt pending, and that a CONS
whose step 0 traps leaves the next instruction at step 0.

### Stage 3: execute (`stage3/stackregs.v`)

- PSP, RSP and FP. One instruction per tick picks one of them with `sel`
  (00 = PSP, 01 = RSP, 10 = FP, 11 = none) and an operation with `op`:

  | op  | name | `addr` to memory access | register at the edge |
  |-----|------|-------------------------|----------------------|
  | 000 | BASE | ptr + offset            | unchanged            |
  | 001 | PUSH | ptr                     | ptr - 4              |
  | 010 | POP  | ptr + 4                 | ptr + 4              |
  | 011 | SET  | -                       | `w_data`             |
  | 100 | ADD  | ptr + offset            | ptr + offset         |
  | 101 | ENTER | RSP                    | RSP = RSP - 4 - offset, FP = RSP - 4 (both, whatever `sel` is) |
  | 110 | LEAVE | FP + 4                 | RSP = FP + 4, FP = `w_data` (both) |

- `offset` comes sign-extended from decode. `value` is the selected register now
  (to move it into a register). The register changes only when `en` is 1.
- `psp`, `rsp`, `fp` are always on outputs.

Test: `stage3/stackregs_tb.v`, run with `make test` in `stage3`.

### ALU (`stage3/alu.v`) and flags (`stage3/flags.v`)

- No clock. Inputs `a`, `b` (32 bits), `cin` (carry in), `op` (5 bits); outputs `y`,
  `y2` (32 bits) and `flags` = {V, N, Z, C}.
- Ops:
  - ADD, ADC, SUB, SBC;
  - MUL, SMUL: unsigned and signed 32 x 32 -> 64 on the on-chip multiplier
    (`stage3/mul.v`): `y` = low word, `y2` = high word;
  - CSUB: a - b if no borrow, else a;
  - MULS: the step of a 32 x 32 multiply: a + b if cin (else a), on 33 bits, then
    shifted right; `y2[0]` = the bit shifted out (into TMPL[31]);
  - DIVS: the step of a 64 / 32 division: {cin, a} - b if it fits, else {cin, a},
    on 33 bits, then shifted left; C = the bit shifted out, `y2[0]` = the quotient
    bit;
  - AND, OR, XOR, NOT;
  - LSL, LSR, ASR, ROR, ROL: 32-bit, by `b[4:0]`;
  - ROLC, RORC: rotate by one through the carry (33 bits {C, a});
  - ASL: by one, bit 31 kept (2* for signed numbers; V = it overflows);
  - LSL64, LSR64, ASR64, ROL64, ROR64: the 64-bit value {b, a} (a = low word, b =
    high word) shifted by one bit, ROL64 / ROR64 through the carry; `y` is the low
    word of the result, `y2` the high word;
  - TADD, TSUB: ADD and SUB for LISP fixnums, V also set when the low 2 bits of a or
    b are not 00;
  - TTAG: y = (a ^ b[7:0]) & b[15:8] on the low 8 bits, so Z = the tag test.
  The 32-bit ops give `y2` = 0.
- C: the carry out of an add; for a subtract 1 = no borrow (as the 6502); for a
  shift the last bit shifted out. Ops that do not set C (logic, a shift by 0) give
  C = `cin`. Z: the result is 0 (all 64 bits for a 64-bit shift). N: bit 31 of the
  result (bit 63). V: signed overflow of an add / subtract / ASL / LSL (for LSL by
  n: the top n + 1 bits of a are not all equal), bit 30 of the result for AND, OR,
  XOR, NOT, 0 for all other ops.
- One shifter to the right does all five 32-bit shifts and rotates (a left one is
  a right one of the bits reversed).
- `flags.v`: the flags register. Decode gives each opcode a 4-bit mask of the flags
  it updates; they are written as the instruction leaves execute, so the next
  instruction sees them with no forwarding. Reset clears them. Carry in: chosen by
  decode, normally the C flag (for ADC, SBC, ROL64, ROR64, and to keep C for ops that
  do not set it).
- **Two b inputs, two results** (for timing): `b` (operand B, or a register of stage 3,
  or `d_imm`) goes only to the adder, the logic ops and the 64-bit shifts; `bo` (operand
  B itself) to the shifter's amount, the divider, the multiply step, the multiplier and
  TTAG, which never take a register of stage 3. `ya` / `flags_a` are y and the flags of
  the adder and logic ops alone: execute writes the registers of stage 3 (PSP, RSP, FP,
  TMPL, TMPH, ST, HLIM), jumps through the ALU and forms ALU addresses from them (its
  short result `rs`), so no path runs from a register of stage 3 through the divider or
  multiplier back into one. Before this, the core routed at 49 .. 52 MHz in
  `timing/core.v` (the same with and without the LISP opcodes), the path being
  `stackregs` sel -> s3 -> ALU b -> the divider -> y -> r -> FP.
- `mul.v`: one MULT36X36 of the GW2AR with all its registers bypassed (the product in
  the same tick); signed or unsigned (`sgn`). In simulation (`-DMP32_SIM`, set by the
  Makefile) a plain multiply stands in for it.
- Size: about 910 LUTs, 77 carry cells and 1 MULT36X36 (MUL and SMUL share it);
  `make size` in `stage3`.

Tests: `stage3/mul_tb.v`: the multiplier, signed and unsigned, against 64-bit
integer arithmetic. `stage3/alu_tb.v`: every op against a reference written another way (64-bit
integer arithmetic, shifts one bit at a time), on edge values with both carries, at
every shift amount and on 200,000 random cases; 3,000 divisions done with ROL64 and
CSUB as a program would; and the flags register with random
masks, `en` and reset.

### Execute, the whole stage (`stage3/execute.v`)

The wiring of stage 3: forwarding, the ALU (with the multiplier), the flags, the
branch conditions, PSP / RSP / FP, TMP, TMPL / TMPH; stage 3's output registers
`x_*` for stage 4; and the redirect for fetch.

With each instruction decode gives the two operands (`d_a_*`, `d_b_*`) and a
**control word**, held in stage 3 with the instruction:

| field | what it says |
|-------|--------------|
| `d_alu_op` | the ALU op |
| `d_cin` | carry in: 0, 1, the C flag, TMPL[0] (MULS) |
| `d_fmask` | the flags it updates {V, N, Z, C} |
| `d_a_tmpl` | ALU input a = TMPL (else operand A) |
| `d_b_s3`, `d_s3` | ALU input b = the stage 3 value (else operand B); s3 = `stackregs` value (of `d_sp_sel`), TMPL or TMPH |
| `d_res` | the result r: ALU y, operand A, operand B, s3, TMP, ALU y with TMPL[31] in bit 0 (DIVS), the ALU's flags (CMP3), or `d_imm` (CONS's return address) |
| `d_wen`, `d_rd` | the main register write: `d_rd` = r (or the loaded word) |
| `d_x2_wen`, `d_x2_sel`, `d_x2` | the second write: special register `d_x2_sel` = ALU y, y2, operand A or B |
| `d_load`, `d_store`, `d_size`, `d_signed` | memory, as stage 4 |
| `d_wdata` | the store data: operand A or B |
| `d_addr` | the address: `stackregs` addr, or ALU y |
| `d_sp_sel`, `d_sp_op` | `stackregs` (BASE = no change); its offset is operand B, its SET data r |
| `d_tmp_we`, `d_tmp_src` | TMP = operand A or B |
| `d_tl_we`; `d_th_we`, `d_th_y2` | TMPL = r; TMPH = ALU y2 or r |
| `d_tl_shl`, `d_tl_shr` | TMPL shifts left (DIVS) / right (MULS), ALU y2[0] coming in |
| `d_jump`, `d_cond`, `d_tgt` | a jump if the condition holds (TZ: operand B == 0), to operand A or ALU y |
| `d_trap` | CONS step 0: a jump to `GC_VECTOR` when the ALU borrows (L > HLIM); only then do its store, its register write and its `stackregs` op happen |
| `d_hl_we` | HLIM = r |

The table of control words for every instruction is in `stage3/execute_tb.v` (the
part that plays decode); the real decode will make the same.

- **GC_VECTOR** (a parameter, 0xF000_0010 by default: the second line of the boot
  RAM): where CONS traps to.
- **go** = the instruction in execute takes effect at this edge (valid, no stall
  from stage 4, no load-use wait). The registers of stage 3 are written at that
  edge, so the next instruction sees them with no forwarding.
- A load-use wait sends a bubble into stage 4; a stall from stage 4 holds all.
- A jump taken goes out with go: `redirect`, `redirect_pc`, and the instruction
  coming in from decode at that edge is thrown away (`flush` into `forward.v`).
- `advance` tells decode that stage 3 takes its instruction.
- Size: about 2,300 LUTs, 510 flip-flops and the MULT36X36 (`make size-execute`).

Test: `stage3/execute_tb.v`: the real register file, execute, memory access and
writeback, with a memory of 1..4 ticks latency, on a random program of 20,000
instructions of the instruction set: all the stack ops (ROT, DROT as their two
steps), the ALU ops, LIT, MOVR and ADDR with the register file and with PSP, RSP,
FP, TMPL, TMPH and PC, and the jumps (CBR with all conditions, RET, EXC, MOVR PC, T,
ADDR PC, T), each followed by an instruction a taken jump must throw away. A
reference runs the program one instruction at a time; every register write, every
jump, and at the end every register, the flags and the memory are checked.

Test of the LISP opcodes in a real program: `stage2/lisp_tb.v` runs `stage2/lisp.s`
(assembled into `lisp.hex`) through the whole pipeline: it builds a list with CONS,
the third CONS traps to a small GC handler that raises HLIM and returns, the CONS
then allocates; it sums the list with TTAG, CAR, CDR and TADD, untags the sum with
ASRI, checks TADD's V for a non-fixnum and changes a car with RPLACA. The registers,
the cells in memory, L, HLIM and RSP are checked at the end. `stage2/decode_tb.v`
runs the LISP opcodes in its random code too, with a GC handler at its GC vector.

### Branch conditions (`stage3/cond.v`)

- `take` = 1 when the 4-bit condition holds for the flags: EQ NE CS CC MI PL VS VC
  (the 6502's eight; CS is also called HS, CC also LO), HI LS GE LT GT LE (the
  compares after a CMP), A (always), TZ (T == 0, whatever the flags; `tz` comes
  from operand B, where decode puts T for a jump). From 0x0 to 0xD each odd code is
  the opposite of the even one before it.
- No clock: it reads the flags register as it is, so a branch right after the
  instruction that set the flags sees them.
- Jumps redirect fetch from execute. Decode works out the target address (it has
  the PC from fetch) and passes it on port A as a constant; execute checks the
  condition and, when it holds, redirects fetch to operand A. A taken jump costs 2
  ticks (the two instructions behind it are thrown away).
- CJMPL (0x41) jumps within its own line, which is in fetch's buffer: no memory
  access. CBR (0x81) branches relative to the next instruction, -2048 .. +2047
  bytes, CBRL (0xC1) +-512 KB; to another line it costs the fill too. RET (0x01)
  jumps to R (operand A, forwarded) and pops the return stack into R. EXC (0x1F)
  jumps to R and puts the address after it into R (operand B, a constant).
- Calls (JSRS 0x42, JSR 0x82, JSRL 0xC2) always jump and their destination is
  known in decode, so **decode redirects fetch** for them, as it issues the call:
  1 tick (only the instruction in fetch's output is thrown away). Execute then does
  the push of R and R = the return address (operand A, a constant from decode).
  Fetch's redirect: from execute or from decode; when both come in the same tick,
  execute's wins (it is from the older instruction, and it throws the call away).

Test: `stage3/cond_tb.v`: every condition with every combination of the flags and
of T == 0, and
the compare conditions after CMP's flags against integer compares (edge values and
100,000 random pairs).

### TMPL and TMPH (`stage3/tmplh.v`)

- Two visible 32-bit registers next to the ALU, together a 64-bit value {TMPH,
  TMPL}. For DIVS, TMPL shifts left with the quotient bit (the ALU's `y2[0]`)
  coming in (`sh_l`, `sh_bit`), and TMPL[31] goes into bit 0 of the new T. For MULS,
  TMPL shifts right with the ALU's `y2[0]` coming in at the top (`sh_r`), and TMPL[0]
  is the ALU's carry in (add S or not). A 64-bit shift takes `a` = TMPL, `b` = TMPH and writes `y` into TMPL, `y2`
  into TMPH. Special opcodes read them (into a register, through the result) and
  write them (from an operand).
- In execute, so the next instruction always sees what the one before wrote: no
  forwarding. Written as the instruction leaves execute (`en`); `we_l`, `we_h` say
  which. Reset clears them.
- Visible, so an interrupt handler that uses them must save them (unlike TMP).

Test: `stage3/tmplh_tb.v`: the registers against a model, then with the ALU: a
64-bit value rotated 65 times through the carry with ROL64 (it comes back), and
2,000 random runs of 64-bit shifts against 64-bit arithmetic, carry included; and
5,000 64 / 32 divisions with DIVS (33 steps), divisors up to 0xFFFFFFFF; and 5,000
32 x 32 multiplies with MULS (32 steps), half of them adding a start value of T.

### TMP (`stage3/scratch.v`)

- The internal scratch register: written by step 0 of ROT / DROT as it leaves
  execute (`en`: valid, no stall, no load-use wait), read by step 1, which is always
  the very next instruction in execute. So it needs no forwarding.
- Not in the register file, no selector: no instruction can reach it.

### Forwarding (`stage3/forward.v`)

Decode reads the registers a tick before execute uses them. An older instruction
that has not written its register back yet then gives execute the value:

| when decode read, the older one was in | when execute runs, it is in | execute takes it from |
|----------------------------------------|-----------------------------|-----------------------|
| stage 5                                | written                     | (the register file passes it through to decode) |
| stage 4                                | stage 5                     | `w_*` (writeback) |
| stage 3                                | stage 4                     | `x_*` (stage 3's outputs) |

- The youngest wins: `x_*` before `w_*`, then the value decode read.
- **Worked out a tick early:** which write each operand comes from is decided in
  decode's tick, while the instruction is still in decode, and kept in registers
  (`from_x`, `from_x2`, `from_w`, `from_w2` for each operand). The instruction in
  execute now will be in `x_*`, the one in `x_*` now in `w_*`. Execute only switches
  a multiplexer. While execute holds, the registers move with the pipeline: a stall
  from stage 4 keeps `x_*` and drops `w_*`; a load-use wait moves the load from
  `x_*` to `w_*`.
- Both writes of an instruction are forwarded: the main one (`x_rd` / `w_sel`) and
  the second one to a special register (`x2_*` / `w2_*`). Within one instruction
  the main write wins, as in the register file.
- `forward.v` holds stage 3's operand registers and gives the ALU `e_a`, `e_b`.
- **Load-use:** a load's value is known only at the end of stage 4. When execute
  needs the register of a load in stage 4, `load_use` is 1: stage 3 holds and sends a
  bubble into stage 4 (`x_valid` = 0). A tick later the value is on `w_*`.
- **Holding:** while stage 3 holds (stall from stage 4, or load-use), the operand
  registers take the forwarded values every tick, so a value forwarded once stays
  even after its instruction has gone.
- `advance` = no stall from stage 4 and no load-use: stage 3 takes decode's
  instruction at the edge (and decode moves on).
- Decode says with `d_a_use` / `d_b_use` whether an operand comes from a register.
  Only then is it forwarded and can it cause a load-use wait. When it is 0 the value
  stays as decode gave it: a constant made by decode (e.g. the n of LIT), or an
  unused operand. So constants go from decode to execute on port A or B as values,
  as if from a register: there is no separate path for them.
- Not forwarded: the regfile's direct outputs `t`, `s`, `r`, `l` (instructions read
  T, S, R, L through port A or B), and PSP, RSP, FP (they live in stage 3).

Test: `stage3/forward_tb.v` runs a small pipeline of the real register file,
forwarding, memory access and writeback, with a made-up ALU and a memory of 1..4
ticks latency, on 20,000 random instructions using only r0 .. r3, T and S, so nearly
every one depends on the one before. Among them: constants on port A with
`d_a_use` = 0 and a random register field, loads with a second write (often exactly
DROP), two-write instructions without memory, and two-step pairs that carry a value
through the real TMP. Every register write and the memory at the end are checked
against a reference running one instruction at a time.

### Stage 4: memory access (`stage4/memaccess.v`, `stage4/membus.v`, `stage4/bram.v`, `stage4/memsys.v`)

- `memaccess.v` takes stage 3's output registers `x_*`: `x_load` / `x_store`,
  `x_size` (00 = byte, 01 = halfword, 10 = word), `x_signed` (sign- or zero-extend
  a byte or halfword load), `x_addr`, `x_wdata`, `x_wen`, `x_rd`, `x_result` for the
  register write, and `x2_wen`, `x2_sel`, `x2_data` for the second write (a special
  register, passed straight on). It drives the memory bus (`d_sel`, `d_we`, `d_be`, `d_addr`
  (32 bits), `d_wdata`, `d_rdata`, `d_ready`, the cache's handshake) straight from
  `x_*`, and holds stage 3 with `stall` until `d_ready`.
- A store puts the byte or halfword in every lane and picks the lanes with `d_be`;
  a load takes its lane out of the word. Halfwords ignore address bit 0, words bits
  1..0: they are set to 0 on `d_addr`, so the bus sees an aligned address.
- It gives stage 5 `m_valid`, `m_wen`, `m_rd`, `m_data` (the data loaded, or
  `x_result`), and `m2_wen`, `m2_sel`, `m2_data`. While it waits for the bus
  `m_valid` is 0. No redirect: nothing after execute throws instructions away.
- `membus.v` is the memory bus. Two masters: stage 4 (words) and stage 1 (lines,
  its `line_*` port). When both ask in the same tick stage 4 gets the bus; an access
  going on is never broken off. Three slaves picked by the address map: the cache
  (`c_*`, with the new `cpu_rline` output of `cache.v`, the whole line of a read),
  the block RAM (inside the bus) and the I/O (`io_*`, 32-bit, same handshake).
- `bram.v`: the mapped block RAM, one line (128 bits) wide with byte enables, so
  fetch can run a program from it. 8 KB = 4 block RAMs. Answers 1 tick after sel.
  It can be loaded with the FPGA from a `$readmemh` file (parameter `BRAM_INIT`).
- A cache hit or a block RAM access takes 2 ticks, so every load or store stalls at
  least 1 tick.

- `memsys.v` is the memory system that stage 4 and fetch reach: the bus (with the
  block RAM) and the cache with the SDRAM controller under it, on the SDRAM range;
  the I/O port (`io_*`) and the video port (`vid_*`, row bursts straight from the
  SDRAM, ahead of the cache) go out to their devices; the SDRAM pins too.
  Parameters: `CLK_MHZ` (42), `CAS`, `RD_LAT`, `EXT_CLK` (0; see below), the cache's
  size and write-through region, the block RAM's base, size and `BRAM_INIT`.
- At 42 MHz the inverted clock is enough for the SDRAM (up to about 60 MHz, sdram.v):
  `EXT_CLK` = 0, no second clock. (At 63 MHz it would need `EXT_CLK` = 1, a
  phase-shifted clock on `clk_sdram` and `RD_LAT` to go with it, found on the board.)

Tests, run with `make test` in `stage4`:
- `memaccess_tb.v`: the bus played by a model with 1..8 ticks latency.
- `membus_tb.v`: both masters at once against a cache model, an I/O model and the
  real block RAM; checks every read, the priority, and that no access is broken off.
- `memsys_tb.v`: the memory system with the real cache and SDRAM controller and the
  SDRAM model, at 42 MHz: stage 4 (random reads and writes, words and bytes, in four
  SDRAM regions far apart so lines are evicted all the time, one write-through, the
  block RAM, the I/O, the unmapped space), fetch (random line reads) and video row
  bursts all at once; every read checked, everything read back at the end; the
  model checks the SDRAM's timing and refresh.

`make size` in `stage4` shows what the bus and block RAM take on the chip.

### Stage 5: writeback (`stage5/writeback.v`)

- Takes stage 4's output registers `m_valid`, `m_wen`, `m_rd`, `m_data` and drives
  the register file's write port W in stage 2: `w_en = m_valid & m_wen`,
  `w_sel = m_rd` (the 6-bit selector: r0 .. r31, or T, S, R, L), `w_data = m_data`;
  and port W2: `w2_en = m_valid & m2_wen`, `w2_sel = m2_sel`, `w2_data = m2_data`.
- No registers of its own: the register file writes at the end of the tick and
  passes the value through to decode in the same tick.
- `w_*` and `w2_*` also go to execute for forwarding.
- Never stalls. PSP, RSP and FP live in stage 3 and are not written here.

Test: `stage5/writeback_tb.v`, with the real `stage2/regfile.v`, run with
`make test` in `stage5`.

## Timing

Target clock: **42 MHz** (23.8 ns), 126 / 3 (see Clocks). It was 63 MHz (126 / 2);
the core does not reach that now (below), so the computer is brought up at 42 MHz
first. Going to 63 MHz later changes only the clock and `CLK_MHZ`, not the CPU.

**Now** (`timing/core.v`: the five stages with two 8 KB block RAMs, `make timing` in
`timing`; yosys 0.71, nextpnr-himbaechel, three seeds): 54.6 .. 56.8 MHz after the
LISP opcodes and the short result path of execute (49 .. 52 MHz before that, the
same with and without the LISP opcodes). So 42 MHz has about 25 % to spare. The
critical paths, each about 17.5 .. 18.3 ns, two thirds of it routing:

- decode: the instruction from fetch -> the big case of decode -> the register
  file's read address -> the read -> operand B into execute (`fwd.b_val`);
- the stall network: `x_load` / the bus handshake -> `load_use` / `mem_stall` ->
  `advance` -> `go` -> the enables of the registers of stage 3 (the flags);
- execute: a register of stage 3 -> ALU b -> the adder -> the result into
  `x_result`.

For 63 MHz both of the first two must get shorter: a pre-decode in fetch's output
register (the register numbers and the kind of constant worked out a tick early, so
decode reads the register file straight from a register), and `mem_stall` from a
register in stage 4 (which costs about a tick per memory access).

**Earlier** (before ADD3, LDR3 / STR3, MOV2, ENTER / LEAVE, INCR, ST, the LISP
opcodes), measured with yosys 0.71 and nextpnr-himbaechel (Gowin, GW2AR-LV18QN88C8/I7),
`--freq 63`, on the core: fetch, decode, execute, memory access and writeback, with
two 8 KB block RAMs for code and data (no cache, SDRAM or memory bus yet):

| seed | max frequency after routing |
|------|-----------------------------|
| 1    | 68.4 MHz |
| 2    | 67.6 MHz |
| 3    | 72.8 MHz |

So the core passes 63 MHz, with 1 .. 2 ns to spare. (The estimates before routing are
lower, 49 .. 53 MHz: only the routed numbers count.) Used: about 6,500 LUT4 (31 %),
300 ALU, 1,060 DFF, 8 BSRAM, 1 MULT36X36.

The critical path is in execute: from its control registers through forwarding, the
ALU's adder (the carry chain), the flags and conditions, to the second write's data
`x2_data`; about 5 ns logic, 9.6 ns routing. The adders are ripple carry on the
chip's carry chain, which is the fastest form on this FPGA.

With the memory system too (`memsys.v`: bus, block RAM with the code, cache, SDRAM
controller, video port in use; about 6,500 LUT4, 430 ALU, 9 BSRAM):

| seed | forwarding decided in execute | forwarding decided a tick early |
|------|-------------------------------|---------------------------------|
| 1    | 67.1 MHz | 84.9 MHz |
| 2    | 64.4 MHz | 81.6 MHz |
| 3    | 63.0 MHz (fails by a hair) | 77.7 MHz |

With forwarding decided in execute the critical path was there: comparing register
numbers and picking the value (about 4 ns), the ALU's input select, the adder, the
result select. Now that decode works it out a tick early (see Forwarding), the
critical path is from TMPL / the stack pointers through the ALU's adder to
`x2_data`, about 12.9 ns (5.5 logic, 7.4 routing): 63 MHz has 15 .. 35 % to spare.

## Clocks

- The processor and the memory system run on one clock, **42 MHz**, `cpu_clk`.
- It comes from the display's PLL, which makes 126 MHz (5 x the 25.2 MHz pixel
  clock, for the HDMI serializer): 126 / 3. Divide it in the PLL (the rPLL's
  `CLKOUTD3`, its fixed divide by 3), not with a flip-flop in the logic, so it is a
  real clock. (For 63 MHz later: `CLKOUTD` with `SDIV` = 2.)
- The video unit (`display2/video.v`) already has the processor's clock `cpu_clk`
  apart from its pixel clock, with the handover between them; its SDRAM port is on
  `cpu_clk`.
- The SDRAM at 42 MHz: the inverted clock is enough (`EXT_CLK` = 0, sdram.v). At 63
  MHz, just above the about 60 MHz up to which it is, `EXT_CLK` = 1 would need a
  second 63 MHz clock shifted in
  phase. An rPLL shifts only `CLKOUTP` (at the full frequency), so the cleanest is a
  second rPLL (the GW2A-18 has four) giving 63 MHz on `CLKOUT` (`cpu_clk`) and the
  shifted 63 MHz on `CLKOUTP` (`clk_sdram`). The phase and `RD_LAT` must be found on
  the board.

## Open points

- Prefetch the next line into a second buffer, so moving into the next line costs
  no fill.
- Function of R beyond the return stack's top. (L is the allocation pointer of LISP.)
- The GC handler at the GC vector (0xF000_0010) in the boot program.
- 63 MHz: see Timing (a pre-decode in fetch, a registered `mem_stall`).
- `display2`: at 42 and 54 MHz (`make test-clocks`) the video test bench reports 78
  wrong pixels in scrolled.bmp (at 100 MHz none): that picture reads 5 lines past the
  demo pixels, which the processor's random traffic has not written into the SDRAM
  at the slower clocks. The test bench's model, not the video unit; to be fixed there.
- The size of the LISP opcodes, by yosys 0.71
  (synth_gowin, no wide LUTs): execute 2,862 LUTs, 284 ALU, 571 flip-flops (32 of them
  HLIM), 1 MULT36X36; decode 1,896 LUTs, 72 ALU, 130 flip-flops, 32 RAM16SDP4. (By
  yosys 0.33 the LISP opcodes added about 76 LUTs to execute and 57 to decode.) New
  in the critical part of execute:
  the trap (the ALU's borrow) on `redirect`, on the `stackregs` enable and on
  `x_store` / `x_wen`; check the routed frequency with `make timing` in `timing`
  (`timing/core.v`: the five stages with two 8 KB block RAMs, as measured above;
  `make test` there runs it first in simulation).
- The I/O devices on the I/O range (keyboard, mouse, video registers, ...), and an
  I/O decoder behind `io_*`.
- The boot program for the block RAM (a `$readmemh` file for `BRAM_INIT`).
- The real interrupt sequence (`irq_sequence.v`), and where `irq_pending` comes from.
- Putting the stages together into the processor (with the memory bus and the
  interrupt sequence).
- The opcodes that read and write TMPL and TMPH, and the 64-bit shift opcodes.
- A shift right of {C, T} by one, to get the remainder after DIVS.
  The sequencer is done: ROT and DROT are two steps, all else one.
- The other jumps (CJMPL, CBR, CBRL, RET and EXC redirect from execute; the calls
  JSRS, JSR, JSRL from decode).
