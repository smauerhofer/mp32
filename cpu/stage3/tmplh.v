// tmplh.v: TMPL and TMPH, two 32-bit registers of the mp32 processor (temp lo, temp
// hi), in stage 3 (execute), next to the ALU.
//
//   They hold a 64-bit value for the ALU: {TMPH, TMPL}. A 64-bit shift (LSL64 ..
//   ROR64) takes a = TMPL, b = TMPH, and writes y into TMPL and y2 into TMPH. Special
//   opcodes read them (into a register, through the result) and write them (from an
//   operand).
//
//   DIVS (the division step) shifts TMPL left by one with the quotient bit (the
//   ALU's y2[0]) coming in at the bottom: sh_l = 1, sh_bit = y2[0]. sh_l wins over
//   we_l. TMPL[31], the bit that goes out, goes into bit 0 of the new T.
//
//   MULS (the multiply step) shifts TMPL right by one with the bit from the ALU
//   (y2[0], the low bit of the new T before its shift) coming in at the top:
//   sh_r = 1, sh_bit = y2[0]. TMPL[0], the bit that goes out, is the ALU's carry in
//   for that MULS (add S or not).
//
//   They live in execute, so an instruction in execute always sees what the one
//   before wrote: no forwarding. They are written as the instruction leaves execute
//   (en: valid, no stall, no load-use wait); we_l / we_h say which ones it writes.
//
//   They are visible registers: an interrupt handler that uses them must save them.
//   reset clears them, as T, S, R and L.

module tmplh (
    input  wire        clk,
    input  wire        reset,          // synchronous, active high
    input  wire        en,             // the instruction in execute takes effect
    input  wire        we_l,           // it writes TMPL
    input  wire [31:0] d_l,
    input  wire        sh_l,           // shift TMPL left, sh_bit in at bit 0
    input  wire        sh_r,           // shift TMPL right, sh_bit in at bit 31
    input  wire        sh_bit,
    input  wire        we_h,           // it writes TMPH
    input  wire [31:0] d_h,
    output reg  [31:0] tmpl,
    output reg  [31:0] tmph
);
    always @(posedge clk)
        if (reset) begin
            tmpl <= 32'h0;
            tmph <= 32'h0;
        end else if (en) begin
            if (sh_l)      tmpl <= {tmpl[30:0], sh_bit};
            else if (sh_r) tmpl <= {sh_bit, tmpl[31:1]};
            else if (we_l) tmpl <= d_l;
            if (we_h) tmph <= d_h;
        end
endmodule
