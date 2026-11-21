// regfile_tb.v: tests regfile.v.
//
//   make test-regfile
// or by hand:
//   iverilog -g2005 -o regfile_tb.vvp regfile_tb.v regfile.v
//   vvp regfile_tb.vvp
//
// First a few fixed cases: every general register written and read back on both
// ports, a read of the register being written (it must give the new value), T, S, R
// and L through the ports, on their own outputs and with reset, and the unused bits
// 4..2 of a special selector (they count: 1001xx etc. are not here). Then thousands of random ticks against a model: random
// reads on both ports, random writes to any register, now and then reset.

`timescale 1ns/1ps

module regfile_tb;
    reg clk = 0;
    always #18.5 clk = ~clk;              // 27 MHz

    // the selectors of the special registers
    localparam [5:0] T = 6'b100000, S = 6'b100001, R = 6'b100010, L = 6'b100011;

    reg         reset = 0;
    reg  [5:0]  a_sel = 0, b_sel = 0, w_sel = 0;
    reg         w_en = 0;
    reg  [31:0] w_data = 0;
    reg         w2_en = 0;
    reg  [1:0]  w2_sel = 0;
    reg  [31:0] w2_data = 0;
    wire [31:0] a_data, b_data, t, s, r, l;

    regfile dut (
        .clk(clk), .reset(reset),
        .a_sel(a_sel), .a_data(a_data),
        .b_sel(b_sel), .b_data(b_data),
        .w_en(w_en), .w_sel(w_sel), .w_data(w_data),
        .w2_en(w2_en), .w2_sel(w2_sel), .w2_data(w2_data),
        .t(t), .s(s), .r(r), .l(l)
    );

    // ---- the model: 0..31 the register file, 32..35 T, S, R, L
    reg [31:0] m [0:36];
    integer errors = 0, i, k;
    integer seed = 11;

    // 0..31 the register file, 32..35 T, S, R, L, 36: a special selector that is not
    // in the register file (bits 4..2 not 000: in stage 3); it reads as 0
    function integer index(input [5:0] sel);
        index = !sel[5] ? sel[4:0] : (sel[4:2] == 3'b000) ? 32 + sel[1:0] : 36;
    endfunction

    function [31:0] model_read(input [5:0] sel);
        model_read = index(sel) == 36                         ? 32'h0   :
                     (w_en  && index(sel) == index(w_sel))   ? w_data  :
                     (w2_en && index(sel) == 32 + w2_sel)    ? w2_data : m[index(sel)];
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

    task check_outputs;
        begin
            expect(a_data, model_read(a_sel), "port A");
            expect(b_data, model_read(b_sel), "port B");
            expect(t, model_read(T), "T");
            expect(s, model_read(S), "S");
            expect(r, model_read(R), "R");
            expect(l, model_read(L), "L");
        end
    endtask

    // the edge: the model does what the registers do
    task edge_;
        begin
            @(posedge clk);
            if (w2_en) m[32 + w2_sel] = w2_data;
            if (w_en)  m[index(w_sel)] = w_data;       // W wins
            m[36] = 0;                                  // not in the register file
            if (reset) begin
                m[32] = 0; m[33] = 0; m[34] = 0; m[35] = 0;
            end
            #1;
        end
    endtask

    initial begin
        for (i = 0; i < 37; i = i + 1) m[i] = 0;

        // ---- after loading, everything is 0
        reset = 1; edge_; reset = 0;
        for (i = 0; i < 32; i = i + 1) begin
            a_sel = i; b_sel = 31 - i; #1;
            check_outputs;
        end

        // ---- write every general register, read it back on both ports
        for (i = 0; i < 32; i = i + 1) begin
            w_en = 1; w_sel = i; w_data = 32'hA5000000 | (i << 8) | i;
            edge_;
        end
        w_en = 0;
        for (i = 0; i < 32; i = i + 1) begin
            a_sel = i; b_sel = i; #1;
            expect(a_data, 32'hA5000000 | (i << 8) | i, "read back A");
            expect(b_data, 32'hA5000000 | (i << 8) | i, "read back B");
        end

        // ---- a read of the register being written gives the new value
        a_sel = 7; b_sel = 7; w_en = 1; w_sel = 7; w_data = 32'hDEADBEEF; #1;
        expect(a_data, 32'hDEADBEEF, "write-through A");
        expect(b_data, 32'hDEADBEEF, "write-through B");
        edge_;
        w_en = 0; #1;
        expect(a_data, 32'hDEADBEEF, "after write-through");

        // ---- T, S, R, L: written through port W, read on A, B and their outputs
        w_en = 1;
        w_sel = T; w_data = 32'h11111111; edge_;
        w_sel = S; w_data = 32'h22222222; edge_;
        w_sel = R; w_data = 32'h33333333; edge_;
        w_sel = L; w_data = 32'h44444444; #1;
        expect(l, 32'h44444444, "L passed through");
        edge_;
        w_en = 0;
        a_sel = T; b_sel = S; #1;
        expect(a_data, 32'h11111111, "T on A");
        expect(b_data, 32'h22222222, "S on B");
        a_sel = R; b_sel = L; #1;
        expect(a_data, 32'h33333333, "R on A");
        expect(b_data, 32'h44444444, "L on B");
        expect(t, 32'h11111111, "T out");
        expect(s, 32'h22222222, "S out");
        expect(r, 32'h33333333, "R out");
        expect(l, 32'h44444444, "L out");

        // the specials did not touch r0 .. r3
        a_sel = 0; b_sel = 3; #1;
        expect(a_data, 32'hA5000000, "r0 untouched");
        expect(b_data, 32'hA5000303, "r3 untouched");

        // all 5 bits count: 100101 (RSP, in stage 3) is not S; it reads as 0, and a
        // write with it changes nothing here
        a_sel = 6'b100101; #1;
        expect(a_data, 32'h0, "a stage 3 selector reads 0");
        w_en = 1; w_sel = 6'b100101; w_data = 32'hDEAD_BEEF; a_sel = 6'b100101; #1;
        expect(a_data, 32'h0, "no pass-through for a stage 3 selector");
        edge_; w_en = 0; #1;
        expect(s, 32'h22222222, "S not written by 100101");

        // reset clears T, S, R, L, not the register file
        reset = 1; edge_; reset = 0; #1;
        expect(t | s | r | l, 0, "T, S, R, L after reset");
        a_sel = 7; #1;
        expect(a_data, 32'hDEADBEEF, "r7 after reset (not cleared)");

        // ---- port W2: a special register written alongside port W, as DROP does
        a_sel = S; b_sel = T;
        w_en = 1; w_sel = S; w_data = 32'hAAAA0001;   // S from memory
        w2_en = 1; w2_sel = 2'b00; w2_data = 32'hBBBB0002;   // T = old S
        #1;
        expect(a_data, 32'hAAAA0001, "S passed through from W");
        expect(b_data, 32'hBBBB0002, "T passed through from W2");
        expect(t, 32'hBBBB0002, "t passed through from W2");
        edge_;
        w_en = 0; w2_en = 0; #1;
        expect(s, 32'hAAAA0001, "S written by W");
        expect(t, 32'hBBBB0002, "T written by W2");

        // W and W2 on the same register: W wins
        w_en = 1; w_sel = R; w_data = 32'h1234_5678;
        w2_en = 1; w2_sel = 2'b10; w2_data = 32'h8765_4321;
        a_sel = R; #1;
        expect(a_data, 32'h1234_5678, "W wins, passed through");
        edge_;
        w_en = 0; w2_en = 0; #1;
        expect(r, 32'h1234_5678, "W wins, written");

        // W2 never touches the register file
        w2_en = 1; w2_sel = 2'b11; w2_data = 32'h5555_5555; edge_;
        w2_en = 0; a_sel = 3; #1;
        expect(a_data, 32'hA5000303, "r3 not touched by W2");
        expect(l, 32'h5555_5555, "L written by W2");

        // ---- random ticks against the model
        for (k = 0; k < 20000; k = k + 1) begin
            a_sel  = $random(seed);
            b_sel  = ($random(seed) & 1) ? a_sel : $random(seed);
            w_en   = $random(seed);
            w_sel  = ($random(seed) & 3) == 0 ? a_sel : $random(seed);
            w_data = $random(seed);
            w2_en   = $random(seed);
            w2_sel  = ($random(seed) & 1) ? w_sel[1:0] : $random(seed);
            w2_data = $random(seed);
            reset  = ($random(seed) & 255) == 0;
            #1;
            if (!reset) check_outputs;
            edge_;
        end

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
