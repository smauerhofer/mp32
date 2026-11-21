// forward_tb.v: tests forward.v in a small pipeline of stages 2 to 5.
//
//   make test-forward
// or by hand:
//   iverilog -g2005 -o forward_tb.vvp forward_tb.v forward.v scratch.v ../stage2/regfile.v \
//            ../stage4/memaccess.v ../stage5/writeback.v
//   vvp forward_tb.vvp
//
// The real register file, forwarding, memory access and writeback; decode and the
// ALU of execute are played by the test bench, with a few made-up instructions:
//
//   ADD  rd = a + b                     LD   rd = mem[a]
//   LI   rd = n                         ST   mem[a] = b
//   STW  mem[a] = b, rd = a             (a store that also writes a register, as DUP)
//   LD2  rd = mem[a], sp = a            (a load with a second write, as DROP)
//   MV2  rd = a + b, sp = b             (two writes, no memory)
//
//   RT0  TMP = b, rd = mem[a]           two steps, always back to back, as ROT and
//   RT1  mem[a] = b, rd = TMP           DROT: the real scratch register TMP carries
//                                       a value from the first to the second
//
// LI's constant n is made by decode and comes on port A as a value, as if from a
// register, with d_a_use = 0; its register field is still random, so a forwarding
// that did not respect d_a_use would overwrite it. There is no other path for
// constants: the addresses come from operand A only.
//
// sp is a special register written on the second write port. Often LD2 is exactly
// DROP: S = mem[...], T = S. Now and then rd and sp are the same register: the main
// write wins.
//
// The memory answers after 1 to 4 ticks. The registers are drawn from only r0 .. r3
// and T, S, so nearly every instruction depends on one just before it. A reference
// runs the same program one instruction at a time; every register write coming out
// of writeback (on both ports) must be the next one of the reference, and at the end
// the memory must match. Without forwarding nearly every write is wrong.

