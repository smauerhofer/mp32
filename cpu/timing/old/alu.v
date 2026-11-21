// alu.v: the ALU of the mp32 processor, in stage 3 (execute).
//
//   Two 32-bit inputs, a and b, a carry in, two 32-bit outputs, y and y2, and four
//   flags out. No clock: the flags register is flags.v.
//
// ---------------------------------------------------------------- the flags
//   bit 0  C  carry       add: the carry out; subtract: 1 = no borrow (as the 6502);
//                         shift: the last bit shifted out
//   bit 1  Z  zero        the result is 0 (for a 64-bit shift: all 64 bits)
//   bit 2  N  negative    bit 31 of the result (for a 64-bit shift: bit 63)
//   bit 3  V  overflow    add/subtract: signed overflow; AND, OR, XOR, NOT: bit 30
//                         of the result (as the 6502's BIT gives bit 6); ASL: 2 * a
//                         overflows; LSL: a << n overflows (signed), i.e. the top
//                         n + 1 bits of a are not all equal; all other ops: 0
//
// When an op does not set C (logic ops, a shift by 0), C out is the carry in. So with
// cin = the C flag, C stays as it is even if the op's flags mask updates it.
//
// ---------------------------------------------------------------- the ops
//   op     name    y                               y2       C out
//   00000  ADD     a + b                           0        carry
//   00001  ADC     a + b + cin                     0        carry
//   00010  SUB     a - b                           0        no borrow
//   00011  SBC     a - b - (1 - cin)               0        no borrow
//   00100  AND     a & b                           0        cin
//   00101  OR      a | b                           0        cin
//   00110  XOR     a ^ b                           0        cin
//   00111  NOT     ~a                              0        cin
//   01000  LSL     a << b[4:0]                     0        last bit out (cin if 0)
//   01001  LSR     a >> b[4:0]                     0        last bit out (cin if 0)
//   01010  ASR     a >> b[4:0], sign kept          0        last bit out (cin if 0)
//   01011  ROR     a rotated right by b[4:0]       0        bit 31 of y (cin if 0)
//   01100  LSL64   {b, a} << 1        (y = low word, y2 = high word)    b[31]
//   01101  LSR64   {b, a} >> 1                                          a[0]
//   01110  ASR64   {b, a} >> 1, sign kept                               a[0]
//   01111  ROL64   {b, a} << 1, cin into bit 0                          b[31]
//   10000  ROR64   {b, a} >> 1, cin into bit 63                         a[0]
//   10001  CSUB    a - b if that needs no borrow,  0        1 = taken (no borrow),
//                  else a (unchanged)                       0 = not taken
//   10010  DIVS    r = {cin, a} (33 bits);         {0, q}   bit 31 of d, the bit
//                  q = (r >= b);                            shifted out
//                  d = q ? r - b : r[31:0];
//                  y = {d[30:0], 0}: d shifted left
//   10011  MUL     a * b, low word                 high     cin
//                  (unsigned, 64 bits)             word
//   10100  SMUL    a * b, low word                 high     cin
//                  (signed, 64 bits)               word
//   10101  ASL     a << 1, bit 31 kept:            0        a[30], the bit pushed
//                  {a[31], a[29:0], 0}                      out
//   10110  ROL     a rotated left by b[4:0]        0        bit 0 of y (cin if 0)
//   10111  ROLC    {a[30:0], cin}: rotate left     0        a[31]
//                  through the carry (33 bits)
//   11000  RORC    {cin, a[31:1]}: rotate right    0        a[0]
//                  through the carry (33 bits)
//   11001  MULS    w = a + (cin ? b : 0), 33 bits; {0, w[0]} cin
//                  y = w[32:1]: w shifted right
//   11010  RSB     b - a                           0        no borrow
//   11011  RSC     b - a - (1 - cin)               0        no borrow
//   others: as ADD
//
// RSB and RSC are SUB and SBC with a and b the other way round: the adder inverts a
// instead of b (b - a = ~a + b + 1). SUBR and SBCR use them when the register, not T, is the destination
// (register = register - T), because a register of stage 3 (PSP, RSP, FP, TMPL,
// TMPH) can only come in on b. Their flags are those of SUB and SBC on (b, a).
//
// MULS is one step of a 32 x 32 multiply (shift and add): a = T (the high word so
// far), b = S (the multiplicand), cin = TMPL[0] (the multiplier bit: add or not). The
// add's carry comes into bit 31 of y; w[0], the bit shifted out, goes into bit 31 of
// TMPL as TMPL shifts right (tmplh.v). Z and N are those of y, V is 0.
//
// ASL is 2* for signed numbers: the sign stays. V = 1 if 2 * a does not fit in 32
// bits (signed), i.e. a[31] != a[30]; Z, N are those of y.
//
// MUL and SMUL use the on-chip multiplier (mul.v). Their Z and N are those of the
// 64-bit product (Z: all 64 bits 0, N: bit 63), C is cin, V is 0.
//
// DIVS is one step of a 64 / 32 division: first the conditional subtract, then the
// shift. a = T (the remainder so far), b = S (the divisor), cin = the C flag (the bit
// the step before shifted out of T, so r has 33 bits and no bit is lost). y2[0] = q is
// the quotient bit; it goes into TMPL at the bottom as TMPL shifts left, and the bit
// coming out of TMPL goes into bit 0 of y (both in stage 3: tmplh.v). Z and N are
// those of y, V is 0.
//
// CSUB is the step of a division (restoring division): subtract when it fits. Its Z
// and N are those of y (what is kept); V is the overflow of the subtraction when it
// is taken, 0 when not.
//
// For the 64-bit shifts a is the low word and b the high word; they shift by one bit,
// through the carry for ROL64 / ROR64, so a 64-bit value can be shifted one bit per
// instruction (as in a multiply or divide done by the program).

