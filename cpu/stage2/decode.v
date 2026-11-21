// decode.v: stage 2 of the mp32 pipeline, decode.
//
//   It takes the instruction from fetch (f_*), reads its registers from the register
//   file (regfile.v), and gives execute (stage 3) the two operands and the control
//   word (see stage3/execute.v). ROT and DROT go out as two steps, CONS as four
//   (sequencer.v).
//
// ---------------------------------------------------------------- the operands
// Operand A and operand B each come from a register (d_*_use = 1: the register file
// read with d_*_sel, forwarded later in execute) or are a value made here
// (d_*_use = 0): a LIT's constant, a jump's target, a return address, the PC, the
// shift amount 1, the 0 of NEG.
//
// ---------------------------------------------------------------- addresses
// next = the PC of the instruction + its length (the next instruction). One adder
// makes target = next + the instruction's offset, for CBR, CBRL and the calls; CJMPL's
// target is {PC[31:4], the offset in the line}.
//
// ---------------------------------------------------------------- the calls
// JSRS, JSR, JSRL always jump, and their destination is known here, so decode
// redirects fetch itself, as it issues the call (call_go). Execute then pushes R and
// writes the return address into R. When execute redirects in the same tick (an older
// jump taken), execute wins: the call is thrown away (execute's flush) and so is its
// redirect. redirect / redirect_pc to fetch are the two put together.
//
// ---------------------------------------------------------------- the pre-decode
// The decoder (decoder.v) works out everything from the instruction in f_*. The
// registers the two operands read (d_a_use, d_a_sel, d_b_use, d_b_sel) are worked out
// a tick early instead: a second decoder looks at the instruction and step that will
// be in f_* and the sequencer after the next edge (fetch's f_next_instr at step 0
// when it loads, else f_instr at its next step), and they go into registers. So the
// register file reads from a register, not from the end of the decoder (timing). In
// simulation (MP32_SIM) decode checks every tick that they are what the decoder makes
// of the instruction in f_*.
//
// ---------------------------------------------------------------- unknown opcodes
// Opcodes that are not defined (and MOVR / ADDR .. CMPR with a register number that
// does not exist) do nothing: they go through as a NOP.
//
// ---------------------------------------------------------------- LISP
// The low 2 bits of a LISP value are its tag: 00 fixnum, 01 cons, 10 other object,
// 11 immediate. A cons cell is 8 bytes, 8-aligned: its car is at the tagged pointer
// - 1, its cdr at + 3. L is the allocation pointer: the tagged address of the next
// free cell. CAR, CDR, RPLACA, RPLACD go through the address path of LDR3 / STR3;
// CONS is four steps: 0 the check against HLIM (a trap to the GC vector, d_trap),
// 1 the car, 2 the cdr and T = L, 3 the pop into S and L = L + 8.

