// sequencer.v: the sequencer of decode (stage 2) in the mp32 pipeline.
//
//   Most instructions are one pass through the pipeline. A few are issued by decode
//   as several steps, one after the other, each one pass: ROT (0x0E) and DROT (0x0F)
//   as two, CONS (0x31) as four. The sequencer counts the steps: d_step = 0 for the
//   first, 1 for the second, and so on.
//
// ---------------------------------------------------------------- how
// The instruction stays in fetch's output registers (f_*) for all its steps: the
// sequencer holds fetch with stall while the steps before the last go out, and lets
// it go with the last.
//
//   hold    stage 3 cannot take an instruction at this edge (from forward.v: not
//           advance). Nothing is issued; d_step stays.
//   stall   to fetch: keep f_* at the next edge. 1 while hold, and while a step that
//           is not the last of its instruction is being issued.
//
// ---------------------------------------------------------------- no interrupt in between
// Fetch injects the interrupt sequence only into f_* when decode takes what is there.
// While stall is 1 it holds f_*, so nothing, not even an interrupt, can come between
// the steps. That is why the scratch register TMP that carries a value from the
// first step of ROT / DROT to the second (stage3/scratch.v) never needs saving.
//
// ---------------------------------------------------------------- redirect
// A redirect throws f_* away and starts again at step 0. Redirects come from execute,
// from the instruction just before the one in decode: that one is never half issued
// (once the first step is in execute, nothing older is left in execute), so a
// redirect never splits an instruction of several steps either. The one exception is
// on purpose: step 0 of CONS can trap (a jump to the GC vector), and that redirect
// throws away the steps of the same CONS behind it, which then never happen. Decode
// redirects too, for a call (JSRS, JSR, JSRL), as it issues it: a call is one step,
// and the redirect throws away only what comes after it.

module sequencer (
    input  wire        clk,
    input  wire        reset,          // synchronous, active high
    input  wire        redirect,       // from execute: f_* is thrown away

    // from fetch
    input  wire        f_valid,
    input  wire [7:0]  f_opcode,       // the first byte of f_instr

    input  wire        hold,           // stage 3 does not take an instruction now

    output reg  [1:0]  d_step,         // which step decode issues now: 0 .. 3
    output wire        d_last,         // this is the last step of the instruction
    output wire        stall           // to fetch: keep f_*
);
    localparam [7:0] ROT = 8'h0E, DROT = 8'h0F, CONS = 8'h31;

    // the number of the last step of the instruction in f_*
    wire [1:0] last = (f_opcode == ROT) | (f_opcode == DROT) ? 2'd1 :
                      (f_opcode == CONS)                     ? 2'd3 : 2'd0;

    assign d_last = (d_step == last);
    assign stall  = hold | (f_valid & !d_last);

    always @(posedge clk)
        if (reset | redirect)
            d_step <= 2'd0;
        else if (f_valid & !hold)
            d_step <= d_last ? 2'd0 : d_step + 2'd1;
endmodule
