// sequencer_tb.v: tests sequencer.v together with the real fetch stage (stage 1).
//
//   make test-sequencer
// or by hand:
//   iverilog -g2005 -o sequencer_tb.vvp sequencer_tb.v sequencer.v \
//            ../stage1/fetch.v ../stage1/pc.v ../stage1/irq_sequence.v
//   vvp sequencer_tb.vvp
//
// A program of random instructions of 1 to 4 bytes, many of them ROT (0x0E), DROT
// (0x0F) and CONS (0x31). The rest of the pipeline is played by the test bench: it
// holds decode at random (hold), redirects at random to the start of an instruction
// (only when decode is at step 0, as a branch in execute would; and right after step 0
// of a CONS, as its trap does), and makes interrupts pending at random (it
// acknowledges after the 3 instructions of the placeholder sequence and jumps to a
// random instruction a few ticks later).
//
// Every issued step is checked: instructions come in program order, one step for an
// ordinary one, steps 0, 1 for ROT and DROT, steps 0 .. 3 for CONS, and between the
// steps of one instruction nothing else comes out, not even an instruction of the
// interrupt sequence. A CONS that traps after step 0 starts the next instruction at
// step 0. The test also counts how often an interrupt was pending while a later step
// was waiting, to show that the case was really tried.

`timescale 1ns/1ps

module sequencer_tb;
    parameter PROG_END = 32'h0000_8000;
    parameter MAX_INS  = 20000;
    parameter TICKS    = 300000;

    reg clk = 0;
    always #18.5 clk = ~clk;              // 27 MHz

    localparam [7:0] ROT = 8'h0E, DROT = 8'h0F, CONS = 8'h31;

    reg          reset = 1;
    reg          redirect = 0;
    reg  [31:0]  redirect_pc = 0;
    reg          irq_pending = 0;
    reg          hold = 0;

    wire         f_valid, f_inject;
    wire [31:0]  f_pc, f_instr;
    wire [2:0]   f_len;
    wire         line_sel;
    wire [31:4]  line_addr;
    reg  [127:0] line_data = 0;
    reg          line_ready = 0;
    wire [31:0]  pc;

    wire [1:0]   d_step;
    wire         d_last, stall;

    fetch #(.RESET_PC(32'h0000_0000)) fe (
        .clk(clk), .reset(reset),
        .redirect(redirect), .redirect_pc(redirect_pc), .irq_pending(irq_pending),
        .stall(stall), .f_valid(f_valid), .f_pc(f_pc), .f_instr(f_instr), .f_len(f_len),
        .f_inject(f_inject),
        .line_sel(line_sel), .line_addr(line_addr), .line_data(line_data),
        .line_ready(line_ready), .pc(pc)
    );

    sequencer dut (
        .clk(clk), .reset(reset), .redirect(redirect),
        .f_valid(f_valid), .f_opcode(f_instr[7:0]), .hold(hold),
        .d_step(d_step), .d_last(d_last), .stall(stall)
    );

    // ================================================================ the program
    reg [7:0]  mem    [0:65535];
    reg [31:0] exp_pc [0:MAX_INS-1];
    reg [2:0]  exp_n  [0:MAX_INS-1];    // its number of steps: 1, 2 or 4
    integer    n_ins = 0, seed = 9, a, i, l;

    initial begin
        for (a = 0; a < 65536; a = a + 1) mem[a] = 0;
        a = 0;
        while (a + 4 <= PROG_END && n_ins < MAX_INS) begin
            l = 1 + ($random(seed) & 3);
            if ((a % 16) + l > 16) l = 16 - (a % 16);          // stay in the line
            mem[a] = {l[1:0] - 2'd1, 6'h00} | ($random(seed) & 8'h3F);
            if (l == 1 && ($random(seed) & 1))
                mem[a] = (($random(seed) & 3) == 0) ? ROT : (($random(seed) & 1) ? DROT : CONS);
            for (i = 1; i < l; i = i + 1) mem[a + i] = $random(seed);
            exp_pc[n_ins] = a;
            exp_n[n_ins]  = (mem[a] == ROT) || (mem[a] == DROT) ? 2 : (mem[a] == CONS) ? 4 : 1;
            a = a + l;
            n_ins = n_ins + 1;
        end
    end

    // ================================================================ the line memory
    integer wait_n = 0, k;
    reg     busy = 0;
    always @(posedge clk) begin
        line_ready <= 0;
        if (line_sel && !line_ready) begin
            if (!busy) begin busy <= 1; wait_n <= $random(seed) & 7; end
            else if (wait_n == 0) begin
                for (k = 0; k < 16; k = k + 1)
                    line_data[8*k +: 8] <= mem[{line_addr[15:4], 4'b0000} + k];
                line_ready <= 1; busy <= 0;
            end else wait_n <= wait_n - 1;
        end
    end

    // ================================================================ checking
    integer errors = 0, idx = 0, issued = 0, two_steps = 0, ticks = 0, conses = 0, traps = 0;
    integer irq_during_step1 = 0, hold_during_step1 = 0, injected = 0, interrupts = 0;
    integer want = 0;                     // the next step of the instruction going out (0: none)
    reg [31:0] step0_pc;
    reg        trap_now = 0;              // CONS step 0 just went out: trap at this edge
    integer jump_in = -1, n_seq = 0, target;

    task fail(input [8*48-1:0] what);
        begin
            errors = errors + 1;
            if (errors <= 20) $display("%t %0s", $realtime, what);
        end
    endtask

    always @(posedge clk) if (!reset) begin
        ticks = ticks + 1;
        if (want != 0 && irq_pending) irq_during_step1 = irq_during_step1 + 1;
        if (want != 0 && hold)        hold_during_step1 = hold_during_step1 + 1;
        trap_now = 0;

        // what decode issues at this edge
        if (f_valid && !hold && !redirect) begin
            issued = issued + 1;
            if (want != 0) begin
                if (f_inject || f_pc !== step0_pc || d_step !== want)
                    fail("something came between the steps");
                if (d_last !== (want == exp_n[idx] - 1)) fail("last step wrong");
                want = want + 1;
                if (want == exp_n[idx]) begin want = 0; idx = idx + 1; end
            end else if (f_inject) begin
                injected = injected + 1;
                n_seq = n_seq + 1;
                if (d_step !== 0) fail("injected instruction not at step 0");
            end else begin
                if (f_pc !== exp_pc[idx]) fail("instruction out of order");
                if (d_step !== 0) fail("an instruction started at step 1");
                if (exp_n[idx] > 1) begin
                    if (d_last) fail("step 0 of several marked last");
                    want = 1; step0_pc = f_pc;
                    if (exp_n[idx] == 2) two_steps = two_steps + 1;
                    else begin
                        conses = conses + 1;
                        trap_now = ($random(seed) & 3) == 0;    // CONS traps now and then
                    end
                end else begin
                    if (!d_last) fail("ordinary instruction not last");
                    idx = idx + 1;
                end
            end
        end

        // ---- the rest of the pipeline, played at random
        redirect <= 0;
        hold     <= ($random(seed) & 3) == 0;
        // the interrupt sequence: acknowledge after its 3 instructions, then the jump
        if (irq_pending && n_seq >= 3) begin
            irq_pending <= 0; jump_in = 2 + ($random(seed) & 3);
        end
        if (trap_now) begin                                            // CONS's trap
            target = ($random(seed) & 32'h7FFF_FFFF) % (n_ins - 64);
            redirect <= 1; redirect_pc <= exp_pc[target]; idx = target; want = 0;
            traps = traps + 1;
        end else if (jump_in > 0) jump_in = jump_in - 1;
        else if (jump_in == 0 && want == 0) begin
            target = ($random(seed) & 32'h7FFF_FFFF) % (n_ins - 64);
            redirect <= 1; redirect_pc <= exp_pc[target]; idx = target;
            jump_in = -1; n_seq = 0;
        end else if (jump_in < 0 && !irq_pending && want == 0 &&
                     ($random(seed) & 255) == 0) begin
            target = ($random(seed) & 32'h7FFF_FFFF) % (n_ins - 64);   // a branch
            redirect <= 1; redirect_pc <= exp_pc[target]; idx = target;
        end else if (jump_in < 0 && !irq_pending && ($random(seed) & 127) == 0) begin
            irq_pending <= 1; interrupts = interrupts + 1; n_seq = 0;
        end
        if (idx > n_ins - 32 && want == 0) begin                       // near the end
            redirect <= 1; redirect_pc <= 0; idx = 0;
        end
    end

    initial begin
        repeat (2) @(posedge clk);
        #1 reset = 0;
        repeat (TICKS) @(posedge clk);
        $display("%0d issued, %0d ROT/DROT, %0d CONS (%0d trapped), %0d interrupts, %0d injected; while a later step was waiting: %0d ticks an interrupt was pending, %0d ticks hold",
                 issued, two_steps, conses, traps, interrupts, injected, irq_during_step1, hold_during_step1);
        if (two_steps < 1000 || conses < 1000 || traps < 200 || interrupts < 100 || irq_during_step1 < 50) begin
            errors = errors + 1;
            $display("too few cases tried");
        end
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
