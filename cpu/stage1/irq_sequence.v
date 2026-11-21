// irq_sequence.v: the instructions stage 1 injects into stage 2 when it takes an
// interrupt.
//
//   A table of up to 16 instructions. index picks one; instr is its 4 bytes, in the
//   same form as f_instr (first byte in bits 7..6 = the length, little-endian, unused
//   bytes 0); last is 1 for the last instruction of the sequence.
//
//   The sequence must do two things, because stage 1 relies on them:
//     - stop the interrupt from being pending (acknowledge it, or turn interrupts
//       off) before its last instruction takes effect;
//     - end with an instruction that redirects stage 1 (a jump to the handler).
//       Until that redirect, stage 1 fetches nothing more.
//   The injected instructions reach stage 2 with f_pc = the PC: the address of the
//   first instruction not executed, where the program goes on after the interrupt.
//
// ************************************************************************
// PLACEHOLDERS. The instruction set is not defined yet, so these are three dummy
// instructions of 1, 2 and 4 bytes. Replace them with the real sequence, e.g.:
//     push the PC (f_pc), push the flags, interrupts off, jump to the vector.
// ************************************************************************

module irq_sequence (
    input  wire [3:0]  index,
    output reg  [31:0] instr,
    output reg         last
);
    always @* begin
        last  = 1'b0;
        instr = 32'h0000_0000;
        case (index)
        4'd0: instr = 32'h0000_003E;            // 1 byte:  00 111110
        4'd1: instr = 32'h0000_A57D;            // 2 bytes: 01 111101, A5
        4'd2: begin                             // 4 bytes: 11 111111, 3 bytes
                  instr = 32'h1234_56FF;
                  last  = 1'b1;
              end
        default: last = 1'b1;                   // never used
        endcase
    end
endmodule
