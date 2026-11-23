// audio_tb.v: tests audio.v at 42 MHz.
//
//   make test
// or by hand:
//   iverilog -g2005 -s audio_tb -o audio_tb.vvp audio_tb.v audio.v
//   vvp audio_tb.vvp
//
// The MAX98357A is a model at the other end of the three wires: it takes DIN and
// LRCLK at each rising edge of BCLK, as the chip does, and keeps every frame it gets
// (the left and the right sample). It checks that BCLK has the period DIV gives, that
// a frame is 64 BCLKs, and that left and right are the same.
//
// It checks the registers after reset; ON and pa_en; samples written in a row (the
// writes wait while the queue is full) coming out in order; UNDER; silence when the
// queue is empty; the tone with its height, period and length, and LEN = $FF_FFFF;
// the sum of queue and tone held at 16 bits; a new DIV; the interrupt. Then the
// sample memory: two banks played one after the other, the end of the banks
// (BUNDER), a stream of banks refilled while the other plays, with 32-bit and 16-bit
// writes, PLAY waiting for a bank, BLEN, DONE and its interrupt (and a stream fed by
// the interrupt), and the banks added to the tone.

`timescale 1ns/1ps

module audio_tb;
    localparam real TICK = 23.810;        // 42 MHz
    reg clk = 0;
    always #(TICK / 2) clk = ~clk;

    reg         reset = 1;
    reg         io_sel = 0, io_we = 0;
    reg  [12:2] io_addr = 0;
    reg  [3:0]  io_be = 4'hF;
    reg  [31:0] io_wdata = 0;
    wire [31:0] io_rdata;
    wire        io_ready;
    wire        irq;
    wire        bck, ws, din, pa_en;

    audio #(.DIV_INIT(8'd7), .BITS(6)) dut (
        .clk(clk), .reset(reset),
        .io_sel(io_sel), .io_we(io_we), .io_be(io_be), .io_addr(io_addr),
        .io_wdata(io_wdata), .io_rdata(io_rdata), .io_ready(io_ready),
        .irq(irq), .hp_bck(bck), .hp_ws(ws), .hp_din(din), .pa_en(pa_en)
    );

    localparam DATA = 0, STATUS = 1, CTRL = 2, DIV = 3, TONE = 4, LEN = 5,
               BSTATUS = 6, BLEN = 7, READY = 8;
    localparam [10:0] MEM = 11'h400;    // io_addr[12:2] of the sample memory

    integer errors = 0;

    task check(input [31:0] got_v, input [31:0] want, input [8*40-1:0] what);
        if (got_v !== want) begin
            errors = errors + 1;
            if (errors < 30)
                $display("%t %0s: %h, expected %h", $realtime, what, got_v, want);
        end
    endtask

    // ================================================================ the chip
    // Every frame, in heard[]: the left sample (the right one is checked against it).
    reg  [15:0] heard [0:65535];
    integer     nheard = 0;
    integer     n = 0, bits_in_frame = 0;
    reg         last_ws = 1;
    reg  [15:0] word = 0, left = 0;
    integer     ticks = 0, last_rise = 0, period = 0, want_period = 14;
    integer     frames_checked = 0;

    always @(posedge clk) ticks = ticks + 1;

    always @(posedge bck) begin
        period = ticks - last_rise;
        last_rise = ticks;
        if (nheard > 1 && want_period > 0 && period != want_period) begin
            errors = errors + 1;
            if (errors < 30) $display("%t BCLK period %0d ticks, expected %0d", $realtime, period, want_period);
        end
        if (ws != last_ws) begin
            n = 0;
            if (ws == 0) begin                  // a new frame
                if (nheard > 0 && bits_in_frame != 64) begin
                    errors = errors + 1;
                    $display("%t a frame of %0d BCLKs", $realtime, bits_in_frame);
                end
                bits_in_frame = 0;
            end
        end else
            n = n + 1;
        bits_in_frame = bits_in_frame + 1;
        last_ws = ws;
        if (n >= 1 && n <= 16) word = {word[14:0], din};
        if (n > 16 && din !== 1'b0) begin
            errors = errors + 1;
            if (errors < 30) $display("%t DIN not 0 after the sample (bit %0d)", $realtime, n);
        end
        if (n == 16) begin
            if (ws == 0) left = word;
            else begin
                if (word !== left) begin
                    errors = errors + 1;
                    if (errors < 30) $display("%t left %h, right %h", $realtime, left, word);
                end
                heard[nheard] = left;
                nheard = nheard + 1;
            end
        end
    end

    // ================================================================ the bus
    reg  [31:0] r;
    integer     waited;

    task access(input we, input [10:0] a, input [31:0] wd, output [31:0] rd);
        begin
            @(negedge clk);
            io_sel = 1; io_we = we; io_addr = a; io_wdata = wd;
            waited = 0;
            @(posedge clk);
            while (!io_ready) begin waited = waited + 1; @(posedge clk); end
            rd = io_rdata;
            @(negedge clk);
            io_sel = 0; io_we = 0;
        end
    endtask

    task wr(input [10:0] a, input [31:0] wd); access(1, a, wd, r); endtask
    task rd(input [10:0] a);                  access(0, a, 0,  r); endtask

    // sample k of bank b (two to a word): two with a 32-bit write, or one 16-bit
    task put2(input b, input integer k, input [15:0] first, input [15:0] second);
        wr(MEM | (b << 9) | (k >> 1), {second, first});
    endtask
    task put1(input b, input integer k, input [15:0] v);
        begin
            io_be = k[0] ? 4'b1100 : 4'b0011;
            wr(MEM | (b << 9) | (k >> 1), k[0] ? {v, 16'h0} : {16'h0, v});
            io_be = 4'hF;
        end
    endtask

    // a bank of n samples: base + k
    task fill(input b, input integer n, input [15:0] base, input sixteen);
        integer k;
        for (k = 0; k < n; k = k + 2)
            if (sixteen) begin put1(b, k, base + k); put1(b, k + 1, base + k + 1); end
            else         put2(b, k, base + k, base + k + 1);
    endtask

    task frames(input integer k);
        integer start;
        begin start = nheard; wait (nheard >= start + k); end
    endtask

    // the index in heard[] of the first v at or after from, or -1
    function integer find(input integer from, input [15:0] v);
        integer i;
        begin
            find = -1;
            for (i = nheard - 1; i >= from; i = i - 1)
                if (heard[i] === v) find = i;
        end
    endfunction

    // ================================================================ the tests
    integer i, at, max_wait, mark, k, bk;
    reg [15:0] want;

    initial begin
        repeat (4) @(posedge clk);
        reset = 0;

        // ---- after reset
        rd(STATUS); check(r, 32'h0000_0005, "STATUS after reset (EMPTY, HALF)");
        rd(CTRL);   check(r, 0, "CTRL after reset");
        rd(DIV);    check(r, 7, "DIV after reset");
        rd(TONE);   check(r, 0, "TONE after reset");
        rd(LEN);    check(r, 0, "LEN after reset");
        rd(DATA);   check(r, 0, "DATA reads 0");
        check(pa_en, 0, "pa_en after reset");
        check(irq, 0, "irq after reset");

        wr(CTRL, 1);
        check(pa_en, 1, "pa_en with ON");
        rd(CTRL); check(r, 1, "CTRL");

        frames(3);
        for (i = 0; i < 3; i = i + 1) check(heard[nheard - 1 - i], 0, "silence");

        // ---- a stream: 200 samples in a row; the queue makes the writes wait
        mark = nheard;
        max_wait = 0;
        for (i = 0; i < 200; i = i + 1) begin
            wr(DATA, 16'h1000 + i * 97);
            if (waited > max_wait) max_wait = waited;
        end
        if (max_wait < 100) begin
            errors = errors + 1;
            $display("the writes never waited for the queue (at most %0d ticks)", max_wait);
        end
        rd(STATUS);
        check(r[1], 1, "FULL after the stream is written");
        check(r[15:8], 64, "the queue holds 64");
        frames(70);
        at = find(mark, 16'h1000);
        if (at < 0) begin errors = errors + 1; $display("the stream's first sample never came"); end
        else for (i = 0; i < 200; i = i + 1) begin
            want = 16'h1000 + i * 97;
            check(heard[at + i], want, "the stream, in order");
        end
        check(heard[at + 200], 0, "silence after the stream");
        rd(STATUS);
        check(r[0], 1, "EMPTY after the stream");
        check(r[3], 1, "UNDER after the stream ran dry");
        wr(STATUS, 32'h8);
        rd(STATUS); check(r[3], 0, "UNDER cleared");
        frames(4);
        rd(STATUS); check(r[3], 0, "UNDER stays 0 while nothing is played");

        // ---- the tone: half period 3, height 1000, 20 samples
        wr(TONE, {1'b0, 15'd1000, 16'd3});
        rd(TONE); check(r, {1'b0, 15'd1000, 16'd3}, "TONE");
        mark = nheard;
        wr(LEN, 20);
        rd(STATUS); check(r[4], 1, "TONE in STATUS while it sounds");
        frames(26);
        at = find(mark, 16'd1000);
        if (at < 0) begin errors = errors + 1; $display("the tone never came"); end
        else begin
            for (i = 0; i < 20; i = i + 1) begin
                want = ((i / 3) % 2 == 0) ? 16'd1000 : -16'sd1000;
                check(heard[at + i], want, "the tone");
            end
            check(heard[at + 20], 0, "silence after the tone");
        end
        rd(STATUS); check(r[4], 0, "TONE in STATUS after it ended");
        rd(LEN);    check(r, 0, "LEN after the tone");

        // ---- the tone without end, and the sum held at 16 bits
        wr(TONE, {1'b0, 15'd1000, 16'd2});
        wr(LEN, 24'hFF_FFFF);
        frames(10);
        rd(LEN); check(r, 24'hFF_FFFF, "LEN $FF_FFFF does not count down");
        mark = nheard;
        for (i = 0; i < 8; i = i + 1) wr(DATA, (i % 2) ? 16'h8300 : 16'h7D00);  // -32000, 32000
        frames(12);
        // queue +-32000, tone +-1000: 33000 is held to 32767, -33000 to -32768,
        // 31000 and -31000 pass
        if (find(mark, 16'h7FFF) < 0 || find(mark, 16'h8000) < 0) begin
            errors = errors + 1;
            $display("the sum was not held at 32767 and -32768");
        end
        for (i = mark; i < nheard; i = i + 1)
            if (heard[i] !== 16'h7FFF && heard[i] !== 16'h8000 && heard[i] !== 16'd31000 &&
                heard[i] !== -16'sd31000 && heard[i] !== 16'd1000 && heard[i] !== -16'sd1000) begin
                errors = errors + 1;
                $display("a sum of queue and tone: %h", heard[i]);
            end
        wr(LEN, 0);
        rd(STATUS); check(r[4], 0, "the tone stopped with LEN = 0");

        // ---- a new DIV: 10 ticks of half a BCLK
        want_period = -1;                   // the BCLK that DIV changes in
        wr(DIV, 10);
        rd(DIV); check(r, 10, "DIV");
        @(posedge bck); @(posedge bck);
        want_period = 20;
        frames(4);
        want_period = -1;
        wr(DIV, 1);
        rd(DIV); check(r, 2, "DIV at least 2");
        @(posedge bck); @(posedge bck); @(posedge bck);
        want_period = 4;
        frames(4);
        want_period = -1;
        wr(DIV, 7);
        @(posedge bck); @(posedge bck); @(posedge bck);
        want_period = 14;
        frames(2);

        // ---- the interrupt: while the queue is at most half full
        wr(CTRL, 3);
        check(irq, 1, "irq with IE, the queue empty");
        for (i = 0; i < 64; i = i + 1) wr(DATA, i);
        check(irq, 0, "no irq with the queue full");
        wait (irq);
        rd(STATUS); check(r[15:8] <= 32, 1, "irq when half full");
        wr(CTRL, 1);
        check(irq, 0, "no irq without IE");
        wr(CTRL, 0);
        check(pa_en, 0, "pa_en off");
        frames(70);                         // the queue played out
        wr(STATUS, 32'h8);

        // ================================================ the sample memory
        rd(BSTATUS); check(r, 0, "BSTATUS after reset");
        rd(BLEN);    check(r, 1024, "BLEN after reset");
        wr(BLEN, 0);    rd(BLEN); check(r, 1024, "BLEN 0 is 1024");
        wr(BLEN, 2000); rd(BLEN); check(r, 1024, "BLEN 2000 is 1024");
        wr(BLEN, 16);   rd(BLEN); check(r, 16, "BLEN");
        rd(MEM);     check(r, 0, "the sample memory reads 0");

        // ---- two banks, played one after the other, then BUNDER
        fill(0, 16, 16'h2000, 0);
        fill(1, 16, 16'h3000, 0);
        wr(READY, 3);
        rd(BSTATUS); check(r[4:0], 5'b00011, "BSTATUS: both FULL, bank 0, not playing");
        mark = nheard;
        wr(CTRL, 32'h5);                    // ON, PLAY
        frames(40);
        at = find(mark, 16'h2000);
        if (at < 0) begin errors = errors + 1; $display("bank 0 never played"); end
        else begin
            for (i = 0; i < 16; i = i + 1) check(heard[at + i], 16'h2000 + i, "bank 0");
            for (i = 0; i < 16; i = i + 1) check(heard[at + 16 + i], 16'h3000 + i, "bank 1, right after");
            check(heard[at + 32], 0, "silence after both banks");
        end
        rd(BSTATUS);
        check(r[1:0], 0, "both banks empty again");
        check(r[3], 1, "BUNDER after the banks ran out");
        check(r[4], 0, "no bank playing");
        wr(BSTATUS, 32'h8);
        rd(BSTATUS); check(r[3], 0, "BUNDER cleared");

        // ---- waiting: PLAY with nothing FULL plays 0, then starts at sample 0 of
        // the bank it waits for (bank 0, after PLAY off and on)
        wr(CTRL, 32'h1);
        wr(CTRL, 32'h5);
        rd(BSTATUS); check(r[2], 0, "PLAY starts at bank 0");
        frames(5);
        fill(0, 16, 16'h5000, 1);           // 16-bit writes
        mark = nheard;
        wr(READY, 1);
        frames(20);
        at = find(mark, 16'h5000);
        if (at < 0) begin errors = errors + 1; $display("the waited-for bank never played"); end
        else for (i = 0; i < 16; i = i + 1) check(heard[at + i], 16'h5000 + i, "bank 0 from 16-bit writes");
        wr(BSTATUS, 32'h8);

        // ---- a stream: 12 banks of 32, each filled while the other plays
        wr(CTRL, 32'h1);                    // PLAY off: back to bank 0
        wr(BLEN, 32);
        fill(0, 32, 16'h6000, 0);
        fill(1, 32, 16'h6020, 0);
        wr(READY, 3);
        mark = nheard;
        wr(CTRL, 32'h5);
        bk = 0;
        for (k = 2; k < 12; k = k + 1) begin
            rd(BSTATUS);
            while (r[bk]) rd(BSTATUS);      // wait until the bank is empty
            fill(bk, 32, 16'h6000 + k * 32, k % 2);
            wr(READY, 1 << bk);
            bk = 1 - bk;
        end
        frames(80);
        at = find(mark, 16'h6000);
        if (at < 0) begin errors = errors + 1; $display("the stream never played"); end
        else begin
            for (i = 0; i < 12 * 32; i = i + 1) check(heard[at + i], 16'h6000 + i, "the stream of banks, without a gap");
            check(heard[at + 12 * 32], 0, "silence after the stream");
        end
        rd(BSTATUS);
        check(r[3], 1, "BUNDER only at the end of the stream");

        // ---- DONE and BIE: a bank played to its end
        rd(BSTATUS);
        check(r[6:5], 2'b11, "DONE0 and DONE1 after the stream");
        wr(CTRL, 32'h1);                    // PLAY off
        wr(BSTATUS, 32'h68);                // clear DONE0, DONE1, BUNDER
        rd(BSTATUS); check(r[6:3], 0, "DONE and BUNDER cleared");
        wr(CTRL, 32'h9);                    // ON, BIE, not PLAY
        check(irq, 0, "no irq with BIE and nothing played");
        wr(BLEN, 16);
        fill(0, 16, 16'h7000, 0);
        fill(1, 16, 16'h7010, 0);
        wr(READY, 3);
        wr(CTRL, 32'hD);                    // ON, PLAY, BIE
        check(irq, 0, "no irq while bank 0 plays");
        wait (irq);
        rd(BSTATUS);
        check(r[6:5], 2'b01, "DONE0 when bank 0 has been played");
        check(r[0], 0, "bank 0 empty with DONE0");
        check(r[2], 1, "bank 1 playing with DONE0");
        wr(BSTATUS, 32'h20);
        check(irq, 0, "no irq once DONE0 is cleared");
        wait (irq);
        rd(BSTATUS); check(r[6:5], 2'b10, "DONE1 when bank 1 has been played");
        wr(CTRL, 32'h5);                    // without BIE
        check(irq, 0, "no irq without BIE");
        wr(CTRL, 32'hD);
        check(irq, 1, "DONE1 still there: irq again with BIE");
        wr(CTRL, 32'h1);
        wr(BSTATUS, 32'h68);

        // ---- a stream fed by the interrupt: the handler fills each bank it is told
        // is done, says READY and clears its DONE. 14 banks of 32 without a gap.
        wr(BLEN, 32);
        fill(0, 32, 16'h0800, 0);
        fill(1, 32, 16'h0820, 0);
        wr(READY, 3);
        mark = nheard;
        wr(CTRL, 32'hD);
        k = 2;
        while (k < 14) begin
            wait (irq);
            rd(BSTATUS);
            for (bk = 0; bk < 2; bk = bk + 1)
                if (r[5 + bk] && k < 14) begin
                    fill(bk, 32, 16'h0800 + k * 32, 0);
                    wr(READY, 1 << bk);
                    wr(BSTATUS, 32'h20 << bk);
                    k = k + 1;
                end
        end
        frames(90);
        at = find(mark, 16'h0800);
        if (at < 0) begin errors = errors + 1; $display("the interrupt stream never played"); end
        else begin
            for (i = 0; i < 14 * 32; i = i + 1) check(heard[at + i], 16'h0800 + i, "the stream fed by the interrupt, without a gap");
            check(heard[at + 14 * 32], 0, "silence after the interrupt stream");
        end
        wr(CTRL, 32'h1);
        wr(BSTATUS, 32'h68);

        // ---- the banks plus the tone
        wr(CTRL, 32'h1);
        wr(BLEN, 8);
        fill(0, 8, 16'd100, 0);
        wr(READY, 1);
        wr(TONE, {1'b0, 15'd10, 16'd1000});
        wr(LEN, 24'hFF_FFFF);
        mark = nheard;
        wr(CTRL, 32'h5);
        frames(12);
        wr(LEN, 0);
        at = find(mark, 16'd110);
        if (at < 0) begin errors = errors + 1; $display("bank + tone never came"); end
        else for (i = 0; i < 8; i = i + 1) check(heard[at + i], 16'd110 + i, "bank + tone");
        wr(CTRL, 0);

        $display("%0d frames heard", nheard);
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
