// cond.v: the branch conditions of the mp32 processor, in stage 3 (execute), next to
// the flags.
//
//   take = 1 when the condition cond holds for the flags f = {V, N, Z, C}.
//
//   cond  name  holds when            6502    after CMP (S - T)
//   0000  EQ    Z = 1                 BEQ     S == T
//   0001  NE    Z = 0                 BNE     S != T
//   0010  CS    C = 1                 BCS     S >= T unsigned (also called HS)
//   0011  CC    C = 0                 BCC     S <  T unsigned (also called LO)
//   0100  MI    N = 1                 BMI
//   0101  PL    N = 0                 BPL
//   0110  VS    V = 1                 BVS
//   0111  VC    V = 0                 BVC
//   1000  HI    C = 1 and Z = 0               S >  T unsigned
//   1001  LS    C = 0 or  Z = 1               S <= T unsigned
//   1010  GE    N = V                         S >= T signed
//   1011  LT    N != V                        S <  T signed
//   1100  GT    Z = 0 and N = V               S >  T signed
//   1101  LE    Z = 1 or  N != V              S <= T signed
//   1110  A     always
//   1111  TZ    T = 0, whatever the flags
//
// Codes 0000 .. 1101: each odd code is the opposite of the even one before it: the
// even ones are worked out, and bit 0 turns the answer round. 1110 and 1111 stand
// alone. tz = (T == 0) comes from execute: decode reads T on port B for a jump, so it
// is forwarded like any operand.
// No clock: the flags are read as they are now, so a branch right after the
// instruction that set them (CMP, SUB, ...) sees the new flags.

module cond (
    input  wire [3:0] cond,
    input  wire [3:0] f,               // {V, N, Z, C}
    input  wire       tz,              // T == 0
    output wire       take
);
    wire c = f[0], z = f[1], n = f[2], v = f[3];

    reg even;
    always @* begin
        case (cond[3:1])
            3'd0: even = z;                    // EQ
            3'd1: even = c;                    // CS
            3'd2: even = n;                    // MI
            3'd3: even = v;                    // VS
            3'd4: even = c & !z;               // HI
            3'd5: even = (n == v);             // GE
            default: even = !z & (n == v);     // GT
        endcase
    end

    assign take = (cond == 4'hE) ? 1'b1 :          // A
                  (cond == 4'hF) ? tz   :          // TZ
                  even ^ cond[0];
endmodule
