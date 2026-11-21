// lisp_tb.v: a test of the LISP opcodes (CAR, CDR, RPLACA, CONS with its trap to the
// GC, TADD, TTAG, ASRI) through the whole pipeline: fetch, decode, execute, memory
// access and writeback, on a real program (lisp.s, assembled into lisp.hex).
//
//   make test-lisp
//
// The program builds the list (1 2 3) with CONS; the heap only has room for two cells,
// so the third CONS traps to the GC handler at $100 (GC_VECTOR), which raises HLIM and
// returns; the CONS then allocates. Then it sums the list with TTAG, CAR, CDR and TADD,
// untags the sum, sees TADD set V for a value that is not a fixnum, changes a car with
// RPLACA. At the end the test bench checks the registers and the cells in memory.
// The code memory answers after 1 to 8 ticks, the data memory after 1 to 4.

`timescale 1ns/1ps

module lisp_tb;
    reg clk = 0;
    always #18.5 clk = ~clk;

    reg [7:0] cmem [0:1023];
    integer   seed = 3, i;

    reg reset = 1;

    // ---- stage 1
    wire         f_valid, f_inject;
    wire [31:0]  f_pc, f_instr;
    wire [2:0]   f_len;
    wire         line_sel;
    wire [31:4]  line_addr;
    reg  [127:0] line_data = 0;
    reg          line_ready = 0;
    wire [31:0]  pc;
    wire         stall, redirect;
    wire [31:0]  redirect_pc;

    fetch #(.RESET_PC(32'h0)) fe (
        .clk(clk), .reset(reset),
        .redirect(redirect), .redirect_pc(redirect_pc), .irq_pending(1'b0),
        .stall(stall), .f_valid(f_valid), .f_pc(f_pc), .f_instr(f_instr), .f_len(f_len),
        .f_inject(f_inject),
        .line_sel(line_sel), .line_addr(line_addr), .line_data(line_data),
        .line_ready(line_ready), .pc(pc)
    );

    integer cwait = -1;
    always @(posedge clk) begin
        line_ready <= 0;
        if (line_sel && !line_ready) begin
            if (cwait < 0) cwait = $random(seed) & 7;
            if (cwait == 0) begin
                for (i = 0; i < 16; i = i + 1)
                    line_data[8*i +: 8] <= cmem[{line_addr[9:4], 4'h0} + i];
                line_ready <= 1; cwait = -1;
            end else cwait = cwait - 1;
        end
    end

    // ---- stage 2
    wire        advance, ex_redirect;
    wire [31:0] ex_redirect_pc;
    wire        w_en, w2_en;
    wire [5:0]  w_sel;
    wire [1:0]  w2_sel;
    wire [31:0] w_data, w2_data;

    wire        d_valid, d_a_use, d_b_use;
    wire [5:0]  d_a_sel, d_b_sel, d_rd;
    wire [31:0] d_a_data, d_b_data;
    wire [4:0]  d_alu_op;  wire [1:0] d_cin;  wire [3:0] d_fmask;
    wire        d_a_tmpl, d_b_s3;  wire [2:0] d_s3;  wire [2:0] d_res;
    wire        d_b_imm;  wire [31:0] d_imm;
    wire        d_wen, d_x2_wen;  wire [1:0] d_x2_sel, d_x2;
    wire        d_load, d_store, d_signed, d_wdata, d_addr;  wire [1:0] d_size;
    wire [1:0]  d_sp_sel;  wire [2:0] d_sp_op;
    wire        d_tmp_we, d_tmp_src, d_tl_we, d_th_we, d_th_y2, d_tl_shl, d_tl_shr, d_st_we;
    wire        d_jump, d_tgt;  wire [3:0] d_cond;
    wire        d_trap, d_hl_we;
    wire [31:0] t, s, l;

    decode dec (
        .clk(clk), .reset(reset),
        .f_valid(f_valid), .f_pc(f_pc), .f_instr(f_instr), .f_len(f_len), .stall(stall),
        .advance(advance), .ex_redirect(ex_redirect), .ex_redirect_pc(ex_redirect_pc),
        .redirect(redirect), .redirect_pc(redirect_pc),
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
        .d_jump(d_jump), .d_cond(d_cond), .d_tgt(d_tgt), .d_trap(d_trap), .d_hl_we(d_hl_we),
        .t(t), .s(s), .r(), .l(l)
    );

    // ---- stage 3
    wire        mem_stall;
    wire        x_valid, x_load, x_store, x_signed, x_wen, x2_wen;
    wire [1:0]  x_size, x2_sel;
    wire [31:0] x_addr, x_wdata, x_result, x2_data;
    wire [5:0]  x_rd;
    wire [3:0]  flags_out;
    wire [31:0] psp, rsp, fp, tmpl, tmph, hlim;

    execute #(.GC_VECTOR(32'h0000_0100)) ex (
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
        .d_jump(d_jump), .d_cond(d_cond), .d_tgt(d_tgt), .d_trap(d_trap), .d_hl_we(d_hl_we),
        .advance(advance), .mem_stall(mem_stall),
        .x_valid(x_valid), .x_load(x_load), .x_store(x_store), .x_size(x_size),
        .x_signed(x_signed), .x_addr(x_addr), .x_wdata(x_wdata), .x_wen(x_wen),
        .x_rd(x_rd), .x_result(x_result), .x2_wen(x2_wen), .x2_sel(x2_sel), .x2_data(x2_data),
        .w_en(w_en), .w_sel(w_sel), .w_data(w_data),
        .w2_en(w2_en), .w2_sel(w2_sel), .w2_data(w2_data),
        .redirect(ex_redirect), .redirect_pc(ex_redirect_pc),
        .flags_out(flags_out), .psp(psp), .rsp(rsp), .fp(fp), .tmpl(tmpl), .tmph(tmph), .hlim(hlim)
    );

    // ---- stage 4, with the data memory (1 KB)
    wire        m_valid, m_wen, m2_wen;
    wire [5:0]  m_rd;
    wire [1:0]  m2_sel;
    wire [31:0] m_data, m2_data;
    wire        b_sel, b_we;
    wire [3:0]  b_be;
    wire [31:0] b_addr, b_wdata;
    reg  [31:0] b_rdata = 0;
    reg         b_ready = 0;

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

    reg [31:0] dmem [0:255];
    integer    dwait = -1;
    always @(posedge clk) begin
        b_ready <= 0;
        if (b_sel && !b_ready) begin
            if (dwait < 0) dwait = $random(seed) & 3;
            if (dwait == 0) begin
                b_ready <= 1;
                if (b_we) begin
                    if (b_be[0]) dmem[b_addr[9:2]][7:0]   <= b_wdata[7:0];
                    if (b_be[1]) dmem[b_addr[9:2]][15:8]  <= b_wdata[15:8];
                    if (b_be[2]) dmem[b_addr[9:2]][23:16] <= b_wdata[23:16];
                    if (b_be[3]) dmem[b_addr[9:2]][31:24] <= b_wdata[31:24];
                end else
                    b_rdata <= dmem[b_addr[9:2]];
                dwait = -1;
            end else dwait = dwait - 1;
        end
    end

    // ---- stage 5
    writeback wb (
        .m_valid(m_valid), .m_wen(m_wen), .m_rd(m_rd), .m_data(m_data),
        .m2_wen(m2_wen), .m2_sel(m2_sel), .m2_data(m2_data),
        .w_en(w_en), .w_sel(w_sel), .w_data(w_data),
        .w2_en(w2_en), .w2_sel(w2_sel), .w2_data(w2_data)
    );

    // ================================================================ checks
    integer errors = 0, traps = 0;
    always @(posedge clk) if (!reset && ex_redirect && ex_redirect_pc == 32'h100) traps = traps + 1;

    task expect(input [8*24-1:0] what, input [31:0] got, input [31:0] want);
        if (got !== want) begin
            errors = errors + 1;
            $display("%0s: got %h, expected %h", what, got, want);
        end
    endtask

    initial begin
        for (i = 0; i < 1024; i = i + 1) cmem[i] = 8'h00;
        for (i = 0; i < 256; i = i + 1)  dmem[i] = 32'h0;
        $readmemh("../lisp.hex", cmem);
        repeat (2) @(posedge clk);
        #1 reset = 0;
        repeat (3000) @(posedge clk);
        #1;
        expect("r2: the sum, fixnum",       dec.regs.regs[2], 32'd24);
        expect("r5: the sum untagged",      dec.regs.regs[5], 32'd6);
        expect("r7: GC handler runs",       dec.regs.regs[7], 32'd1);
        expect("r4 bit 3: TADD's V",        {31'h0, dec.regs.regs[4][3]}, 32'd1);
        expect("r6: car after RPLACA",      dec.regs.regs[6], 32'd40);
        expect("r8: the car of the cdr",    dec.regs.regs[8], 32'd8);
        expect("r9: HLIM was raised",       dec.regs.regs[9], 32'd1);
        expect("HLIM",                      hlim, 32'h1F9);
        expect("L after 3 CONS",            l, 32'h119);
        expect("traps to the GC vector",    traps, 1);
        // the cells: (3) at $100, (2 3) at $108, (1 2 3) at $110 (its car now 10)
        expect("cell $100 car",             dmem[8'h40], 32'd12);
        expect("cell $100 cdr",             dmem[8'h41], 32'd3);
        expect("cell $108 car",             dmem[8'h42], 32'd8);
        expect("cell $108 cdr",             dmem[8'h43], 32'h101);
        expect("cell $110 car",             dmem[8'h44], 32'd40);
        expect("cell $110 cdr",             dmem[8'h45], 32'h109);
        // the return stack is back where it was (the trap's push was popped by RET)
        expect("RSP",                       rsp, 32'h3F0);
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
