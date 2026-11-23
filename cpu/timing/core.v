// core.v: the mp32 core alone, for its timing on the chip: fetch, decode, execute,
// memory access and writeback, with two 8 KB block RAMs (stage4/bram.v), one for the
// code (on fetch's line port) and one for the data (on stage 4's word port). No cache,
// SDRAM or I/O: what is measured is the pipeline itself. The interrupt request comes
// from a counter, so its logic stays in (the program never sets I, so none is taken).
//
//   make timing     (in cpu/timing) places and routes it at 63 MHz, with three seeds
//
// The clock is the board's 27 MHz on pin 4; nextpnr is told --freq 42, the processor's
// clock in the computer, and reports the highest frequency the routed core reaches.
// So that nothing is optimized away, everything the core writes into its registers
// is folded into the 6 LEDs. A power-on reset holds the core for 16 ticks.
//
// The code RAM is loaded with the FPGA from CODE (one 128-bit line per row); the
// memories repeat every 8 KB, so the core starts at 0 (VEC = 0) and CONS traps to $10.

module top #(
    parameter CODE = ""
) (
    input  wire       clk,
    output reg  [5:0] led                     // on the board: 0 = lit
);
    // ---------------------------------------------------------------- power-on reset
    reg [4:0] por = 0;
    wire      reset = !por[4];
    always @(posedge clk) if (!por[4]) por <= por + 1'b1;

    // ---------------------------------------------------------------- stage 1
    wire         f_valid, f_inject;
    wire [31:0]  f_pc, f_instr, f_next_instr;
    wire         f_load;
    wire [2:0]   f_len;
    wire         line_sel, line_ready;
    wire [31:4]  line_addr;
    wire [127:0] line_data;
    wire [31:0]  pc;
    wire         stall, redirect, redirect_exc;
    wire [31:0]  redirect_pc;
    wire [7:0]   redirect_exc_n;

    // ---------------------------------------------------------------- the interrupt request
    // as cpu.v makes it, from a counter
    reg  [9:0]   irq_count = 0;
    always @(posedge clk) irq_count <= irq_count + 1'b1;
    wire         irq = irq_count[9];
    wire [7:0]   irq_num = irq_count[7:0];
    wire         ie, ie_off;
    reg          irq_pending;
    reg  [7:0]   irq_pnum;
    always @(posedge clk) begin
        irq_pending <= !reset & irq & ie & !ie_off;
        irq_pnum    <= irq_num;
    end

    fetch #(.RESET_PC(32'h0)) fe (
        .clk(clk), .reset(reset),
        .redirect(redirect), .redirect_pc(redirect_pc),
        .redirect_exc(redirect_exc), .redirect_exc_n(redirect_exc_n),
        .irq_pending(irq_pending), .irq_num(irq_pnum),
        .stall(stall), .f_valid(f_valid), .f_pc(f_pc), .f_instr(f_instr), .f_len(f_len),
        .f_inject(f_inject), .f_next_instr(f_next_instr), .f_load(f_load),
        .line_sel(line_sel), .line_addr(line_addr), .line_data(line_data),
        .line_ready(line_ready), .pc(pc)
    );

    bram #(.BITS(13), .INIT(CODE)) code (
        .clk(clk), .reset(reset), .sel(line_sel), .we(1'b0), .be(16'h0),
        .addr(line_addr[12:4]), .wdata(128'h0), .rline(line_data), .ready(line_ready)
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
        .t(), .s(), .r(), .l()
    );

    // ---------------------------------------------------------------- stage 3
    wire        mem_stall;
    wire        x_valid, x_load, x_store, x_signed, x_wen, x2_wen;
    wire [1:0]  x_size, x2_sel;
    wire [31:0] x_addr, x_wdata, x_result, x2_data;
    wire [5:0]  x_rd;

    execute #(.VEC_RESET(32'h0000_0000)) ex (
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
        .flags_out(), .psp(), .rsp(), .fp(), .tmpl(), .tmph(), .hlim(),
        .vec(), .ie(ie), .ie_off(ie_off)
    );

    // ---------------------------------------------------------------- stage 4, the data RAM
    wire        m_valid, m_wen, m2_wen;
    wire [5:0]  m_rd;
    wire [1:0]  m2_sel;
    wire [31:0] m_data, m2_data;
    wire        b_sel, b_we;
    wire [3:0]  b_be;
    wire [31:0] b_addr, b_wdata, b_rdata;
    wire        b_ready;

    memaccess ma (
        .clk(clk), .reset(reset),
        .x_valid(x_valid), .x_load(x_load), .x_store(x_store), .x_size(x_size),
        .x_signed(x_signed), .x_addr(x_addr), .x_wdata(x_wdata), .x_wen(x_wen),
        .x_rd(x_rd), .x_result(x_result),
        .x2_wen(x2_wen), .x2_sel(x2_sel), .x2_data(x2_data), .stall(mem_stall),
        .d_sel(b_sel), .d_we(b_we), .d_be(b_be), .d_addr(b_addr),
        .d_wdata(b_wdata), .d_rdata(b_rdata), .d_ready(b_ready),
        .m_valid(m_valid), .m_wen(m_wen), .m_rd(m_rd), .m_data(m_data),
        .m2_wen(m2_wen), .m2_sel(m2_sel), .m2_data(m2_data)
    );

    // the word in its lane of the line: the lane is address bits 3..2
    wire [127:0] d_line;
    bram #(.BITS(13)) data (
        .clk(clk), .reset(reset), .sel(b_sel), .we(b_we),
        .be({12'h0, b_be} << (4 * b_addr[3:2])),
        .addr(b_addr[12:4]), .wdata({4{b_wdata}}), .rline(d_line), .ready(b_ready)
    );
    assign b_rdata = d_line[32 * b_addr[3:2] +: 32];

    // ---------------------------------------------------------------- stage 5
    writeback wb (
        .m_valid(m_valid), .m_wen(m_wen), .m_rd(m_rd), .m_data(m_data),
        .m2_wen(m2_wen), .m2_sel(m2_sel), .m2_data(m2_data),
        .w_en(w_en), .w_sel(w_sel), .w_data(w_data),
        .w2_en(w2_en), .w2_sel(w2_sel), .w2_data(w2_data)
    );

    // ---------------------------------------------------------------- the LEDs
    // every register write folded into 6 bits, so the whole datapath is kept
    function [5:0] fold(input [31:0] x);
        fold = x[5:0] ^ x[11:6] ^ x[17:12] ^ x[23:18] ^ x[29:24] ^ {4'h0, x[31:30]};
    endfunction
    always @(posedge clk)
        if (reset) led <= 6'h3F;
        else       led <= led ^ (w_en ? fold(w_data) ^ {w_sel[5:0]} : 6'h0)
                              ^ (w2_en ? fold(w2_data) ^ {4'h0, w2_sel} : 6'h0);
endmodule