module decode (
    input  wire        clk,
    input  wire        reset,          // synchronous, active high

    // ---- from fetch
    input  wire        f_valid,
    input  wire [31:0] f_pc,
    input  wire [31:0] f_instr,
    input  wire [2:0]  f_len,
    input  wire [31:0] f_next_instr,   // what f_instr becomes at the next edge, if f_load
    input  wire        f_load,         // fetch loads f_* at the next edge
    output wire        stall,          // to fetch: keep f_*

    // ---- from execute
    input  wire        advance,        // execute takes the instruction at this edge
    input  wire        ex_redirect,    // a jump taken in execute
    input  wire [31:0] ex_redirect_pc,

    // ---- to fetch: a jump (from execute, or a call from here)
    output wire        redirect,
    output wire [31:0] redirect_pc,

    // ---- from writeback: the register file's write ports
    input  wire        w_en,
    input  wire [5:0]  w_sel,
    input  wire [31:0] w_data,
    input  wire        w2_en,
    input  wire [1:0]  w2_sel,
    input  wire [31:0] w2_data,

    // ---- to execute: the instruction
    output wire        d_valid,
    output reg         d_a_use,
    output reg  [5:0]  d_a_sel,
    output wire [31:0] d_a_data,
    output reg         d_b_use,
    output reg  [5:0]  d_b_sel,
    output wire [31:0] d_b_data,

    // ---- to execute: the control word
    output wire [4:0]  d_alu_op,
    output wire [1:0]  d_cin,
    output wire [3:0]  d_fmask,
    output wire        d_a_tmpl,
    output wire        d_b_s3,
    output wire        d_b_imm,
    output wire [31:0] d_imm,
    output wire [2:0]  d_s3,
    output wire [2:0]  d_res,
    output wire        d_wen,
    output wire [5:0]  d_rd,
    output wire        d_x2_wen,
    output wire [1:0]  d_x2_sel,
    output wire [1:0]  d_x2,
    output wire        d_load,
    output wire        d_store,
    output wire [1:0]  d_size,
    output wire        d_signed,
    output wire        d_wdata,
    output wire        d_addr,
    output wire [1:0]  d_sp_sel,
    output wire [2:0]  d_sp_op,
    output wire        d_tmp_we,
    output wire        d_tmp_src,
    output wire        d_tl_we,
    output wire        d_th_we,
    output wire        d_th_y2,
    output wire        d_tl_shl,
    output wire        d_tl_shr,
    output wire        d_st_we,
    output wire        d_jump,
    output wire [3:0]  d_cond,
    output wire        d_tgt,
    output wire        d_trap,         // CONS step 0: trap unless L <= HLIM
    output wire        d_hl_we,        // HLIM = r

    // ---- the special registers, to look at
    output wire [31:0] t,
    output wire [31:0] s,
    output wire [31:0] r,
    output wire [31:0] l
);

    // ================================================================ the sequencer
    wire [1:0] d_step;
    wire       d_last;
    sequencer seq (
        .clk(clk), .reset(reset), .redirect(redirect),
        .f_valid(f_valid), .f_opcode(f_instr[7:0]), .hold(!advance),
        .d_step(d_step), .d_last(d_last), .stall(stall)
    );

    assign d_valid = f_valid;

    // ================================================================ the decoder
    wire [31:0] a_const, b_const, target;
    wire        call;
    wire        now_a_use, now_b_use;
    wire [5:0]  now_a_sel, now_b_sel;

    decoder now (
        .f_pc(f_pc), .f_instr(f_instr), .f_len(f_len), .d_step(d_step),
        .a_const(a_const), .b_const(b_const), .call(call), .target(target),
        .d_a_use(now_a_use), .d_a_sel(now_a_sel), .d_b_use(now_b_use), .d_b_sel(now_b_sel),
        .d_alu_op(d_alu_op), .d_cin(d_cin), .d_fmask(d_fmask), .d_a_tmpl(d_a_tmpl),
        .d_b_s3(d_b_s3), .d_b_imm(d_b_imm), .d_imm(d_imm), .d_s3(d_s3), .d_res(d_res),
        .d_wen(d_wen), .d_rd(d_rd), .d_x2_wen(d_x2_wen), .d_x2_sel(d_x2_sel), .d_x2(d_x2),
        .d_load(d_load), .d_store(d_store), .d_size(d_size), .d_signed(d_signed),
        .d_wdata(d_wdata), .d_addr(d_addr), .d_sp_sel(d_sp_sel), .d_sp_op(d_sp_op),
        .d_tmp_we(d_tmp_we), .d_tmp_src(d_tmp_src), .d_tl_we(d_tl_we), .d_th_we(d_th_we),
        .d_th_y2(d_th_y2), .d_tl_shl(d_tl_shl), .d_tl_shr(d_tl_shr), .d_st_we(d_st_we),
        .d_jump(d_jump), .d_cond(d_cond), .d_tgt(d_tgt), .d_trap(d_trap), .d_hl_we(d_hl_we)
    );

    // ================================================================ the pre-decode
    // After the next edge f_* holds either a new instruction from fetch (f_load), at
    // step 0, or the same instruction at its next step (decode issues a step that is
    // not the last), or stays (hold). The two decoders work on both candidates; the
    // late signals (f_load, advance: they come from the stall network) only pick one
    // at the end, so they do not go through a decoder.
    wire        l_a_use, l_b_use, s_a_use, s_b_use;
    wire [5:0]  l_a_sel, l_b_sel, s_a_sel, s_b_sel;

    decoder next_instr (                                   // the new instruction, step 0
        .f_pc(32'h0), .f_instr(f_next_instr), .f_len(3'd0), .d_step(2'd0),
        .a_const(), .b_const(), .call(), .target(),
        .d_a_use(l_a_use), .d_a_sel(l_a_sel), .d_b_use(l_b_use), .d_b_sel(l_b_sel),
        .d_alu_op(), .d_cin(), .d_fmask(), .d_a_tmpl(), .d_b_s3(), .d_b_imm(), .d_imm(),
        .d_s3(), .d_res(), .d_wen(), .d_rd(), .d_x2_wen(), .d_x2_sel(), .d_x2(),
        .d_load(), .d_store(), .d_size(), .d_signed(), .d_wdata(), .d_addr(),
        .d_sp_sel(), .d_sp_op(), .d_tmp_we(), .d_tmp_src(), .d_tl_we(), .d_th_we(),
        .d_th_y2(), .d_tl_shl(), .d_tl_shr(), .d_st_we(), .d_jump(), .d_cond(), .d_tgt(),
        .d_trap(), .d_hl_we()
    );

    decoder next_step (                                    // this instruction, the next step
        .f_pc(32'h0), .f_instr(f_instr), .f_len(3'd0), .d_step(d_step + 2'd1),
        .a_const(), .b_const(), .call(), .target(),
        .d_a_use(s_a_use), .d_a_sel(s_a_sel), .d_b_use(s_b_use), .d_b_sel(s_b_sel),
        .d_alu_op(), .d_cin(), .d_fmask(), .d_a_tmpl(), .d_b_s3(), .d_b_imm(), .d_imm(),
        .d_s3(), .d_res(), .d_wen(), .d_rd(), .d_x2_wen(), .d_x2_sel(), .d_x2(),
        .d_load(), .d_store(), .d_size(), .d_signed(), .d_wdata(), .d_addr(),
        .d_sp_sel(), .d_sp_op(), .d_tmp_we(), .d_tmp_src(), .d_tl_we(), .d_th_we(),
        .d_th_y2(), .d_tl_shl(), .d_tl_shr(), .d_st_we(), .d_jump(), .d_cond(), .d_tgt(),
        .d_trap(), .d_hl_we()
    );

    always @(posedge clk)
        if (f_load) begin                                  // a new instruction
            d_a_use <= l_a_use;  d_a_sel <= l_a_sel;
            d_b_use <= l_b_use;  d_b_sel <= l_b_sel;
        end else if (f_valid & advance) begin              // its next step (after the
            d_a_use <= s_a_use;  d_a_sel <= s_a_sel;       // last one f_* is empty or
            d_b_use <= s_b_use;  d_b_sel <= s_b_sel;       // new: f_load)
        end

`ifdef MP32_SIM
    // the pre-decode must be what the decoder makes of the instruction in f_*
    integer predecode_errors = 0;
    always @(posedge clk)
        if (!reset && f_valid &&
            (d_a_use !== now_a_use || (now_a_use && d_a_sel !== now_a_sel) ||
             d_b_use !== now_b_use || (now_b_use && d_b_sel !== now_b_sel))) begin
            predecode_errors = predecode_errors + 1;
            if (predecode_errors <= 10)
                $display("%t decode: PRE-DECODE WRONG at pc %h op %h step %0d: a %b %h / %b %h, b %b %h / %b %h",
                         $realtime, f_pc, f_instr[7:0], d_step,
                         d_a_use, d_a_sel, now_a_use, now_a_sel, d_b_use, d_b_sel, now_b_use, now_b_sel);
        end
`endif

    // ================================================================ the register file
    wire [31:0] a_reg, b_reg;
    regfile regs (
        .clk(clk), .reset(reset),
        .a_sel(d_a_sel), .a_data(a_reg), .b_sel(d_b_sel), .b_data(b_reg),
        .w_en(w_en), .w_sel(w_sel), .w_data(w_data),
        .w2_en(w2_en), .w2_sel(w2_sel), .w2_data(w2_data),
        .t(t), .s(s), .r(r), .l(l)
    );

    assign d_a_data = d_a_use ? a_reg : a_const;
    assign d_b_data = d_b_use ? b_reg : b_const;

    // ================================================================ redirects
    // a call goes out as execute takes it, unless execute jumps at the same time.
    // (The & !ex_redirect is for clarity: redirect_pc takes execute's target first,
    // and execute throws the call away, so the result would be the same without it.)
    wire call_go = f_valid & call & advance & !ex_redirect;

    assign redirect    = ex_redirect | call_go;
    assign redirect_pc = ex_redirect ? ex_redirect_pc : target;
endmodule
