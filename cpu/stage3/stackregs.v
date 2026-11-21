// stackregs.v: the stack and frame registers of the mp32 processor, in stage 3
// (execute).
//
//   PSP   parameter stack pointer
//   RSP   return stack pointer
//   FP    frame pointer
//
// They are reached by special opcodes only. They live in execute, so a stack
// instruction works out its memory address and steps its pointer in the same tick:
// the next instruction in execute already sees the new pointer, with no forwarding.
//
// ---------------------------------------------------------------- the stacks
// A stack grows down, 4 bytes (one word) at a time, and its pointer points to the
// next free word:
//
//   push   store at ptr,     then ptr = ptr - 4      (post-decrement)
//   pop    ptr = ptr + 4,    then load from ptr      (pre-increment)
//
// ---------------------------------------------------------------- the operations
// sel picks the register: 00 = PSP, 01 = RSP, 10 = FP (11 = none: no change,
// value and addr read as 0 + offset). op says what to do with it:
//
//   op    name   addr (to memory access)   the register at the edge
//   000   BASE   ptr + offset              unchanged      load/store with an offset
//   001   PUSH   ptr                       ptr - 4
//   010   POP    ptr + 4                   ptr + 4
//   011   SET    -                         w_data         e.g. FP = RSP, PSP = rN
//   100   ADD    ptr + offset              ptr + offset   reserve / free stack space
//   101   ENTER  RSP                       RSP = RSP - 4 - offset, FP = RSP - 4
//   110   LEAVE  FP + 4                    RSP = FP + 4, FP = w_data
//   others: as BASE
//
// ENTER and LEAVE make and drop a stack frame on the return stack (the opcodes ENTER,
// ENTER2, ENTER3, LEAVE). They work on RSP and FP whatever sel is, and write both in
// the same tick: ENTER stores R at RSP (a push) and sets FP to the new RSP, then
// reserves offset bytes below it (decode gives 4 * the instruction's n words); LEAVE loads R from FP + 4 (a pop) and sets FP to
// w_data (the old R). value is still the register sel picks.
//
// offset is the signed offset, already sign-extended by decode. value is the selected
// register as it is now, to move it into a register or to SET another one from it.
// The register only changes when en is 1 (a valid instruction in execute that is not
// stalled and not thrown away).
//
// ---------------------------------------------------------------- reset
// reset does not change them: the program sets them before it uses them. They are 0
// after loading the FPGA.

module stackregs (
    input  wire        clk,
    input  wire        en,             // 1: the instruction in execute takes effect

    input  wire [1:0]  sel,            // 00 = PSP, 01 = RSP, 10 = FP
    input  wire [2:0]  op,             // BASE, PUSH, POP, SET, ADD
    input  wire [31:0] offset,         // signed, for BASE and ADD
    input  wire [31:0] w_data,         // for SET

    output wire [31:0] value,          // the selected register
    output reg  [31:0] addr,           // the memory address for memory access

    // always readable
    output wire [31:0] psp,
    output wire [31:0] rsp,
    output wire [31:0] fp
);
    localparam [2:0] BASE = 3'd0, PUSH = 3'd1, POP = 3'd2, SET = 3'd3, ADD = 3'd4,
                     ENTER = 3'd5, LEAVE = 3'd6;

    reg [31:0] ptrs [0:2];             // 0 = PSP, 1 = RSP, 2 = FP
    initial begin
        ptrs[0] = 32'h0;
        ptrs[1] = 32'h0;
        ptrs[2] = 32'h0;
    end

    assign psp   = ptrs[0];
    assign rsp   = ptrs[1];
    assign fp    = ptrs[2];
    assign value = (sel == 2'b11) ? 32'h0 : ptrs[sel];

    // the new value of the selected register
    reg [31:0] next;
    always @* begin
        case (op)
            PUSH:    begin addr = value;          next = value - 32'd4;   end
            POP:     begin addr = value + 32'd4;  next = value + 32'd4;   end
            SET:     begin addr = value + offset; next = w_data;          end
            ADD:     begin addr = value + offset; next = value + offset;  end
            ENTER:   begin addr = ptrs[1];         next = value;           end
            LEAVE:   begin addr = ptrs[2] + 32'd4; next = value;           end
            default: begin addr = value + offset; next = value;           end
        endcase
    end

    always @(posedge clk)
        if (en) begin
            if (op == ENTER) begin
                ptrs[1] <= ptrs[1] - 32'd4 - offset;           // RSP: the push, then the frame
                ptrs[2] <= ptrs[1] - 32'd4;                    // FP = RSP after the push
            end else if (op == LEAVE) begin
                ptrs[1] <= ptrs[2] + 32'd4;                    // RSP = FP, then the pop
                ptrs[2] <= w_data;                             // FP = the old R
            end else if (sel != 2'b11)
                ptrs[sel] <= next;
        end
endmodule
