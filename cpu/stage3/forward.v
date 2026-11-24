// forward.v: forwarding for the mp32 pipeline, in stage 3 (execute).
//
//   It holds the two operands of the instruction in execute (stage 3's operand
//   registers) and gives the ALU their up-to-date values, taken from the
//   instructions further down the pipeline that have not written them back yet.
//
// ---------------------------------------------------------------- why
// Decode reads the registers one tick before execute. A register written by an
// older instruction that is still in the pipeline then is stale:
//
//   at the read, in decode   in execute, a tick later   so execute takes it from
//   ------------------------  --------------------------  -----------------------
//   older one in stage 5      written                    (the register file passes
//                                                         it through to decode)
//   older one in stage 4      in stage 5                 w_*  (writeback)
//   older one in stage 3      in stage 4                 x_*  (stage 3's outputs)
//
// The youngest wins: x_* before w_*, then the value decode read.
//
// An instruction can write two registers: its main one (x_rd / w_sel) and a special
// register on the second write (x2_* / w2_*, e.g. T in DROP). Within one
// instruction the main write wins, as in the register file.
//
// ---------------------------------------------------------------- loads
// A load's value is only known at the end of stage 4. When the instruction in execute
// needs the register of a load that is in stage 4 (x_load), it must wait: load_use is
// 1, stage 3 holds its instruction and sends a bubble into stage 4 (x_valid = 0).
// A tick after the load leaves stage 4 its value is on w_*.
//
// ---------------------------------------------------------------- worked out a tick early
// Which write an operand comes from is worked out in decode's tick, while the
// instruction is still in decode, and kept in registers (for each operand: from_x,
// from_x2, from_w, from_w2). In execute only a multiplexer switches on them: the
// comparisons of register numbers are off the critical path.
//
// When the instruction goes from decode into execute (advance), a tick later:
//   - x_* holds the instruction that is in execute now: its main write (e_wen, e_rd)
//     and second write (e_x2_wen, e_x2_sel) are compared with the operand's register;
//   - w_* holds the instruction that is in x_* now (x_wen, x_rd, x2_wen, x2_sel).
//
// ---------------------------------------------------------------- holding
// While stage 3 holds its instruction (stall from stage 4, or load_use), the
// instructions further down still move on (and stage 4 sends bubbles while it waits),
// so a value seen on w_* now is gone later. So in every tick in which stage 3 does not
// take a new instruction, the operand registers take the forwarded values: what was
// forwarded once stays. And the from_* registers move with the pipeline:
//   - stall from stage 4: x_* stays, w_* becomes a bubble: from_w, from_w2 = 0 (their
//     value has just been taken into the operand register);
//   - load_use (no stall): the load goes from x_* to w_*, x_* becomes a bubble:
//     from_w = from_x, from_w2 = from_x2, from_x = from_x2 = 0.
//
// hold (from execute: a WAIT waiting for a device) holds stage 3 the same way as a
// load-use wait: load_use is 1 while it does, so execute sends bubbles into stage 4.
//
// ---------------------------------------------------------------- what it does not do
// - PSP, RSP, FP live in stage 3 and need no forwarding.
// - The regfile's outputs t, s, r, l are not forwarded: an instruction that needs T,
//   S, R or L reads them through port A or B (as DUP does).
// - d_a_use / d_b_use say whether the operand comes from a register. Only then is it
//   forwarded and can it cause a load_use wait. When it is 0 the value is kept as
//   decode gave it: a constant made by decode (e.g. the n of LIT), or an operand the
//   instruction does not use. So constants need no path of their own: decode passes
//   them on port A or B as if they came from a register.
//
// A register is the 6-bit selector of regfile.v: two selectors name the same register
// exactly when they are equal (all 5 bits count for the special registers too).

