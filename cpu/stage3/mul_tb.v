// mul_tb.v: tests mul.v (its simulation model) against 64-bit integer arithmetic.
//
//   make test-mul
// or by hand:
//   iverilog -g2005 -DMP32_SIM -o mul_tb.vvp mul_tb.v mul.v
//   vvp mul_tb.vvp
//
// Unsigned and signed, edge values and 200,000 random cases. (The real multiplier
// on the chip is the GW2AR's MULT36X36; `make size` shows that it is used.)

`timescale 1ns/1ps

module mul_tb;
    reg  [31:0] a = 0, b = 0;
    reg         sgn = 0;
    wire [63:0] p;
    reg  [63:0] want;
    reg  [31:0] edges [0:5];
    integer errors = 0, i, j, k, seed = 3;

    mul dut (.a(a), .b(b), .sgn(sgn), .p(p));

    task check;
        begin
            #1;
            want = sgn ? $signed({{32{a[31]}}, a}) * $signed({{32{b[31]}}, b})
                       : {32'h0, a} * {32'h0, b};
            if (p !== want) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("%s %h * %h: got %h, expected %h",
                             sgn ? "signed" : "unsigned", a, b, p, want);
            end
        end
    endtask

    initial begin
        edges[0] = 0; edges[1] = 1; edges[2] = 32'hFFFF_FFFF;
        edges[3] = 32'h7FFF_FFFF; edges[4] = 32'h8000_0000; edges[5] = 32'h0001_0000;
        for (i = 0; i < 6; i = i + 1)
            for (j = 0; j < 6; j = j + 1)
                for (k = 0; k < 2; k = k + 1) begin
                    a = edges[i]; b = edges[j]; sgn = k; check;
                end
        for (i = 0; i < 200000; i = i + 1) begin
            a = $random(seed); b = $random(seed); sgn = $random(seed); check;
        end
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
