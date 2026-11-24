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
// ---------------------------------------------------------------- two b inputs, two results
// b feeds the adder (ADD .. SBC, RSB, RSC, CSUB, TADD, TSUB), the logic ops (AND, OR,
// XOR) and the 64-bit shifts: it can be a register of stage 3 (execute's s3). bo is
// the plain operand B: it feeds the shifter (the amount), the divider, the multiply
// step, the multiplier and TTAG, which never take a register of stage 3. So the long
// path from the registers of stage 3 does not go through them (timing).
//
// x2_data (the second write) takes ya only: its ops are all adder or logic ops.
//
// ya is y for the adder and the logic ops only (for others: the adder's sum), and
// flags_a the flags of the adder alone: what the writes of the registers of stage 3,
// the jumps and the addresses need, without the long ops behind them. flags_s are the
// flags of ya for all of those ops (the adder's, or for AND, OR, XOR: V = bit 30, C =
// cin): for those ops they are the same as y and flags, a few levels of logic sooner.
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
//   11100  TADD    a + b (tagged, for LISP)        0        carry
//   11101  TSUB    a - b (tagged)                  0        no borrow
//   11110  TTAG    (a ^ b) & (b >> 8), low 8 bits  0        cin
//  100000  CLZ     the number of leading 0 bits    0        cin
//                  of a (32 when a = 0)
//  100001  PCNT    the number of 1 bits in a       0        cin
//  100010  ABS     |a| (0x8000_0000 stays,         0        cin
//                  V = 1)
//  100011  MIN     the smaller of a, b (signed)    0        cin
//  100100  MAX     the larger of a, b (signed)     0        cin
//  100101  MINU    the smaller of a, b (unsigned)  0        cin
//  100110  MAXU    the larger of a, b (unsigned)   0        cin
//   others: as ADD
//
// RSB and RSC are SUB and SBC with a and b the other way round: the adder inverts a
// instead of b (b - a = ~a + b + 1). SUBR and SBCR use them when the register, not T, is the destination
// (register = register - T), because a register of stage 3 (PSP, RSP, FP, TMPL,
// TMPH) can only come in on b. Their flags are those of SUB and SBC on (b, a).
//
// TADD and TSUB are ADD and SUB for LISP fixnums, whose low 2 bits are 00 (as
// SPARC's TADDcc, TSUBcc): V = 1 when the add / subtract overflows, or when the low
// 2 bits of a or b are not 00 (one of them is not a fixnum). So one branch on V
// takes both cases to the slow path. C, Z, N as ADD and SUB.
//
// TTAG tests a tag: b[15:8] is a mask, b[7:0] a value; y = (a ^ value) & mask, on the
// low 8 bits (0 above), so Z = 1 exactly when (a & mask) == value. N = 0, V = 0, C =
// cin.
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
// CLZ, PCNT and ABS work on a alone. CLZ counts the 0 bits above the highest 1 (32 for
// 0), PCNT the 1 bits. ABS is a for a >= 0 and 0 - a for a < 0; |0x8000_0000| does not
// fit, so it stays 0x8000_0000 and V = 1 (V = 0 for all others). Z and N are those of y,
// C is cin.
//
// MIN, MAX, MINU, MAXU pick a or b. They compare with the adder (a - b, its borrow and
// its signed "less than", N != V), so they take b, not bo; a tie gives a. Z and N are
// those of y, C is cin, V is 0.
//
// For the 64-bit shifts a is the low word and b the high word; they shift by one bit,
// through the carry for ROL64 / ROR64, so a 64-bit value can be shifted one bit per
// instruction (as in a multiply or divide done by the program).

