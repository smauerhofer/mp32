// decode_tb.v: tests decode.v, with the whole pipeline: fetch, decode, execute, memory
// access and writeback, on random machine code.
//
//   make test-decode
// or by hand:
//   iverilog -g2005 -DMP32_SIM -o decode_tb.vvp decode_tb.v decode.v regfile.v \
//            sequencer.v ../stage1/fetch.v ../stage1/pc.v ../stage1/irq_sequence.v \
//            ../stage3/execute.v ../stage3/forward.v ../stage3/alu.v ../stage3/mul.v \
//            ../stage3/flags.v ../stage3/cond.v ../stage3/stackregs.v \
//            ../stage3/scratch.v ../stage3/tmplh.v ../stage4/memaccess.v \
//            ../stage5/writeback.v
//   vvp decode_tb.vvp
//
// The LISP opcodes too: CONS raises exception 4 (EXC 4: to VEC + 16 = GC = 0x9010 here) when
// L > HLIM, and goes through its four steps when not. The code starts by setting
// HLIM, and at GC there is a tiny "garbage collector": L = 1, HLIM = $79 (a heap of 16
// cells), RET. So the CONS that trapped allocates when it runs again, and every 16
// CONS or so one traps.
//
// INTR and EXC call through the vector table at VEC = 0x9000: INTR 0, 2, 3 go to a RET
// (back after the INTR); EXC 1, and every undefined opcode (exception 1: decode sends
// fetch back to it, fetch injects EXC 1), go to a handler at 0x9020 that skips the
// instruction: it reads its first byte (a load from 0x0040_xxxx reads the code memory
// here), adds its length to R and returns. CLI, SEI and RTI change the I flag,
// which MOVR T, ST reads in bit 4 (there are no interrupts here).
//
// 64 KB of random machine code: instructions of every defined opcode (and some that
// are not defined, which trap), with random operands, one after the other. The
// code memory answers fetch's line reads after 1 to 8 ticks; the data memory (1 KB,
// addresses wrap) answers stage 4 after 1 to 4 ticks. Code and data are separate here,
// so stores cannot change the code.
//
// A reference runs the same code one instruction at a time, from the same PC (0),
// following every jump, with the same rule for the line (a byte past the end of the
// line is 0). Where random code gets caught in a loop, the reference turns the jump
// into a NOP and starts again (see `TRAP`). Its ALU and its conditions are separate instances of alu.v and cond.v.
// It runs 40,000 instructions and records what they do: every register write (main
// and second), every store (address and data) and every jump taken (calls too). The
// pipeline must do the same things in the same order: each of the three is checked
// as it happens.

