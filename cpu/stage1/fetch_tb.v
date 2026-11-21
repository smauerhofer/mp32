// fetch_tb.v: tests fetch.v.
//
//   make test-fetch
// or by hand:
//   iverilog -g2005 -o fetch_tb.vvp fetch_tb.v fetch.v pc.v irq_sequence.v
//   vvp fetch_tb.vvp
//
// It makes a program of random instructions, 1 to 4 bytes, in 64 KB of memory. The
// bytes an instruction would put past the end of a line are left random in the
// memory: fetch must deliver them as 0. A simple line memory answers the line port
// after a random 1 to 8 ticks and checks that line_sel and line_addr are held.
//
// Phase 1 runs straight through, never stalled, to measure the speed.
// Phase 2 stalls the fetch at random, redirects it at random to the start of some
// instruction (a taken branch), and makes interrupts pending at random. For an
// interrupt it plays the later stages: when the last instruction of the sequence
// reaches decode it clears irq_pending (the acknowledge), and a few ticks later it
// redirects to a random instruction (the jump to the handler). A random branch can
// come in the middle of a sequence; then the sequence must start again.
//
// Every instruction that comes out is checked: PC, the 4 bytes, the length, and
// f_inject. An injected instruction must be the next one of the sequence, with
// f_pc = the address of the next instruction of the program (the PC did not move).
// Between the end of a sequence and the jump nothing may come out.