module alu (
    input  wire [4:0]  op,
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire        cin,
    output reg  [31:0] y,
    output reg  [31:0] y2,
    output wire [3:0]  flags           // {V, N, Z, C}
);
    localparam [4:0] ADD = 5'd0,  ADC = 5'd1,  SUB = 5'd2,  SBC = 5'd3,
                     AND = 5'd4,  OR  = 5'd5,  XOR = 5'd6,  NOT = 5'd7,
                     LSL = 5'd8,  LSR = 5'd9,  ASR = 5'd10, ROR = 5'd11,
                     LSL64 = 5'd12, LSR64 = 5'd13, ASR64 = 5'd14,
                     ROL64 = 5'd15, ROR64 = 5'd16, CSUB = 5'd17, DIVS = 5'd18,
                     MUL = 5'd19, SMUL = 5'd20, ASL = 5'd21,
                     ROL = 5'd22, ROLC = 5'd23, RORC = 5'd24, MULS = 5'd25,
                     RSB = 5'd26, RSC = 5'd27;

    // ---- the adder: a' + b' + c', for add and subtract. a - b = a + ~b + 1 inverts b;
    // the reverse subtract b - a = ~a + b + 1 (RSB, RSC) inverts a instead.
    wire        rev   = (op == RSB) | (op == RSC);
    wire        sub   = (op == SUB) | (op == SBC) | (op == CSUB);
    wire [31:0] a_in  = rev ? ~a : a;
    wire [31:0] b_in  = sub ? ~b : b;
    wire        c_in  = (op == ADC) | (op == SBC) | (op == RSC) ? cin : sub | rev;
    wire [32:0] sum   = {1'b0, a_in} + {1'b0, b_in} + {32'h0, c_in};
    wire        ovf   = (a_in[31] == b_in[31]) & (sum[31] != a_in[31]);

    // ---- the multiply step: add b if cin, then shift right (33 bits)
    wire [32:0] mul_w = {1'b0, a} + (cin ? {1'b0, b} : 33'h0);

    // ---- the multiplier: the on-chip one
    wire [63:0] prod;
    mul multiplier (.a(a), .b(b), .sgn(op == SMUL), .p(prod));

    // ---- the division step: 33 bits {cin, a} minus b if it fits, then shifted
    wire [32:0] div_r = {cin, a};
    wire [33:0] div_d = {1'b0, div_r} - {2'b00, b};
    wire        div_q = !div_d[33];                           // no borrow: it fits
    wire [31:0] div_k = div_q ? div_d[31:0] : div_r[31:0];    // what is kept

    // ---- the 32-bit shifts by n = b[4:0]: one shifter to the right for all five.
    // A left shift or rotate is a right one of the bits in reverse order. Above the
    // word goes what comes in (0, copies of the sign, or the word again for the
    // rotates), below it one bit that catches the last bit shifted out (the carry).
    function [31:0] reverse(input [31:0] x);
        integer i;
        for (i = 0; i < 32; i = i + 1) reverse[i] = x[31 - i];
    endfunction

    wire [4:0]  n     = b[4:0];
    wire        left  = (op == LSL) | (op == ROL);
    wire [31:0] src   = left ? reverse(a) : a;
    wire [31:0] fill  = (op == ASR) ? {32{a[31]}} :
                        (op == ROR) | (op == ROL) ? src : 32'h0;
    wire [64:0] shr   = {fill, src, 1'b0} >> n;
    wire [31:0] sh_y  = left ? reverse(shr[32:1]) : shr[32:1];
    wire        sh_c  = shr[0];                               // the last bit out

    // LSL's V: a << n overflows (signed) when the top n + 1 bits of a are not all
    // equal, i.e. when a[k] != a[k-1] for some k in 31 .. 32-n. (a ^ a << 1) has a 1
    // at each such k; the mask keeps the top n bits.
    wire [31:0] lsl_dif = a ^ {a[30:0], 1'b0};
    wire [31:0] lsl_top = ~(32'hFFFF_FFFF >> n);
    wire        lsl_v   = |(lsl_dif & lsl_top);

    reg c, v;
    always @* begin
        y = 32'h0; y2 = 32'h0; c = cin; v = 1'b0;
        case (op)
        ADD, ADC, SUB, SBC, RSB, RSC: begin y = sum[31:0]; c = sum[32]; v = ovf; end
        AND:   begin y = a & b; v = y[30]; end
        OR:    begin y = a | b; v = y[30]; end
        XOR:   begin y = a ^ b; v = y[30]; end
        NOT:   begin y = ~a; v = y[30]; end
        LSL, LSR, ASR, ROR, ROL:
               begin y = sh_y; if (n != 0) c = sh_c; v = (op == LSL) & lsl_v; end
        ROLC:  begin y = {a[30:0], cin}; c = a[31]; end
        RORC:  begin y = {cin, a[31:1]}; c = a[0];  end
        MULS:  begin y = mul_w[32:1]; y2 = {31'h0, mul_w[0]}; end
        LSL64: begin {y2, y} = {b[30:0], a, 1'b0};      c = b[31]; end
        ROL64: begin {y2, y} = {b[30:0], a, cin};       c = b[31]; end
        LSR64: begin {y2, y} = {1'b0, b, a[31:1]};      c = a[0];  end
        ASR64: begin {y2, y} = {b[31], b, a[31:1]};     c = a[0];  end
        ROR64: begin {y2, y} = {cin, b, a[31:1]};       c = a[0];  end
        CSUB:  begin c = sum[32]; y = c ? sum[31:0] : a; v = c & ovf; end
        DIVS:  begin y = {div_k[30:0], 1'b0}; y2 = {31'h0, div_q}; c = div_k[31]; end
        MUL, SMUL: begin y = prod[31:0]; y2 = prod[63:32]; end
        ASL:   begin y = {a[31], a[29:0], 1'b0}; c = a[30]; v = a[31] ^ a[30]; end
        default: begin y = sum[31:0]; c = sum[32]; v = ovf; end
        endcase
    end

    wire wide = ((op >= LSL64) & (op <= ROR64)) | (op == MUL) | (op == SMUL);
    wire z    = wide ? ({y2, y} == 64'h0) : (y == 32'h0);
    wire neg  = wide ? y2[31] : y[31];

    assign flags = {v, neg, z, c};
endmodule
