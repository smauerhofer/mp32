// tmplh_tb.v: tests tmplh.v, alone and with the ALU.
//
//   make test-tmplh
// or by hand:
//   iverilog -g2005 -o tmplh_tb.vvp tmplh_tb.v tmplh.v alu.v
//   vvp tmplh_tb.vvp
//
// First the registers against a model: random writes of either or both, en, reset.
// Then the use they are made for: the ALU's 64-bit shifts on {TMPH, TMPL}, one bit
// per tick, with the carry fed back as the C flag would be. A 64-bit value is
// rotated 65 times through the carry with ROL64 (it must come back), shifted with
// LSL64 / LSR64 / ASR64 / ROR64 against 64-bit arithmetic, and so on at random.
// Last, DIVS: 64 / 32 divisions, {T, TMPL} = the dividend, S = the divisor (any 32-bit
// value, with the high word below it), C = 0, 33 steps; TMPL must be the quotient and
// {C, T} >> 1 the remainder (T bit 0 = 0).

`timescale 1ns/1ps

module tmplh_tb;
    reg clk = 0;
    always #18.5 clk = ~clk;

    localparam [5:0] LSL64 = 6'd12, LSR64 = 5'd13, ASR64 = 5'd14, ROL64 = 5'd15, ROR64 = 5'd16,
                     DIVS = 5'd18, MULS = 5'd25;

    reg         reset = 1, en = 0, we_l = 0, we_h = 0, use_alu = 0, sh_l = 0, sh_r = 0;
    reg         multiply = 0;             // MULS: a = T, b = S, cin = TMPL[0]
    reg  [31:0] d_l = 0, d_h = 0;
    wire [31:0] tmpl, tmph;

    // the ALU on {TMPH, TMPL}
    reg  [5:0]  op = LSL64;
    reg         c = 0;                    // the C flag
    reg         divide = 0;               // DIVS: a = T, b = S, cin = C
    reg  [31:0] t_reg = 0, s_reg = 0;     // T and S, for DIVS
    wire [31:0] y, y2;
    wire [3:0]  fl;
    alu alu (.op(op), .a(divide | multiply ? t_reg : tmpl), .b(divide | multiply ? s_reg : tmph), .bo(divide | multiply ? s_reg : tmph),
             .cin(multiply ? tmpl[0] : c), .y(y), .y2(y2), .flags(fl));

    tmplh dut (
        .clk(clk), .reset(reset), .en(en),
        .we_l(we_l), .d_l(use_alu ? y : d_l), .we_h(we_h), .d_h(use_alu ? y2 : d_h),
        .sh_l(sh_l), .sh_r(sh_r), .sh_bit(y2[0]),
        .tmpl(tmpl), .tmph(tmph)
    );

    integer errors = 0, i, k, seed = 31;
    reg [31:0] ml, mh;
    reg [63:0] v, start;
    reg        mc;

    task expect(input [63:0] got, input [63:0] want, input [8*32-1:0] what);
        begin
            if (got !== want) begin
                errors = errors + 1;
                if (errors <= 20) $display("%t %0s: got %h, expected %h", $realtime, what, got, want);
            end
        end
    endtask

    // one 64-bit shift: TMPH:TMPL from the ALU, C from the ALU's carry
    task shift64(input [5:0] o);
        begin
            op = o; use_alu = 1; en = 1; we_l = 1; we_h = 1; #1;
            @(posedge clk); c = fl[0]; #1;
            en = 0; we_l = 0; we_h = 0; use_alu = 0;
        end
    endtask

    task load(input [63:0] x);
        begin
            en = 1; we_l = 1; we_h = 1; d_l = x[31:0]; d_h = x[63:32];
            @(posedge clk); #1; en = 0; we_l = 0; we_h = 0;
        end
    endtask

    initial begin
        @(posedge clk); #1 reset = 0;
        expect({tmph, tmpl}, 0, "after reset");

        // ---- the registers against a model
        ml = 0; mh = 0;
        for (i = 0; i < 20000; i = i + 1) begin
            en = $random(seed); we_l = $random(seed); we_h = $random(seed);
            d_l = $random(seed); d_h = $random(seed);
            reset = ($random(seed) & 255) == 0;
            @(posedge clk);
            if (reset) begin ml = 0; mh = 0; end
            else if (en) begin if (we_l) ml = d_l; if (we_h) mh = d_h; end
            #1;
            expect({tmph, tmpl}, {mh, ml}, "registers");
        end
        reset = 0; en = 0; we_l = 0; we_h = 0;

        // ---- ROL64 65 times through the carry brings the value back
        start = {$random(seed), $random(seed)};
        load(start); c = 0;
        for (i = 0; i < 65; i = i + 1) shift64(ROL64);
        expect({tmph, tmpl}, start, "ROL64 x 65");
        expect(c, 0, "carry after ROL64 x 65");

        // ---- random 64-bit shifts against 64-bit arithmetic
        for (k = 0; k < 2000; k = k + 1) begin
            v = {$random(seed), $random(seed)}; load(v); c = $random(seed); mc = c;
            for (i = 0; i < 8; i = i + 1) begin
                op = LSL64 + (($random(seed) & 32'h7FFF_FFFF) % 5);
                case (op)
                    LSL64: begin mc = v[63]; v = v << 1; end
                    ROL64: begin {mc, v} = {v, mc}; end
                    LSR64: begin mc = v[0];  v = v >> 1; end
                    ASR64: begin mc = v[0];  v = {v[63], v[63:1]}; end
                    ROR64: begin {v, mc} = {mc, v}; end
                endcase
                shift64(op);
                expect({tmph, tmpl}, v, "64-bit shift");
                expect(c, mc, "64-bit shift carry");
            end
        end

        // ---- DIVS: 64 / 32 division in 32 steps
        for (k = 0; k < 5000; k = k + 1) begin : divide64
            reg [31:0] dv, hi, lo;
            reg [63:0] n64;
            reg [31:0] t_next;
            dv = $random(seed);
            if (k & 1) dv = dv >> ($random(seed) & 31);
            if (k % 4 == 0) dv = dv | 32'h8000_0000;          // divisors of 2^31 and up
            if (dv == 0) dv = 1;
            hi = $random(seed) % dv; if (hi >= dv) hi = dv - 1;
            lo = $random(seed);
            n64 = {hi, lo};
            load({32'h0, lo});                                // TMPL = the low word
            t_reg = hi; s_reg = dv; c = 0;
            for (i = 0; i < 33; i = i + 1) begin
                divide = 1; op = DIVS; en = 1; sh_l = 1; #1;
                t_next = y | tmpl[31];                        // T = y, TMPL's top bit in
                @(posedge clk); #1; t_reg = t_next; c = fl[0];   // TMPL shifted, C
                en = 0; sh_l = 0; divide = 0;
            end
            expect(tmpl, n64 / dv, "DIVS quotient");
            expect({c, t_reg[31:1]}, n64 % dv, "DIVS remainder");
            expect(t_reg[0], 0, "DIVS T bit 0");
        end

        // ---- MULS: 32 x 32 -> 64 multiply in 32 steps
        for (k = 0; k < 5000; k = k + 1) begin : multiply32
            reg [31:0] m1, m2, add, t_next;
            reg [63:0] prod;
            m1 = $random(seed); m2 = $random(seed);
            add = (k & 2) ? $random(seed) : 0;                // T at the start
            if (k % 8 == 0) m1 = 32'hFFFF_FFFF;
            if (k % 8 == 1) m2 = 32'hFFFF_FFFF;
            prod = {32'h0, m1} * {32'h0, m2} + add;
            load({32'h0, m2});                                // TMPL = the multiplier
            t_reg = add; s_reg = m1;
            for (i = 0; i < 32; i = i + 1) begin
                multiply = 1; op = MULS; en = 1; sh_r = 1; #1;
                t_next = y;
                @(posedge clk); #1; t_reg = t_next;           // TMPL shifted right
                en = 0; sh_r = 0; multiply = 0;
            end
            expect({t_reg, tmpl}, prod, "MULS product");
        end

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
