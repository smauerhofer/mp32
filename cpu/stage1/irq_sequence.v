// irq_sequence.v: the instruction stage 1 injects into stage 2 when it takes an
// interrupt or an exception (see fetch.v).
//
//   One instruction, 2 bytes, in the same form as f_instr (first byte in bits 7..0,
//   the unused bytes 0):
//     exc = 0:  INTR num   (0x49, num)   an interrupt from a device
//     exc = 1:  EXC  num   (0x4A, num)   an exception (num: what failed)
//
//   Both are calls through the vector table (VEC + 4 * num, see ../isa.md). Their return
//   address is f_pc, the instruction that was not executed, so the program goes on with
//   it after the handler (RTI for an interrupt, RET for an exception).
//
// (It was a table of up to 16 instructions when the interrupt sequence was still open;
// the name stays so the Makefiles stay as they are.)

module irq_sequence (
    input  wire        exc,
    input  wire [7:0]  num,
    output wire [31:0] instr
);
    assign instr = {16'h0, num, exc ? 8'h4A : 8'h49};
endmodule
