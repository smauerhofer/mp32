// execute.v: stage 3 of the mp32 pipeline, execute: the wiring of its parts.
//
//   forward.v    the two operands A and B, forwarded
//   alu.v        the ALU (with mul.v, the on-chip multiplier)
//   flags.v      C Z N V (also ST, the status register: the flags in bits 3..0)
//   cond.v       the branch conditions
//   stackregs.v  PSP, RSP, FP
//   scratch.v    TMP (for the two steps of ROT, DROT)
//   tmplh.v      TMPL, TMPH
//   (here)       HLIM, the heap limit of CONS; VEC, the vector table; I, the
//                interrupt flag; PSPL, PSPH, RSPL, RSPH, the limits of the stacks
//
// and stage 3's output registers x_* for stage 4, and the redirect for fetch.
//
// ---------------------------------------------------------------- the control word
// With each instruction decode gives the operands (d_a_*, d_b_*: see forward.v) and a
// control word that says what each part does. It is held in stage 3 (e_*) with the
// instruction, like the operands.
//
//   ALU
//   d_alu_op    the ALU op (alu.v)
//   d_cin       carry in: 0 = 0, 1 = 1, 2 = the C flag, 3 = TMPL[0] (MULS)
//   d_fmask     the flags it updates {V, N, Z, C}
//   d_a_tmpl    ALU input a = TMPL (else operand A)
//   d_b_s3      ALU input b = the stage 3 value (else operand B)
//   d_b_imm, d_imm  ALU input b = d_imm, a constant from decode (else operand B): so
//               both operands stay free, e.g. STR3's base and data. d_imm comes in as
//               s3 = 0 (decode leaves d_s3 at 0 with d_b_imm), so b has one mux: s3 or B
//
//   the stage 3 value (s3) and the result (r)
//   d_s3        s3 = 0: d_imm, 1: TMPL, 2: TMPH,
//               3: ST = {27'h0, I, the flags V N Z C}, 4: PSP, 5: RSP, 6: FP (read
//               from `stackregs`' own outputs, not through sel: so an instruction can
//               read one of them and write another, e.g. MOV2 FP, PSP), 7: HLIM,
//               8: VEC, 9: PSPL, 10: PSPH, 11: RSPL, 12: RSPH
//   d_res       r = 0: ALU y, 1: operand A, 2: operand B, 3: s3, 4: TMP,
//               5: ALU y with TMPL[31] in bit 0 (DIVS),
//               6: the ALU's flags {V, N, Z, C} in bits 3..0, 0 above (CMP3),
//               7: d_imm (a return address: INTR, EXC),
//               8: operand A if the condition d_cond holds, else 0 (SET, SET2)
//
//   register writes (through stages 4 and 5)
//   d_wen, d_rd                 the main write: register d_rd = r (or the loaded word)
//   d_x2_wen, d_x2_sel, d_x2    the second write: special register d_x2_sel =
//                               0: ALU y, 1: ALU y2, 2: operand A, 3: operand B
//
//   memory (stage 4)
//   d_load, d_store, d_size, d_signed    as memaccess.v
//   d_wdata     the store data: 0 = operand A, 1 = operand B
//   d_addr      the address: 0 = `stackregs` addr, 1 = ALU y
//
//   the registers of stage 3
//   d_sp_sel, d_sp_op   `stackregs` sel and op (BASE = no change); its offset is
//                       operand B, its SET data r
//   d_tmp_we, d_tmp_src TMP = 0: operand A, 1: operand B
//   d_tl_we             TMPL = r
//   d_th_we, d_th_y2    TMPH = ALU y2 (d_th_y2) or r
//   d_tl_shl, d_tl_shr  TMPL shifts left (DIVS) / right (MULS), ALU y2[0] coming in
//   d_st_we             ST = r: the flags = r[3:0] (bits 31..4 are dropped). This wins
//                       over the flags the ALU sets (d_fmask) in the same instruction
//   d_hl_we             HLIM = r (the heap limit; reset clears it)
//   d_vec_we            VEC = r, bits 9..0 dropped (the vector table: 1 KB aligned)
//   d_lim_we            PSPL, PSPH, RSPL, RSPH = r (bits 0 .. 3; reset clears them)
//   d_ie                I = 0 (01: CLI), 1 (10: SEI, RTI) or r[4] (11: POPF); reset
//                       clears it
//
//   jumps
//   d_jump, d_cond      a jump if the condition holds (cond.v; TZ: operand B == 0)
//   d_tgt               to 0: operand A, 1: ALU y
//   d_loop              UNEXT, NEXT2, NEXT3: when operand B (the counter) is not 0,
//                       a jump to d_imm, and the write (counter - 1) takes effect;
//                       the load and the `stackregs` op do not. When it is 0: no
//                       jump, and the write takes effect only with the load (R
//                       popped); otherwise nothing changes
//   d_trap              step 0 of CONS: the ALU works out HLIM - L. When it borrows
//                       (C = 0: L > HLIM, the heap is full) the CONS raises exception
//                       4: a redirect back to the CONS (d_imm, its address) with
//                       redirect_exc = 1, redirect_exc_n = 4, and fetch injects EXC 4
//                       there (the call to VEC + 16 is the EXC's). The redirect throws
//                       away steps 1 .. 3. When it does not borrow, the step is a
//                       bubble. It writes nothing either way.
//   d_vec               INTR n, EXC n: a jump to VEC + 4n = {VEC[31:10], operand A[9:0]}
//                       (decode puts 4n on operand A), with the store, the register
//                       write and the `stackregs` op (push R, R = d_imm).
//   d_chk               the stack check (below): bit 0 checks the instruction's own
//                       push or pop (d_sp_sel, d_sp_op: PUSH, POP, ENTER, LEAVE), bit 1
//                       a pop of PSP that comes in a later step (CONS)
//   d_wait              WAIT: held here (bubbles into stage 4) until a device asks for
//                       an interrupt (irq, a tick late: irq_q), whatever I is; then a
//                       jump to operand A (the next instruction), so fetch injects
//                       the interrupt there when I = 1
//   d_hw                an INTR that fetch injected for a device. It was injected a few
//                       ticks ago; since then an older instruction may have cleared I
//                       or served the device. So it is taken only if irq is still 1,
//                       I is 1 and irq_num is still its number; then I = 0. If not,
//                       it does nothing but jump back to its return address (d_imm,
//                       the instruction it came before): fetch goes on there.
//
// ---------------------------------------------------------------- the stack check
// PSPL, PSPH, RSPL, RSPH are the lowest and highest values PSP and RSP may take. Bit 0
// of each turns its check on (bits 1..0 are not part of the limit: the pointers are
// word aligned). A push (or ENTER) that would take the pointer below its low limit is
// an overflow, a pop (or LEAVE) that would take it above its high limit an underflow:
//
//   push   ptr - 4 < LO       ptr[31:2] <= LO[31:2]     PSP: exception 8, RSP: 10
//   pop    ptr + 4 > HI       ptr[31:2] >= HI[31:2]     PSP: exception 9, RSP: 11
//   ENTER  RSP - 4 - 4n < LO  (RSP - 4n)[31:2] <= LO[31:2], or a borrow  10
//   LEAVE  FP + 4 > HI        FP[31:2] >= HI[31:2]                     11
//
// So for a stack in the words A .. B - 4 (B - 4 the first word a push stores into),
// LO = A - 4 and HI = B - 4: the pointer starts at HI. The check is made on the
// pointers as they are before the instruction, so it needs no adder (but ENTER's).
// When it fails the instruction does nothing at all (act = 0: no store, no register
// write, no load, no flags, no stack op) and execute sends fetch back to it with the
// exception (as CONS's trap): fetch injects EXC n there, R = the instruction. INTR and
// EXC themselves are never checked, so a handler can always be entered.
//
// ---------------------------------------------------------------- the short result
// The registers of stage 3 (PSP, RSP, FP, TMPL, TMPH, ST, HLIM), the jumps through the
// ALU and the ALU addresses only ever take operand A, the adder's or a logic op's y,
// or the adder's flags (CMP3): rs, from the ALU's ya and flags_a. The shifter, divider
// and multipliers are behind y only, which goes on to x_result. So no path goes from
// a register of stage 3 through the divider back into one (timing).
//
// The adder and logic ops (ADD .. XOR, RSB, RSC: e_short) take their result r, their
// second write and their flags from ya and flags_s too, not from the ALU's y and
// flags, behind which are all the other ops: the longest path, from a register of
// stage 3 through b and the adder into x_result, is shorter so.
//
// ---------------------------------------------------------------- timing
// go = the instruction in execute takes effect at this edge: it is valid, stage 4
// takes x_* (no mem_stall) and it waits for no load (no load_use). The registers of
// stage 3 (flags, PSP, RSP, FP, TMP, TMPL, TMPH) are written at that edge, so the next
// instruction sees them with no forwarding.
//
// When stage 4 takes x_* but the instruction waits for a load (load_use), a bubble
// goes into stage 4. When stage 4 cannot take x_* (mem_stall), everything holds.
//
// A jump taken goes out with go: redirect = 1, redirect_pc = the target, and the
// instruction coming in from decode at that edge is thrown away (flush). redirect
// also goes to decode and fetch, which throw away what they hold.
//
// `advance` tells decode that stage 3 takes its instruction at this edge.