module forward (
    input  wire        clk,
    input  wire        reset,          // synchronous, active high

    // from stage 4: it cannot take x_*, so stage 3 holds
    input  wire        mem_stall,

    // a jump taken in execute: the instruction coming from decode at this edge is
    // thrown away (it becomes a bubble)
    input  wire        flush,
    input  wire        hold,           // execute holds its instruction (WAIT): as a load-use wait

    // from stage 2, decode: the instruction and the operands it read
    input  wire        d_valid,
    input  wire        d_a_use,        // operand A comes from a register
    input  wire [5:0]  d_a_sel,
    input  wire [31:0] d_a_data,
    input  wire        d_b_use,        // operand B comes from a register
    input  wire [5:0]  d_b_sel,
    input  wire [31:0] d_b_data,

    // the instruction in execute now (execute.v's control word): what it will write
    input  wire        e_wen,
    input  wire [5:0]  e_rd,
    input  wire        e_x2_wen,
    input  wire [1:0]  e_x2_sel,
    input  wire        e_load,         // it is a load: in x_* its value is not there yet

    // the instruction in stage 4: stage 3's output registers
    input  wire        x_valid,
    input  wire        x_wen,
    input  wire        x_load,
    input  wire [5:0]  x_rd,
    input  wire [31:0] x_result,
    input  wire        x2_wen,         // its second write: a special register
    input  wire [1:0]  x2_sel,
    input  wire [31:0] x2_data,

    // the instruction in stage 5: writeback (its values; which register it writes
    // was worked out a tick earlier from x_*)
    input  wire        w_en,
    input  wire [5:0]  w_sel,
    input  wire [31:0] w_data,
    input  wire        w2_en,
    input  wire [1:0]  w2_sel,
    input  wire [31:0] w2_data,

    // the instruction in execute
    output reg         e_valid,
    output wire [31:0] e_a,            // operand A, forwarded
    output wire [31:0] e_b,            // operand B, forwarded
    output wire        load_use,       // wait: an operand comes from a load in stage 4, or hold
    output wire        advance         // stage 3 takes decode's instruction at the edge
);
    // ================================================================ the operand registers
    reg [31:0] a_val, b_val;
    // where each operand comes from in execute (worked out a tick early)
    reg a_fx, a_fx2, a_fw, a_fw2;
    reg b_fx, b_fx2, b_fw, b_fw2;
    // a_fx and the one in x_* is not a load: take x_result (worked out a tick early too,
    // from e_load, so x_load is not in the operands' path: timing)
    reg a_fxr, b_fxr;

    // ================================================================ in decode's tick
    // the instruction in execute now will be in x_* (if it is valid); the one in
    // x_* now will be in w_*. Within one instruction the main write wins.
    wire [5:0] e_x2_full = {1'b1, 3'b000, e_x2_sel};
    wire [5:0] x2_full   = {1'b1, 3'b000, x2_sel};

    wire n_a_fx  = d_a_use & e_valid & e_wen    & (d_a_sel == e_rd);
    wire n_a_fx2 = d_a_use & e_valid & e_x2_wen & !(e_wen & (d_a_sel == e_rd)) & (d_a_sel == e_x2_full);
    wire n_a_fw  = d_a_use & x_valid & x_wen    & (d_a_sel == x_rd);
    wire n_a_fw2 = d_a_use & x_valid & x2_wen   & !(x_wen & (d_a_sel == x_rd)) & (d_a_sel == x2_full);
    wire n_b_fx  = d_b_use & e_valid & e_wen    & (d_b_sel == e_rd);
    wire n_b_fx2 = d_b_use & e_valid & e_x2_wen & !(e_wen & (d_b_sel == e_rd)) & (d_b_sel == e_x2_full);
    wire n_b_fw  = d_b_use & x_valid & x_wen    & (d_b_sel == x_rd);
    wire n_b_fw2 = d_b_use & x_valid & x2_wen   & !(x_wen & (d_b_sel == x_rd)) & (d_b_sel == x2_full);

    // ================================================================ in execute
    // youngest first (a load in stage 4 has no value yet: load_use waits for it)
    // a_fxr, b_fxr were worked out from e_wen; execute can still drop that write (the
    // end of UNEXT / NEXT2 / NEXT3, a CONS that does not trap, a refused INTR): then
    // x_wen is 0 and the operand is what it was before (an older write, or the register)
    assign e_a = (a_fxr & x_wen) ? x_result : a_fx2 ? x2_data :
                 a_fw ? w_data : a_fw2 ? w2_data : a_val;
    assign e_b = (b_fxr & x_wen) ? x_result : b_fx2 ? x2_data :
                 b_fw ? w_data : b_fw2 ? w2_data : b_val;

    assign load_use = e_valid & (x_load & (a_fx | b_fx) | hold);

    assign advance  = !mem_stall & !load_use;

    always @(posedge clk) begin
        if (reset)
            e_valid <= 1'b0;
        else if (advance)
            e_valid <= d_valid & !flush;

        if (advance) begin
            a_val <= d_a_data;
            b_val <= d_b_data;
            {a_fx, a_fx2, a_fw, a_fw2} <= {n_a_fx, n_a_fx2, n_a_fw, n_a_fw2};
            {b_fx, b_fx2, b_fw, b_fw2} <= {n_b_fx, n_b_fx2, n_b_fw, n_b_fw2};
            // at this edge the instruction in execute goes into x_*: x_load = e_load
            a_fxr <= n_a_fx & !e_load;
            b_fxr <= n_b_fx & !e_load;
        end else begin                 // holding: keep what is forwarded now
            a_val <= e_a;
            b_val <= e_b;
            if (mem_stall) begin       // x_* stays, w_* becomes a bubble
                {a_fw, a_fw2} <= 2'b00;
                {b_fw, b_fw2} <= 2'b00;
            end else begin             // load_use: x_* moves to w_*, x_* a bubble
                {a_fw, a_fw2, a_fx, a_fx2} <= {a_fx, a_fx2, 2'b00};
                {b_fw, b_fw2, b_fx, b_fx2} <= {b_fx, b_fx2, 2'b00};
                {a_fxr, b_fxr} <= 2'b00;
            end
        end
    end
endmodule
