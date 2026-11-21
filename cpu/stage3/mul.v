// mul.v: the 32 x 32 -> 64 multiplier of the mp32 processor, on the on-chip
// multiplier of the GW2AR (one MULT36X36: 4 of the 18 x 18 multipliers).
//
//   p = a * b, 64 bits. sgn = 0: unsigned; 1: signed (two's complement). No clock:
//   all the primitive's registers are bypassed, so the product is ready in the same
//   tick.
//
// Simulation: iverilog has no model of MULT36X36, so with MP32_SIM defined (the
// Makefiles pass -DMP32_SIM) the same product is written as a plain multiply.

module mul (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire        sgn,            // 1: signed
    output wire [63:0] p
);
`ifdef MP32_SIM
    // 33 bits, signed: the 32 bits with a sign bit (0 when unsigned)
    wire signed [32:0] sa = $signed({sgn & a[31], a});
    wire signed [32:0] sb = $signed({sgn & b[31], b});
    wire signed [65:0] sp = sa * sb;
    assign p = sp[63:0];
`else
    // 36-bit inputs: the 32 bits, extended by 4 sign bits (or 0s when unsigned)
    wire [35:0] a36 = {{4{sgn & a[31]}}, a};
    wire [35:0] b36 = {{4{sgn & b[31]}}, b};
    wire [71:0] dout;

    MULT36X36 #(
        .AREG(1'b0), .BREG(1'b0), .OUT0_REG(1'b0), .OUT1_REG(1'b0),
        .PIPE_REG(1'b0), .ASIGN_REG(1'b0), .BSIGN_REG(1'b0),
        .MULT_RESET_MODE("SYNC")
    ) dsp (
        .A(a36), .B(b36), .ASIGN(sgn), .BSIGN(sgn),
        .CE(1'b1), .CLK(1'b0), .RESET(1'b0),
        .DOUT(dout)
    );

    assign p = dout[63:0];
`endif
endmodule