module alu (
    input  wire [5:0]  op,
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [31:0] bo,             // operand B: for the shifter, divider, multipliers, TTAG
    input  wire        cin,
    output reg  [31:0] y,
    output reg  [31:0] y2,
    output wire [3:0]  flags,          // {V, N, Z, C}
    output reg  [31:0] ya,             // y of the adder and logic ops only
    output wire [3:0]  flags_a,        // the flags of the adder: {V, N, Z, C}
    output wire [3:0]  flags_s         // the flags of ya (adder and logic ops)
);
    localparam [5:0] ADD = 6'd0,  ADC = 6'd1,  SUB = 6'd2,  SBC = 6'd3,
                     AND = 6'd4,  OR  = 6'd5,  XOR = 6'd6,  NOT = 6'd7,
                     LSL = 6'd8,  LSR = 6'd9,  ASR = 6'd10, ROR = 6'd11,
                     LSL64 = 6'd12, LSR64 = 6'd13, ASR64 = 6'd14,
                     ROL64 = 6'd15, ROR64 = 6'd16, CSUB = 6'd17, DIVS = 6'd18,
                     MUL = 6'd19, SMUL = 6'd20, ASL = 6'd21,
                     ROL = 6'd22, ROLC = 6'd23, RORC = 6'd24, MULS = 6'd25,
                     RSB = 6'd26, RSC = 6'd27, TADD = 6'd28, TSUB = 6'd29, TTAG = 6'd30,
                     CLZ = 6'd32, PCNT = 6'd33, ABS = 6'd34,
                     MIN = 6'd35, MAX = 6'd36, MINU = 6'd37, MAXU = 6'd38;

    // ---- the adder: a' + b' + c', for add and subtract. a - b = a + ~b + 1 inverts b;
    // the reverse subtract b - a = ~a + b + 1 (RSB, RSC) inverts a instead.
    wire        rev   = (op == RSB) | (op == RSC);
    wire        mm    = (op == MIN) | (op == MAX) | (op == MINU) | (op == MAXU);
    wire        sub   = (op == SUB) | (op == SBC) | (op == CSUB) | (op == TSUB) | mm;
    wire [31:0] a_in  = rev ? ~a : a;
    wire [31:0] b_in  = sub ? ~b : b;
    wire        c_in  = (op == ADC) | (op == SBC) | (op == RSC) ? cin : sub | rev;
    wire [32:0] sum   = {1'b0, a_in} + {1'b0, b_in} + {32'h0, c_in};
    wire        ovf   = (a_in[31] == b_in[31]) & (sum[31] != a_in[31]);

    // ---- the multiply step: add b if cin, then shift right (33 bits)
    wire [32:0] mul_w = {1'b0, a} + (cin ? {1'b0, bo} : 33'h0);

    // ---- the multiplier: the on-chip one
    wire [63:0] prod;
    mul multiplier (.a(a), .b(bo), .sgn(op == SMUL), .p(prod));

    // ---- the division step: 33 bits {cin, a} minus b if it fits, then shifted
    wire [32:0] div_r = {cin, a};
    wire [33:0] div_d = {1'b0, div_r} - {2'b00, bo};
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

    wire [4:0]  n     = bo[4:0];
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

    // ---- MIN, MAX, MINU, MAXU: a - b on the adder; a < b signed: N != V, unsigned: borrow
    wire        lt_s  = sum[31] ^ ovf;
    wire        lt_u  = !sum[32];

    // ---- CLZ, PCNT, ABS. CLZ and PCNT as trees, 5 levels deep (a loop over the 32 bits
    // would make a chain of 32: the long result path of the ALU)
    //
    // CLZ: each half says whether it is all 0s and how many 0s lead it; the upper half
    // wins unless it is all 0s, then it is its width + the lower half's count.
    wire [15:0] z1;  wire [15:0] c1;                     // 16 x 2 bits: 0 .. 1 (+ all 0)
    wire [7:0]  z2;  wire [15:0] c2;                     //  8 x 4 bits: 0 .. 3
    wire [3:0]  z3;  wire [11:0] c3;                     //  4 x 8 bits: 0 .. 7
    wire [1:0]  z4;  wire [7:0]  c4;                     //  2 x 16 bits: 0 .. 15
    genvar g;
    generate
        for (g = 0; g < 16; g = g + 1) begin : clz1
            assign z1[g] = !(a[2*g+1] | a[2*g]);
            assign c1[g] = !a[2*g+1];                     // 1 when the upper bit is 0
        end
        for (g = 0; g < 8; g = g + 1) begin : clz2
            assign z2[g] = z1[2*g+1] & z1[2*g];
            assign c2[2*g +: 2] = z1[2*g+1] ? {1'b1, c1[2*g]} : {1'b0, c1[2*g+1]};
        end
        for (g = 0; g < 4; g = g + 1) begin : clz3
            assign z3[g] = z2[2*g+1] & z2[2*g];
            assign c3[3*g +: 3] = z2[2*g+1] ? {1'b1, c2[4*g +: 2]} : {1'b0, c2[4*g+2 +: 2]};
        end
        for (g = 0; g < 2; g = g + 1) begin : clz4
            assign z4[g] = z3[2*g+1] & z3[2*g];
            assign c4[4*g +: 4] = z3[2*g+1] ? {1'b1, c3[6*g +: 3]} : {1'b0, c3[6*g+3 +: 3]};
        end
    endgenerate
    wire [5:0]  clz_n = (z4[1] & z4[0]) ? 6'd32 :
                        z4[1] ? {2'b01, c4[3:0]} : {2'b00, c4[7:4]};

    // PCNT: pairs, then sums of 2, 4, 8, 16 bits
    wire [31:0] p1;  wire [23:0] p2;  wire [15:0] p3;  wire [9:0] p4;
    generate
        for (g = 0; g < 16; g = g + 1) begin : pc1
            assign p1[2*g +: 2] = {1'b0, a[2*g]} + {1'b0, a[2*g+1]};                  // 0 .. 2
        end
        for (g = 0; g < 8; g = g + 1) begin : pc2
            assign p2[3*g +: 3] = {1'b0, p1[4*g +: 2]} + {1'b0, p1[4*g+2 +: 2]};       // 0 .. 4
        end
        for (g = 0; g < 4; g = g + 1) begin : pc3
            assign p3[4*g +: 4] = {1'b0, p2[6*g +: 3]} + {1'b0, p2[6*g+3 +: 3]};       // 0 .. 8
        end
        for (g = 0; g < 2; g = g + 1) begin : pc4
            assign p4[5*g +: 5] = {1'b0, p3[8*g +: 4]} + {1'b0, p3[8*g+4 +: 4]};       // 0 .. 16
        end
    endgenerate
    wire [5:0]  pcnt_n = {1'b0, p4[4:0]} + {1'b0, p4[9:5]};                            // 0 .. 32
    wire [31:0] neg_a = ~a + 32'd1;

    // The result in two parts: y_old for the ops 0 .. 31, y_new for CLZ .. MAXU (op[5]),
    // put together at the end. The flags of the new ops are worked out from their inputs
    // (flags_new), not from y: so they stay off the path through all the ops' results
    // into Z and N, the long path into the flags register.
    reg [31:0] y_old, y_new;
    reg c, v;
    always @* begin
        y_old = 32'h0; y2 = 32'h0; c = cin; v = 1'b0;
        case (op)
        ADD, ADC, SUB, SBC, RSB, RSC: begin y_old = sum[31:0]; c = sum[32]; v = ovf; end
        AND:   begin y_old = a & b; v = y_old[30]; end
        OR:    begin y_old = a | b; v = y_old[30]; end
        XOR:   begin y_old = a ^ b; v = y_old[30]; end
        NOT:   begin y_old = ~a; v = y_old[30]; end
        LSL, LSR, ASR, ROR, ROL:
               begin y_old = sh_y; if (n != 0) c = sh_c; v = (op == LSL) & lsl_v; end
        ROLC:  begin y_old = {a[30:0], cin}; c = a[31]; end
        RORC:  begin y_old = {cin, a[31:1]}; c = a[0];  end
        MULS:  begin y_old = mul_w[32:1]; y2 = {31'h0, mul_w[0]}; end
        LSL64: begin {y2, y_old} = {b[30:0], a, 1'b0};      c = b[31]; end
        ROL64: begin {y2, y_old} = {b[30:0], a, cin};       c = b[31]; end
        LSR64: begin {y2, y_old} = {1'b0, b, a[31:1]};      c = a[0];  end
        ASR64: begin {y2, y_old} = {b[31], b, a[31:1]};     c = a[0];  end
        ROR64: begin {y2, y_old} = {cin, b, a[31:1]};       c = a[0];  end
        CSUB:  begin c = sum[32]; y_old = c ? sum[31:0] : a; v = c & ovf; end
        DIVS:  begin y_old = {div_k[30:0], 1'b0}; y2 = {31'h0, div_q}; c = div_k[31]; end
        MUL, SMUL: begin y_old = prod[31:0]; y2 = prod[63:32]; end
        ASL:   begin y_old = {a[31], a[29:0], 1'b0}; c = a[30]; v = a[31] ^ a[30]; end
        TADD, TSUB: begin y_old = sum[31:0]; c = sum[32]; v = ovf | (|{a[1:0], b[1:0]}); end
        TTAG:  begin y_old = {24'h0, (a[7:0] ^ bo[7:0]) & bo[15:8]}; end
        default: begin y_old = sum[31:0]; c = sum[32]; v = ovf; end
        endcase
    end

    // the new ops and their flags {V, N, Z}: Z and N of the result, from the inputs
    wire        a_zero = (a == 32'h0), b_zero = (b == 32'h0);
    reg  [2:0]  f_new;
    always @*
        case (op)
            CLZ:     begin y_new = {26'h0, clz_n};  f_new = {2'b00, a[31]};  end   // 0 only for a 1 on top
            PCNT:    begin y_new = {26'h0, pcnt_n}; f_new = {2'b00, a_zero}; end
            ABS:     begin y_new = a[31] ? neg_a : a;                              // N: only 0x8000_0000
                           f_new = {a == 32'h8000_0000, a == 32'h8000_0000, a_zero}; end
            MIN:     begin y_new = lt_s ? a : b; f_new = lt_s ? {1'b0, a[31], a_zero} : {1'b0, b[31], b_zero}; end
            MAX:     begin y_new = lt_s ? b : a; f_new = lt_s ? {1'b0, b[31], b_zero} : {1'b0, a[31], a_zero}; end
            MINU:    begin y_new = lt_u ? a : b; f_new = lt_u ? {1'b0, a[31], a_zero} : {1'b0, b[31], b_zero}; end
            default: begin y_new = lt_u ? b : a; f_new = lt_u ? {1'b0, b[31], b_zero} : {1'b0, a[31], a_zero}; end  // MAXU
        endcase

    always @* y = op[5] ? y_new : y_old;

    wire wide = ((op >= LSL64) & (op <= ROR64)) | (op == MUL) | (op == SMUL);
    wire z    = wide ? ({y2, y_old} == 64'h0) : (y_old == 32'h0);
    wire neg  = wide ? y2[31] : y_old[31];

    assign flags = op[5] ? {f_new, cin} : {v, neg, z, c};

    // the short result: the adder and the logic ops
    always @*
        case (op)
            AND:     ya = a & b;
            OR:      ya = a | b;
            XOR:     ya = a ^ b;
            default: ya = sum[31:0];
        endcase
    assign flags_a = {ovf, sum[31], sum[31:0] == 32'h0, sum[32]};
    wire   logic_op = (op == AND) | (op == OR) | (op == XOR);
    assign flags_s = logic_op ? {ya[30], ya[31], ya == 32'h0, cin} : flags_a;
endmodule
