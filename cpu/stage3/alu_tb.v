// alu_tb.v: tests alu.v and flags.v.
//
//   make test-alu
// or by hand:
//   iverilog -g2005 -DMP32_SIM -o alu_tb.vvp alu_tb.v alu.v mul.v flags.v
//   vvp alu_tb.vvp
//
// Every op is checked against a reference written another way (64-bit integer
// arithmetic, a bit at a time for the shifts): first on edge values (0, 1, -1,
// 0x7FFFFFFF, 0x80000000, ...) with both carries and every shift amount, then on
// random values. MUL and SMUL are checked against 64-bit multiplies, unsigned and
// signed. CSUB is checked as an unsigned compare followed by a subtract or
// not, and in use: 3,000 divisions done with ROL64 and CSUB as a program would.
// DIVS is checked against 33-bit integer arithmetic and a multiply by 2 (its use, the
// 64 / 32 division, is tested in tmplh_tb.v with the real TMPL).
// TADD and TSUB are checked as ADD and SUB with V also set by a tag that is not 00;
// TTAG against (a & mask) == (value & mask) on every low byte with many masks.
// Then the flags register: random masks, en and reset against a model.

`timescale 1ns/1ps

module alu_tb;
    localparam [4:0] ADD = 5'd0,  ADC = 5'd1,  SUB = 5'd2,  SBC = 5'd3,
                     AND = 5'd4,  OR  = 5'd5,  XOR = 5'd6,  NOT = 5'd7,
                     LSL = 5'd8,  LSR = 5'd9,  ASR = 5'd10, ROR = 5'd11,
                     LSL64 = 5'd12, LSR64 = 5'd13, ASR64 = 5'd14,
                     ROL64 = 5'd15, ROR64 = 5'd16, CSUB = 5'd17, DIVS = 5'd18,
                     MUL = 5'd19, SMUL = 5'd20, ASL = 5'd21,
                     ROL = 5'd22, ROLC = 5'd23, RORC = 5'd24, MULS = 5'd25,
                     RSB = 5'd26, RSC = 5'd27, TADD = 5'd28, TSUB = 5'd29, TTAG = 5'd30;
    localparam       NOPS = 31;           // ops 0 .. 30

    reg  [4:0]  op = 0;
    reg  [31:0] a = 0, b = 0;
    reg         cin = 0;
    wire [31:0] y, y2;
    wire [3:0]  fl;

    alu dut (.op(op), .a(a), .b(b), .cin(cin), .y(y), .y2(y2), .flags(fl));

    integer errors = 0, checks = 0, seed = 21, i, j, k, o;

    // ================================================================ the reference
    reg [31:0] ry, ry2;
    reg        rc, rv;
    reg [63:0] w;
    integer    s, t;
    reg signed [63:0] sa, sb, sr;

    task reference;
        begin
            ry2 = 0; rc = cin; rv = 0;
            case (op)
            ADD, ADC, SUB, SBC, TADD, TSUB: begin
                // unsigned: carry; signed: overflow
                case (op)
                    ADD, TADD: w = {32'h0, a} + {32'h0, b};
                    ADC: w = {32'h0, a} + {32'h0, b} + cin;
                    SUB, TSUB: w = {32'h0, a} + {32'h0, ~b} + 1;
                    SBC: w = {32'h0, a} + {32'h0, ~b} + cin;
                endcase
                ry = w[31:0]; rc = w[32];
                sa = $signed(a); sb = $signed(b);
                case (op)
                    ADD, TADD: sr = sa + sb;
                    ADC: sr = sa + sb + cin;
                    SUB, TSUB: sr = sa - sb;
                    SBC: sr = sa - sb - (1 - cin);
                endcase
                rv = (sr > 64'sh7FFFFFFF) || (sr < -64'sh80000000);
                // tagged: a value that is not a fixnum (low bits not 00) sets V too
                if ((op == TADD || op == TSUB) && (a % 4 != 0 || b % 4 != 0)) rv = 1;
            end
            TTAG: ry = {24'h0, (a[7:0] ^ b[7:0]) & b[15:8]};
            RSB, RSC: begin                     // b - a, as integers
                w = (op == RSB) ? {32'h0, b} - {32'h0, a} : {32'h0, b} - {32'h0, a} - (1 - cin);
                ry = w[31:0]; rc = !w[63];      // no borrow: the difference is not negative
                sa = $signed(a); sb = $signed(b);
                sr = (op == RSB) ? sb - sa : sb - sa - (1 - cin);
                rv = (sr > 64'sh7FFFFFFF) || (sr < -64'sh80000000);
            end
            CSUB: begin                         // unsigned compare, then subtract or not
                if (a >= b) begin
                    ry = a - b; rc = 1;
                    sr = $signed(a) - $signed(b);
                    rv = (sr > 64'sh7FFFFFFF) || (sr < -64'sh80000000);
                end else begin
                    ry = a; rc = 0; rv = 0;
                end
            end
            DIVS: begin                         // 33 bits, as integers, then the shift
                w = {31'h0, cin, a};
                if (w >= b) begin w = w - b; ry2 = 1; end else ry2 = 0;
                rc = w[31]; ry = w[31:0] * 2;
            end
            MUL: begin w = {32'h0, a} * {32'h0, b}; ry = w[31:0]; ry2 = w[63:32]; end
            SMUL: begin
                sr = $signed({{32{a[31]}}, a}) * $signed({{32{b[31]}}, b});
                ry = sr[31:0]; ry2 = sr[63:32];
            end
            ASL: begin                          // 2 * a, signed, the sign kept
                sr = $signed(a) * 2;
                rv = (sr > 64'sh7FFFFFFF) || (sr < -64'sh80000000);
                ry = {a[31], sr[30:0]}; rc = a[30];
            end
            AND: begin ry = a & b; rv = ry[30]; end
            OR:  begin ry = a | b; rv = ry[30]; end
            XOR: begin ry = a ^ b; rv = ry[30]; end
            NOT: begin ry = ~a; rv = ry[30]; end
            MULS: begin                         // 33-bit add or not, then halved
                w = {32'h0, a} + (cin ? {32'h0, b} : 64'h0);
                ry = w[32:1]; ry2 = {31'h0, w[0]};
            end
            ROLC: begin ry = {a[30:0], cin}; rc = a[31]; end
            RORC: begin ry = {cin, a[31:1]}; rc = a[0];  end
            LSL, LSR, ASR, ROR, ROL: begin      // one bit at a time
                ry = a;
                if (op == LSL) begin            // V: a * 2^n does not fit (signed)
                    sr = $signed({{32{a[31]}}, a}) * (64'sd1 << b[4:0]);
                    rv = (sr > 64'sh7FFFFFFF) || (sr < -64'sh80000000);
                end
                for (s = 0; s < b[4:0]; s = s + 1)
                    case (op)
                        LSL: begin rc = ry[31]; ry = {ry[30:0], 1'b0}; end
                        LSR: begin rc = ry[0];  ry = {1'b0, ry[31:1]}; end
                        ASR: begin rc = ry[0];  ry = {ry[31], ry[31:1]}; end
                        ROR: begin ry = {ry[0], ry[31:1]}; rc = ry[31]; end
                        ROL: begin ry = {ry[30:0], ry[31]}; rc = ry[0]; end
                    endcase
            end
            LSL64, LSR64, ASR64, ROL64, ROR64: begin
                w = {b, a};
                case (op)
                    LSL64: begin rc = w[63]; w = w * 2; end
                    ROL64: begin rc = w[63]; w = w * 2 + cin; end
                    LSR64: begin rc = w[0];  w = w / 2; end
                    ASR64: begin rc = w[0];  w = w / 2; w[63] = b[31]; end
                    ROR64: begin rc = w[0];  w = w / 2; w[63] = cin; end
                endcase
                ry = w[31:0]; ry2 = w[63:32];
            end
            default: begin w = {32'h0, a} + {32'h0, b}; ry = w[31:0]; rc = w[32];
                     sr = $signed(a) + $signed(b);
                     rv = (sr > 64'sh7FFFFFFF) || (sr < -64'sh80000000); end
            endcase
        end
    endtask

    task check;
        reg wide, rz, rn;
        begin
            #1;
            reference;
            wide = ((op >= LSL64) && (op <= ROR64)) || (op == MUL) || (op == SMUL);
            rz = wide ? ({ry2, ry} == 0) : (ry == 0);
            rn = wide ? ry2[31] : ry[31];
            checks = checks + 1;
            if (y !== ry || y2 !== ry2 || fl !== {rv, rn, rz, rc}) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("op %0d a=%h b=%h cin=%b: got y=%h y2=%h VNZC=%b, expected y=%h y2=%h VNZC=%b",
                             op, a, b, cin, y, y2, fl, ry, ry2, {rv, rn, rz, rc});
            end
        end
    endtask

    // ================================================================ the flags register
    reg        clk = 0, reset = 0, en = 0;
    reg  [3:0] mask = 0, alu_f = 0, mf;
    wire [3:0] f;
    always #18.5 clk = ~clk;

    flags fr (.clk(clk), .reset(reset), .en(en), .mask(mask), .alu_flags(alu_f), .f(f));

    reg [31:0] edges [0:9];

    initial begin
        edges[0] = 32'h0000_0000; edges[1] = 32'h0000_0001; edges[2] = 32'hFFFF_FFFF;
        edges[3] = 32'h7FFF_FFFF; edges[4] = 32'h8000_0000; edges[5] = 32'h8000_0001;
        edges[6] = 32'h0000_001F; edges[7] = 32'h0000_0020; edges[8] = 32'h5555_5555;
        edges[9] = 32'hAAAA_AAAA;

        // ---- edge values, both carries
        for (o = 0; o < NOPS; o = o + 1)
            for (i = 0; i < 10; i = i + 1)
                for (j = 0; j < 10; j = j + 1)
                    for (k = 0; k < 2; k = k + 1) begin
                        op = o; a = edges[i]; b = edges[j]; cin = k; check;
                    end
        // ---- every shift amount
        for (o = LSL; o <= ROR; o = o + 1)
            for (i = 0; i < 64; i = i + 1)
                for (k = 0; k < 2; k = k + 1) begin
                    op = o; a = 32'hC3A5_0F81; b = i; cin = k; check;
                end
        for (i = 0; i < 64; i = i + 1)
            for (k = 0; k < 2; k = k + 1) begin
                op = ROL; a = 32'hC3A5_0F81; b = i; cin = k; check;
            end
        // ---- TTAG: Z is the tag test, (a & mask) == (value & mask); every low byte
        for (i = 0; i < 256; i = i + 1)
            for (j = 0; j < 300; j = j + 1) begin
                op = TTAG; a = {$random(seed), i[7:0]}; b = $random(seed); cin = $random(seed);
                if (j < 8) b[15:8] = 8'hFF >> j;                 // the usual masks
                check;
                checks = checks + 1;
                if (fl[1] !== ((a[7:0] & b[15:8]) == (b[7:0] & b[15:8]))) begin
                    errors = errors + 1;
                    if (errors <= 20) $display("TTAG a=%h b=%h: Z=%b", a, b, fl[1]);
                end
            end
        // ---- random
        for (i = 0; i < 200000; i = i + 1) begin
            op = (($random(seed) & 32'h7FFF_FFFF) % NOPS);
            a = $random(seed); b = $random(seed); cin = $random(seed);
            if (($random(seed) & 7) == 0) b = a;              // equal: Z, borrow edge
            check;
        end

        // ---- a 32 / 32 division done with ROL64 and CSUB, as a program would do it:
        // {hi, lo} = {remainder, dividend}; 32 times: shift left through the carry
        // (the carry is the quotient bit of the step before), CSUB the divisor from
        // the high word. A last ROL64 brings the last quotient bit in; the remainder is
        // hi before it. (So shifted, the divisor must be below 2^31.)
        for (k = 0; k < 3000; k = k + 1) begin : divide
            reg [31:0] n0, lo, hi, dv, rem;
            reg        cy;
            n0 = $random(seed); dv = $random(seed) & 32'h7FFF_FFFF;
            dv = dv >> ($random(seed) & 31);
            if (dv == 0) dv = 1;
            lo = n0; hi = 0; cy = 0;
            for (s = 0; s < 32; s = s + 1) begin
                op = ROL64; a = lo; b = hi; cin = cy; #1;
                lo = y; hi = y2;
                op = CSUB; a = hi; b = dv; cin = 1; #1;
                hi = y; cy = fl[0];
            end
            rem = hi;
            op = ROL64; a = lo; b = hi; cin = cy; #1;
            checks = checks + 1;
            if (y !== n0 / dv || rem !== n0 % dv) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("divide %h / %h: got q=%h r=%h, expected q=%h r=%h",
                             n0, dv, y, rem, n0 / dv, n0 % dv);
            end
        end

        // ---- the flags register against a model
        reset = 1; @(posedge clk); #1 reset = 0; mf = 0;
        if (f !== 0) begin errors = errors + 1; $display("flags not cleared by reset"); end
        for (i = 0; i < 20000; i = i + 1) begin
            en = $random(seed); mask = $random(seed); alu_f = $random(seed);
            reset = ($random(seed) & 255) == 0;
            @(posedge clk);
            if (reset)   mf = 0;
            else if (en) mf = (mf & ~mask) | (alu_f & mask);
            #1;
            checks = checks + 1;
            if (f !== mf) begin
                errors = errors + 1;
                if (errors <= 20) $display("flags: got %b, expected %b", f, mf);
            end
        end

        $display("%0d checks", checks);
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
