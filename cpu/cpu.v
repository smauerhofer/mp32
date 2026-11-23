// cpu.v: the mp32 processor: the five stages of its pipeline, wired together.
//
//   stage1/fetch.v      fetch          (with pc.v and irq_sequence.v: INTR / EXC)
//   stage2/decode.v     decode         (with decoder.v, regfile.v, sequencer.v)
//   stage3/execute.v    execute        (with forward.v, alu.v, mul.v, flags.v, cond.v,
//                                       stackregs.v, scratch.v, tmplh.v)
//   stage4/memaccess.v  memory access
//   stage5/writeback.v  writeback
//
// It has two ports to the memory system (stage4/memsys.v), both with the cache's
// handshake (sel and the rest held until ready):
//
//   line_*   fetch reads 16-byte lines of code
//   data_*   memory access reads and writes bytes, halfwords and words (memsys's d_*)
//
// and the interrupt request: irq = 1 while a device wants an interrupt, irq_num its
// number (the interrupt controller, irqc.v, which gets irq_ack / irq_ack_num back when
// the processor takes it, to mark it in service). While irq is 1 and the I flag
// is 1, fetch injects INTR irq_num (stage1/fetch.v); execute checks again that it is
// still wanted when the INTR gets there (stage3/execute.v). The registers T, S, R, L,
// PSP, RSP, FP and the flags come out to be looked at (by a test bench, or LEDs).
//
// The parameters: RESET_PC, where it starts (the block RAM, with the boot program),
// and VEC_RESET, VEC after reset: the vector table (INTR 0, the reset, is its first
// entry, so the two are the same). CONS traps to VEC + 16 (exception 4).

