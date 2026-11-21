// writeback_tb.v: tests writeback.v together with the register file of stage 2.
//
//   make test-writeback
// or by hand:
//   iverilog -g2005 -o writeback_tb.vvp writeback_tb.v writeback.v ../stage2/regfile.v
//   vvp writeback_tb.vvp
//
// Stage 4 is played by the test bench: it sends instructions into m_* (results for
// r0 .. r31 and T, S, R, L, instructions that write nothing, bubbles), some with a
// second write to a special register (m2_*), as DROP. Every write
// must land in the right register, nothing else may change, and the value must be
// readable in decode in the same tick (pass-through). Then thousands of random ticks
// against a model.

`timescale 1ns/1ps

module writeback_tb;
    reg clk = 0;
    always #18.5 clk = ~clk;              // 27 MHz

    localparam [5:0] T = 6'b100000, S = 6'b100001, R = 6'b100010, L = 6'b100011;

    reg         reset = 0;
    reg         m_valid = 0, m_wen = 0;
    reg  [5:0]  m_rd = 0;
    reg  [31:0] m_data = 0;
    reg         m2_wen = 0;
    reg  [1:0]  m2_sel = 0;
    reg  [31:0] m2_data = 0;
    wire        w_en, w2_en;
    wire [5:0]  w_sel;
    wire [1:0]  w2_sel;
    wire [31:0] w_data, w2_data;

    reg  [5:0]  a_sel = 0, b_sel = 0;
    wire [31:0] a_data, b_data, t, s, r, l;

    writeback dut (
        .m_valid(m_valid), .m_wen(m_wen), .m_rd(m_rd), .m_data(m_data),
        .m2_wen(m2_wen), .m2_sel(m2_sel), .m2_data(m2_data),
        .w_en(w_en), .w_sel(w_sel), .w_data(w_data),
        .w2_en(w2_en), .w2_sel(w2_sel), .w2_data(w2_data)
    );

    regfile regs (
        .clk(clk), .reset(reset),
        .a_sel(a_sel), .a_data(a_data), .b_sel(b_sel), .b_data(b_data),
        .w_en(w_en), .w_sel(w_sel), .w_data(w_data),
        .w2_en(w2_en), .w2_sel(w2_sel), .w2_data(w2_data),
        .t(t), .s(s), .r(r), .l(l)
    );

    // ---- the model: 0..31 the register file, 32..35 T, S, R, L
    reg [31:0] m [0:36];
    integer errors = 0, i, k, seed = 3;

    // 0..31 the register file, 32..35 T, S, R, L, 36: a special selector that is not
    // in the register file (bits 4..2 not 000: in stage 3); it reads as 0
    function integer index(input [5:0] sel);
        index = !sel[5] ? sel[4:0] : (sel[4:2] == 3'b000) ? 32 + sel[1:0] : 36;
    endfunction

    // what decode reads now: a register being written reads as the new value
    function [31:0] model_read(input [5:0] sel);
        model_read = index(sel) == 36                                 ? 32'h0   :
                     (m_valid && m_wen  && index(sel) == index(m_rd)) ? m_data  :
                     (m_valid && m2_wen && index(sel) == 32 + m2_sel)  ? m2_data :
                                                                         m[index(sel)];
    endfunction

    task expect(input [31:0] got, input [31:0] want, input [8*32-1:0] what);
        begin
            if (got !== want) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("%t %0s: got %h, expected %h", $realtime, what, got, want);
            end
        end
    endtask

    task check_all;
        begin
            expect(a_data, model_read(a_sel), "port A");
            expect(b_data, model_read(b_sel), "port B");
            expect(t, model_read(T), "T");
            expect(s, model_read(S), "S");
            expect(r, model_read(R), "R");
            expect(l, model_read(L), "L");
        end
    endtask

    task edge_;
        begin
            @(posedge clk);
            if (m_valid && m2_wen) m[32 + m2_sel] = m2_data;
            if (m_valid && m_wen)  m[index(m_rd)] = m_data;     // W wins
            m[36] = 0;                                          // not in the register file
            if (reset) begin m[32] = 0; m[33] = 0; m[34] = 0; m[35] = 0; end
            #1;
        end
    endtask

    // one instruction from stage 4
    task send(input v, input we, input [5:0] rd, input [31:0] d);
        begin
            m_valid = v; m_wen = we; m_rd = rd; m_data = d;
            a_sel = rd; #1;
            check_all;
            edge_;
            m_valid = 0;
        end
    endtask

    initial begin
        for (i = 0; i < 37; i = i + 1) m[i] = 0;
        reset = 1; edge_; reset = 0;

        // ---- every general register
        for (i = 0; i < 32; i = i + 1) send(1, 1, i, 32'hC0DE0000 | i);
        for (i = 0; i < 32; i = i + 1) begin
            a_sel = i; #1;
            expect(a_data, 32'hC0DE0000 | i, "r written");
        end

        // ---- the special registers
        send(1, 1, T, 32'h1111_1111);
        send(1, 1, S, 32'h2222_2222);
        send(1, 1, R, 32'h3333_3333);
        send(1, 1, L, 32'h4444_4444);
        #1;
        expect(t, 32'h1111_1111, "T written");
        expect(s, 32'h2222_2222, "S written");
        expect(r, 32'h3333_3333, "R written");
        expect(l, 32'h4444_4444, "L written");
        a_sel = 0; #1; expect(a_data, 32'hC0DE0000, "r0 untouched by specials");

        // ---- no write: m_wen = 0, and a bubble with m_wen = 1
        send(1, 0, 5'd5, 32'hBAD0_0001);
        send(0, 1, 5'd6, 32'hBAD0_0002);
        send(0, 1, T,    32'hBAD0_0003);
        a_sel = 5; b_sel = 6; #1;
        expect(a_data, 32'hC0DE0005, "r5 not written (m_wen = 0)");
        expect(b_data, 32'hC0DE0006, "r6 not written (bubble)");
        expect(t, 32'h1111_1111, "T not written (bubble)");

        // ---- DROP: S from memory on W, T = old S on W2, in one tick
        m_valid = 1; m_wen = 1; m_rd = S; m_data = 32'hD0D0_0001;
        m2_wen = 1; m2_sel = 2'b00; m2_data = 32'h2222_2222;
        a_sel = S; b_sel = T; #1;
        expect(a_data, 32'hD0D0_0001, "DROP: S passed through");
        expect(b_data, 32'h2222_2222, "DROP: T passed through");
        edge_; m_valid = 0; m2_wen = 0; #1;
        expect(s, 32'hD0D0_0001, "DROP: S written");
        expect(t, 32'h2222_2222, "DROP: T written");

        // a bubble with m2_wen = 1 writes nothing
        m_valid = 0; m2_wen = 1; m2_sel = 2'b11; m2_data = 32'hBAD0_0004; edge_;
        m2_wen = 0; #1;
        expect(l, 32'h4444_4444, "L not written (bubble on W2)");

        // ---- pass-through: decode reads the value in the tick it is written
        m_valid = 1; m_wen = 1; m_rd = 9; m_data = 32'h0BAD_F00D;
        a_sel = 9; b_sel = 9; #1;
        expect(a_data, 32'h0BAD_F00D, "pass-through A");
        expect(b_data, 32'h0BAD_F00D, "pass-through B");
        edge_; m_valid = 0;

        // ---- random ticks against the model
        for (k = 0; k < 20000; k = k + 1) begin
            m_valid = ($random(seed) & 3) != 0;
            m_wen   = ($random(seed) & 3) != 0;
            m_rd    = $random(seed);
            m_data  = $random(seed);
            m2_wen  = $random(seed);
            m2_sel  = ($random(seed) & 1) ? m_rd[1:0] : $random(seed);
            m2_data = $random(seed);
            a_sel   = ($random(seed) & 1) ? m_rd : $random(seed);
            b_sel   = $random(seed);
            reset   = ($random(seed) & 1023) == 0;
            #1;
            if (!reset) check_all;
            edge_;
        end

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
