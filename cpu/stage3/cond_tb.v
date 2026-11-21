// cond_tb.v: tests cond.v.
//
//   make test-cond
// or by hand:
//   iverilog -g2005 -o cond_tb.vvp cond_tb.v cond.v
//   vvp cond_tb.vvp
//
// Every condition with every combination of the flags and of T == 0 (16 x 16 x 2),
// against a reference written as a list of the 16 conditions. Then the compare conditions in use: for
// random S and T (and edge values), the flags of CMP (S - T, as the ALU makes them)
// must give EQ / NE / CS / CC / HI / LS / GE / LT / GT / LE exactly as comparing S and
// T as integers does.

`timescale 1ns/1ps

module cond_tb;
    reg  [3:0] cd = 0, f = 0;
    reg        tz = 0;
    wire       take;
    integer    errors = 0, i, j, k, seed = 41;
    reg        want, c, z, n, v;

    cond dut (.cond(cd), .f(f), .tz(tz), .take(take));

    function ref_take(input [3:0] cc, input [3:0] ff, input t0);
        reg c, z, n, v;
        begin
            c = ff[0]; z = ff[1]; n = ff[2]; v = ff[3];
            case (cc)
                4'h0: ref_take = z == 1;
                4'h1: ref_take = z == 0;
                4'h2: ref_take = c == 1;
                4'h3: ref_take = c == 0;
                4'h4: ref_take = n == 1;
                4'h5: ref_take = n == 0;
                4'h6: ref_take = v == 1;
                4'h7: ref_take = v == 0;
                4'h8: ref_take = c == 1 && z == 0;
                4'h9: ref_take = c == 0 || z == 1;
                4'hA: ref_take = n == v;
                4'hB: ref_take = n != v;
                4'hC: ref_take = z == 0 && n == v;
                4'hD: ref_take = z == 1 || n != v;
                4'hE: ref_take = 1;
                4'hF: ref_take = t0;            // TZ: T == 0, whatever the flags
            endcase
        end
    endfunction

    // the flags of S - T, as SUB / CMP set them (6502: C = no borrow)
    reg [32:0] d;
    reg [31:0] s_, t_;
    task cmp_flags;
        begin
            d = {1'b0, s_} + {1'b0, ~t_} + 33'd1;
            f = {(s_[31] != t_[31]) && (d[31] != s_[31]),    // V
                 d[31],                                       // N
                 d[31:0] == 0,                                // Z
                 d[32]};                                      // C
        end
    endtask

    task check_compare;
        reg w;
        begin
            cmp_flags;
            for (k = 0; k < 14; k = k + 1) begin
                cd = k; #1;
                case (k)
                    0:  w = s_ == t_;
                    1:  w = s_ != t_;
                    2:  w = s_ >= t_;
                    3:  w = s_ <  t_;
                    8:  w = s_ >  t_;
                    9:  w = s_ <= t_;
                    10: w = $signed(s_) >= $signed(t_);
                    11: w = $signed(s_) <  $signed(t_);
                    12: w = $signed(s_) >  $signed(t_);
                    13: w = $signed(s_) <= $signed(t_);
                    default: w = take;                        // MI .. VC: no compare meaning
                endcase
                if (take !== w) begin
                    errors = errors + 1;
                    if (errors <= 20) $display("compare S=%h T=%h cond %h: got %b", s_, t_, k, take);
                end
            end
        end
    endtask

    reg [31:0] edges [0:5];

    initial begin
        // ---- every condition, every flag combination
        for (i = 0; i < 16; i = i + 1)
            for (j = 0; j < 16; j = j + 1)
                for (k = 0; k < 2; k = k + 1) begin
                    cd = i; f = j; tz = k; #1;
                    want = ref_take(i, j, k);
                    if (take !== want) begin
                        errors = errors + 1;
                        $display("cond %h flags VNZC=%b tz=%b: got %b, expected %b",
                                 i, j[3:0], tz, take, want);
                    end
                end
        tz = 0;

        // ---- after CMP: the compare conditions against integer compares
        edges[0] = 0; edges[1] = 1; edges[2] = 32'hFFFF_FFFF;
        edges[3] = 32'h7FFF_FFFF; edges[4] = 32'h8000_0000; edges[5] = 32'h8000_0001;
        for (i = 0; i < 6; i = i + 1)
            for (j = 0; j < 6; j = j + 1) begin
                s_ = edges[i]; t_ = edges[j]; check_compare;
            end
        for (i = 0; i < 100000; i = i + 1) begin
            s_ = $random(seed); t_ = ($random(seed) & 3) == 0 ? s_ : $random(seed);
            check_compare;
        end

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