`timescale 1ns/1ps

module forward_tb;
    reg clk = 0;
    always #18.5 clk = ~clk;              // 27 MHz

    parameter N = 20000;                  // instructions

    localparam ADD = 0, LI = 1, LD = 2, ST = 3, STW = 4, LD2 = 5, MV2 = 6, RT0 = 7, RT1 = 8;

    // ================================================================ the program
    integer      p_op  [0:N-1];
    reg  [5:0]   p_rd  [0:N-1], p_ra [0:N-1], p_rb [0:N-1];
    reg  [1:0]   p_sp  [0:N-1];          // the second write's special register
    reg  [31:0]  p_imm [0:N-1];
    reg          p_gap [0:N-1];           // a bubble from decode before it

    // the reference: the writes, in order (one record per instruction that writes),
    // and the memory at the end
    reg  [5:0]   r_sel  [0:N-1];
    reg  [31:0]  r_data [0:N-1];
    reg          r_two  [0:N-1];         // a second write too
    reg  [1:0]   r_sp   [0:N-1];
    reg  [31:0]  r_data2[0:N-1];
    integer      n_writes = 0;
    reg  [31:0]  ref_regs [0:35];
    reg  [31:0]  ref_mem  [0:63];
    reg  [31:0]  ref_tmp;

    integer seed = 17, i, k;

    // 0..31 the register file, 32..35 T, S, R, L, 36: a special selector that is not
    // in the register file (bits 4..2 not 000: in stage 3); it reads as 0
    function integer index(input [5:0] sel);
        index = !sel[5] ? sel[4:0] : (sel[4:2] == 3'b000) ? 32 + sel[1:0] : 36;
    endfunction

    function [5:0] random_reg(input integer dummy);
        reg [31:0] r;
        begin
            r = $random(seed);
            case (r[2:0] % 6)
                0, 1, 2, 3: random_reg = {1'b0, 3'b000, r[4:3]};
                4:          random_reg = 6'b100000;               // T
                default:    random_reg = 6'b100001;               // S
            endcase
        end
    endfunction

    function [31:0] word_addr(input [31:0] a);
        word_addr = a & 32'h0000_00FC;
    endfunction

    task make_program;
        reg [31:0] a, b, ad;
        begin
            for (i = 0; i < 36; i = i + 1) ref_regs[i] = 0;
            for (i = 0; i < 64; i = i + 1) ref_mem[i]  = 0;
            for (k = 0; k < N; k = k + 1) begin
                if (k > 0 && p_op[k-1] == RT0) p_op[k] = RT1;   // the second step
                else begin
                    p_op[k] = (($random(seed) & 32'h7FFF_FFFF) % 8);
                    if (k == N - 1 && p_op[k] == RT0) p_op[k] = ADD;
                end
                p_rd[k]  = random_reg(0);
                p_ra[k]  = random_reg(0);
                p_rb[k]  = random_reg(0);
                p_sp[k]  = $random(seed) & 1;          // T or S
                if (p_op[k] == LD2 && ($random(seed) & 1)) begin
                    p_rd[k] = 6'b100001; p_ra[k] = 6'b100001; p_sp[k] = 2'b00;  // DROP
                end
                p_imm[k] = $random(seed);
                p_gap[k] = ($random(seed) & 7) == 0 && p_op[k] != RT1;
                a  = ref_regs[index(p_ra[k])];
                b  = ref_regs[index(p_rb[k])];
                ad = word_addr(a);
                case (p_op[k])
                ADD: begin r_sel[n_writes] = p_rd[k]; r_data[n_writes] = a + b; end
                LI:  begin r_sel[n_writes] = p_rd[k]; r_data[n_writes] = p_imm[k]; end
                LD:  begin r_sel[n_writes] = p_rd[k]; r_data[n_writes] = ref_mem[ad[7:2]]; end
                STW: begin r_sel[n_writes] = p_rd[k]; r_data[n_writes] = a; end
                LD2: begin r_sel[n_writes] = p_rd[k]; r_data[n_writes] = ref_mem[ad[7:2]]; end
                MV2: begin r_sel[n_writes] = p_rd[k]; r_data[n_writes] = a + b; end
                RT0: begin r_sel[n_writes] = p_rd[k]; r_data[n_writes] = ref_mem[ad[7:2]]; end
                RT1: begin r_sel[n_writes] = p_rd[k]; r_data[n_writes] = ref_tmp; end
                default: ;
                endcase
                r_two[n_writes]   = (p_op[k] == LD2 || p_op[k] == MV2);
                r_sp[n_writes]    = p_sp[k];
                r_data2[n_writes] = (p_op[k] == LD2) ? a : b;
                if (p_op[k] == ST || p_op[k] == STW || p_op[k] == RT1) ref_mem[ad[7:2]] = b;
                if (p_op[k] == RT0) ref_tmp = b;
                if (p_op[k] != ST) begin
                    if (r_two[n_writes]) ref_regs[32 + p_sp[k]] = r_data2[n_writes];
                    ref_regs[index(r_sel[n_writes])] = r_data[n_writes];   // main wins
                    n_writes = n_writes + 1;
                end
            end
        end
    endtask

    // ================================================================ the pipeline
    reg reset = 1;

    // ---- stage 2: decode (the test bench) and the register file
    integer     pc = 0;
    reg         gap_done = 0;
    wire        d_valid = (pc < N) && !(p_gap[pc] && !gap_done);
    wire [5:0]  d_a_sel = p_ra[pc < N ? pc : 0];
    wire [5:0]  d_b_sel = p_rb[pc < N ? pc : 0];
    wire        d_a_use = (p_op[pc < N ? pc : 0] != LI);
    wire        d_b_use = (p_op[pc < N ? pc : 0] == ADD) || (p_op[pc < N ? pc : 0] == ST) ||
                          (p_op[pc < N ? pc : 0] == STW) || (p_op[pc < N ? pc : 0] == MV2) ||
                          (p_op[pc < N ? pc : 0] == RT0) || (p_op[pc < N ? pc : 0] == RT1);
    wire [31:0] a_data, b_data;
    // decode: LI's constant goes out on port A instead of the register's value
    wire        d_const = (p_op[pc < N ? pc : 0] == LI);
    wire [31:0] d_a_val = d_const ? p_imm[pc < N ? pc : 0] : a_data;

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

    // ---- stage 3: forwarding (real) and the ALU (the test bench)
    wire        mem_stall;
    wire        e_valid, load_use, advance;
    wire [31:0] e_a, e_b;

    reg         x_valid = 0, x_load = 0, x_store = 0, x_wen = 0;
    reg  [5:0]  x_rd = 0;
    reg  [31:0] x_addr = 0, x_wdata = 0, x_result = 0;
    reg         x2_wen = 0;
    reg  [1:0]  x2_sel = 0;
    reg  [31:0] x2_data = 0;

    // the rest of the instruction in execute
    integer     e_op;
    reg  [5:0]  e_rd;
    reg  [1:0]  e_sp;

    forward fw (
        .clk(clk), .reset(reset), .mem_stall(mem_stall), .flush(1'b0),
        .d_valid(d_valid), .d_a_use(d_a_use), .d_a_sel(d_a_sel), .d_a_data(d_a_val),
        .d_b_use(d_b_use), .d_b_sel(d_b_sel), .d_b_data(b_data),
        .e_wen(e_op != ST), .e_rd(e_rd), .e_x2_wen((e_op == LD2) || (e_op == MV2)),
        .e_x2_sel(e_sp), .e_load((e_op == LD) || (e_op == LD2) || (e_op == RT0)),
        .x_valid(x_valid), .x_wen(x_wen), .x_load(x_load), .x_rd(x_rd),
        .x_result(x_result), .x2_wen(x2_wen), .x2_sel(x2_sel), .x2_data(x2_data),
        .w_en(w_en), .w_sel(w_sel), .w_data(w_data),
        .w2_en(w2_en), .w2_sel(w2_sel), .w2_data(w2_data),
        .e_valid(e_valid), .e_a(e_a), .e_b(e_b), .load_use(load_use), .advance(advance)
    );


    // TMP (real): written by RT0 as it leaves execute, read by RT1
    wire [31:0] tmp;
    scratch scr (
        .clk(clk), .en(e_valid & advance), .we(e_op == RT0), .d(e_b), .tmp(tmp)
    );

    always @(posedge clk) begin
        // decode moves on when stage 3 takes its instruction
        if (!reset && advance) begin
            if (d_valid) begin
                e_op <= p_op[pc]; e_rd <= p_rd[pc]; e_sp <= p_sp[pc];
                pc <= pc + 1; gap_done <= 0;
            end else if (pc < N)
                gap_done <= 1;
        end
        // stage 3's output registers
        if (reset)
            x_valid <= 0;
        else if (!mem_stall) begin
            x_valid  <= e_valid & !load_use;
            x_load   <= (e_op == LD) || (e_op == LD2) || (e_op == RT0);
            x_store  <= (e_op == ST) || (e_op == STW) || (e_op == RT1);
            x_wen    <= (e_op != ST);
            x_rd     <= e_rd;
            x_addr   <= word_addr(e_a);
            x_wdata  <= e_b;
            x_result <= (e_op == ADD) ? e_a + e_b :
                        (e_op == LI)  ? e_a       :
                        (e_op == STW) ? e_a       :
                        (e_op == MV2) ? e_a + e_b :
                        (e_op == RT1) ? tmp       : 32'hx;
            x2_wen   <= (e_op == LD2) || (e_op == MV2);
            x2_sel   <= e_sp;
            x2_data  <= (e_op == LD2) ? e_a : e_b;
        end
    end

    // ---- stage 4: memory access (real) and a memory
    wire        m_valid, m_wen;
    wire [5:0]  m_rd;
    wire [31:0] m_data;
    wire        m2_wen;
    wire [1:0]  m2_sel;
    wire [31:0] m2_data;
    wire        d_sel, d_we;
    wire [3:0]  d_be;
    wire [31:0] d_addr, d_wdata;
    reg  [31:0] d_rdata = 0;
    reg         d_ready = 0;

    memaccess ma (
        .clk(clk), .reset(reset),
        .x_valid(x_valid), .x_load(x_load), .x_store(x_store), .x_size(2'b10),
        .x_signed(1'b0), .x_addr(x_addr), .x_wdata(x_wdata), .x_wen(x_wen),
        .x_rd(x_rd), .x_result(x_result),
        .x2_wen(x2_wen), .x2_sel(x2_sel), .x2_data(x2_data), .stall(mem_stall),
        .d_sel(d_sel), .d_we(d_we), .d_be(d_be), .d_addr(d_addr),
        .d_wdata(d_wdata), .d_rdata(d_rdata), .d_ready(d_ready),
        .m_valid(m_valid), .m_wen(m_wen), .m_rd(m_rd), .m_data(m_data),
        .m2_wen(m2_wen), .m2_sel(m2_sel), .m2_data(m2_data)
    );

    reg [31:0] mem [0:63];
    integer    wait_ticks = -1;
    always @(posedge clk) begin
        d_ready <= 0;
        if (d_sel && !d_ready) begin
            if (wait_ticks < 0) wait_ticks = $random(seed) & 3;
            if (wait_ticks == 0) begin
                d_ready <= 1;
                if (d_we) mem[d_addr[7:2]] <= d_wdata;
                else      d_rdata <= mem[d_addr[7:2]];
                wait_ticks = -1;
            end else
                wait_ticks = wait_ticks - 1;
        end
    end

    // ---- stage 5: writeback (real)
    writeback wb (
        .m_valid(m_valid), .m_wen(m_wen), .m_rd(m_rd), .m_data(m_data),
        .m2_wen(m2_wen), .m2_sel(m2_sel), .m2_data(m2_data),
        .w_en(w_en), .w_sel(w_sel), .w_data(w_data),
        .w2_en(w2_en), .w2_sel(w2_sel), .w2_data(w2_data)
    );

    // ================================================================ checks
    integer errors = 0, n_got = 0, ticks = 0, n_load_use = 0, n_hold = 0;

    always @(posedge clk) if (!reset) begin
        ticks = ticks + 1;
        if (load_use) n_load_use = n_load_use + 1;
        if (!advance) n_hold = n_hold + 1;
        if (w_en || w2_en) begin
            if (n_got >= n_writes) begin
                errors = errors + 1;
                $display("%t a write too many", $realtime);
            end else begin
                if (!w_en || index(w_sel) != index(r_sel[n_got]) || w_data !== r_data[n_got]) begin
                    errors = errors + 1;
                    if (errors <= 20)
                        $display("%t write %0d: got reg %0d = %h, expected reg %0d = %h",
                                 $realtime, n_got, index(w_sel), w_data,
                                 index(r_sel[n_got]), r_data[n_got]);
                end
                if (w2_en !== r_two[n_got] ||
                    (w2_en && (w2_sel !== r_sp[n_got] || w2_data !== r_data2[n_got]))) begin
                    errors = errors + 1;
                    if (errors <= 20)
                        $display("%t write %0d, port W2: got %b sp %0d = %h, expected %b sp %0d = %h",
                                 $realtime, n_got, w2_en, w2_sel, w2_data,
                                 r_two[n_got], r_sp[n_got], r_data2[n_got]);
                end
            end
            n_got = n_got + 1;
        end
    end

    initial begin
        for (i = 0; i < 64; i = i + 1) mem[i] = 0;
        make_program;
        repeat (2) @(posedge clk);
        #1 reset = 0;
        wait (pc == N);
        repeat (20) @(posedge clk);
        #1;
        if (n_got != n_writes) begin
            errors = errors + 1;
            $display("%0d writes, expected %0d", n_got, n_writes);
        end
        for (i = 0; i < 64; i = i + 1)
            if (mem[i] !== ref_mem[i]) begin
                errors = errors + 1;
                if (errors <= 20) $display("mem[%0d] = %h, expected %h", i, mem[i], ref_mem[i]);
            end
        $display("%0d instructions in %0d ticks, %0d load-use stalls, %0d ticks held",
                 N, ticks, n_load_use, n_hold);
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