module execute #(
    parameter [31:0] VEC_RESET = 32'hF000_0000    // VEC after reset: the vector table in the boot RAM
) (
    input  wire        clk,
    input  wire        reset,          // synchronous, active high

    // ---- from stage 2, decode: the instruction
    input  wire        d_valid,
    input  wire        d_a_use,
    input  wire [5:0]  d_a_sel,
    input  wire [31:0] d_a_data,
    input  wire        d_b_use,
    input  wire [5:0]  d_b_sel,
    input  wire [31:0] d_b_data,

    // ---- from stage 2, decode: the control word
    input  wire [5:0]  d_alu_op,
    input  wire [1:0]  d_cin,
    input  wire [3:0]  d_fmask,
    input  wire        d_a_tmpl,
    input  wire        d_b_s3,
    input  wire        d_b_imm,
    input  wire [31:0] d_imm,
    input  wire [3:0]  d_s3,
    input  wire [3:0]  d_res,
    input  wire        d_wen,
    input  wire [5:0]  d_rd,
    input  wire        d_x2_wen,
    input  wire [1:0]  d_x2_sel,
    input  wire [1:0]  d_x2,
    input  wire        d_load,
    input  wire        d_store,
    input  wire [1:0]  d_size,
    input  wire        d_signed,
    input  wire        d_wdata,
    input  wire        d_addr,
    input  wire [1:0]  d_sp_sel,
    input  wire [2:0]  d_sp_op,
    input  wire        d_tmp_we,
    input  wire        d_tmp_src,
    input  wire        d_tl_we,
    input  wire        d_th_we,
    input  wire        d_th_y2,
    input  wire        d_tl_shl,
    input  wire        d_tl_shr,
    input  wire        d_st_we,
    input  wire        d_jump,
    input  wire [3:0]  d_cond,
    input  wire        d_tgt,
    input  wire        d_trap,
    input  wire        d_hl_we,
    input  wire        d_loop,
    input  wire        d_vec,
    input  wire        d_hw,
    input  wire [1:0]  d_ie,
    input  wire        d_vec_we,
    input  wire [3:0]  d_lim_we,
    input  wire [1:0]  d_chk,
    input  wire        d_wait,
    input  wire [31:0] d_pc,

    // ---- the interrupt request (for the check of an injected INTR)
    input  wire        irq,
    input  wire [7:0]  irq_num,

    output wire        advance,        // stage 3 takes decode's instruction at the edge

    // ---- stage 4
    input  wire        mem_stall,      // stage 4 cannot take x_*
    output reg         x_valid,
    output reg         x_load,
    output reg         x_store,
    output reg  [1:0]  x_size,
    output reg         x_signed,
    output reg  [31:0] x_addr,
    output reg  [31:0] x_wdata,
    output reg         x_wen,
    output reg  [5:0]  x_rd,
    output reg  [31:0] x_result,
    output reg         x2_wen,
    output reg  [1:0]  x2_sel,
    output reg  [31:0] x2_data,

    // ---- stage 5, writeback (for forwarding)
    input  wire        w_en,
    input  wire [5:0]  w_sel,
    input  wire [31:0] w_data,
    input  wire        w2_en,
    input  wire [1:0]  w2_sel,
    input  wire [31:0] w2_data,

    // ---- to fetch (and decode): a jump taken
    output wire        redirect,
    output wire [31:0] redirect_pc,
    output wire        redirect_exc,   // with redirect: an exception; fetch injects
    output wire [7:0]  redirect_exc_n, // EXC redirect_exc_n at redirect_pc

    // ---- the registers of stage 3, to look at
    output wire [3:0]  flags_out,      // {V, N, Z, C}
    output wire [31:0] psp,
    output wire [31:0] rsp,
    output wire [31:0] fp,
    output wire [31:0] tmpl,
    output wire [31:0] tmph,
    output wire [31:0] hlim,
    output wire [31:0] vec,
    output wire [31:0] pspl,           // the limits of the stacks
    output wire [31:0] psph,
    output wire [31:0] rspl,
    output wire [31:0] rsph,
    output wire        ie,             // the I flag: interrupts on
    output wire        ie_off,         // an INTR from a device or CLI is here: I may go to 0
    output wire        irq_ack,        // a device's INTR is taken at this edge ...
    output wire [7:0]  irq_ack_num     // ... with this number (for the controller's in-service bits)
);
    // ================================================================ the control word, held
    reg [5:0]  e_alu_op;   reg [1:0] e_cin;    reg [3:0] e_fmask;
    reg        e_a_tmpl, e_b_s3, e_b_imm;      reg [3:0] e_s3;     reg [3:0] e_res;
    reg [3:0]  e_lim_we;   reg [1:0] e_chk;    reg e_wait;         reg [31:0] e_pc;
    reg [31:0] e_imm;
    reg        e_vec, e_hw, e_vec_we;  reg [1:0] e_ie;
    reg        e_wen;      reg [5:0] e_rd;
    reg        e_x2_wen;   reg [1:0] e_x2_sel; reg [1:0] e_x2;
    reg        e_load, e_store, e_signed, e_wdata, e_addr;         reg [1:0] e_size;
    reg [1:0]  e_sp_sel;   reg [2:0] e_sp_op;
    reg        e_tmp_we, e_tmp_src, e_tl_we, e_th_we, e_th_y2, e_tl_shl, e_tl_shr, e_st_we;
    reg        e_jump, e_tgt;                  reg [3:0] e_cond;
    reg        e_trap, e_hl_we, e_loop;
    reg        e_bsel;                 // ALU input b = s3 (a register of stage 3, or d_imm)
    reg        e_short;                // an adder or logic op: its results from ya, flags_s
    reg [12:0] e_s3h;                  // d_s3 one-hot: bit k = s3 is source k (timing)

    // ================================================================ the operands
    wire        e_valid, load_use;
    wire [31:0] e_a, e_b;

    // WAIT: held until a device asks (irq, through a register)
    reg  irq_q;
    always @(posedge clk) irq_q <= irq & !reset;
    wire wait_hold;

    forward fwd (
        .clk(clk), .reset(reset), .mem_stall(mem_stall), .flush(redirect), .hold(wait_hold),
        .d_valid(d_valid), .d_a_use(d_a_use), .d_a_sel(d_a_sel), .d_a_data(d_a_data),
        .d_b_use(d_b_use), .d_b_sel(d_b_sel), .d_b_data(d_b_data),
        .e_wen(e_wen), .e_rd(e_rd), .e_x2_wen(e_x2_wen), .e_x2_sel(e_x2_sel), .e_load(e_load),
        .x_valid(x_valid), .x_wen(x_wen), .x_load(x_load), .x_rd(x_rd),
        .x_result(x_result), .x2_wen(x2_wen), .x2_sel(x2_sel), .x2_data(x2_data),
        .w_en(w_en), .w_sel(w_sel), .w_data(w_data),
        .w2_en(w2_en), .w2_sel(w2_sel), .w2_data(w2_data),
        .e_valid(e_valid), .e_a(e_a), .e_b(e_b), .load_use(load_use), .advance(advance)
    );

    always @(posedge clk)
        if (advance) begin
            e_alu_op <= d_alu_op;  e_cin <= d_cin;        e_fmask <= d_fmask;
            e_a_tmpl <= d_a_tmpl;  e_b_s3 <= d_b_s3;      e_s3 <= d_s3;     e_res <= d_res;
            e_b_imm <= d_b_imm;    e_imm <= d_imm;
            e_wen <= d_wen;        e_rd <= d_rd;
            e_x2_wen <= d_x2_wen;  e_x2_sel <= d_x2_sel;  e_x2 <= d_x2;
            e_load <= d_load;      e_store <= d_store;    e_size <= d_size;
            e_signed <= d_signed;  e_wdata <= d_wdata;    e_addr <= d_addr;
            e_sp_sel <= d_sp_sel;  e_sp_op <= d_sp_op;
            e_tmp_we <= d_tmp_we;  e_tmp_src <= d_tmp_src;
            e_tl_we <= d_tl_we;    e_th_we <= d_th_we;    e_th_y2 <= d_th_y2;
            e_tl_shl <= d_tl_shl;  e_tl_shr <= d_tl_shr;  e_st_we <= d_st_we;
            e_jump <= d_jump;      e_cond <= d_cond;      e_tgt <= d_tgt;
            e_trap <= d_trap;      e_hl_we <= d_hl_we;    e_loop <= d_loop;
            e_vec <= d_vec;        e_hw <= d_hw;          e_ie <= d_ie;     e_vec_we <= d_vec_we;
            e_lim_we <= d_lim_we;  e_chk <= d_chk;        e_wait <= d_wait; e_pc <= d_pc;
            e_bsel <= d_b_s3 | d_b_imm;
            e_s3h  <= 13'b1 << d_s3;
            e_short <= (d_alu_op <= 6'd6) | (d_alu_op == 6'd26) | (d_alu_op == 6'd27);
        end

    assign wait_hold = e_valid & e_wait & !irq_q;

    // the instruction in execute takes effect at this edge
    wire go = e_valid & advance;

    // CONS step 0: exception 4 when the ALU borrows on HLIM - L (wired below)
    wire trap;
    reg        ie_r;                    // I (below)
    reg [31:10] vec_r;                  // VEC (below)
    // an INTR from fetch: taken only if the interrupt is still wanted (see d_hw)
    wire refuse = e_hw & !(irq & ie_r & (irq_num == e_a[9:2]));

    // UNEXT, NEXT2, NEXT3: the counter (operand B) is not 0: branch, write counter - 1,
    // and no load or stack op (they pop R when the loop ends). When it is 0: no
    // branch, and only the load into R (a pop) is written; another register stays 0.
    wire tz = (e_b == 32'h0);
    wire ltake = e_loop & !tz;

    // the stack check (see above): strap = the instruction fails it, exception strap_n
    wire        strap;
    wire [7:0]  strap_n;
    // the instruction takes effect: not an INTR turned down, not a stack exception
    wire act = !refuse & !strap;

    // ================================================================ the registers of stage 3
    wire [31:0] sp_value, sp_addr;
    wire [31:0] tmp;
    wire [3:0]  f;
    reg  [31:0] r;                      // the result
    wire [31:0] y, y2;
    wire [3:0]  alu_flags;

    wire [31:0] ya;
    wire [3:0]  flags_a, flags_s;
    reg  [31:0] rs;                     // the short result, for the registers of stage 3

    stackregs stack (
        .clk(clk), .en(go & act & !ltake), .sel(e_sp_sel), .op(e_sp_op),
        .offset(e_b), .w_data(rs),
        .value(sp_value), .addr(sp_addr), .psp(psp), .rsp(rsp), .fp(fp)
    );

    scratch scr (
        .clk(clk), .en(go & act), .we(e_tmp_we), .d(e_tmp_src ? e_b : e_a), .tmp(tmp)
    );

    tmplh tlh (
        .clk(clk), .reset(reset), .en(go & act),
        .we_l(e_tl_we), .d_l(rs), .we_h(e_th_we), .d_h(e_th_y2 ? y2 : rs),
        .sh_l(e_tl_shl), .sh_r(e_tl_shr), .sh_bit(y2[0]),
        .tmpl(tmpl), .tmph(tmph)
    );

    // the flags: from the ALU (mask e_fmask), or all four from r when ST is written
    flags flg (
        .clk(clk), .reset(reset), .en(go & act),
        .mask(e_st_we ? 4'hF : e_fmask),
        .alu_flags(e_st_we ? rs[3:0] : e_short ? flags_s : alu_flags), .f(f)
    );
    assign flags_out = f;

    // HLIM: the heap limit, the largest L that CONS allocates at
    reg [31:0] hlim_r;
    always @(posedge clk)
        if (reset)                  hlim_r <= 32'h0;
        else if (go & act & e_hl_we) hlim_r <= rs;
    assign hlim = hlim_r;

    // VEC: the vector table, 1 KB aligned (bits 9..0 are 0)
    always @(posedge clk)
        if (reset)                  vec_r <= VEC_RESET[31:10];
        else if (go & act & e_vec_we) vec_r <= rs[31:10];
    assign vec = {vec_r, 10'h000};

    // PSPL, PSPH, RSPL, RSPH: the limits of the stacks, bit 0 = the check on
    reg [31:0] lim_r [0:3];
    integer    li;
    always @(posedge clk)
        for (li = 0; li < 4; li = li + 1)
            if (reset)                          lim_r[li] <= 32'h0;
            else if (go & act & e_lim_we[li])   lim_r[li] <= rs;
    assign pspl = lim_r[0];
    assign psph = lim_r[1];
    assign rspl = lim_r[2];
    assign rsph = lim_r[3];

    // the check, on the pointers before the instruction
    wire [32:0] enter_d = {1'b0, rsp} - {1'b0, e_imm};                  // RSP - 4n (d_imm = 4n): its new RSP + 4
    wire ovf_p = lim_r[0][0] & (psp[31:2] <= lim_r[0][31:2]);
    wire unf_p = lim_r[1][0] & (psp[31:2] >= lim_r[1][31:2]);
    wire ovf_r = lim_r[2][0] & (rsp[31:2] <= lim_r[2][31:2]);
    wire unf_r = lim_r[3][0] & (rsp[31:2] >= lim_r[3][31:2]);
    wire ovf_e = lim_r[2][0] & (enter_d[32] | (enter_d[31:2] <= lim_r[2][31:2]));    // as a push of n + 1 words
    wire unf_l = lim_r[3][0] & (fp[31:2] >= lim_r[3][31:2]);
    localparam [2:0] SP_PUSH = 3'd1, SP_POP = 3'd2, SP_ENTER = 3'd5, SP_LEAVE = 3'd6;
    reg [7:0] sn;                        // the exception, 0: none
    always @*
        if (e_chk[1] & unf_p)                                   sn = 8'd9;   // CONS: its pop of PSP
        else if (!e_chk[0] | ltake)                             sn = 8'd0;   // (a loop that goes on pops nothing)
        else case (e_sp_op)
            SP_PUSH:  sn = (e_sp_sel == 2'd0) ? (ovf_p ? 8'd8 : 8'd0) : (ovf_r ? 8'd10 : 8'd0);
            SP_POP:   sn = (e_sp_sel == 2'd0) ? (unf_p ? 8'd9 : 8'd0) : (unf_r ? 8'd11 : 8'd0);
            SP_ENTER: sn = ovf_e ? 8'd10 : 8'd0;
            SP_LEAVE: sn = unf_l ? 8'd11 : 8'd0;
            default:  sn = 8'd0;
        endcase
    assign strap   = (sn != 8'd0);
    assign strap_n = sn;

    // I: interrupts on. An INTR taken for a device clears it; CLI clears it, SEI and
    // RTI set it.
    always @(posedge clk)
        if (reset)                              ie_r <= 1'b0;
        else if (go & e_hw & !refuse)           ie_r <= 1'b0;
        else if (go & act & (e_ie == 2'b11))    ie_r <= rs[4];             // POPF
        else if (go & act & e_ie[0])            ie_r <= 1'b0;
        else if (go & act & e_ie[1])            ie_r <= 1'b1;
    assign ie = ie_r;
    // for the request to fetch (cpu.v): I is 1, but the instruction here may clear it at
    // this edge; without this, fetch would inject another INTR right behind an INTR
    // taken, which execute would only turn down
    assign ie_off = e_valid & (e_hw | e_ie[0]);          // (POPF too: e_ie = 11)

    // to the interrupt controller: which device's interrupt is being served now
    assign irq_ack     = go & e_hw & !refuse;
    assign irq_ack_num = e_a[9:2];

    // ================================================================ the ALU
    // s3, picked with the one-hot e_s3h (decoded from d_s3 as it is held): an AND-OR,
    // so each source goes through one level of gates, not a tree of multiplexers
    wire [31:0] s3 = ({32{e_s3h[0]}} & e_imm)             // d_imm
                   | ({32{e_s3h[1]}} & tmpl)
                   | ({32{e_s3h[2]}} & tmph)
                   | ({32{e_s3h[3]}} & {27'h0, ie_r, f})  // ST
                   | ({32{e_s3h[4]}} & psp)
                   | ({32{e_s3h[5]}} & rsp)
                   | ({32{e_s3h[6]}} & fp)
                   | ({32{e_s3h[7]}} & hlim_r)
                   | ({32{e_s3h[8]}} & {vec_r, 10'h000})
                   | ({32{e_s3h[9]}}  & lim_r[0])
                   | ({32{e_s3h[10]}} & lim_r[1])
                   | ({32{e_s3h[11]}} & lim_r[2])
                   | ({32{e_s3h[12]}} & lim_r[3]);

    reg cin;
    always @*
        case (e_cin)
            2'd0: cin = 1'b0;
            2'd1: cin = 1'b1;
            2'd2: cin = f[0];
            default: cin = tmpl[0];
        endcase

    alu alu (
        .op(e_alu_op), .a(e_a_tmpl ? tmpl : e_a), .b(e_bsel ? s3 : e_b),
        .bo(e_b), .cin(cin),
        .y(y), .y2(y2), .flags(alu_flags), .ya(ya), .flags_a(flags_a), .flags_s(flags_s)
    );

    wire take;
    always @*
        case (e_res)
            4'd0: r = e_short ? ya : y;
            4'd1: r = e_a;
            4'd2: r = e_b;
            4'd3: r = s3;
            4'd4: r = tmp;
            4'd6: r = {28'h0, flags_a};                 // CMP3 (a SUB)
            4'd7: r = e_imm;                            // a return address (CONS's trap, INTR, EXC)
            4'd8: r = take ? e_a : 32'h0;               // SET, SET2
            default: r = {y[31:1], y[0] | tmpl[31]};   // DIVS
        endcase

    always @*
        case (e_res)
            4'd1:    rs = e_a;
            4'd6:    rs = {28'h0, flags_a};             // CMP3 into ST, PSP, ...
            default: rs = ya;
        endcase

    reg [31:0] r2;                      // the second write's value
    always @*
        case (e_x2)
            2'd0: r2 = e_short ? ya : y;
            2'd1: r2 = y2;
            2'd2: r2 = e_a;
            default: r2 = e_b;
        endcase

    // ================================================================ jumps
    cond cnd (.cond(e_cond), .f(f), .tz(tz), .take(take));

    assign trap        = e_trap & !flags_a[0];
    assign redirect    = go & (e_jump & take | trap | ltake | e_vec | strap);
    // exceptions found here: a stack limit (8 .. 11), CONS's (4)
    assign redirect_exc   = strap | e_trap;
    assign redirect_exc_n = strap ? strap_n : 8'd4;
    assign redirect_pc = strap  ? e_pc :                               // back to the instruction: EXC n
                         e_trap ? e_imm :                              // back to the CONS: EXC 4
                         e_vec  ? (refuse ? e_imm : {vec_r, e_a[9:0]}) :
                         e_loop ? e_imm : e_tgt ? ya : e_a;

    // ================================================================ to stage 4
    always @(posedge clk)
        if (reset)
            x_valid <= 1'b0;
        else if (!mem_stall) begin
            x_valid  <= e_valid & !load_use;
            x_load   <= e_load & !ltake & act;
            x_store  <= e_store & act;
            x_size   <= e_size;
            x_signed <= e_signed;
            x_addr   <= e_addr ? ya : sp_addr;
            x_wdata  <= e_wdata ? e_b : e_a;
            x_wen    <= e_wen & act & (!e_loop | ltake | e_load);
            x_rd     <= e_rd;
            x_result <= r;
            x2_wen   <= e_x2_wen & act;
            x2_sel   <= e_x2_sel;
            x2_data  <= r2;
        end
endmodule
