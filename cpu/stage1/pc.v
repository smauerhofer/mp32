// pc.v: the program counter (PC) of the mp32 processor, a 32-bit register in stage 1.
//
//   It holds the byte address of the next instruction to fetch. At each rising edge:
//
//     reset            PC = RESET_PC
//     else load        PC = load_value      (a jump, a taken branch, an interrupt, ...)
//     else irq_pending PC stays             (an interrupt is pending)
//     else step        PC = PC + len        (the instruction at PC was fetched; len 1..4)
//     else             PC stays
//
//   load wins over step: when a later stage redirects the processor, the instruction
//   being fetched in that tick does not count. The PC wraps from FFFFFFFF to 0.
//
//   While an interrupt is pending the PC is not increased: it keeps the address of the
//   first instruction not yet fetched, which is where the program goes on after the
//   interrupt. The stage that takes the interrupt saves it and loads the address of
//   the handler; load still works while irq_pending is 1.

module pc #(
    parameter [31:0] RESET_PC = 32'h0000_0000
) (
    input  wire        clk,
    input  wire        reset,          // synchronous, active high

    input  wire        load,
    input  wire [31:0] load_value,

    input  wire        irq_pending,

    input  wire        step,
    input  wire [2:0]  len,            // 1..4

    output reg  [31:0] value
);
    always @(posedge clk) begin
        if (reset)
            value <= RESET_PC;
        else if (load)
            value <= load_value;
        else if (step & !irq_pending)
            value <= value + {29'd0, len};
    end
endmodule
