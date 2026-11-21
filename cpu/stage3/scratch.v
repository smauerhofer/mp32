// scratch.v: TMP, the internal scratch register of the mp32 processor, in stage 3
// (execute).
//
//   It carries a value from the first step of a two-step instruction (ROT, DROT) to
//   the second. No instruction can name it: it is not in the register file and has
//   no selector. It needs no forwarding: the first step writes it as it leaves
//   execute, and the second step, which is always the very next instruction in
//   execute, reads it there.
//
//   The sequencer (stage2/sequencer.v) issues the two steps back to back and nothing,
//   not even an interrupt, can come between them, so TMP never needs saving.
//
//   en: the instruction in execute takes effect at this edge (it leaves execute:
//   valid, no stall from stage 4, no load-use wait). we: it writes TMP.
//   Not cleared by reset (0 after loading the FPGA): it is always written before it
//   is read.

module scratch (
    input  wire        clk,
    input  wire        en,
    input  wire        we,
    input  wire [31:0] d,
    output reg  [31:0] tmp
);
    initial tmp = 32'h0;

    always @(posedge clk)
        if (en && we) tmp <= d;
endmodule
