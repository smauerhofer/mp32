// execute_tb.v: tests execute.v: the wiring of stage 3, with real programs.
//
//   make test-execute
// or by hand:
//   iverilog -g2005 -DMP32_SIM -o execute_tb.vvp execute_tb.v execute.v forward.v \
//            alu.v mul.v flags.v cond.v stackregs.v scratch.v tmplh.v \
//            ../stage2/regfile.v ../stage4/memaccess.v ../stage5/writeback.v
//   vvp execute_tb.vvp
//
// The real register file (stage 2), execute (stage 3), memory access (stage 4) and
// writeback (stage 5), with a memory that answers after 1 to 4 ticks. Decode is played
// by the test bench: it turns each instruction into the operands and the control word
// of execute.v, as the real decode will (the table below is the one decode needs).
//
// A random program of 20,000 instructions of the instruction set: the stack ops (DUP
// .. DROT, ROT and DROT as their two steps), the ALU ops (ADD .. RORC, MUL, SMUL,
// DIVS, MULS, CMP), LIT, MOVR and ADDR with the register file and with PSP, RSP, FP,
// TMPL, TMPH and PC, and the jumps CBR (all conditions, TZ too), RET, EXC, MOVR PC, T,
// ADDR PC, T. It starts by setting PSP and RSP. Decode follows the program in order,
// not the jumps. Right after each jump comes a "shadow" instruction (a LIT, DUP, DROP,
// SWAP, an ALU op or a MOVR): a taken jump must throw it away (flush), a jump not
// taken runs it; the reference does the same, so a missing flush shows.
//
// A reference runs the same program one instruction at a time (its ALU and its
// conditions are separate instances of alu.v and cond.v, tested on their own). Checked:
// every register write coming out of writeback (both ports) against the reference's,
// in order; every redirect (target, in order); and at the end every register (r0 ..
// r31, T, S, R, L, PSP, RSP, FP, TMPL, TMPH), the flags and the memory.