`timescale 1ns/1ps

module decode_tb;
    reg clk = 0;
    always #18.5 clk = ~clk;              // 27 MHz

    parameter NREF = 40000;               // instructions the reference runs
    parameter [31:0] VEC = 32'h0000_9000; // the vector table (execute's VEC_RESET)
    parameter [31:0] GC  = VEC + 16;      // where CONS traps to (exception 4)

    localparam [4:0] A_ADD = 0, A_ADC = 1, A_SUB = 2, A_SBC = 3, A_AND = 4, A_OR = 5,
                     A_XOR = 6, A_NOT = 7, A_LSL = 8, A_LSR = 9, A_ASR = 10, A_ROR = 11,
                     A_CSUB = 17, A_DIVS = 18, A_MUL = 19, A_SMUL = 20, A_ASL = 21,
                     A_ROL = 22, A_ROLC = 23, A_RORC = 24, A_MULS = 25,
                     A_RSB = 26, A_RSC = 27, A_TADD = 28, A_TSUB = 29, A_TTAG = 30;
    localparam [5:0] T_ = 6'b100000, S_ = 6'b100001, R_ = 6'b100010, L_ = 6'b100011;

    reg [7:0] cmem [0:65535];             // the code
    integer   seed = 5;

    // ================================================================ the pipeline
    reg reset = 1;

    // ---- stage 1: fetch, with the code memory on its line port
    wire         f_valid, f_inject;
    wire [31:0]  f_pc, f_instr, f_next_instr;
    wire         f_load;
    wire [2:0]   f_len;
    wire         line_sel;
    wire [31:4]  line_addr;
    reg  [127:0] line_data = 0;
    reg          line_ready = 0;
    wire [31:0]  pc;
    wire         stall, redirect, redirect_exc;
    wire [31:0]  redirect_pc;
    wire [7:0]   redirect_exc_n;

    fetch #(.RESET_PC(32'h0)) fe (
        .clk(clk), .reset(reset),
        .redirect(redirect), .redirect_pc(redirect_pc),
        .redirect_exc(redirect_exc), .redirect_exc_n(redirect_exc_n),
        .irq_pending(1'b0), .irq_num(8'h0),
        .stall(stall), .f_valid(f_valid), .f_pc(f_pc), .f_instr(f_instr), .f_len(f_len),
        .f_inject(f_inject), .f_next_instr(f_next_instr), .f_load(f_load),
        .line_sel(line_sel), .line_addr(line_addr), .line_data(line_data),
        .line_ready(line_ready), .pc(pc)
    );

    integer cwait = -1, i;
    always @(posedge clk) begin
        line_ready <= 0;
        if (line_sel && !line_ready) begin
            if (cwait < 0) cwait = $random(seed) & 7;
            if (cwait == 0) begin
                for (i = 0; i < 16; i = i + 1)
                    line_data[8*i +: 8] <= cmem[{line_addr[15:4], 4'h0} + i];
                line_ready <= 1; cwait = -1;
            end else cwait = cwait - 1;
        end
    end

    // ---- stage 2: decode (real)
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
        .f_inject(f_inject), .f_next_instr(f_next_instr), .f_load(f_load),
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

    // ---- stage 3: execute (real)
    wire        mem_stall;
    wire        x_valid, x_load, x_store, x_signed, x_wen, x2_wen;
    wire [1:0]  x_size, x2_sel;
    wire [31:0] x_addr, x_wdata, x_result, x2_data;
    wire [5:0]  x_rd;
    wire [3:0]  flags_out;
    wire [31:0] psp, rsp, fp, tmpl, tmph;

    execute #(.VEC_RESET(VEC)) ex (
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
        .irq(1'b0), .irq_num(8'h0),
        .advance(advance), .mem_stall(mem_stall),
        .x_valid(x_valid), .x_load(x_load), .x_store(x_store), .x_size(x_size),
        .x_signed(x_signed), .x_addr(x_addr), .x_wdata(x_wdata), .x_wen(x_wen),
        .x_rd(x_rd), .x_result(x_result), .x2_wen(x2_wen), .x2_sel(x2_sel), .x2_data(x2_data),
        .w_en(w_en), .w_sel(w_sel), .w_data(w_data),
        .w2_en(w2_en), .w2_sel(w2_sel), .w2_data(w2_data),
        .redirect(ex_redirect), .redirect_pc(ex_redirect_pc),
        .redirect_exc(ex_redirect_exc), .redirect_exc_n(ex_redirect_exc_n),
        .flags_out(flags_out), .psp(psp), .rsp(rsp), .fp(fp), .tmpl(tmpl), .tmph(tmph), .hlim(),
        .vec(), .ie(), .ie_off()
    );

    // ---- stage 4: memory access (real), with the data memory
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

    // ---- stage 5: writeback (real)
    writeback wb (
        .m_valid(m_valid), .m_wen(m_wen), .m_rd(m_rd), .m_data(m_data),
        .m2_wen(m2_wen), .m2_sel(m2_sel), .m2_data(m2_data),
        .w_en(w_en), .w_sel(w_sel), .w_data(w_data),
        .w2_en(w2_en), .w2_sel(w2_sel), .w2_data(w2_data)
    );

    // ================================================================ the reference
    reg [31:0] rf [0:31];
    reg [31:0] sp [0:3];                  // T S R L
    reg [31:0] r_psp, r_rsp, r_fp, r_tmpl, r_tmph, r_hlim, r_pc, r_vec;
    reg        r_ie;
    reg [3:0]  r_fl;
    reg [31:0] rmem [0:255];
    reg [31:0] mem0 [0:255];              // what the data memory starts with

    reg  [4:0]  ra_op;   reg [31:0] ra_a, ra_b;   reg ra_cin;
    wire [31:0] ra_y, ra_y2;   wire [3:0] ra_f;
    alu ref_alu (.op(ra_op), .a(ra_a), .b(ra_b), .bo(ra_b), .cin(ra_cin), .y(ra_y), .y2(ra_y2), .flags(ra_f));
    reg  [3:0]  rc_cond; reg rc_tz;  wire rc_take;
    cond ref_cond (.cond(rc_cond), .f(r_fl), .tz(rc_tz), .take(rc_take));

    // the reference's own state, declared before the tasks that use it
    reg [31:0] cur_pc, last_jump;         // traps (below): the instruction now, the last jump taken
    reg [7:0]  hits [0:65535];
    reg        trapped;
    integer    n_cons, n_gc;              // CONS allocated, CONS trapped (in the reference)
    integer    n_loop, n_lend;            // UNEXT, NEXT2, NEXT3: branched back, ended
    integer    n_intr, n_exc, n_undef;    // INTR, EXC from memory, undefined opcodes

    // what it does, in order
    parameter MAXW = 3 * NREF;
    reg        e_one [0:MAXW];  reg [5:0] e_sel [0:MAXW];  reg [31:0] e_data  [0:MAXW];
    reg        e_two [0:MAXW];  reg [1:0] e_sp2 [0:MAXW];  reg [31:0] e_data2 [0:MAXW];
    reg [31:0] e_st_a [0:MAXW]; reg [31:0] e_st_d [0:MAXW]; reg [3:0] e_st_be [0:MAXW];
    reg [31:0] e_jump [0:MAXW];
    integer    n_rec = 0, n_st = 0, n_jmp = 0;
    integer    count [0:255];             // how often each opcode ran

    function integer ix(input [5:0] sel);
        ix = sel[5] ? 32 + sel[1:0] : sel[4:0];
    endfunction
    function [31:0] get(input [5:0] sel);
        get = sel[5] ? sp[sel[1:0]] : rf[sel[4:0]];
    endfunction
    task put(input [5:0] sel, input [31:0] v);
        if (sel[5]) sp[sel[1:0]] = v; else rf[sel[4:0]] = v;
    endtask
    task rec(input one, input [5:0] sel, input [31:0] v, input two, input [1:0] k2, input [31:0] v2);
        begin
            e_one[n_rec] = one; e_sel[n_rec] = sel; e_data[n_rec] = v;
            e_two[n_rec] = two; e_sp2[n_rec] = k2;  e_data2[n_rec] = v2;
            n_rec = n_rec + 1;
            if (two) sp[k2] = v2;
            if (one) put(sel, v);
        end
    endtask
    task w1(input [5:0] sel, input [31:0] v); rec(1, sel, v, 0, 0, 0); endtask
    task alu_(input [4:0] op, input [31:0] a, input [31:0] b, input c, input [3:0] mask);
        begin
            ra_op = op; ra_a = a; ra_b = b; ra_cin = c; #1;
            r_fl = (r_fl & ~mask) | (ra_f & mask);
        end
    endtask
    task rpush(inout [31:0] ptr, input [31:0] v);
        begin
            rmem[ptr[9:2]] = v;
            e_st_a[n_st] = {ptr[31:2], 2'b00}; e_st_d[n_st] = v; e_st_be[n_st] = 4'hF; n_st = n_st + 1;
            ptr = ptr - 4;
        end
    endtask
    // a word as the data memory answers: 0x0040_xxxx is the code (for the handler that
    // skips an undefined instruction), all else the 1 KB of data (the address wraps)
    function [31:0] memword(input [31:0] addr);
        memword = (addr[31:16] == 16'h0040) ? {cmem[{addr[15:2], 2'd3}], cmem[{addr[15:2], 2'd2}],
                                               cmem[{addr[15:2], 2'd1}], cmem[{addr[15:2], 2'd0}]}
                                            : rmem[addr[9:2]];
    endfunction
    task rpop(inout [31:0] ptr, output [31:0] v);
        begin ptr = ptr + 4; v = memword(ptr); end
    endtask
    // LDR / STR: a byte, halfword or word at addr (the low bits of an aligned size dropped)
    task rstore(input [31:0] addr, input [31:0] v, input [1:0] size);
        reg [3:0]  be;
        reg [31:0] d, m;
        integer    j;
        begin
            case (size)
                2'b00:   begin be = 4'b0001 << addr[1:0]; d = {4{v[7:0]}};  end
                2'b01:   begin be = addr[1] ? 4'b1100 : 4'b0011; d = {2{v[15:0]}}; end
                default: begin be = 4'b1111; d = v; end
            endcase
            m = rmem[addr[9:2]];
            for (j = 0; j < 4; j = j + 1) if (be[j]) m[8*j +: 8] = d[8*j +: 8];
            rmem[addr[9:2]] = m;
            e_st_a[n_st] = (size == 2'b00) ? addr : (size == 2'b01) ? {addr[31:1], 1'b0} : {addr[31:2], 2'b00};
            e_st_d[n_st] = d; e_st_be[n_st] = be; n_st = n_st + 1;
        end
    endtask
    function [31:0] rload(input [31:0] addr, input [1:0] size, input sgn);
        reg [31:0] m;
        reg [7:0]  b8;
        reg [15:0] h;
        begin
            m = memword(addr);
            b8 = m >> (8 * addr[1:0]);
            h  = addr[1] ? m[31:16] : m[15:0];
            case (size)
                2'b00:   rload = {{24{sgn & b8[7]}}, b8};
                2'b01:   rload = {{16{sgn & h[15]}}, h};
                default: rload = m;
            endcase
        end
    endfunction

    task jump(input [31:0] to);
        begin
            e_jump[n_jmp] = to; n_jmp = n_jmp + 1; r_pc = to;
            if (cur_pc[15:6] != VEC[15:6]) last_jump = cur_pc;     // not the handlers' own jumps
        end
    endtask

    // traps: random code can get caught in a loop that never ends (a jump through data
    // into random bytes, run misaligned, that jumps back). The reference counts how
    // often each address runs; past TRAP times it stops, the last jump taken is made a
    // NOP, and the reference runs again from the start. The pipeline runs the code as
    // it is in the end.
    parameter TRAP = 40;

    // the stage 3 registers and PC, as decode numbers them: 0 PSP 1 RSP 2 FP 4 TMPL 5 TMPH
    // 6 ST (the flags in bits 3..0, I in bit 4; a write sets the flags, after what the
    // ALU set, and leaves I) 7 HLIM 8 VEC (bits 9..0 are 0)
    function [31:0] s3get(input [3:0] w);
        case (w) 0: s3get = r_psp; 1: s3get = r_rsp; 2: s3get = r_fp;
                 4: s3get = r_tmpl; 6: s3get = {27'h0, r_ie, r_fl}; 7: s3get = r_hlim;
                 8: s3get = r_vec;
                 default: s3get = r_tmph; endcase
    endfunction
    task s3put(input [3:0] w, input [31:0] v);
        case (w) 0: r_psp = v; 1: r_rsp = v; 2: r_fp = v;
                 4: r_tmpl = v; 6: r_fl = v[3:0]; 7: r_hlim = v;
                 8: r_vec = {v[31:10], 10'h0}; default: r_tmph = v; endcase
    endtask

    // a register as byte 1 / 2 names it: in the register file, its stage 3 / PC number
    function file_of(input [5:0] g); file_of = !g[5] | (g[4:2] == 0); endfunction
    // PSP RSP FP TMPL TMPH ST HLIM VEC
    function is_s3(input [5:0] g); is_s3 = (g == 6'h24) || (g == 6'h25) || (g == 6'h26) || (g == 6'h28) || (g == 6'h29) || (g == 6'h2A) || (g == 6'h2B) || (g == 6'h2C); endfunction
    // 15: none
    function [3:0] w_of(input [5:0] g);
        case (g)
            6'b100100: w_of = 0; 6'b100101: w_of = 1; 6'b100110: w_of = 2;
            6'b100111: w_of = 3; 6'b101000: w_of = 4; 6'b101001: w_of = 5;
            6'b101010: w_of = 6; 6'b101011: w_of = 7; 6'b101100: w_of = 8;
            default:   w_of = 15;
        endcase
    endfunction

    // the opcodes of the instruction set (byte 0)
    function defined(input [7:0] o);
        defined = (o <= 8'h36) || (o >= 8'h40 && o <= 8'h44) || (o >= 8'h46 && o <= 8'h4A) ||
                  (o >= 8'h50 && o <= 8'h57) || (o >= 8'h80 && o <= 8'h88) ||
                  (o >= 8'h90 && o <= 8'h97) || o == 8'hC0 || o == 8'hC1 || o == 8'hC2 ||
                  o == 8'hC4 || o == 8'hC5 || o == 8'hC6 || o == 8'hC8 || (o >= 8'hD0 && o <= 8'hD7);
    endfunction

    // one instruction at r_pc
    task step;
        reg [7:0]  op, b1, b2, b3;
        reg [31:0] t, s, rr, v, nx, tg, pc_of;
        reg [2:0]  len;
        reg [5:0]  g;
        reg [3:0]  w;
        reg        in_file, to_t;
        reg [5:0]  g1, g2, g3;
        reg [31:0] v1, v2;
        integer    kk;
        reg [7:0]  by [0:3];
        begin
            for (kk = 0; kk < 4; kk = kk + 1)
                by[kk] = (r_pc[3:0] + kk >= 16) ? 8'h00 : cmem[(r_pc[15:0] + kk) & 16'hFFFF];
            op = by[0]; b1 = by[1]; b2 = by[2]; b3 = by[3];
            len = op[7:6] + 1; nx = r_pc + len; pc_of = r_pc;
            t = sp[0]; s = sp[1]; rr = sp[2];
            g = b1[5:0]; to_t = b1[6];
            in_file = !g[5] | (g[4:2] == 0);
            w = w_of(g);
            count[op] = count[op] + 1;
            cur_pc = r_pc;
            if (r_pc[15:6] == VEC[15:6]) ;                // the vector table, the handlers: every trap comes here
            else if (hits[r_pc[15:0]] == TRAP) trapped = 1;
            else hits[r_pc[15:0]] = hits[r_pc[15:0]] + 1;
            r_pc = nx;                                    // unless it jumps
            case (op)
            8'h01: begin jump(rr); rpop(r_rsp, v); w1(R_, v); end                       // RET
            8'h02: begin rpush(r_psp, s); w1(S_, t); end                                // DUP
            8'h03: begin rpop(r_psp, v); rec(1, S_, v, 1, 0, s); end                    // DROP
            8'h04: rec(1, T_, s, 1, 1, t);                                              // SWAP
            8'h05: begin rpush(r_psp, s); rec(1, T_, s, 1, 1, t); end                   // OVER
            8'h06: rpush(r_psp, s);                                                     // DIP
            8'h07: begin rpop(r_psp, v); w1(S_, v); end                                 // NIP
            8'h08: rpush(r_psp, t);                                                     // TUCK
            8'h09: begin rpop(r_psp, v); w1(T_, v); end                                 // DRIP
            8'h0A: begin rpush(r_rsp, rr); w1(R_, t); end                               // PUSH
            8'h0B: begin rpop(r_rsp, v); rec(1, R_, v, 1, 0, rr); end                   // POP
            8'h0C: begin rpush(r_rsp, rr); w1(R_, s); end                               // PUSHS
            8'h0D: begin rpop(r_rsp, v); rec(1, R_, v, 1, 1, rr); end                   // POPS
            8'h0E: begin rpop(r_psp, v); w1(T_, v); rpush(r_psp, s); w1(S_, t); end     // ROT
            8'h0F: begin rpop(r_psp, v); w1(S_, v); rpush(r_psp, t); w1(T_, s); end     // DROT
            8'h10, 8'h11, 8'h12, 8'h13, 8'h18, 8'h19, 8'h1A, 8'h32, 8'h33: begin        // binary ops
                       case (op)
                           8'h32: alu_(A_TADD, s, t, 0, 4'hF);
                           8'h33: alu_(A_TSUB, s, t, 1, 4'hF);
                           8'h10: alu_(A_ADD, s, t, 0, 4'hF);
                           8'h11: alu_(A_ADC, s, t, r_fl[0], 4'hF);
                           8'h12: alu_(A_SUB, s, t, 1, 4'hF);
                           8'h13: alu_(A_SBC, s, t, r_fl[0], 4'hF);
                           8'h18: alu_(A_AND, s, t, r_fl[0], 4'hF);
                           8'h19: alu_(A_OR,  s, t, r_fl[0], 4'hF);
                           default: alu_(A_XOR, s, t, r_fl[0], 4'hF);
                       endcase
                       rpop(r_psp, v); rec(1, S_, v, 1, 0, ra_y);
                   end
            8'h14: begin alu_(A_CSUB, t, s, 1, 4'hF); w1(T_, ra_y); end                 // CSUB
            8'h15: begin alu_(A_DIVS, t, s, r_fl[0], 4'h1);                             // DIVS
                         w1(T_, {ra_y[31:1], ra_y[0] | r_tmpl[31]});
                         r_tmpl = {r_tmpl[30:0], ra_y2[0]}; end
            8'h16: begin alu_(A_MUL,  s, t, 0, 4'h6); rec(1, T_, ra_y, 1, 1, ra_y2); end // MUL
            8'h17: begin alu_(A_SMUL, s, t, 0, 4'h6); rec(1, T_, ra_y, 1, 1, ra_y2); end // SMUL
            8'h1B: begin alu_(A_NOT, t, 0, r_fl[0], 4'hE); w1(T_, ra_y); end            // INV
            8'h1C: begin alu_(A_SUB, 0, t, 1, 4'hF); w1(T_, ra_y); end                  // NEG
            8'h1D: begin alu_(A_MULS, t, s, r_tmpl[0], 4'h0); w1(T_, ra_y);             // MULS
                         r_tmpl = {ra_y2[0], r_tmpl[31:1]}; end
            8'h1E: alu_(A_SUB, s, t, 1, 4'hF);                                          // CMP
            8'h1F: begin jump(rr); w1(R_, nx); end                                      // EXEC
            8'h20, 8'h21, 8'h22, 8'h23, 8'h24, 8'h25, 8'h26, 8'h27: begin              // shifts
                       case (op)
                           8'h20: alu_(A_ASL,  t, 1, r_fl[0], 4'hF);
                           8'h21: alu_(A_ASR,  t, 1, r_fl[0], 4'hF);
                           8'h22: alu_(A_LSL,  t, 1, r_fl[0], 4'hF);
                           8'h23: alu_(A_LSR,  t, 1, r_fl[0], 4'hF);
                           8'h24: alu_(A_ROL,  t, 1, r_fl[0], 4'hF);
                           8'h25: alu_(A_ROR,  t, 1, r_fl[0], 4'hF);
                           8'h26: alu_(A_ROLC, t, 1, r_fl[0], 4'hF);
                           default: alu_(A_RORC, t, 1, r_fl[0], 4'hF);
                       endcase
                       w1(T_, ra_y);
                   end
            // ---- LISP: the cons tag is 01, the car at - 1, the cdr at + 3
            8'h2C: w1(T_, rload(t - 1, 2'b10, 0));                                      // CAR
            8'h2D: w1(T_, rload(t + 3, 2'b10, 0));                                      // CDR
            8'h2E: rstore(t - 1, s, 2'b10);                                             // RPLACA
            8'h2F: rstore(t + 3, s, 2'b10);                                             // RPLACD
            8'h31: begin                                                                // CONS
                       v = sp[3];                                                       // L
                       if (v > r_hlim) begin                                            // full: the trap
                           n_gc = n_gc + 1;
                           jump(pc_of);               // execute sends fetch back to the CONS ...
                           rpush(r_rsp, rr); w1(R_, pc_of); jump(r_vec + 16);   // ... and EXC 4 there
                       end else begin
                           n_cons = n_cons + 1;
                           rstore(v - 1, s, 2'b10); rstore(v + 3, t, 2'b10); w1(T_, v);
                           rpop(r_psp, v1); rec(1, S_, v1, 1, 3, v + 8);
                       end
                   end
            8'h34: r_ie = 0;                                                            // CLI
            8'h35: r_ie = 1;                                                            // SEI
            8'h36: begin jump(rr); rpop(r_rsp, v); w1(R_, v); r_ie = 1; end             // RTI
            8'h49: begin rpush(r_rsp, rr); w1(R_, nx); jump(r_vec + 4 * b1);           // INTR n
                         n_intr = n_intr + 1; end
            8'h4A: begin rpush(r_rsp, rr); w1(R_, pc_of); jump(r_vec + 4 * b1);        // EXC n
                         n_exc = n_exc + 1; end
            8'h47: if (b1[7:5] <= 4) begin                                              // SHI
                       case (b1[7:5])
                           0: alu_(A_LSL, t, b1[4:0], r_fl[0], 4'hF);
                           1: alu_(A_LSR, t, b1[4:0], r_fl[0], 4'hF);
                           2: alu_(A_ASR, t, b1[4:0], r_fl[0], 4'hF);
                           3: alu_(A_ROL, t, b1[4:0], r_fl[0], 4'hF);
                           default: alu_(A_ROR, t, b1[4:0], r_fl[0], 4'hF);
                       endcase
                       w1(T_, ra_y);
                   end
            8'h87: alu_(A_TTAG, t, {16'h0, b1, b2}, r_fl[0], 4'b0010);                  // TTAG
            8'h30: begin r_rsp = r_fp; r_fp = rr; rpop(r_rsp, v); w1(R_, v); end          // LEAVE
            8'h46, 8'h86, 8'hC6: begin                                                  // ENTER, ENTER2, ENTER3
                       v = (op == 8'h46) ? {24'h0, b1} : (op == 8'h86) ? {16'h0, b2, b1} : {8'h0, b3, b2, b1};
                       rpush(r_rsp, rr); w1(R_, r_fp);            // push R, R = FP
                       r_fp = r_rsp; r_rsp = r_rsp - v * 4;       // FP = RSP, RSP = RSP - n words
                   end
            8'h28: begin alu_(A_ADD, t, 1, 0, 4'hF); w1(T_, ra_y); end                  // INC
            8'h29: begin alu_(A_SUB, t, 1, 1, 4'hF); w1(T_, ra_y); end                  // DEC
            8'h2A: begin alu_(A_ADD, t, 4, 0, 4'hF); w1(T_, ra_y); end                  // INCW
            8'h2B: begin alu_(A_SUB, t, 4, 1, 4'hF); w1(T_, ra_y); end                  // DECW
            8'h84, 8'h85: begin                                                         // LDR, STR
                       g2 = b2[5:0];
                       if (b1[7:6] != 2'b11 && file_of(g) &&
                           (file_of(g2) || w_of(g2) == 3 || w_of(g2) < 3) &&
                           (op[0] ? (b2[7:6] == 0) : !b2[6])) begin
                           if (file_of(g2))         v = get(g2);           // the address
                           else if (w_of(g2) == 3)  v = nx;
                           else                     v = s3get(w_of(g2));
                           if (op[0]) rstore(v, get(g), b1[7:6]);          // STR
                           else       w1(g, rload(v, b1[7:6], b2[7]));     // LDR
                       end
                   end
            8'hC4, 8'hC5: begin                                                         // LDR3, STR3
                       g2 = b2[5:0]; g3 = b3[5:0];
                       if (b1[7:6] != 2'b11 && file_of(g) && (file_of(g2) || w_of(g2) != 15) &&
                           (b2[6] || ((file_of(g3) || w_of(g3) != 15) && w_of(g3) != 3)) &&   // offset: imm, or not PC
                           !(is_s3(g2) && !b2[6] && is_s3(g3)) &&
                           (!op[0] || (!b2[7] && !(file_of(g2) && !b2[6] && file_of(g3))))) begin
                           v1 = file_of(g2) ? get(g2) : (w_of(g2) == 3) ? nx : s3get(w_of(g2));   // base
                           v2 = b2[6] ? {{24{b3[7]}}, b3} : file_of(g3) ? get(g3) : s3get(w_of(g3));
                           v = v1 + v2;                                                           // the address
                           if (op[0]) rstore(v, get(g), b1[7:6]);
                           else       w1(g, rload(v, b1[7:6], b2[7]));
                       end
                   end
            8'h44: if (in_file || w != 15) begin                                         // INCR .. DECWR
                       if (in_file)     v = get(g);
                       else if (w == 3) v = nx;
                       else             v = s3get(w);
                       if (b1[7]) alu_(A_SUB, v, b1[6] ? 4 : 1, 1, 4'hF);                  // reg - k
                       else       alu_(A_ADD, v, b1[6] ? 4 : 1, 0, 4'hF);                  // reg + k
                       if (in_file)     w1(g, ra_y);
                       else if (w == 3) jump(ra_y);
                       else             s3put(w, ra_y);
                   end
            8'h40: w1(T_, {{24{b1[7]}}, b1});                                           // LIT8
            8'h80: w1(T_, {{16{b2[7]}}, b2, b1});                                       // LIT16
            8'hC0: w1(T_, {{8{b3[7]}}, b3, b2, b1});                                    // LIT24
            8'h41, 8'h81, 8'hC1: begin                                                  // CJMPL, CBR, CBRL
                       if (op == 8'h41)      tg = {pc_of[31:4], b1[3:0]};
                       else if (op == 8'h81) tg = nx + {{20{b2[7]}}, b2, b1[3:0]};
                       else                  tg = nx + {{12{b3[7]}}, b3, b2, b1[3:0]};
                       rc_cond = b1[7:4]; rc_tz = (t == 0); #1;
                       if (rc_take) jump(tg);
                   end
            8'h48: if (b1[7:4] == 4'h0) begin                                           // UNEXT
                       tg = {pc_of[31:4], b1[3:0]};
                       if (rr != 0) begin w1(R_, rr - 1); jump(tg); n_loop = n_loop + 1; end
                       else         begin rpop(r_rsp, v); w1(R_, v); n_lend = n_lend + 1; end  // R dropped
                   end
            8'h88, 8'hC8: if (b1[7:6] == 2'b00 && in_file) begin                       // NEXT2, NEXT3
                       tg = nx + ((op == 8'h88) ? {{24{b2[7]}}, b2} : {{16{b3[7]}}, b3, b2});
                       v = get(g);
                       if (v != 0)        begin w1(g, v - 1); jump(tg); n_loop = n_loop + 1; end
                       else begin
                           n_lend = n_lend + 1;
                           if (g == R_) begin rpop(r_rsp, v); w1(R_, v); end            // R dropped
                       end
                   end
            8'h42, 8'h82, 8'hC2: begin                                                  // calls
                       if (op == 8'h42)      tg = nx + {{24{b1[7]}}, b1};
                       else if (op == 8'h82) tg = nx + {{16{b2[7]}}, b2, b1};
                       else                  tg = nx + {{8{b3[7]}}, b3, b2, b1};
                       rpush(r_rsp, rr); w1(R_, nx); jump(tg);
                   end
            8'h43: if (!b1[7]) begin                                                    // MOVR
                       if (in_file) begin
                           if (to_t) w1(T_, get(g)); else w1(g, t);
                       end else if (w == 3) begin
                           if (to_t) w1(T_, nx); else jump(t);
                       end else if (w != 15) begin
                           if (to_t) w1(T_, s3get(w)); else s3put(w, t);
                       end
                   end
            8'h50, 8'h51, 8'h52, 8'h53, 8'h54, 8'h55, 8'h56, 8'h57:                    // ADDR .. CMPR
                   if (!b1[7] && (in_file || w != 15)) begin
                       // the register's value
                       if (in_file)     v = get(g);
                       else if (w == 3) v = nx;
                       else             v = s3get(w);
                       // the destination comes first: T op register, or register op T
                       // (for SUBR, SBCR a plain SUB / SBC with the operands that way)
                       case (op)
                           8'h50: alu_(A_ADD, t, v, 0, 4'hF);
                           8'h51: alu_(A_ADC, t, v, r_fl[0], 4'hF);
                           8'h52: if (to_t) alu_(A_SUB, t, v, 1, 4'hF);
                                  else      alu_(A_SUB, v, t, 1, 4'hF);
                           8'h53: if (to_t) alu_(A_SBC, t, v, r_fl[0], 4'hF);
                                  else      alu_(A_SBC, v, t, r_fl[0], 4'hF);
                           8'h54: alu_(A_AND, t, v, r_fl[0], 4'hF);
                           8'h55: alu_(A_OR,  t, v, r_fl[0], 4'hF);
                           8'h56: alu_(A_XOR, t, v, r_fl[0], 4'hF);
                           default: if (to_t) alu_(A_SUB, t, v, 1, 4'hF);         // CMPR
                                    else      alu_(A_SUB, v, t, 1, 4'hF);
                       endcase
                       if (op == 8'h57)  ;                                         // CMPR: flags only
                       else if (to_t)    w1(T_, ra_y);
                       else if (in_file) w1(g, ra_y);
                       else if (w == 3)  jump(ra_y);
                       else              s3put(w, ra_y);
                   end
            8'h90, 8'h91, 8'h92, 8'h93, 8'h94, 8'h95, 8'h96, 8'h97: begin              // ADD2 .. CMP2
                       g1 = b1[5:0]; g2 = b2[5:0];
                       // both must exist, at most one in stage 3, byte 1 bits 7..6 (opx) 0
                       if (b1[7:6] == 0 && (file_of(g1) || w_of(g1) != 15) && (file_of(g2) || w_of(g2) != 15)
                           && !(!file_of(g1) && w_of(g1) != 3 && !file_of(g2) && w_of(g2) != 3)) begin
                           v1 = file_of(g1) ? get(g1) : (w_of(g1) == 3) ? nx : s3get(w_of(g1));
                           v2 = file_of(g2) ? get(g2) : (w_of(g2) == 3) ? nx : s3get(w_of(g2));
                           // dst op src, the destination first (plain SUB / SBC)
                           case (op)
                               8'h90: alu_(A_ADD, v1, v2, 0, 4'hF);
                               8'h91: alu_(A_ADC, v1, v2, r_fl[0], 4'hF);
                               8'h92: alu_(A_SUB, v1, v2, 1, 4'hF);
                               8'h93: alu_(A_SBC, v1, v2, r_fl[0], 4'hF);
                               8'h94: alu_(A_AND, v1, v2, r_fl[0], 4'hF);
                               8'h95: alu_(A_OR,  v1, v2, r_fl[0], 4'hF);
                               8'h96: alu_(A_XOR, v1, v2, r_fl[0], 4'hF);
                               default: alu_(A_SUB, v1, v2, 1, 4'hF);                // CMP2
                           endcase
                           if (op == 8'h97)      ;                                   // CMP2: flags only
                           else if (file_of(g1)) w1(g1, ra_y);
                           else if (w_of(g1) == 3) jump(ra_y);
                           else                  s3put(w_of(g1), ra_y);
                       end
                   end
            8'h83: begin                                                                // MOV2, MOVI2
                       g1 = b1[5:0]; g2 = b2[5:0];
                       if (!b1[6] && (file_of(g1) || w_of(g1) != 15) &&
                           (b1[7] || file_of(g2) || w_of(g2) != 15)) begin
                           if (b1[7])              v = {{24{b2[7]}}, b2};            // MOVI2
                           else if (file_of(g2))   v = get(g2);
                           else if (w_of(g2) == 3) v = nx;
                           else                    v = s3get(w_of(g2));
                           if (file_of(g1))        w1(g1, v);                        // no flags
                           else if (w_of(g1) == 3) jump(v);
                           else                    s3put(w_of(g1), v);
                       end
                   end
            8'hD0, 8'hD1, 8'hD2, 8'hD3, 8'hD4, 8'hD5, 8'hD6, 8'hD7: begin              // ADD3 .. CMP3
                       g1 = b1[5:0]; g2 = b2[5:0]; g3 = b3[5:0];
                       if (b1[7:6] == 0 && (file_of(g1) || w_of(g1) != 15) && (file_of(g2) || w_of(g2) != 15)
                           && (file_of(g3) || w_of(g3) != 15)
                           && !(is_s3(g2) && is_s3(g3))

                           && !(op == 8'hD7 && g1 == 6'h27)) begin                          // CMP3 PC, ..: no
                           v1 = file_of(g2) ? get(g2) : (w_of(g2) == 3) ? nx : s3get(w_of(g2));
                           v2 = file_of(g3) ? get(g3) : (w_of(g3) == 3) ? nx : s3get(w_of(g3));
                           // src1 op src2 (plain SUB / SBC)
                           case (op)
                               8'hD0: alu_(A_ADD, v1, v2, 0, 4'hF);
                               8'hD1: alu_(A_ADC, v1, v2, r_fl[0], 4'hF);
                               8'hD2: alu_(A_SUB, v1, v2, 1, 4'hF);
                               8'hD3: alu_(A_SBC, v1, v2, r_fl[0], 4'hF);
                               8'hD4: alu_(A_AND, v1, v2, r_fl[0], 4'hF);
                               8'hD5: alu_(A_OR,  v1, v2, r_fl[0], 4'hF);
                               8'hD6: alu_(A_XOR, v1, v2, r_fl[0], 4'hF);
                               default: alu_(A_SUB, v1, v2, 1, 4'hF);                // CMP3
                           endcase
                           v = (op == 8'hD7) ? {28'h0, r_fl} : ra_y;                // CMP3: the flags
                           if (file_of(g1))        w1(g1, v);
                           else if (w_of(g1) == 3) jump(v);
                           else                    s3put(w_of(g1), v);
                       end
                   end
            default: if (!defined(op)) begin                                            // undefined: exception 1
                         n_undef = n_undef + 1;
                         jump(pc_of);                     // decode sends fetch back to it ...
                         rpush(r_rsp, rr); w1(R_, pc_of); jump(r_vec + 4);   // ... and EXC 1 there
                     end                                                                // NOP
            endcase
        end
    endtask

    // ================================================================ the code
    // one random instruction at address a; returns its length
    reg [7:0] ops [0:127];
    integer   n_ops = 0;
    task opcode(input [7:0] o); begin ops[n_ops] = o; n_ops = n_ops + 1; end endtask

    function [7:0] reg_byte(input integer dummy);   // MOVR / ADDR .. CMPR byte 1
        reg [31:0] x;
        reg [5:0]  g;
        begin
            x = $random(seed);
            case (x[3:0] % 15)
                0, 1, 2, 3: g = {1'b0, 3'b000, x[5:4]};        // r0 .. r3
                4, 5:       g = {1'b1, 3'b000, x[5:4]};        // T S R L
                6:  g = 6'b100100;  7: g = 6'b100101;  8: g = 6'b100110;   // PSP RSP FP
                9:  g = 6'b100111;                                         // PC
                10: g = 6'b101000;  11: g = 6'b101001;                     // TMPL TMPH
                12: g = 6'b101010;                                         // ST
                13: g = 6'b101011;                                         // HLIM
                default: g = (x[13:8] == 6'h2C) ? 6'h2B : x[13:8];         // anything (not VEC)
            endcase
            // PC as a destination (a jump through T) only now and then
            if (g == 6'b100111 && !x[6] && x[22:21] != 0) g = 6'b100000;
            reg_byte = {(x[20:16] == 0), x[6], g};          // bit 7 now and then 1
        end
    endfunction

    task make_code;
        reg [31:0] x;
        reg [7:0]  o;
        integer    a, n;
        reg [31:0] nib;
        reg [7:0]  rb1;
        begin
            for (o = 8'h01; o <= 8'h2B; o = o + 1) opcode(o);
            opcode(8'h30); opcode(8'h46); opcode(8'h86); opcode(8'hC6);
            for (o = 8'h2C; o <= 8'h2F; o = o + 1) opcode(o);
            opcode(8'h31); opcode(8'h31); opcode(8'h32); opcode(8'h33); opcode(8'h47); opcode(8'h87);
            opcode(8'h00);
            opcode(8'h40); opcode(8'h41); opcode(8'h42); opcode(8'h43); opcode(8'h44);
            opcode(8'h50); opcode(8'h51); opcode(8'h52); opcode(8'h53);
            opcode(8'h54); opcode(8'h55); opcode(8'h56); opcode(8'h57);
            opcode(8'h80); opcode(8'h81); opcode(8'h82); opcode(8'h83);
            opcode(8'h84); opcode(8'h85);
            for (o = 8'h90; o <= 8'h97; o = o + 1) opcode(o);
            opcode(8'hC0); opcode(8'hC1); opcode(8'hC2);
            for (o = 8'hD0; o <= 8'hD7; o = o + 1) opcode(o);
            opcode(8'hC4); opcode(8'hC5);
            opcode(8'h48); opcode(8'h88); opcode(8'hC8);                       // UNEXT, NEXT2, NEXT3
            opcode(8'h34); opcode(8'h35); opcode(8'h36);                       // CLI, SEI, RTI
            opcode(8'h49); opcode(8'h4A);                                      // INTR, EXC
            // the start: HLIM = $7FFFFF (MOVR HLIM, T), so CONS allocates until L
            // passes it; L comes near it now and then (MOVR L, T), so it also traps
            cmem[0] = 8'hC0; cmem[1] = 8'hFF; cmem[2] = 8'hFF; cmem[3] = 8'h7F;    // LIT24 $7FFFFF
            cmem[4] = 8'h43; cmem[5] = 8'h2B;                                       // MOVR HLIM, T
            a = 6;
            while (a < 65536) begin
                x = $random(seed);
                if (x[7:0] < 8) o = $random(seed);                       // anything, rarely
                else if (x[7:0] < 40) o = (x[9:8] == 0) ? 8'h40 : (x[9:8] == 1) ? 8'h80 : 8'hC0;  // LITs
                else            o = ops[(x[31:16] % n_ops)];
                // jumps through data (RET, EXEC, RTI, MOVR / ADDR .. CMPR PC, T) can loop: keep them rare
                while ((o == 8'h01 || o == 8'h1F || o == 8'h36) && x[11:10] != 0) begin
                    o = ops[($random(seed) & 32'h7FFF_FFFF) % n_ops]; x[11:10] = $random(seed);
                end
                // CJMPL at the end of a line (14, 15) has no later instruction in the
                // line to jump to; at 15 its byte 1 is in the next line, read as 0:
                // EQ to the start of the line, a loop. Put a LIT8 there instead.
                if ((o == 8'h41 || o == 8'h48) && (a % 16) >= 14) o = 8'h40;
                n = o[7:6] + 1;
                // the assembler's rule: an instruction does not cross the end of a line
                // (pad with NOPs); now and then one does anyway, with 0s in the next line
                if ((a % 16) + n > 16 && x[30:28] != 0) begin
                    while (a % 16 != 0) begin cmem[a] = 8'h00; a = a + 1; end
                    if (a >= 65536) n = 0;
                end
                if (n > 0) begin
                cmem[a] = o;
                if (n > 1) cmem[(a + 1) & 16'hFFFF] = $random(seed);
                if (n > 2) cmem[(a + 2) & 16'hFFFF] = $random(seed);
                if (n > 3) cmem[(a + 3) & 16'hFFFF] = $random(seed);
                // operands that make sense, most of the time; branches and calls go
                // forward (so the program does not get caught in a loop; backward
                // jumps come from RET, EXC and the jumps through T)
                if (o == 8'h43 || (o >= 8'h50 && o <= 8'h57)) cmem[(a + 1) & 16'hFFFF] = reg_byte(0);
                if (o == 8'h84 || o == 8'h85) begin                      // LDR, STR
                    rb1 = reg_byte(0);
                    // size: byte, halfword, word; now and then 11 (does nothing)
                    nib = (x[31:29] == 0) ? 3 : (x[28:27] == 3) ? 2 : x[28:27];
                    cmem[(a + 1) & 16'hFFFF] = {nib[1:0], rb1[5:0]};
                    rb1 = reg_byte(0);
                    cmem[(a + 2) & 16'hFFFF] = {x[26], (x[25:23] == 0), rb1[5:0]};    // signed, bit 6 now and then 1
                end
                if (o == 8'hC4 || o == 8'hC5) begin                      // LDR3, STR3
                    rb1 = reg_byte(0);
                    nib = (x[31:29] == 0) ? 3 : (x[28:27] == 3) ? 2 : x[28:27];
                    cmem[(a + 1) & 16'hFFFF] = {nib[1:0], rb1[5:0]};
                    rb1 = reg_byte(0);
                    cmem[(a + 2) & 16'hFFFF] = {x[26] & (o == 8'hC4 || x[22:20] == 0), x[25], rb1[5:0]};  // signed (STR3: rarely), mode
                    cmem[(a + 3) & 16'hFFFF] = x[25] ? $random(seed) : reg_byte(0);
                end
                if (o == 8'h44) begin                                    // INCR .. DECWR: any bits 7..6
                    rb1 = reg_byte(0);
                    cmem[(a + 1) & 16'hFFFF] = {x[28], x[29], rb1[5:0]};
                end
                if (o == 8'h83) begin                                    // MOV2 / MOVI2
                    rb1 = reg_byte(0);
                    cmem[(a + 1) & 16'hFFFF] = {x[27], (x[26:24] == 0) ? 1'b1 : 1'b0, rb1[5:0]};  // bit 6 now and then 1
                    cmem[(a + 2) & 16'hFFFF] = x[27] ? $random(seed) : reg_byte(0);
                end
                if (o >= 8'hD0 && o <= 8'hD7) begin                      // ADD3 .. CMP3: three registers
                    cmem[(a + 1) & 16'hFFFF] = reg_byte(0) & ((x[26:24] == 0) ? 8'hFF : 8'h3F);  // opx now and then not 0
                    cmem[(a + 2) & 16'hFFFF] = reg_byte(0);              // bits 7..6 anything (ignored)
                    cmem[(a + 3) & 16'hFFFF] = reg_byte(0);
                end
                if (o >= 8'h90 && o <= 8'h97) begin                      // ADD2 .. CMP2: two registers
                    cmem[(a + 1) & 16'hFFFF] = reg_byte(0) & ((x[26:24] == 0) ? 8'hFF : 8'h3F);  // opx now and then not 0
                    cmem[(a + 2) & 16'hFFFF] = reg_byte(0);              // bits 7..6 anything (ignored)
                end
                if (o == 8'h47)                                          // SHI: op 5 .. 7 (nothing) now and then
                begin
                    nib = (x[18:16] == 0) ? 5 + x[20:19] % 3 : x[23:21] % 5;
                    cmem[(a + 1) & 16'hFFFF] = {nib[2:0], x[28:24]};
                end
                if (o == 8'h87)                                          // TTAG: the usual masks, mostly
                    cmem[(a + 1) & 16'hFFFF] = x[20] ? (x[21] ? 8'h03 : 8'h07) : x[31:24];
                if (o == 8'h41) begin                                    // CJMPL: later in the line
                    nib = (a % 16) + 2 + x[17:16];
                    cmem[(a + 1) & 16'hFFFF] = {x[15:12], (nib > 15) ? 4'hF : nib[3:0]};
                end
                if (o == 8'h48) begin                                    // UNEXT: later in the line
                    nib = (a % 16) + 2 + x[17:16];
                    cmem[(a + 1) & 16'hFFFF] = {(x[15:12] == 0) ? x[11:8] : 4'h0, (nib > 15) ? 4'hF : nib[3:0]};  // bits 7..4 now and then not 0
                end
                if (o == 8'h88 || o == 8'hC8) begin                      // NEXT2, NEXT3: a register, forward
                    rb1 = reg_byte(0);
                    cmem[(a + 1) & 16'hFFFF] = {(x[26:24] == 0) ? x[28:27] : 2'b00, rb1[5:0]};  // opx now and then not 0
                    cmem[(a + 2) & 16'hFFFF] = {1'b0, x[22:16]};         // +0 .. +127
                    if (o == 8'hC8) cmem[(a + 3) & 16'hFFFF] = {6'h0, x[30:29]};   // .. +1023
                end
                if (o == 8'h49) cmem[(a + 1) & 16'hFFFF] = (x[19:18] == 1) ? 8'd0 : {6'd0, x[19:18]};  // INTR 0, 2, 3
                if (o == 8'h4A) cmem[(a + 1) & 16'hFFFF] = 8'd1;                 // EXC 1
                if (o == 8'h81) cmem[(a + 2) & 16'hFFFF] = {1'b0, 2'b00, x[22:18]};   // +0 .. +511
                if (o == 8'hC1) cmem[(a + 3) & 16'hFFFF] = {1'b0, x[24:18]};
                if (o == 8'h42) cmem[(a + 1) & 16'hFFFF] = {1'b0, x[24:18]};
                if (o == 8'h82) cmem[(a + 2) & 16'hFFFF] = {1'b0, 2'b00, x[22:18]};
                if (o == 8'hC2) cmem[(a + 3) & 16'hFFFF] = {1'b0, x[24:18]};
                // crossing a line: the bytes in the next line are 0, as the assembler
                // would only allow it then
                if ((a % 16) + n > 16)
                    for (i = 16 - (a % 16); i < n; i = i + 1) cmem[(a + i) & 16'hFFFF] = 8'h00;
                a = a + n;
                end
            end
        end
    endtask

    // ================================================================ checks
    integer errors = 0, g_rec = 0, g_st = 0, g_jmp = 0, ticks = 0;

    task fail(input [8*48-1:0] what);
        begin
            errors = errors + 1;
            if (errors <= 20) $display("%t %0s", $realtime, what);
        end
    endtask

    // the data memory: checks every store as it happens
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
                    if (g_st < n_st && (b_addr !== e_st_a[g_st] || b_wdata !== e_st_d[g_st] ||
                                        b_be !== e_st_be[g_st])) begin
                        fail("store");
                        if (errors <= 20) $display("   store %0d: got [%h] = %h, expected [%h] = %h",
                                                   g_st, b_addr, b_wdata, e_st_a[g_st], e_st_d[g_st]);
                    end
                    g_st = g_st + 1;
                end else if (b_addr[31:16] == 16'h0040)                      // the code
                    b_rdata <= {cmem[{b_addr[15:2], 2'd3}], cmem[{b_addr[15:2], 2'd2}],
                                cmem[{b_addr[15:2], 2'd1}], cmem[{b_addr[15:2], 2'd0}]};
                else
                    b_rdata <= dmem[b_addr[9:2]];
                dwait = -1;
            end else dwait = dwait - 1;
        end
    end

    always @(posedge clk) if (!reset) begin
        ticks = ticks + 1;
        if (w_en || w2_en) begin
            if (g_rec < n_rec) begin
                if (w_en !== e_one[g_rec] || (w_en && (ix(w_sel) != ix(e_sel[g_rec]) ||
                                                        w_data !== e_data[g_rec])) ||
                    w2_en !== e_two[g_rec] || (w2_en && (w2_sel !== e_sp2[g_rec] ||
                                                          w2_data !== e_data2[g_rec]))) begin
                    fail("register write");
                    if (errors <= 20)
                        $display("   write %0d: got %b r%0d=%h %b sp%0d=%h, expected %b r%0d=%h %b sp%0d=%h",
                                 g_rec, w_en, ix(w_sel), w_data, w2_en, w2_sel, w2_data,
                                 e_one[g_rec], ix(e_sel[g_rec]), e_data[g_rec],
                                 e_two[g_rec], e_sp2[g_rec], e_data2[g_rec]);
                end
            end
            g_rec = g_rec + 1;
        end
        if (redirect) begin
            if (g_jmp < n_jmp && redirect_pc !== e_jump[g_jmp]) begin
                fail("jump");
                if (errors <= 20) $display("   jump %0d: got %h, expected %h",
                                           g_jmp, redirect_pc, e_jump[g_jmp]);
            end
            g_jmp = g_jmp + 1;
        end
    end

    integer k, n_kinds, n_traps;
    reg [7:0] skip_code [0:14];
    initial begin
        skip_code[0]  = 8'hC0; skip_code[1]  = 8'h00; skip_code[2]  = 8'h00; skip_code[3] = 8'h40; // LIT24 $400000 (the code)
        skip_code[4]  = 8'h50; skip_code[5]  = 8'h62;                          // ADDR T, R
        skip_code[6]  = 8'h84; skip_code[7]  = 8'h20; skip_code[8]  = 8'h20;   // LDRB T, T (the opcode)
        skip_code[9]  = 8'h47; skip_code[10] = 8'h26;                          // LSRI 6
        skip_code[11] = 8'h28;                                                 // INC: its length
        skip_code[12] = 8'h50; skip_code[13] = 8'h22;                          // ADDR R, T
        skip_code[14] = 8'h01;                                                 // RET
    end
    initial begin
        // the data memory starts with random words (the same in both), so loads see
        // negative bytes and halfwords too
        for (k = 0; k < 256; k = k + 1) begin mem0[k] = $random(seed); dmem[k] = mem0[k]; count[k] = 0; end
        for (k = 0; k < 65536; k = k + 1) cmem[k] = 0;
        make_code;
        // the vector table and the handlers (four lines, whole)
        for (k = 0; k < 64; k = k + 1) cmem[VEC[15:0] + k] = 8'h00;
        cmem[VEC[15:0] + 0] = 8'h01;                                                           // 0: RET
        cmem[VEC[15:0] + 4] = 8'h81; cmem[VEC[15:0] + 5] = 8'hE9; cmem[VEC[15:0] + 6] = 8'h01;  // 1: CBR A, skip
        cmem[VEC[15:0] + 8] = 8'h01;                                                           // 2: RET
        cmem[VEC[15:0] + 12] = 8'h01;                                                          // 3: RET
        // skip ($9020): R = R + the length of the instruction at R
        for (k = 0; k < 15; k = k + 1) cmem[VEC[15:0] + 32 + k] = skip_code[k];
        cmem[GC[15:0] + 0] = 8'h83; cmem[GC[15:0] + 1] = 8'hA3; cmem[GC[15:0] + 2] = 8'h01;   // MOVI2 L, 1
        cmem[GC[15:0] + 3] = 8'h83; cmem[GC[15:0] + 4] = 8'hAB; cmem[GC[15:0] + 5] = 8'h79;   // MOVI2 HLIM, $79
        cmem[GC[15:0] + 6] = 8'h01;                                                             // RET

        // the reference, again after each trap it breaks
        n_traps = 0;
        trapped = 1;
        while (trapped) begin
            for (k = 0; k < 32; k = k + 1) rf[k] = 0;
            for (k = 0; k < 4; k = k + 1)  sp[k] = 0;
            for (k = 0; k < 256; k = k + 1) begin rmem[k] = mem0[k]; count[k] = 0; end
            for (k = 0; k < 65536; k = k + 1) hits[k] = 0;
            r_psp = 0; r_rsp = 0; r_fp = 0; r_tmpl = 0; r_tmph = 0; r_hlim = 0; r_fl = 0; r_pc = 0;
            r_vec = VEC; r_ie = 0;
            n_cons = 0; n_gc = 0; n_loop = 0; n_lend = 0; n_intr = 0; n_exc = 0; n_undef = 0;
            n_rec = 0; n_st = 0; n_jmp = 0; trapped = 0; last_jump = 0;
            for (k = 0; k < NREF && !trapped; k = k + 1) step;
            if (trapped) begin
                cmem[last_jump[15:0]] = 8'h00;
                n_traps = n_traps + 1;
            end
        end

        // the pipeline, until it has done all the reference did
        @(posedge clk); @(posedge clk);
        #1 reset = 0;
        while ((g_rec < n_rec || g_st < n_st || g_jmp < n_jmp) && ticks < 40 * NREF)
            @(posedge clk);

        if (g_rec < n_rec || g_st < n_st || g_jmp < n_jmp) begin
            fail("the pipeline did not get as far as the reference");
            $display("   writes %0d / %0d, stores %0d / %0d, jumps %0d / %0d",
                     g_rec, n_rec, g_st, n_st, g_jmp, n_jmp);
        end
        // the most frequent opcodes
        for (i = 0; i < 3; i = i + 1) begin : top
            integer best, bk;
            best = -1; bk = 0;
            for (k = 0; k < 256; k = k + 1) if (count[k] > best) begin best = count[k]; bk = k; end
            $display("   most frequent: opcode %h, %0d times", bk[7:0], best);
            count[bk] = -count[bk];
        end
        for (k = 0; k < 256; k = k + 1) if (count[k] < 0) count[k] = -count[k];
        n_kinds = 0;
        for (k = 0; k < 256; k = k + 1) if (count[k] > 0) n_kinds = n_kinds + 1;
        $display("reference: %0d instructions (%0d different opcodes), %0d register writes, %0d stores, %0d jumps, %0d traps broken; pipeline: %0d ticks",
                 NREF, n_kinds, n_rec, n_st, n_jmp, n_traps, ticks);
        $display("   CONS: %0d allocated, %0d trapped to the GC vector", n_cons, n_gc);
        $display("   UNEXT, NEXT2, NEXT3: %0d branched, %0d ended", n_loop, n_lend);
        $display("   INTR %0d, EXC %0d, undefined opcodes (exception 1) %0d", n_intr, n_exc, n_undef);
        if (n_intr < 50 || n_exc < 50 || n_undef < 20) fail("too few INTR, EXC or undefined opcodes");
        if (n_cons < 50 || n_gc < 20) begin
            fail("too few CONS of one kind");
        end
        for (k = 0; k < 256; k = k + 1)
            if ((k <= 8'h2F || (k >= 8'h31 && k <= 8'h33) || k == 8'h47 || k == 8'h87 || k == 8'h30 || k == 8'h46 || k == 8'h86 || k == 8'hC6 || k == 8'h40 || k == 8'h41 || k == 8'h42 || k == 8'h43 || k == 8'h44 ||
                 (k >= 8'h50 && k <= 8'h57) || k == 8'h80 || k == 8'h81 || k == 8'h83 || k == 8'h84 || k == 8'h85 || (k >= 8'h90 && k <= 8'h97) || k == 8'h82 || k >= 8'hC0 && k <= 8'hC2 || k == 8'hC4 || k == 8'hC5 || k >= 8'hD0 && k <= 8'hD7 ||
                 k == 8'h48 || k == 8'h88 || k == 8'hC8 || (k >= 8'h34 && k <= 8'h36) || k == 8'h49 || k == 8'h4A)
                && count[k] < ((k == 8'h01 || k == 8'h1F || k == 8'h36) ? 25 : 50)) begin   // RET, EXEC, RTI: kept rare on purpose
                fail("an opcode ran too rarely");
                $display("   opcode %h: %0d times", k, count[k]);
            end
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
