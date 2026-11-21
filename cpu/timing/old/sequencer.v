// sequencer.v: the sequencer of decode (stage 2) in the mp32 pipeline.
//
//   Most instructions are one pass through the pipeline. A few are issued by decode
//   as two steps, one after the other, each one pass: ROT (0x0E) and DROT (0x0F).
//   The sequencer counts the steps: d_step = 0 for the first, 1 for the second.
//
// ---------------------------------------------------------------- how
// The instruction stays in fetch's output registers (f_*) for both steps: the
// sequencer holds fetch with stall while the first step goes out, and lets it go
// with the second.
//
//   hold    stage 3 cannot take an instruction at this edge (from forward.v: not
//           advance). Nothing is issued; d_step stays.
//   stall   to fetch: keep f_* at the next edge. 1 while hold, and while the first
//           step of a two-step instruction is being issued.
//
// ---------------------------------------------------------------- no interrupt in between
// Fetch injects the interrupt sequence only into f_* when decode takes what is there.
// While stall is 1 it holds f_*, so nothing, not even an interrupt, can come between
// the two steps. That is why the scratch register TMP that carries a value from the
// first step to the second (stage3/scratch.v) never needs saving.
//
// ---------------------------------------------------------------- redirect
// A redirect throws f_* away and starts again at step 0. Redirects come from execute,
// from the instruction just before the one in decode: that one is never half issued
// (once the first step is in execute, nothing older is left in execute), so a
// redirect never splits a two-step instruction either. Decode redirects too, for a
// call (JSRS, JSR, JSRL), as it issues it: a call is one step, and the redirect
// throws away only what comes after it.

module sequencer (
    input  wire        clk,
    input  wire        reset,          // synchronous, active high
    input  wire        redirect,       // from execute: f_* is thrown away

    // from fetch
    input  wire        f_valid,
    input  wire [7:0]  f_opcode,       // the first byte of f_instr

    input  wire        hold,           // stage 3 does not take an instruction now

    output reg         d_step,         // which step decode issues now: 0 or 1
    output wire        d_last,         // this is the last step of the instruction
    output wire        stall           // to fetch: keep f_*
);
    localparam [7:0] ROT = 8'h0E, DROT = 8'h0F;

    wire two_step = (f_opcode == ROT) | (f_opcode == DROT);

    assign d_last = !two_step | d_step;
    assign stall  = hold | (f_valid & !d_last);

    always @(posedge clk)
        if (reset | redirect)
            d_step <= 1'b0;
        else if (f_valid & !hold)
            d_step <= !d_last;         // after step 0 of a two-step one: step 1
endmodule
