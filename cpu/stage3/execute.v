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
//                interrupt flag
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
//               8: VEC
//   d_res       r = 0: ALU y, 1: operand A, 2: operand B, 3: s3, 4: TMP,
//               5: ALU y with TMPL[31] in bit 0 (DIVS),
//               6: the ALU's flags {V, N, Z, C} in bits 3..0, 0 above (CMP3),
//               7: d_imm (a return address: INTR, EXC)
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
//   d_ie                I = 0 (01: CLI) or 1 (10: SEI, RTI); reset clears it
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
//   d_hw                an INTR that fetch injected for a device. It was injected a few
//                       ticks ago; since then an older instruction may have cleared I
//                       or served the device. So it is taken only if irq is still 1,
//                       I is 1 and irq_num is still its number; then I = 0. If not,
//                       it does nothing but jump back to its return address (d_imm,
//                       the instruction it came before): fetch goes on there.
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
    input  wire [4:0]  d_alu_op,
    input  wire [1:0]  d_cin,
    input  wire [3:0]  d_fmask,
    input  wire        d_a_tmpl,
    input  wire        d_b_s3,
    input  wire        d_b_imm,
    input  wire [31:0] d_imm,
    input  wire [3:0]  d_s3,
    input  wire [2:0]  d_res,
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
    output wire        ie,             // the I flag: interrupts on
    output wire        ie_off          // an INTR from a device or CLI is here: I may go to 0
);
    // ================================================================ the control word, held
    reg [4:0]  e_alu_op;   reg [1:0] e_cin;    reg [3:0] e_fmask;
    reg        e_a_tmpl, e_b_s3, e_b_imm;      reg [2:0] e_s3;     reg [2:0] e_res;
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
    reg [8:0]  e_s3h;                  // d_s3 one-hot: bit k = s3 is source k (timing)

    // ================================================================ the operands
    wire        e_valid, load_use;
    wire [31:0] e_a, e_b;

    forward fwd (
        .clk(clk), .reset(reset), .mem_stall(mem_stall), .flush(redirect),
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
            e_bsel <= d_b_s3 | d_b_imm;
            e_s3h  <= 9'b1 << d_s3;
            e_short <= (d_alu_op <= 5'd6) | (d_alu_op == 5'd26) | (d_alu_op == 5'd27);
        end

    // the instruction in execute takes effect at this edge
    wire go = e_valid & advance;

    // CONS step 0: exception 4 when the ALU borrows on HLIM - L (wired below)
    wire trap;
    reg        ie_r;                    // I (below)
    reg [31:10] vec_r;                  // VEC (below)
    // an INTR from fetch: taken only if the interrupt is still wanted (see d_hw)
    wire refuse = e_hw & !(irq & ie_r & (irq_num == e_a[9:2]));
    wire act = !refuse;                 // the store, the write, the stack op take effect

    // UNEXT, NEXT2, NEXT3: the counter (operand B) is not 0: branch, write counter - 1,
    // and no load or stack op (they pop R when the loop ends). When it is 0: no
    // branch, and only the load into R (a pop) is written; another register stays 0.
    wire tz = (e_b == 32'h0);
    wire ltake = e_loop & !tz;

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
        .clk(clk), .en(go), .we(e_tmp_we), .d(e_tmp_src ? e_b : e_a), .tmp(tmp)
    );

    tmplh tlh (
        .clk(clk), .reset(reset), .en(go),
        .we_l(e_tl_we), .d_l(rs), .we_h(e_th_we), .d_h(e_th_y2 ? y2 : rs),
        .sh_l(e_tl_shl), .sh_r(e_tl_shr), .sh_bit(y2[0]),
        .tmpl(tmpl), .tmph(tmph)
    );

    // the flags: from the ALU (mask e_fmask), or all four from r when ST is written
    flags flg (
        .clk(clk), .reset(reset), .en(go),
        .mask(e_st_we ? 4'hF : e_fmask),
        .alu_flags(e_st_we ? rs[3:0] : e_short ? flags_s : alu_flags), .f(f)
    );
    assign flags_out = f;

    // HLIM: the heap limit, the largest L that CONS allocates at
    reg [31:0] hlim_r;
    always @(posedge clk)
        if (reset)                  hlim_r <= 32'h0;
        else if (go & e_hl_we)      hlim_r <= rs;
    assign hlim = hlim_r;

    // VEC: the vector table, 1 KB aligned (bits 9..0 are 0)
    always @(posedge clk)
        if (reset)                  vec_r <= VEC_RESET[31:10];
        else if (go & e_vec_we)     vec_r <= rs[31:10];
    assign vec = {vec_r, 10'h000};

    // I: interrupts on. An INTR taken for a device clears it; CLI clears it, SEI and
    // RTI set it.
    always @(posedge clk)
        if (reset)                          ie_r <= 1'b0;
        else if (go & e_hw & !refuse)       ie_r <= 1'b0;
        else if (go & e_ie[0])              ie_r <= 1'b0;
        else if (go & e_ie[1])              ie_r <= 1'b1;
    assign ie = ie_r;
    // for the request to fetch (cpu.v): I is 1, but the instruction here may clear it at
    // this edge; without this, fetch would inject another INTR right behind an INTR
    // taken, which execute would only turn down
    assign ie_off = e_valid & (e_hw | e_ie[0]);

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
                   | ({32{e_s3h[8]}} & {vec_r, 10'h000});

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

    always @*
        case (e_res)
            3'd0: r = e_short ? ya : y;
            3'd1: r = e_a;
            3'd2: r = e_b;
            3'd3: r = s3;
            3'd4: r = tmp;
            3'd6: r = {28'h0, flags_a};                 // CMP3 (a SUB)
            3'd7: r = e_imm;                            // a return address (CONS's trap, INTR, EXC)
            default: r = {y[31:1], y[0] | tmpl[31]};   // DIVS
        endcase

    always @*
        case (e_res)
            3'd1:    rs = e_a;
            3'd6:    rs = {28'h0, flags_a};             // CMP3 into ST, PSP, ...
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
    wire take;
    cond cnd (.cond(e_cond), .f(f), .tz(tz), .take(take));

    assign trap        = e_trap & !flags_a[0];
    assign redirect    = go & (e_jump & take | trap | ltake | e_vec);
    // exceptions found here: so far only CONS's (4)
    assign redirect_exc   = e_trap;
    assign redirect_exc_n = 8'd4;
    assign redirect_pc = e_trap ? e_imm :                              // back to the CONS: EXC 4
                         e_vec  ? (refuse ? e_imm : {vec_r, e_a[9:0]}) :
                         e_loop ? e_imm : e_tgt ? ya : e_a;

    // ================================================================ to stage 4
    always @(posedge clk)
        if (reset)
            x_valid <= 1'b0;
        else if (!mem_stall) begin
            x_valid  <= e_valid & !load_use;
            x_load   <= e_load & !ltake;
            x_store  <= e_store & act;
            x_size   <= e_size;
            x_signed <= e_signed;
            x_addr   <= e_addr ? ya : sp_addr;
            x_wdata  <= e_wdata ? e_b : e_a;
            x_wen    <= e_wen & act & (!e_loop | ltake | e_load);
            x_rd     <= e_rd;
            x_result <= r;
            x2_wen   <= e_x2_wen;
            x2_sel   <= e_x2_sel;
            x2_data  <= r2;
        end
endmodule
