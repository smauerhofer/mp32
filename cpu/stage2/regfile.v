// regfile.v: the registers of the mp32 processor, in stage 2 (decode).
//
//   r0 .. r31   32 general registers of 32 bits; r0 is a normal register
//   T, S, R, L  4 special registers of 32 bits, used by special opcodes only
//
// ---------------------------------------------------------------- register selectors
// A register is selected with 6 bits:
//
//   bit 5      0 = the register file       1 = a special register
//   bits 4..0  the register, 0 .. 31       the special register, all 5 bits:
//                                            00000 T, 00001 S, 00010 R, 00011 L
//                                            (here, in the register file);
//                                            00100 PSP, 00101 RSP, 00110 FP,
//                                            00111 PC, 01000 TMPL, 01001 TMPH,
//                                            01010 ST
//                                            (in stage 3 and fetch, not here)
//
// So two selectors name the same register exactly when they are equal. A special
// selector with bits 4..2 not 000 is not a register of this file: it is never written
// here and reads as 0 (decode does not use it for a read: stage 3 has the register).
//
// ---------------------------------------------------------------- the ports
// Two read ports, A and B, for decode: give a selector, the value comes back in the
// same tick (a read without a clock). Two write ports for writeback, written at the
// rising edge:
//
//   W    any register (6-bit selector), when w_en is 1
//   W2   a special register only (w2_sel: 00 = T, 01 = S, 10 = R, 11 = L), when
//        w2_en is 1: the second register of an instruction that writes two, such as
//        DROP (S from memory on W, T on W2)
//
// When W and W2 write the same register in the same tick, W wins (an instruction
// should not do that).
//
// When writeback writes a register in the same tick decode reads it, decode gets the
// new value (w_data, or w2_data), not the old one: the instruction in decode must see the result
// of the one leaving writeback.
//
// T, S, R and L are also always on the outputs t, s, r and l (with the same rule:
// while one is written, its output shows the new value), for the parts of the
// processor that use them directly.
//
// On the GW2AR r0 .. r31 become LUT memory (shadow RAM): one copy for each read port,
// both written together. They are not cleared by reset; they start at 0 when the FPGA
// is loaded. reset clears T, S, R and L to 0.

module regfile (
    input  wire        clk,
    input  wire        reset,          // synchronous, active high: T, S, R, L to 0

    // read port A
    input  wire [5:0]  a_sel,
    output wire [31:0] a_data,

    // read port B
    input  wire [5:0]  b_sel,
    output wire [31:0] b_data,

    // write port W
    input  wire        w_en,
    input  wire [5:0]  w_sel,
    input  wire [31:0] w_data,

    // write port W2: the special registers only
    input  wire        w2_en,
    input  wire [1:0]  w2_sel,         // 00 = T, 01 = S, 10 = R, 11 = L
    input  wire [31:0] w2_data,

    // the special registers, always readable
    output wire [31:0] t,
    output wire [31:0] s,
    output wire [31:0] r,
    output wire [31:0] l
);
    // a selector names a register of this file: r0 .. r31, or T, S, R, L
    function here(input [5:0] sel);
        here = !sel[5] | (sel[4:2] == 3'b000);
    endfunction

    // a write on port W that this file takes
    wire w_here = w_en && here(w_sel);

    // ================================================================ r0 .. r31
    reg [31:0] regs [0:31];

    integer i;
    initial for (i = 0; i < 32; i = i + 1) regs[i] = 32'h0;

    always @(posedge clk)
        if (w_en && !w_sel[5]) regs[w_sel[4:0]] <= w_data;

    // ================================================================ T, S, R, L
    reg [31:0] special [0:3];          // 0 = T, 1 = S, 2 = R, 3 = L

    // W2 first, then W: W wins when both write the same one
    integer k;
    always @(posedge clk) begin
        if (reset) begin
            special[0] <= 32'h0;
            special[1] <= 32'h0;
            special[2] <= 32'h0;
            special[3] <= 32'h0;
        end else
            for (k = 0; k < 4; k = k + 1)
                if (w_here && w_sel[5] && w_sel[1:0] == k)
                    special[k] <= w_data;
                else if (w2_en && w2_sel == k)
                    special[k] <= w2_data;
    end

    // ================================================================ reading
    // what is stored, then the value being written passed through (W before W2)
    // (0 for a special selector that is not here)
    wire [31:0] a_stored = !a_sel[5] ? regs[a_sel[4:0]] :
                           here(a_sel) ? special[a_sel[1:0]] : 32'h0;
    wire [31:0] b_stored = !b_sel[5] ? regs[b_sel[4:0]] :
                           here(b_sel) ? special[b_sel[1:0]] : 32'h0;

    wire [5:0] w2_full = {1'b1, 3'b000, w2_sel};   // W2's selector as 6 bits

    assign a_data = (w_here && a_sel == w_sel)          ? w_data  :
                    (w2_en  && a_sel == w2_full)        ? w2_data : a_stored;
    assign b_data = (w_here && b_sel == w_sel)          ? w_data  :
                    (w2_en  && b_sel == w2_full)        ? w2_data : b_stored;
    assign t      = (w_here && w_sel == 6'b100000)      ? w_data  :
                    (w2_en  && w2_sel == 2'b00)         ? w2_data : special[0];
    assign s      = (w_here && w_sel == 6'b100001)      ? w_data  :
                    (w2_en  && w2_sel == 2'b01)         ? w2_data : special[1];
    assign r      = (w_here && w_sel == 6'b100010)      ? w_data  :
                    (w2_en  && w2_sel == 2'b10)         ? w2_data : special[2];
    assign l      = (w_here && w_sel == 6'b100011)      ? w_data  :
                    (w2_en  && w2_sel == 2'b11)         ? w2_data : special[3];
endmodule