module cpu #(
    parameter [31:0] RESET_PC  = 32'hF000_0000,
    parameter [31:0] VEC_RESET = RESET_PC
) (
    input  wire         clk,
    input  wire         reset,          // synchronous, active high
    input  wire         irq,            // a device wants an interrupt
    input  wire [7:0]   irq_num,        // its number (the vector)
    output wire         irq_ack,        // that INTR is taken (for one tick) ...
    output wire [7:0]   irq_ack_num,    // ... with this number: the controller marks it in service

    // ---- fetch: lines of code
    output wire         line_sel,
    output wire [31:4]  line_addr,
    input  wire [127:0] line_data,
    input  wire         line_ready,

    // ---- memory access: data
    output wire         data_sel,
    output wire         data_we,
    output wire [3:0]   data_be,
    output wire [31:0]  data_addr,
    output wire [31:0]  data_wdata,
    input  wire [31:0]  data_rdata,
    input  wire         data_ready,

    // ---- to look at
    output wire [31:0]  pc,
    output wire [31:0]  t,
    output wire [31:0]  s,
    output wire [31:0]  r,
    output wire [31:0]  l,
    output wire [31:0]  psp,
    output wire [31:0]  rsp,
    output wire [31:0]  fp,
    output wire [3:0]   flags,          // {V, N, Z, C}
    output wire         ie              // the I flag: interrupts on
);
    // ---------------------------------------------------------------- the request
    // to fetch through a register: irq and I (not while an instruction that may clear
    // I is in execute: ie_off), and the number
    wire         ie_off;
    reg          irq_pending;
    reg  [7:0]   irq_pnum;
    always @(posedge clk) begin
        irq_pending <= !reset & irq & ie & !ie_off;
        irq_pnum    <= irq_num;
    end

    // ---------------------------------------------------------------- stage 1
    wire         f_valid, f_inject;
    wire [31:0]  f_pc, f_instr, f_next_instr;
    wire         f_load;
    wire [2:0]   f_len;
    wire         stall, redirect, redirect_exc;
    wire [31:0]  redirect_pc;
    wire [7:0]   redirect_exc_n;

    fetch #(.RESET_PC(RESET_PC)) fe (
        .clk(clk), .reset(reset),
        .redirect(redirect), .redirect_pc(redirect_pc),
        .redirect_exc(redirect_exc), .redirect_exc_n(redirect_exc_n),
        .irq_pending(irq_pending), .irq_num(irq_pnum),
        .stall(stall), .f_valid(f_valid), .f_pc(f_pc), .f_instr(f_instr), .f_len(f_len),
        .f_inject(f_inject), .f_next_instr(f_next_instr), .f_load(f_load),
        .line_sel(line_sel), .line_addr(line_addr), .line_data(line_data),
        .line_ready(line_ready), .pc(pc)
    );


    // ---------------------------------------------------------------- stage 2
    wire        advance, ex_redirect;
    wire [31:0] ex_redirect_pc;
    wire        ex_redirect_exc;
    wire [7:0]  ex_redirect_exc_n;
    wire        w_en, w2_en;
    wire [5:0]  w_sel;
    wire [1:0]  w2_sel;
    wire [31:0] w_data, w2_data;

    wire        d_valid, d_a_use, d_b_use;
    wire [5:0]  d_a_sel, d_b_sel, d_rd;
    wire [31:0] d_a_data, d_b_data;
    wire [4:0]  d_alu_op;  wire [1:0] d_cin;  wire [3:0] d_fmask;
    wire        d_a_tmpl, d_b_s3;  wire [3:0] d_s3;  wire [2:0] d_res;
    wire        d_b_imm;  wire [31:0] d_imm;
    wire        d_wen, d_x2_wen;  wire [1:0] d_x2_sel, d_x2;
    wire        d_load, d_store, d_signed, d_wdata, d_addr;  wire [1:0] d_size;
    wire [1:0]  d_sp_sel;  wire [2:0] d_sp_op;
    wire        d_tmp_we, d_tmp_src, d_tl_we, d_th_we, d_th_y2, d_tl_shl, d_tl_shr, d_st_we;
    wire        d_jump, d_tgt;  wire [3:0] d_cond;
    wire        d_trap, d_hl_we, d_loop;
    wire        d_vec, d_hw, d_vec_we;  wire [1:0] d_ie;

    decode dec (
        .clk(clk), .reset(reset),
        .f_valid(f_valid), .f_pc(f_pc), .f_instr(f_instr), .f_len(f_len), .stall(stall),
        .f_inject(f_inject),
        .f_next_instr(f_next_instr), .f_load(f_load),
        .advance(advance), .ex_redirect(ex_redirect), .ex_redirect_pc(ex_redirect_pc),
        .ex_redirect_exc(ex_redirect_exc), .ex_redirect_exc_n(ex_redirect_exc_n),
        .redirect(redirect), .redirect_pc(redirect_pc),
        .redirect_exc(redirect_exc), .redirect_exc_n(redirect_exc_n),
        .w_en(w_en), .w_sel(w_sel), .w_data(w_data),
        .w2_en(w2_en), .w2_sel(w2_sel), .w2_data(w2_data),
        .d_valid(d_valid), .d_a_use(d_a_use), .d_a_sel(d_a_sel), .d_a_data(d_a_data),
        .d_b_use(d_b_use), .d_b_sel(d_b_sel), .d_b_data(d_b_data),
        .d_alu_op(d_alu_op), .d_cin(d_cin), .d_fmask(d_fmask), .d_a_tmpl(d_a_tmpl),
        .d_b_s3(d_b_s3), .d_b_imm(d_b_imm), .d_imm(d_imm), .d_s3(d_s3), .d_res(d_res), .d_wen(d_wen), .d_rd(d_rd),
        .d_x2_wen(d_x2_wen), .d_x2_sel(d_x2_sel), .d_x2(d_x2),
        .d_load(d_load), .d_store(d_store), .d_size(d_size), .d_signed(d_signed),
        .d_wdata(d_wdata), .d_addr(d_addr), .d_sp_sel(d_sp_sel), .d_sp_op(d_sp_op),
        .d_tmp_we(d_tmp_we), .d_tmp_src(d_tmp_src), .d_tl_we(d_tl_we), .d_th_we(d_th_we),
        .d_th_y2(d_th_y2), .d_tl_shl(d_tl_shl), .d_tl_shr(d_tl_shr), .d_st_we(d_st_we),
        .d_jump(d_jump), .d_cond(d_cond), .d_tgt(d_tgt), .d_trap(d_trap), .d_hl_we(d_hl_we), .d_loop(d_loop),
        .d_vec(d_vec), .d_hw(d_hw), .d_ie(d_ie), .d_vec_we(d_vec_we),
        .t(t), .s(s), .r(r), .l(l)
    );

    // ---------------------------------------------------------------- stage 3
    wire        mem_stall;
    wire        x_valid, x_load, x_store, x_signed, x_wen, x2_wen;
    wire [1:0]  x_size, x2_sel;
    wire [31:0] x_addr, x_wdata, x_result, x2_data;
    wire [5:0]  x_rd;

    execute #(.VEC_RESET(VEC_RESET)) ex (
        .clk(clk), .reset(reset),
        .d_valid(d_valid), .d_a_use(d_a_use), .d_a_sel(d_a_sel), .d_a_data(d_a_data),
        .d_b_use(d_b_use), .d_b_sel(d_b_sel), .d_b_data(d_b_data),
        .d_alu_op(d_alu_op), .d_cin(d_cin), .d_fmask(d_fmask), .d_a_tmpl(d_a_tmpl),
        .d_b_s3(d_b_s3), .d_b_imm(d_b_imm), .d_imm(d_imm), .d_s3(d_s3), .d_res(d_res), .d_wen(d_wen), .d_rd(d_rd),
        .d_x2_wen(d_x2_wen), .d_x2_sel(d_x2_sel), .d_x2(d_x2),
        .d_load(d_load), .d_store(d_store), .d_size(d_size), .d_signed(d_signed),
        .d_wdata(d_wdata), .d_addr(d_addr), .d_sp_sel(d_sp_sel), .d_sp_op(d_sp_op),
        .d_tmp_we(d_tmp_we), .d_tmp_src(d_tmp_src), .d_tl_we(d_tl_we), .d_th_we(d_th_we),
        .d_th_y2(d_th_y2), .d_tl_shl(d_tl_shl), .d_tl_shr(d_tl_shr), .d_st_we(d_st_we),
        .d_jump(d_jump), .d_cond(d_cond), .d_tgt(d_tgt), .d_trap(d_trap), .d_hl_we(d_hl_we), .d_loop(d_loop),
        .d_vec(d_vec), .d_hw(d_hw), .d_ie(d_ie), .d_vec_we(d_vec_we),
        .irq(irq), .irq_num(irq_num),
        .advance(advance), .mem_stall(mem_stall),
        .x_valid(x_valid), .x_load(x_load), .x_store(x_store), .x_size(x_size),
        .x_signed(x_signed), .x_addr(x_addr), .x_wdata(x_wdata), .x_wen(x_wen),
        .x_rd(x_rd), .x_result(x_result), .x2_wen(x2_wen), .x2_sel(x2_sel), .x2_data(x2_data),
        .w_en(w_en), .w_sel(w_sel), .w_data(w_data),
        .w2_en(w2_en), .w2_sel(w2_sel), .w2_data(w2_data),
        .redirect(ex_redirect), .redirect_pc(ex_redirect_pc),
        .redirect_exc(ex_redirect_exc), .redirect_exc_n(ex_redirect_exc_n),
        .flags_out(flags), .psp(psp), .rsp(rsp), .fp(fp), .tmpl(), .tmph(), .hlim(),
        .vec(), .ie(ie), .ie_off(ie_off), .irq_ack(irq_ack), .irq_ack_num(irq_ack_num)
    );

    // ---------------------------------------------------------------- stage 4
    wire        m_valid, m_wen, m2_wen;
    wire [5:0]  m_rd;
    wire [1:0]  m2_sel;
    wire [31:0] m_data, m2_data;

    memaccess ma (
        .clk(clk), .reset(reset),
        .x_valid(x_valid), .x_load(x_load), .x_store(x_store), .x_size(x_size),
        .x_signed(x_signed), .x_addr(x_addr), .x_wdata(x_wdata), .x_wen(x_wen),
        .x_rd(x_rd), .x_result(x_result),
        .x2_wen(x2_wen), .x2_sel(x2_sel), .x2_data(x2_data), .stall(mem_stall),
        .d_sel(data_sel), .d_we(data_we), .d_be(data_be), .d_addr(data_addr),
        .d_wdata(data_wdata), .d_rdata(data_rdata), .d_ready(data_ready),
        .m_valid(m_valid), .m_wen(m_wen), .m_rd(m_rd), .m_data(m_data),
        .m2_wen(m2_wen), .m2_sel(m2_sel), .m2_data(m2_data)
    );

    // ---------------------------------------------------------------- stage 5
    writeback wb (
        .m_valid(m_valid), .m_wen(m_wen), .m_rd(m_rd), .m_data(m_data),
        .m2_wen(m2_wen), .m2_sel(m2_sel), .m2_data(m2_data),
        .w_en(w_en), .w_sel(w_sel), .w_data(w_data),
        .w2_en(w2_en), .w2_sel(w2_sel), .w2_data(w2_data)
    );
endmodule