`timescale 1ns/1ps

module execute_tb;
    reg clk = 0;
    always #18.5 clk = ~clk;              // 27 MHz

    parameter N = 20000;

    // ---- the kinds of instruction the test uses
    localparam K_NOP = 0, K_DUP = 1, K_DROP = 2, K_SWAP = 3, K_OVER = 4, K_DIP = 5,
               K_NIP = 6, K_TUCK = 7, K_DRIP = 8, K_PUSH = 9, K_POP = 10, K_PUSHS = 11,
               K_POPS = 12, K_ROT0 = 13, K_ROT1 = 14, K_DROT0 = 15, K_DROT1 = 16,
               K_BIN = 17,      // ADD ADC SUB SBC AND OR XOR: p_n = the ALU op
               K_CSUB = 18, K_DIVS = 19, K_MUL = 20, K_SMUL = 21, K_INV = 22,
               K_NEG = 23, K_MULS = 24, K_CMP = 25,
               K_SH1 = 26,      // ASL ASR LSL LSR ROL ROR ROLC RORC: p_n = the ALU op
               K_LIT = 27, K_CBR = 28, K_RET = 29, K_EXC = 30,
               K_MOV_TO = 31,   // MOVR <reg>, T       (reg in the register file)
               K_MOV_FROM = 32, // MOVR T, <reg>
               K_MOV_TO3 = 33,  // MOVR <s3>, T        (s3: 0 PSP 1 RSP 2 FP 3 TMPL 4 TMPH)
               K_MOV_FROM3 = 34,// MOVR T, <s3>
               K_ADDR_T = 35,   // ADDR T, <reg>
               K_ADDR_R = 36,   // ADDR <reg>, T
               K_ADDR_3 = 37,   // ADDR <s3>, T
               K_JMP_T = 38,    // MOVR PC, T
               K_T_PC = 39,     // MOVR T, PC          (p_n = the address of the next one)
               K_ADDR_PC = 40,  // ADDR PC, T          (p_n = the address of the next one)
               K_KINDS = 41;

    // ALU ops (alu.v), stackregs ops and registers
    localparam [4:0] A_ADD = 0, A_ADC = 1, A_SUB = 2, A_SBC = 3, A_AND = 4, A_OR = 5,
                     A_XOR = 6, A_NOT = 7, A_LSL = 8, A_LSR = 9, A_ASR = 10, A_ROR = 11,
                     A_CSUB = 17, A_DIVS = 18, A_MUL = 19, A_SMUL = 20, A_ASL = 21,
                     A_ROL = 22, A_ROLC = 23, A_RORC = 24, A_MULS = 25;
    localparam [2:0] SP_BASE = 0, SP_PUSH = 1, SP_POP = 2, SP_SET = 3;
    localparam [1:0] PSP_ = 0, RSP_ = 1, FP_ = 2;
    localparam [5:0] T_ = 6'b100000, S_ = 6'b100001, R_ = 6'b100010, L_ = 6'b100011;

    // ================================================================ the program
    integer     p_kind [0:N-1];
    reg [31:0]  p_n    [0:N-1];
    reg [5:0]   p_reg  [0:N-1];
    reg [3:0]   p_cond [0:N-1];
    reg         p_gap  [0:N-1];

    // ================================================================ the pipeline
    reg reset = 1;

    // ---- decode (the test bench): the instruction at pc, as operands and control
    integer     pc = 0;
    reg         gap_done = 0;
    wire        have = (pc < N);
    integer     k_now;
    reg  [31:0] n_now;
    reg  [5:0]  reg_now;
    reg  [3:0]  cond_now;
    always @* begin
        k_now    = have ? p_kind[pc] : K_NOP;
        n_now    = have ? p_n[pc]    : 0;
        reg_now  = have ? p_reg[pc]  : 0;
        cond_now = have ? p_cond[pc] : 0;
    end
    wire d_valid = have && !(p_gap[pc] && !gap_done);

    reg        d_a_use, d_b_use;
    reg [5:0]  d_a_sel, d_b_sel;
    reg [31:0] d_a_const, d_b_const;
    reg [4:0]  d_alu_op;  reg [1:0] d_cin;  reg [3:0] d_fmask;
    reg        d_a_tmpl, d_b_s3;  reg [2:0] d_s3;  reg [2:0] d_res;
    reg        d_wen;  reg [5:0] d_rd;  reg d_x2_wen;  reg [1:0] d_x2_sel, d_x2;
    reg        d_load, d_store, d_signed, d_wdata, d_addr;  reg [1:0] d_size;
    reg [1:0]  d_sp_sel;  reg [2:0] d_sp_op;
    reg        d_tmp_we, d_tmp_src, d_tl_we, d_th_we, d_th_y2, d_tl_shl, d_tl_shr;
    reg        d_jump, d_tgt;  reg [3:0] d_cond;

    // the stage 3 register of a MOVR / ADDR (0 PSP 1 RSP 2 FP 3 TMPL 4 TMPH)
    task s3_read(input [2:0] w);
        begin
            if (w < 3) begin d_s3 = 3'd4 + w; d_sp_sel = w; d_sp_op = SP_BASE; end
            else       d_s3 = (w == 3) ? 2'd1 : 2'd2;
        end
    endtask
    task s3_write(input [2:0] w);              // the value: r
        begin
            if (w < 3)       begin d_sp_sel = w; d_sp_op = SP_SET; end
            else if (w == 3) d_tl_we = 1;
            else             d_th_we = 1;
        end
    endtask
    // pop / push on a stack (word)
    task pop_(input [1:0] st); begin d_sp_sel = st; d_sp_op = SP_POP;  d_load  = 1; d_size = 2; end endtask
    task push_(input [1:0] st, input src); begin d_sp_sel = st; d_sp_op = SP_PUSH; d_store = 1; d_size = 2; d_wdata = src; end endtask

    always @* begin
        // nothing, by default
        d_a_use = 0; d_a_sel = 0; d_a_const = 0; d_b_use = 0; d_b_sel = 0; d_b_const = 0;
        d_alu_op = A_ADD; d_cin = 0; d_fmask = 0; d_a_tmpl = 0; d_b_s3 = 0; d_s3 = 0;
        d_res = 0; d_wen = 0; d_rd = 0; d_x2_wen = 0; d_x2_sel = 0; d_x2 = 0;
        d_load = 0; d_store = 0; d_size = 2; d_signed = 0; d_wdata = 0; d_addr = 0;
        d_sp_sel = 0; d_sp_op = SP_BASE; d_tmp_we = 0; d_tmp_src = 0;
        d_tl_we = 0; d_th_we = 0; d_th_y2 = 0; d_tl_shl = 0; d_tl_shr = 0;
        d_jump = 0; d_cond = 0; d_tgt = 0;
        case (k_now)
        K_DUP:   begin d_a_use = 1; d_a_sel = S_; d_b_use = 1; d_b_sel = T_;
                       push_(PSP_, 0); d_wen = 1; d_rd = S_; d_res = 2; end
        K_DROP:  begin d_a_use = 1; d_a_sel = S_; pop_(PSP_);
                       d_wen = 1; d_rd = S_; d_x2_wen = 1; d_x2_sel = 0; d_x2 = 2; end
        K_SWAP:  begin d_a_use = 1; d_a_sel = S_; d_b_use = 1; d_b_sel = T_;
                       d_wen = 1; d_rd = T_; d_res = 1; d_x2_wen = 1; d_x2_sel = 1; d_x2 = 3; end
        K_OVER:  begin d_a_use = 1; d_a_sel = S_; d_b_use = 1; d_b_sel = T_; push_(PSP_, 0);
                       d_wen = 1; d_rd = T_; d_res = 1; d_x2_wen = 1; d_x2_sel = 1; d_x2 = 3; end
        K_DIP:   begin d_a_use = 1; d_a_sel = S_; push_(PSP_, 0); end
        K_NIP:   begin pop_(PSP_); d_wen = 1; d_rd = S_; end
        K_TUCK:  begin d_b_use = 1; d_b_sel = T_; push_(PSP_, 1); end
        K_DRIP:  begin pop_(PSP_); d_wen = 1; d_rd = T_; end
        K_PUSH:  begin d_a_use = 1; d_a_sel = R_; d_b_use = 1; d_b_sel = T_; push_(RSP_, 0);
                       d_wen = 1; d_rd = R_; d_res = 2; end
        K_POP:   begin d_a_use = 1; d_a_sel = R_; pop_(RSP_);
                       d_wen = 1; d_rd = R_; d_x2_wen = 1; d_x2_sel = 0; d_x2 = 2; end
        K_PUSHS: begin d_a_use = 1; d_a_sel = R_; d_b_use = 1; d_b_sel = S_; push_(RSP_, 0);
                       d_wen = 1; d_rd = R_; d_res = 2; end
        K_POPS:  begin d_a_use = 1; d_a_sel = R_; pop_(RSP_);
                       d_wen = 1; d_rd = R_; d_x2_wen = 1; d_x2_sel = 1; d_x2 = 2; end
        K_ROT0:  begin d_b_use = 1; d_b_sel = T_; d_tmp_we = 1; d_tmp_src = 1;
                       pop_(PSP_); d_wen = 1; d_rd = T_; end
        K_ROT1:  begin d_a_use = 1; d_a_sel = S_; push_(PSP_, 0); d_wen = 1; d_rd = S_; d_res = 4; end
        K_DROT0: begin d_a_use = 1; d_a_sel = S_; d_tmp_we = 1; d_tmp_src = 0;
                       pop_(PSP_); d_wen = 1; d_rd = S_; end
        K_DROT1: begin d_b_use = 1; d_b_sel = T_; push_(PSP_, 1); d_wen = 1; d_rd = T_; d_res = 4; end
        K_BIN:   begin d_a_use = 1; d_a_sel = S_; d_b_use = 1; d_b_sel = T_;
                       d_alu_op = n_now[4:0];
                       d_cin = (n_now == A_ADD) ? 0 : (n_now == A_SUB) ? 1 : 2;
                       d_fmask = 4'b1111; pop_(PSP_);
                       d_wen = 1; d_rd = S_; d_x2_wen = 1; d_x2_sel = 0; d_x2 = 0; end
        K_CSUB:  begin d_a_use = 1; d_a_sel = T_; d_b_use = 1; d_b_sel = S_; d_alu_op = A_CSUB;
                       d_cin = 1; d_fmask = 4'b1111; d_wen = 1; d_rd = T_; end
        K_DIVS:  begin d_a_use = 1; d_a_sel = T_; d_b_use = 1; d_b_sel = S_; d_alu_op = A_DIVS;
                       d_cin = 2; d_fmask = 4'b0001; d_tl_shl = 1; d_wen = 1; d_rd = T_; d_res = 5; end
        K_MUL, K_SMUL:
                 begin d_a_use = 1; d_a_sel = S_; d_b_use = 1; d_b_sel = T_;
                       d_alu_op = (k_now == K_MUL) ? A_MUL : A_SMUL; d_fmask = 4'b0110;
                       d_wen = 1; d_rd = T_; d_x2_wen = 1; d_x2_sel = 1; d_x2 = 1; end
        K_INV:   begin d_a_use = 1; d_a_sel = T_; d_alu_op = A_NOT; d_cin = 2; d_fmask = 4'b1110;
                       d_wen = 1; d_rd = T_; end
        K_NEG:   begin d_a_const = 0; d_b_use = 1; d_b_sel = T_; d_alu_op = A_SUB; d_cin = 1;
                       d_fmask = 4'b1111; d_wen = 1; d_rd = T_; end
        K_MULS:  begin d_a_use = 1; d_a_sel = T_; d_b_use = 1; d_b_sel = S_; d_alu_op = A_MULS;
                       d_cin = 3; d_tl_shr = 1; d_wen = 1; d_rd = T_; end
        K_CMP:   begin d_a_use = 1; d_a_sel = S_; d_b_use = 1; d_b_sel = T_; d_alu_op = A_SUB;
                       d_cin = 1; d_fmask = 4'b1111; end
        K_SH1:   begin d_a_use = 1; d_a_sel = T_; d_b_const = 1; d_alu_op = n_now[4:0];
                       d_cin = 2; d_fmask = 4'b1111; d_wen = 1; d_rd = T_; end
        K_LIT:   begin d_a_const = n_now; d_wen = 1; d_rd = T_; d_res = 1; end
        K_CBR:   begin d_a_const = n_now; d_b_use = 1; d_b_sel = T_;
                       d_jump = 1; d_cond = cond_now; d_tgt = 0; end
        K_RET:   begin d_a_use = 1; d_a_sel = R_; d_jump = 1; d_cond = 4'hE; d_tgt = 0;
                       pop_(RSP_); d_wen = 1; d_rd = R_; end
        K_EXC:   begin d_a_use = 1; d_a_sel = R_; d_b_const = n_now; d_jump = 1; d_cond = 4'hE;
                       d_wen = 1; d_rd = R_; d_res = 2; end
        K_MOV_TO:   begin d_a_use = 1; d_a_sel = T_; d_wen = 1; d_rd = reg_now; d_res = 1; end
        K_MOV_FROM: begin d_a_use = 1; d_a_sel = reg_now; d_wen = 1; d_rd = T_; d_res = 1; end
        K_MOV_TO3:  begin d_a_use = 1; d_a_sel = T_; d_res = 1; s3_write(reg_now[2:0]); end
        K_MOV_FROM3:begin s3_read(reg_now[2:0]); d_res = 3; d_wen = 1; d_rd = T_; end
        K_ADDR_T:   begin d_a_use = 1; d_a_sel = T_; d_b_use = 1; d_b_sel = reg_now;
                          d_fmask = 4'b1111; d_wen = 1; d_rd = T_; end
        K_ADDR_R:   begin d_a_use = 1; d_a_sel = T_; d_b_use = 1; d_b_sel = reg_now;
                          d_fmask = 4'b1111; d_wen = 1; d_rd = reg_now; end
        K_ADDR_3:   begin d_a_use = 1; d_a_sel = T_; d_b_s3 = 1; s3_read(reg_now[2:0]);
                          d_fmask = 4'b1111; s3_write(reg_now[2:0]); end
        K_JMP_T:    begin d_a_use = 1; d_a_sel = T_; d_jump = 1; d_cond = 4'hE; end
        K_T_PC:     begin d_a_const = n_now; d_wen = 1; d_rd = T_; d_res = 1; end
        K_ADDR_PC:  begin d_a_use = 1; d_a_sel = T_; d_b_const = n_now; d_fmask = 4'b1111;
                          d_jump = 1; d_cond = 4'hE; d_tgt = 1; end
        default: ;
        endcase
    end

    wire [31:0] a_data, b_data;
    wire        w_en, w2_en;
    wire [5:0]  w_sel;
    wire [1:0]  w2_sel;
    wire [31:0] w_data, w2_data;

    regfile regs (
        .clk(clk), .reset(reset),
        .a_sel(d_a_sel), .a_data(a_data), .b_sel(d_b_sel), .b_data(b_data),
        .w_en(w_en), .w_sel(w_sel), .w_data(w_data),
        .w2_en(w2_en), .w2_sel(w2_sel), .w2_data(w2_data),
        .t(), .s(), .r(), .l()
    );

    // ---- execute (real)
    wire        advance, mem_stall, redirect;
    wire [31:0] redirect_pc;
    wire        x_valid, x_load, x_store, x_signed, x_wen, x2_wen;
    wire [1:0]  x_size, x2_sel;
    wire [31:0] x_addr, x_wdata, x_result, x2_data;
    wire [5:0]  x_rd;
    wire [3:0]  flags_out;
    wire [31:0] psp, rsp, fp, tmpl, tmph;

    execute ex (
        .clk(clk), .reset(reset),
        .d_valid(d_valid),
        .d_a_use(d_a_use), .d_a_sel(d_a_sel), .d_a_data(d_a_use ? a_data : d_a_const),
        .d_b_use(d_b_use), .d_b_sel(d_b_sel), .d_b_data(d_b_use ? b_data : d_b_const),
        .d_alu_op(d_alu_op), .d_cin(d_cin), .d_fmask(d_fmask), .d_a_tmpl(d_a_tmpl),
        .d_b_s3(d_b_s3), .d_s3(d_s3), .d_res(d_res), .d_wen(d_wen), .d_rd(d_rd),
        .d_x2_wen(d_x2_wen), .d_x2_sel(d_x2_sel), .d_x2(d_x2),
        .d_load(d_load), .d_store(d_store), .d_size(d_size), .d_signed(d_signed),
        .d_wdata(d_wdata), .d_addr(d_addr), .d_sp_sel(d_sp_sel), .d_sp_op(d_sp_op),
        .d_tmp_we(d_tmp_we), .d_tmp_src(d_tmp_src), .d_tl_we(d_tl_we), .d_th_we(d_th_we),
        .d_st_we(1'b0),                      // ST: tested in stage2/decode_tb.v
        .d_b_imm(1'b0), .d_imm(32'h0),       // the immediate path: tested there too
        .d_th_y2(d_th_y2), .d_tl_shl(d_tl_shl), .d_tl_shr(d_tl_shr),
        .d_jump(d_jump), .d_cond(d_cond), .d_tgt(d_tgt), .d_trap(1'b0), .d_hl_we(1'b0),
        .advance(advance),
        .mem_stall(mem_stall),
        .x_valid(x_valid), .x_load(x_load), .x_store(x_store), .x_size(x_size),
        .x_signed(x_signed), .x_addr(x_addr), .x_wdata(x_wdata), .x_wen(x_wen),
        .x_rd(x_rd), .x_result(x_result), .x2_wen(x2_wen), .x2_sel(x2_sel), .x2_data(x2_data),
        .w_en(w_en), .w_sel(w_sel), .w_data(w_data),
        .w2_en(w2_en), .w2_sel(w2_sel), .w2_data(w2_data),
        .redirect(redirect), .redirect_pc(redirect_pc),
        .flags_out(flags_out), .psp(psp), .rsp(rsp), .fp(fp), .tmpl(tmpl), .tmph(tmph), .hlim()
    );

    // decode moves on when execute takes its instruction
    always @(posedge clk)
        if (!reset && advance) begin
            if (d_valid) begin pc <= pc + 1; gap_done <= 0; end
            else if (have) gap_done <= 1;
        end

    // ---- memory access (real) and a memory of 1 KB (addresses wrap)
    wire        m_valid, m_wen, m2_wen;
    wire [5:0]  m_rd;
    wire [1:0]  m2_sel;
    wire [31:0] m_data, m2_data;
    wire        d_sel_, d_we_;
    wire [3:0]  d_be_;
    wire [31:0] d_addr_, d_wdata_;
    reg  [31:0] d_rdata_ = 0;
    reg         d_ready_ = 0;

    memaccess ma (
        .clk(clk), .reset(reset),
        .x_valid(x_valid), .x_load(x_load), .x_store(x_store), .x_size(x_size),
        .x_signed(x_signed), .x_addr(x_addr), .x_wdata(x_wdata), .x_wen(x_wen),
        .x_rd(x_rd), .x_result(x_result),
        .x2_wen(x2_wen), .x2_sel(x2_sel), .x2_data(x2_data), .stall(mem_stall),
        .d_sel(d_sel_), .d_we(d_we_), .d_be(d_be_), .d_addr(d_addr_),
        .d_wdata(d_wdata_), .d_rdata(d_rdata_), .d_ready(d_ready_),
        .m_valid(m_valid), .m_wen(m_wen), .m_rd(m_rd), .m_data(m_data),
        .m2_wen(m2_wen), .m2_sel(m2_sel), .m2_data(m2_data)
    );

    reg [31:0] mem [0:255];
    integer    seed = 77, wait_ticks = -1;
    always @(posedge clk) begin
        d_ready_ <= 0;
        if (d_sel_ && !d_ready_) begin
            if (wait_ticks < 0) wait_ticks = $random(seed) & 3;
            if (wait_ticks == 0) begin
                d_ready_ <= 1;
                if (d_we_) mem[d_addr_[9:2]] <= d_wdata_;
                else       d_rdata_ <= mem[d_addr_[9:2]];
                wait_ticks = -1;
            end else
                wait_ticks = wait_ticks - 1;
        end
    end

    // ---- writeback (real)
    writeback wb (
        .m_valid(m_valid), .m_wen(m_wen), .m_rd(m_rd), .m_data(m_data),
        .m2_wen(m2_wen), .m2_sel(m2_sel), .m2_data(m2_data),
        .w_en(w_en), .w_sel(w_sel), .w_data(w_data),
        .w2_en(w2_en), .w2_sel(w2_sel), .w2_data(w2_data)
    );

    // ================================================================ the reference
    reg [31:0] rf [0:31];
    reg [31:0] sp [0:3];                  // T S R L
    reg [31:0] r_psp, r_rsp, r_fp, r_tmpl, r_tmph, r_tmp;
    reg [3:0]  r_fl;
    reg [31:0] rmem [0:255];

    // its ALU and conditions: separate instances, tested on their own
    reg  [4:0]  ra_op;   reg [31:0] ra_a, ra_b;   reg ra_cin;
    wire [31:0] ra_y, ra_y2;   wire [3:0] ra_f;
    alu ref_alu (.op(ra_op), .a(ra_a), .b(ra_b), .bo(ra_b), .cin(ra_cin), .y(ra_y), .y2(ra_y2), .flags(ra_f));
    reg  [3:0]  rc_cond; reg rc_tz;  wire rc_take;
    cond ref_cond (.cond(rc_cond), .f(r_fl), .tz(rc_tz), .take(rc_take));

    // the expected writes (one record per instruction that writes the register file)
    // and the expected redirects
    reg        e_one  [0:2*N];  reg [5:0] e_sel [0:2*N];  reg [31:0] e_data  [0:2*N];
    reg        e_two  [0:2*N];  reg [1:0] e_sp2 [0:2*N];  reg [31:0] e_data2 [0:2*N];
    reg [31:0] e_jump [0:N];
    integer    n_rec = 0, n_jumps = 0, n_taken_ref = 0;
    reg        jumped;                   // the instruction the reference just ran jumped

    function integer ix(input [5:0] sel);          // 0..31 rf, 32..35 T S R L
        ix = sel[5] ? 32 + sel[1:0] : sel[4:0];
    endfunction
    function [31:0] get(input [5:0] sel);
        get = sel[5] ? sp[sel[1:0]] : rf[sel[4:0]];
    endfunction
    task put(input [5:0] sel, input [31:0] v);
        if (sel[5]) sp[sel[1:0]] = v; else rf[sel[4:0]] = v;
    endtask

    // one write record: main (sel, v), and maybe a second (special k2, v2)
    task rec(input one, input [5:0] sel, input [31:0] v, input two, input [1:0] k2, input [31:0] v2);
        begin
            e_one[n_rec] = one; e_sel[n_rec] = sel; e_data[n_rec] = v;
            e_two[n_rec] = two; e_sp2[n_rec] = k2;  e_data2[n_rec] = v2;
            n_rec = n_rec + 1;
            if (two) sp[k2] = v2;                       // the main write wins
            if (one) put(sel, v);
        end
    endtask

    task alu_(input [4:0] op, input [31:0] a, input [31:0] b, input c, input [3:0] mask);
        begin
            ra_op = op; ra_a = a; ra_b = b; ra_cin = c; #1;
            r_fl = (r_fl & ~mask) | (ra_f & mask);
        end
    endtask

    task rpush(inout [31:0] ptr, input [31:0] v);
        begin rmem[ptr[9:2]] = v; ptr = ptr - 4; end
    endtask
    task rpop(inout [31:0] ptr, output [31:0] v);
        begin ptr = ptr + 4; v = rmem[ptr[9:2]]; end
    endtask

    function [31:0] s3get(input [2:0] w);
        case (w) 0: s3get = r_psp; 1: s3get = r_rsp; 2: s3get = r_fp;
                 3: s3get = r_tmpl; default: s3get = r_tmph; endcase
    endfunction
    task s3put(input [2:0] w, input [31:0] v);
        case (w) 0: r_psp = v; 1: r_rsp = v; 2: r_fp = v;
                 3: r_tmpl = v; default: r_tmph = v; endcase
    endtask

    // the reference runs instruction k
    task run(input integer k);
        reg [31:0] t, s, rr, v, ad;
        reg [5:0]  g;
        begin
            t = sp[0]; s = sp[1]; rr = sp[2]; g = p_reg[k];
            case (p_kind[k])
            K_DUP:   begin rpush(r_psp, s); rec(1, S_, t, 0, 0, 0); end
            K_DROP:  begin rpop(r_psp, v); rec(1, S_, v, 1, 0, s); end
            K_SWAP:  rec(1, T_, s, 1, 1, t);
            K_OVER:  begin rpush(r_psp, s); rec(1, T_, s, 1, 1, t); end
            K_DIP:   rpush(r_psp, s);
            K_NIP:   begin rpop(r_psp, v); rec(1, S_, v, 0, 0, 0); end
            K_TUCK:  rpush(r_psp, t);
            K_DRIP:  begin rpop(r_psp, v); rec(1, T_, v, 0, 0, 0); end
            K_PUSH:  begin rpush(r_rsp, rr); rec(1, R_, t, 0, 0, 0); end
            K_POP:   begin rpop(r_rsp, v); rec(1, R_, v, 1, 0, rr); end
            K_PUSHS: begin rpush(r_rsp, rr); rec(1, R_, s, 0, 0, 0); end
            K_POPS:  begin rpop(r_rsp, v); rec(1, R_, v, 1, 1, rr); end
            K_ROT0:  begin r_tmp = t; rpop(r_psp, v); rec(1, T_, v, 0, 0, 0); end
            K_ROT1:  begin rpush(r_psp, s); rec(1, S_, r_tmp, 0, 0, 0); end
            K_DROT0: begin r_tmp = s; rpop(r_psp, v); rec(1, S_, v, 0, 0, 0); end
            K_DROT1: begin rpush(r_psp, t); rec(1, T_, r_tmp, 0, 0, 0); end
            K_BIN:   begin
                         alu_(p_n[k][4:0], s, t, (p_n[k] == A_ADD) ? 1'b0 :
                              (p_n[k] == A_SUB) ? 1'b1 : r_fl[0], 4'b1111);
                         rpop(r_psp, v); rec(1, S_, v, 1, 0, ra_y);
                     end
            K_CSUB:  begin alu_(A_CSUB, t, s, 1, 4'b1111); rec(1, T_, ra_y, 0, 0, 0); end
            K_DIVS:  begin
                         alu_(A_DIVS, t, s, r_fl[0], 4'b0001);
                         rec(1, T_, {ra_y[31:1], ra_y[0] | r_tmpl[31]}, 0, 0, 0);
                         r_tmpl = {r_tmpl[30:0], ra_y2[0]};
                     end
            K_MUL:   begin alu_(A_MUL,  s, t, 0, 4'b0110); rec(1, T_, ra_y, 1, 1, ra_y2); end
            K_SMUL:  begin alu_(A_SMUL, s, t, 0, 4'b0110); rec(1, T_, ra_y, 1, 1, ra_y2); end
            K_INV:   begin alu_(A_NOT, t, 0, r_fl[0], 4'b1110); rec(1, T_, ra_y, 0, 0, 0); end
            K_NEG:   begin alu_(A_SUB, 0, t, 1, 4'b1111); rec(1, T_, ra_y, 0, 0, 0); end
            K_MULS:  begin
                         alu_(A_MULS, t, s, r_tmpl[0], 4'b0000); rec(1, T_, ra_y, 0, 0, 0);
                         r_tmpl = {ra_y2[0], r_tmpl[31:1]};
                     end
            K_CMP:   alu_(A_SUB, s, t, 1, 4'b1111);
            K_SH1:   begin alu_(p_n[k][4:0], t, 1, r_fl[0], 4'b1111); rec(1, T_, ra_y, 0, 0, 0); end
            K_LIT:   rec(1, T_, p_n[k], 0, 0, 0);
            K_CBR:   begin
                         rc_cond = p_cond[k]; rc_tz = (t == 0); #1;
                         if (rc_take) begin e_jump[n_jumps] = p_n[k]; n_jumps = n_jumps + 1; jumped = 1; end
                     end
            K_RET:   begin
                         e_jump[n_jumps] = rr; n_jumps = n_jumps + 1; jumped = 1;
                         rpop(r_rsp, v); rec(1, R_, v, 0, 0, 0);
                     end
            K_EXC:   begin
                         e_jump[n_jumps] = rr; n_jumps = n_jumps + 1; jumped = 1;
                         rec(1, R_, p_n[k], 0, 0, 0);
                     end
            K_MOV_TO:    rec(1, g, t, 0, 0, 0);
            K_MOV_FROM:  rec(1, T_, get(g), 0, 0, 0);
            K_MOV_TO3:   s3put(g[2:0], t);
            K_MOV_FROM3: rec(1, T_, s3get(g[2:0]), 0, 0, 0);
            K_ADDR_T:    begin alu_(A_ADD, t, get(g), 0, 4'b1111); rec(1, T_, ra_y, 0, 0, 0); end
            K_ADDR_R:    begin alu_(A_ADD, t, get(g), 0, 4'b1111); rec(1, g, ra_y, 0, 0, 0); end
            K_ADDR_3:    begin alu_(A_ADD, t, s3get(g[2:0]), 0, 4'b1111); s3put(g[2:0], ra_y); end
            K_JMP_T:     begin e_jump[n_jumps] = t; n_jumps = n_jumps + 1; jumped = 1; end
            K_T_PC:      rec(1, T_, p_n[k], 0, 0, 0);
            K_ADDR_PC:   begin
                             alu_(A_ADD, t, p_n[k], 0, 4'b1111);
                             e_jump[n_jumps] = ra_y; n_jumps = n_jumps + 1; jumped = 1;
                         end
            default: ;
            endcase
        end
    endtask

    // ================================================================ make the program
    function [5:0] any_reg(input integer dummy);       // r0 .. r3, T, S, R, L
        reg [31:0] x;
        begin
            x = $random(seed);
            any_reg = x[2] ? {1'b1, 3'b000, x[1:0]} : {1'b0, 3'b000, x[1:0]};
        end
    endfunction

    reg [4:0] bin_ops [0:6];
    reg [4:0] sh_ops  [0:7];
    integer   k, i, kind;
    task add(input integer kd, input [31:0] n, input [5:0] g, input [3:0] c, input gap);
        begin
            p_kind[k] = kd; p_n[k] = n; p_reg[k] = g; p_cond[k] = c; p_gap[k] = gap;
            k = k + 1;
        end
    endtask

    // the instruction right after a jump: one pass, no jump
    task shadow;
        reg [31:0] y;
        begin
            y = $random(seed);
            case (y[2:0] % 6)
                0: add(K_LIT, $random(seed), 0, 0, 0);
                1: add(K_DUP, 0, 0, 0, 0);
                2: add(K_DROP, 0, 0, 0, 0);
                3: add(K_SWAP, 0, 0, 0, 0);
                4: add(K_BIN, bin_ops[y[10:8] % 7], 0, 0, 0);
                default: add(K_MOV_TO, 0, any_reg(0), 0, 0);
            endcase
        end
    endtask

    task make_program;
        reg [31:0] x;
        begin
            bin_ops[0] = A_ADD; bin_ops[1] = A_ADC; bin_ops[2] = A_SUB; bin_ops[3] = A_SBC;
            bin_ops[4] = A_AND; bin_ops[5] = A_OR;  bin_ops[6] = A_XOR;
            sh_ops[0] = A_ASL; sh_ops[1] = A_ASR; sh_ops[2] = A_LSL; sh_ops[3] = A_LSR;
            sh_ops[4] = A_ROL; sh_ops[5] = A_ROR; sh_ops[6] = A_ROLC; sh_ops[7] = A_RORC;
            k = 0;
            // PSP and RSP first
            add(K_LIT, 32'h200, 0, 0, 0); add(K_MOV_TO3, 0, 0, 0, 0);
            add(K_LIT, 32'h300, 0, 0, 0); add(K_MOV_TO3, 0, 1, 0, 0);
            while (k < N - 3) begin
                kind = ($random(seed) & 32'h7FFF_FFFF) % K_KINDS;
                x = $random(seed);
                case (kind)
                K_ROT0:  begin add(K_ROT0, 0, 0, 0, x[0]);  add(K_ROT1, 0, 0, 0, 0); end
                K_DROT0: begin add(K_DROT0, 0, 0, 0, x[0]); add(K_DROT1, 0, 0, 0, 0); end
                K_ROT1, K_DROT1, K_NOP: add(K_NOP, 0, 0, 0, x[0]);
                K_BIN:   add(K_BIN, bin_ops[x[10:8] % 7], 0, 0, x[0]);
                K_SH1:   add(K_SH1, sh_ops[x[10:8]], 0, 0, x[0]);
                K_LIT:   add(K_LIT, x[1] ? $random(seed) : (x[2] ? 0 : 1), 0, 0, x[0]);
                K_CBR:   begin add(K_CBR, $random(seed), 0, x[7:4], x[0]); shadow; end
                K_RET, K_EXC, K_JMP_T, K_ADDR_PC:
                         begin add(kind, $random(seed), 0, 0, x[0]); shadow; end
                K_MOV_TO, K_MOV_FROM, K_ADDR_T, K_ADDR_R:
                         add(kind, 0, any_reg(0), 0, x[0]);
                K_MOV_TO3, K_MOV_FROM3, K_ADDR_3:
                         add(kind, 0, x[10:8] % 3'd5, 0, x[0]);
                K_T_PC:  add(kind, $random(seed), 0, 0, x[0]);
                default: add(kind, 0, 0, 0, x[0]);
                endcase
            end
            while (k < N) add(K_NOP, 0, 0, 0, 0);

            // the reference runs it
            for (i = 0; i < 32; i = i + 1) rf[i] = 0;
            for (i = 0; i < 4; i = i + 1)  sp[i] = 0;
            for (i = 0; i < 256; i = i + 1) rmem[i] = 0;
            r_psp = 0; r_rsp = 0; r_fp = 0; r_tmpl = 0; r_tmph = 0; r_tmp = 0; r_fl = 0;
            // a taken jump throws away the instruction right after it
            i = 0;
            while (i < N) begin
                jumped = 0; run(i);
                i = i + (jumped ? 2 : 1);
            end
        end
    endtask

    // ================================================================ checks
    integer errors = 0, n_got = 0, n_red = 0, ticks = 0, n_lu = 0, n_ms = 0;

    task fail(input [8*64-1:0] what);
        begin
            errors = errors + 1;
            if (errors <= 20) $display("%t %0s", $realtime, what);
        end
    endtask

    always @(posedge clk) if (!reset) begin
        ticks = ticks + 1;
        if (ex.load_use) n_lu = n_lu + 1;
        if (mem_stall) n_ms = n_ms + 1;
        if (w_en || w2_en) begin
            if (n_got >= n_rec) fail("a write too many");
            else begin
                if (w_en !== e_one[n_got] || (w_en && (ix(w_sel) != ix(e_sel[n_got]) ||
                                                        w_data !== e_data[n_got]))) begin
                    fail("main write");
                    if (errors <= 20)
                        $display("   write %0d: got %b reg %0d = %h, expected %b reg %0d = %h",
                                 n_got, w_en, ix(w_sel), w_data,
                                 e_one[n_got], ix(e_sel[n_got]), e_data[n_got]);
                end
                if (w2_en !== e_two[n_got] || (w2_en && (w2_sel !== e_sp2[n_got] ||
                                                          w2_data !== e_data2[n_got]))) begin
                    fail("second write");
                    if (errors <= 20)
                        $display("   write %0d: got %b sp %0d = %h, expected %b sp %0d = %h",
                                 n_got, w2_en, w2_sel, w2_data,
                                 e_two[n_got], e_sp2[n_got], e_data2[n_got]);
                end
            end
            n_got = n_got + 1;
        end
        if (redirect) begin
            if (n_red >= n_jumps) fail("a redirect too many");
            else if (redirect_pc !== e_jump[n_red]) begin
                fail("redirect target");
                if (errors <= 20) $display("   jump %0d: got %h, expected %h",
                                           n_red, redirect_pc, e_jump[n_red]);
            end
            n_red = n_red + 1;
        end
    end

    task final_check;
        begin
            for (i = 0; i < 32; i = i + 1)
                if (regs.regs[i] !== rf[i]) begin
                    fail("register at the end");
                    $display("   r%0d = %h, expected %h", i, regs.regs[i], rf[i]);
                end
            for (i = 0; i < 4; i = i + 1)
                if (regs.special[i] !== sp[i]) begin
                    fail("T/S/R/L at the end");
                    $display("   special %0d = %h, expected %h", i, regs.special[i], sp[i]);
                end
            if (psp !== r_psp || rsp !== r_rsp || fp !== r_fp) fail("PSP/RSP/FP at the end");
            if (tmpl !== r_tmpl || tmph !== r_tmph) fail("TMPL/TMPH at the end");
            if (flags_out !== r_fl) fail("flags at the end");
            for (i = 0; i < 256; i = i + 1)
                if (mem[i] !== rmem[i]) begin
                    fail("memory at the end");
                    if (errors <= 20) $display("   mem[%0d] = %h, expected %h", i, mem[i], rmem[i]);
                end
            if (n_got != n_rec) begin
                fail("number of writes"); $display("   %0d, expected %0d", n_got, n_rec);
            end
            if (n_red != n_jumps) begin
                fail("number of jumps"); $display("   %0d, expected %0d", n_red, n_jumps);
            end
        end
    endtask

    initial begin
        for (i = 0; i < 256; i = i + 1) mem[i] = 0;
        make_program;
        @(posedge clk); @(posedge clk);
        #1 reset = 0;
        while (pc < N && ticks < 20 * N) @(posedge clk);
        if (pc < N) fail("the pipeline got stuck");
        repeat (30) @(posedge clk);
        #1 final_check;
        $display("%0d instructions in %0d ticks: %0d register writes, %0d jumps taken, %0d load-use waits, %0d ticks memory stall",
                 N, ticks, n_rec, n_jumps, n_lu, n_ms);
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