`timescale 1ns/1ps

module fetch_tb;
    parameter PROG_END = 32'h0000_F000;   // the program fills 0 .. PROG_END-1
    parameter MAX_INS  = 40000;
    parameter PHASE2   = 50000;           // instructions checked in phase 2

    reg clk = 0;
    always #18.5 clk = ~clk;              // 27 MHz

    reg          reset = 1;
    reg          redirect = 0;
    reg  [31:0]  redirect_pc = 0;
    reg          irq_pending = 0;
    reg          stall = 0;
    wire         f_valid;
    wire [31:0]  f_pc, f_instr;
    wire [2:0]   f_len;
    wire         f_inject;
    wire [31:0]  pc;
    wire         line_sel;
    wire [31:4]  line_addr;
    reg  [127:0] line_data = 0;
    reg          line_ready = 0;

    // The program here starts at 0, so the PC must too (the default is 0xF000_0000).
    fetch #(.RESET_PC(32'h0000_0000)) dut (
        .clk(clk), .reset(reset),
        .redirect(redirect), .redirect_pc(redirect_pc), .irq_pending(irq_pending),
        .stall(stall), .f_valid(f_valid), .f_pc(f_pc), .f_instr(f_instr), .f_len(f_len),
        .f_inject(f_inject),
        .line_sel(line_sel), .line_addr(line_addr), .line_data(line_data),
        .line_ready(line_ready), .pc(pc)
    );

    // ================================================================ the program
    reg [7:0]  mem     [0:65535];
    reg [31:0] exp_pc  [0:MAX_INS-1];
    reg [31:0] exp_ins [0:MAX_INS-1];
    reg [2:0]  exp_len [0:MAX_INS-1];
    integer    n_ins = 0;
    integer    seed  = 7;

    integer a, i, l, crossings = 0;
    initial begin
        for (a = 0; a < 65536; a = a + 1) mem[a] = $random(seed);
        a = 0;
        while (a + 4 <= PROG_END && n_ins < MAX_INS) begin
            l = 1 + ($random(seed) & 3);
            mem[a] = {l[1:0] - 2'd1, 6'h00} | ($random(seed) & 8'h3F);
            for (i = 1; i < l; i = i + 1) mem[a + i] = $random(seed);
            if ((a % 16) + l > 16) crossings = crossings + 1;
            exp_pc[n_ins]  = a;
            exp_len[n_ins] = l;
            a = a + l;
            n_ins = n_ins + 1;
        end
        // the 4 bytes fetch must deliver: 0 past the end of the line
        for (i = 0; i < n_ins; i = i + 1)
            for (l = 0; l < 4; l = l + 1)
                exp_ins[i][8*l +: 8] = ((exp_pc[i] % 16) + l < 16) ? mem[exp_pc[i] + l] : 8'h00;
    end

    // ================================================================ the line memory
    integer      wait_n = 0, fills = 0, port_errors = 0;
    reg  [31:4]  held_addr;
    reg          busy = 0;
    integer      k;

    always @(posedge clk) begin
        line_ready <= 0;
        if (line_sel && !line_ready) begin
            if (!busy) begin
                busy      <= 1;
                held_addr <= line_addr;
                wait_n    <= $random(seed) & 7;
            end else begin
                if (line_addr !== held_addr) begin
                    port_errors = port_errors + 1;
                    $display("%t line_addr changed during a fill", $realtime);
                end
                if (wait_n == 0) begin
                    for (k = 0; k < 16; k = k + 1)
                        line_data[8*k +: 8] <= mem[{line_addr[15:4], 4'b0000} + k];
                    line_ready <= 1;
                    busy       <= 0;
                    fills      =  fills + 1;
                end else
                    wait_n <= wait_n - 1;
            end
        end else if (!line_sel && busy) begin
            port_errors = port_errors + 1;
            $display("%t line_sel dropped during a fill", $realtime);
            busy <= 0;
        end
    end

    // ================================================================ checking
    integer idx = 0, checked = 0, errors = 0, ticks = 0, phase = 1;
    integer redirects = 0, target, irq_ticks = 0;
    integer sequences = 0, restarts = 0, injected = 0;
    integer seq_pos   = 0;       // the next instruction of the sequence expected
    integer jump_in   = -1;      // ticks to the jump to the handler; -1: none coming
    reg     seq_done  = 0;       // the sequence is out; nothing more until the jump
    reg     irq_prev  = 0;       // at the edge before: an interrupt pending, f_* loaded,
    reg     took_prev = 0;       // no redirect
    reg     redir_prev = 0;

    // the sequence, as the test bench expects it
    reg  [3:0]  ref_index = 0;
    wire [31:0] ref_instr;
    wire        ref_last;
    irq_sequence ref_seq (.index(ref_index), .instr(ref_instr), .last(ref_last));

    task fail(input [8*40-1:0] what);
        begin
            errors = errors + 1;
            if (errors <= 20)
                $display("%t #%0d: %0s: got pc %h ins %h len %0d inject %b", $realtime,
                         idx, what, f_pc, f_instr, f_len, f_inject);
        end
    endtask

    task check;
        begin
            if (seq_done)
                fail("an instruction before the jump");
            else if (idx >= n_ins)
                fail("ran past the end of the program");
            else if (f_inject) begin
                ref_index = seq_pos;
                #0;
                if (f_pc !== exp_pc[idx] || f_instr !== ref_instr ||
                    f_len !== {1'b0, ref_instr[7:6]} + 3'd1)
                    fail("wrong injected instruction");
                if (seq_pos == 0) sequences = sequences + 1;
                seq_pos  = seq_pos + 1;
                injected = injected + 1;
                if (ref_last) begin             // the later stages: acknowledge, jump
                    seq_done    = 1;
                    irq_pending <= 0;
                    jump_in     = $random(seed) & 3;
                end
            end else begin
                if (seq_pos != 0)
                    fail("the sequence was cut short");
                if (irq_prev && took_prev && !redir_prev)
                    fail("not injected while an interrupt was pending");
                if (f_pc !== exp_pc[idx] || f_instr !== exp_ins[idx] ||
                    f_len !== exp_len[idx])
                    fail("wrong instruction");
                idx     = idx + 1;
                checked = checked + 1;
            end
        end
    endtask

    always @(posedge clk) if (!reset) begin
        ticks = ticks + 1;
        if (irq_pending) irq_ticks = irq_ticks + 1;

        // what decode does at this edge, with the values from before it
        if (f_valid && !stall && !redirect)
            check;
        irq_prev   = irq_pending;
        took_prev  = !stall || !f_valid;
        redir_prev = redirect;
        if (redirect) begin
            if (seq_pos != 0 && !seq_done) restarts = restarts + 1;
            idx      = target;
            seq_pos  = 0;
            seq_done = 0;
            jump_in  = -1;
        end

        // what decode and the later stages do in the next tick
        if (phase == 2) begin
            stall    <= ($random(seed) & 3) == 0;
            redirect <= 0;
            if (!irq_pending && !seq_done && ($random(seed) & 63) == 0)
                irq_pending <= 1;
            if (jump_in == 0 || ($random(seed) & 31) == 0) begin
                // the jump to the handler, or a branch
                target      = ($random(seed) & 32'h7FFF_FFFF) % (n_ins - 64);
                redirect    <= 1;
                redirect_pc <= exp_pc[target];
                redirects   = redirects + 1;
                jump_in     = -1;
            end else if (jump_in > 0)
                jump_in = jump_in - 1;
        end
    end

    // ================================================================ the run
    integer t0;
    initial begin
        #1;
        $display("program: %0d instructions, %0d bytes, %0d cross the end of a line",
                 n_ins, exp_pc[n_ins-1] + exp_len[n_ins-1], crossings);
        repeat (4) @(posedge clk);
        reset <= 0;

        // ---- phase 1: straight through
        t0 = ticks;
        wait (idx >= n_ins - 8);
        @(posedge clk);
        $display("phase 1: %0d instructions in %0d ticks, %0.3f per tick, %0d line fills",
                 idx, ticks - t0, idx * 1.0 / (ticks - t0), fills);

        // ---- phase 2: random stalls and redirects
        @(posedge clk);
        target      = 0;
        redirect    <= 1;
        redirect_pc <= exp_pc[0];
        phase       = 2;
        checked     = 0;
        wait (idx < n_ins - 8);
        wait (checked >= PHASE2 || idx >= n_ins - 8);
        @(posedge clk);
        $display("phase 2: %0d instructions checked, %0d redirects, %0d ticks with an interrupt pending",
                 checked, redirects, irq_ticks);
        $display("         %0d sequences started, %0d instructions injected, %0d sequences cut by a branch",
                 sequences, injected, restarts);

        if (errors == 0 && port_errors == 0)
            $display("PASS");
        else
            $display("FAIL: %0d instruction errors, %0d line port errors", errors, port_errors);
        $finish;
    end

    initial begin
        #100_000_000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
