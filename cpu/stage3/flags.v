// flags.v: the flags register of the mp32 processor, in stage 3 (execute), next to
// the ALU.
//
//   bit 0 C (carry), bit 1 Z (zero), bit 2 N (negative), bit 3 V (overflow).
//
// Each opcode updates only some of the flags: decode gives a 4-bit mask with the
// instruction (bit k = 1: flag k takes the ALU's flag k). The register is written as
// the instruction leaves execute (en: valid, no stall, no load-use wait), so the next
// instruction in execute already sees the new flags: no forwarding is needed.
//
// reset clears them.

module flags (
    input  wire       clk,
    input  wire       reset,           // synchronous, active high
    input  wire       en,              // the instruction in execute takes effect
    input  wire [3:0] mask,            // which flags it updates
    input  wire [3:0] alu_flags,       // {V, N, Z, C} from the ALU
    output reg  [3:0] f                // {V, N, Z, C}
);
    always @(posedge clk)
        if (reset)   f <= 4'h0;
        else if (en) f <= (f & ~mask) | (alu_flags & mask);
endmodule
