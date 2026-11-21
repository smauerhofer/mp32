// writeback.v: stage 5 of the mp32 pipeline, writeback.
//
//   It writes the result of an instruction back into the register file in stage 2
//   (regfile.v): r0 .. r31, or one of the special registers T, S, R, L.
//
// ---------------------------------------------------------------- from stage 4
// m_valid, m_wen, m_rd and m_data are stage 4's output registers:
//
//   m_valid   an instruction is in stage 5 (0: a bubble)
//   m_wen     it writes a register
//   m_rd      which one: the 6-bit selector (bit 5 = 0: r0 .. r31 in bits 4..0;
//             bit 5 = 1: bits 1..0 00 = T, 01 = S, 10 = R, 11 = L)
//   m_data    the value: the data loaded, or the result from execute
//   m2_wen    it also writes a special register (the second write, e.g. T in DROP)
//   m2_sel    which one: 00 = T, 01 = S, 10 = R, 11 = L
//   m2_data   its value
//
// ---------------------------------------------------------------- to stage 2
// w_en, w_sel and w_data go to the register file's write port W; w2_en, w2_sel and
// w2_data to its port W2 (special registers only; W wins if both write the same one).
// It writes at the end of this tick, and passes the values through to its read ports
// in the same tick, so the instruction in decode already sees them. That is why stage 5 has no registers
// of its own: it is the tick in which stage 4's outputs are written.
//
// The same signals go back to execute too, for forwarding (an instruction in
// execute that needs a register still being written must take it from here).
//
// Stage 5 never stalls and nothing throws its instruction away.
//
// PSP, RSP and FP live in stage 3 and are not written here.

module writeback (
    // from stage 4
    input  wire        m_valid,
    input  wire        m_wen,
    input  wire [5:0]  m_rd,
    input  wire [31:0] m_data,
    input  wire        m2_wen,
    input  wire [1:0]  m2_sel,
    input  wire [31:0] m2_data,

    // to the register file in stage 2 (and to execute, for forwarding)
    output wire        w_en,
    output wire [5:0]  w_sel,
    output wire [31:0] w_data,
    output wire        w2_en,
    output wire [1:0]  w2_sel,
    output wire [31:0] w2_data
);
    assign w_en   = m_valid & m_wen;
    assign w_sel  = m_rd;
    assign w_data = m_data;

    assign w2_en   = m_valid & m2_wen;
    assign w2_sel  = m2_sel;
    assign w2_data = m2_data;
endmodule
