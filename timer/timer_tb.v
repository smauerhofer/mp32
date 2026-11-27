// timer_tb.v: tests timer.v at 42 MHz.
//
//   make test
// or by hand:
//   iverilog -g2005 -s timer_tb -o timer_tb.vvp timer_tb.v timer.v
//   vvp timer_tb.vvp
//
// It checks the registers after reset and FREQ; that a periodic timer sets F every
// PERIOD ticks exactly, and irq only with IE; that a clear of F, and OVR when an event
// is lost; a one-shot timer (it stops, EN goes to 0); a write of COUNT; byte writes of
// PERIOD; that the two timers are apart; that every access takes two ticks; and that
// reset stops them.

`timescale 1ns/1ps

module timer_tb;
    localparam real TICK = 23.810;        // 42 MHz
    reg clk = 0;
    always #(TICK / 2) clk = ~clk;

    reg         reset = 1;
    reg         io_sel = 0, io_we = 0;
    reg  [3:0]  io_be = 4'hF;
    reg  [5:2]  io_addr = 0;
    reg  [31:0] io_wdata = 0;
    wire [31:0] io_rdata;
    wire        io_ready;
    wire        irq0, irq1;

    timer dut (
        .clk(clk), .reset(reset),
        .io_sel(io_sel), .io_we(io_we), .io_be(io_be), .io_addr(io_addr),
        .io_wdata(io_wdata), .io_rdata(io_rdata), .io_ready(io_ready),
        .irq0(irq0), .irq1(irq1)
    );

    localparam [7:0] T0CTRL = 8'h00, T0PERIOD = 8'h04, T0COUNT = 8'h08,
                     T1CTRL = 8'h10, T1PERIOD = 8'h14, T1COUNT = 8'h18, FREQ = 8'h20;

    integer errors = 0;

    task check(input [31:0] got_v, input [31:0] want, input [8*40-1:0] what);
        if (got_v !== want) begin
            errors = errors + 1;
            $display("%t %0s: %h, expected %h", $realtime, what, got_v, want);
        end
    endtask

    // One access, as the cache makes it: everything held until io_ready.
    reg [31:0] rd;
    integer    ticks;

    task access(input we, input [3:0] be, input [7:0] addr, input [31:0] wdata);
        begin
            @(negedge clk);
            io_sel = 1; io_we = we; io_be = be; io_addr = addr[5:2]; io_wdata = wdata;
            ticks = 0;
            @(posedge clk); ticks = ticks + 1;
            while (!io_ready) begin
                @(posedge clk); ticks = ticks + 1;
            end
            #1 rd = io_rdata;
            check(ticks, 2, "ticks of an access");
            @(negedge clk);
            io_sel = 0; io_we = 0; io_be = 4'hF;
        end
    endtask

    task write(input [7:0] addr, input [31:0] wdata);
        access(1'b1, 4'hF, addr, wdata);
    endtask

    task read(input [7:0] addr);
        access(1'b0, 4'hF, addr, 32'h0);
    endtask

    // the ticks from now until F of timer 0 is set (a limit of max)
    integer n;
    task ticks_to_f0(input integer max);
        begin
            n = 0;
            while (!dut.t0.f && n < max) begin @(posedge clk); #1 n = n + 1; end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk) reset = 0;

        // ---- after reset
        read(T0CTRL);   check(rd, 32'h0, "T0CTRL after reset");
        read(T0PERIOD); check(rd, 32'h0, "T0PERIOD after reset");
        read(T0COUNT);  check(rd, 32'h0, "T0COUNT after reset");
        read(T1CTRL);   check(rd, 32'h0, "T1CTRL after reset");
        read(FREQ);     check(rd, 32'd42_000_000, "FREQ");
        read(8'h0C);    check(rd, 32'h0, "a free address");
        check(irq0, 0, "irq0 after reset");
        check(irq1, 0, "irq1 after reset");

        // ---- PERIOD loads COUNT; nothing counts without EN
        write(T0PERIOD, 32'd10);
        read(T0COUNT);  check(rd, 32'd9, "COUNT = PERIOD - 1");
        repeat (5) @(posedge clk);
        read(T0COUNT);  check(rd, 32'd9, "no EN: no count");

        // ---- periodic, no IE: F every 10 ticks, no irq
        write(T0CTRL, 32'h1);                   // EN
        ticks_to_f0(100);
        check(dut.t0.f, 1, "F set");
        check(irq0, 0, "F without IE: no irq");
        write(T0CTRL, 32'h101);                 // clear F, EN kept
        check(dut.t0.f, 0, "F cleared");
        // from one event to the next: 10 ticks
        while (!dut.t0.event_hit) begin @(posedge clk); #1; end
        @(posedge clk); #1; n = 1;
        while (!dut.t0.event_hit && n < 100) begin @(posedge clk); #1 n = n + 1; end
        check(n, 10, "from one event to the next");
        write(T0CTRL, 32'h101);
        write(T0CTRL, 32'h103);                 // IE on, clear F
        ticks_to_f0(100);
        check(irq0, 1, "F with IE: irq0");
        check(irq1, 0, "not irq1");

        // ---- OVR: F not cleared for longer than a period
        repeat (25) @(posedge clk);
        read(T0CTRL);   check(rd, 32'h303, "F and OVR");
        write(T0CTRL, 32'h303);                 // clear both
        read(T0CTRL);   check(rd & 32'h200, 32'h0, "OVR cleared");
        write(T0CTRL, 32'h0);                   // stop it
        write(T0CTRL, 32'h300);
        check(irq0, 0, "irq0 gone");

        // ---- one-shot: one event, then EN = 0, COUNT 0
        write(T0PERIOD, 32'd20);
        write(T0CTRL, 32'h7);                   // EN, IE, ONESHOT
        ticks_to_f0(100);
        check(dut.t0.f, 1, "one-shot: F");
        @(posedge clk); #1;
        read(T0CTRL);   check(rd, 32'h106, "one-shot: EN 0");
        read(T0COUNT);  check(rd, 32'h0, "one-shot: COUNT 0");
        write(T0CTRL, 32'h106);                 // clear F
        repeat (50) @(posedge clk);
        check(dut.t0.f, 0, "one-shot: no second event");

        // ---- COUNT written: the event after COUNT + 1 ticks
        write(T0CTRL, 32'h300);
        write(T0COUNT, 32'd4);
        @(negedge clk);
        io_sel = 1; io_we = 1; io_addr = T0CTRL[5:2]; io_wdata = 32'h1;  // EN, by hand
        @(posedge clk); #1; n = 1;              // EN is set at this edge
        @(negedge clk); io_sel = 0; io_we = 0;
        while (!dut.t0.f && n < 100) begin @(posedge clk); #1 n = n + 1; end
        check(n, 6, "COUNT 4: F 5 ticks after EN");
        write(T0CTRL, 32'h300);

        // ---- byte writes of PERIOD
        write(T1PERIOD, 32'h12345678);
        access(1'b1, 4'b0100, T1PERIOD, 32'hAABBCCDD);
        read(T1PERIOD); check(rd, 32'h12BB5678, "a byte of PERIOD");
        read(T1COUNT);  check(rd, 32'h12BB5677, "COUNT with it");
        access(1'b1, 4'b0010, T1CTRL, 32'h0000_0007);   // be[1] only: EN stays 0
        read(T1CTRL);   check(rd, 32'h0, "CTRL without be[0]");

        // ---- the two apart: timer 1 runs, timer 0 does not
        read(T0COUNT);  n = rd;
        write(T1PERIOD, 32'd8);
        write(T1CTRL, 32'h3);
        repeat (12) @(posedge clk); #1;
        check(irq1, 1, "timer 1: irq1");
        check(irq0, 0, "timer 1: not irq0");
        read(T0COUNT);  check(rd, n, "timer 0 stood still");

        // ---- reset stops it
        @(negedge clk) reset = 1;
        @(negedge clk) reset = 0;
        check(irq1, 0, "irq1 after reset");
        read(T1CTRL);   check(rd, 32'h0, "T1CTRL after the second reset");
        read(T1PERIOD); check(rd, 32'h0, "T1PERIOD after the second reset");

        if (errors == 0) $display("timer_tb: all passed");
        else             $display("timer_tb: %0d errors", errors);
        $finish;
    end
endmodule
