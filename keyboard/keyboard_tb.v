// keyboard_tb.v: tests keyboard.v (with ../uart/uart_rx.v and ../uart/uart_tx.v) at
// 42 MHz, against ch9350.v, a model of the CH9350L module on both wires.
//
//   make test
// or by hand:
//   iverilog -g2005 -s keyboard_tb -o keyboard_tb.vvp keyboard_tb.v keyboard.v \
//       ch9350.v ../uart/uart_rx.v ../uart/uart_tx.v
//   vvp keyboard_tb.vvp
//
// The keep-alive here comes every 300,000 ticks (7 ms) instead of every second, so
// that the test bench sees several.
//
//   1. after reset: the registers, ECHO = FF, and nothing sent while TXEN is 0
//   2. the chip starts (86, 80 FF, 89, 80 FF): GONE, and no report
//   3. Q down and up, each report three or four times: two reports in the queue, the
//      repeats dropped; KIE and the irq; KEYS1 takes, KEYS0 does not
//   4. Shift + A, six keys, seven keys (01 everywhere): the bytes in their places
//   5. ten reports not read: eight kept in order, LOST; clearing LOST
//   6. the mouse: frames holding 57 AB 01, the sums, the buttons, the wheel, MOUSE
//      and MIE; then 400 random reports while the program reads MOUSE and BUTTONS
//      as fast as it can: no movement lost
//   7. bytes that begin no frame, a frame of a kind we do not know, a frame cut short
//      (5 ms of silence): SYNC, and the reports after them right
//   8. a byte without its stop bit: FERR
//   9. the LEDs: a write with TXEN at 0 sends nothing; TXEN sends at once; each write
//      sends, the chip answers 80 3N (ECHO); writes while a frame goes out: the last
//      LEDs win; the keep-alive repeats; TXEN at 0 stops it
//  10. the chip 3 % fast, then 3 % slow: reports and the mouse still right
//  11. GONE after a replug lets a held key come up

`timescale 1ns/1ps

module keyboard_tb;
    localparam real TICK = 23.810;          // 42 MHz
    reg clk = 0;
    always #(TICK / 2) clk = ~clk;

    reg         reset = 1;
    reg         io_sel = 0, io_we = 0;
    reg  [4:2]  io_addr = 0;
    reg  [31:0] io_wdata = 0;
    wire [31:0] io_rdata;
    wire        io_ready;
    wire        irq;
    wire        kbd_rx, kbd_tx;

    localparam KEEP = 300_000;

    keyboard #(.DIV(16'd365), .TIMEOUT(210_000), .KEEP(KEEP)) dut (
        .clk(clk), .reset(reset),
        .io_sel(io_sel), .io_we(io_we), .io_be(4'hF), .io_addr(io_addr),
        .io_wdata(io_wdata), .io_rdata(io_rdata), .io_ready(io_ready),
        .irq(irq), .kbd_rx(kbd_rx), .kbd_tx(kbd_tx)
    );

    ch9350 kb (.tx(kbd_rx), .rx(kbd_tx));

    integer errors = 0;

    task check(input [31:0] got_v, input [31:0] want, input [8*40-1:0] what);
        if (got_v !== want) begin
            errors = errors + 1;
            if (errors < 40)
                $display("%t %0s: %h, expected %h", $realtime, what, got_v, want);
        end
    endtask

    // ================================================================ the bus
    task access(input we, input [2:0] a, input [31:0] wd, output [31:0] rd);
        begin
            io_sel <= 1; io_we <= we; io_addr <= a; io_wdata <= wd;
            @(posedge clk); #1;
            while (!io_ready) begin @(posedge clk); #1; end
            rd = io_rdata;
            @(posedge clk); #1;
            io_sel <= 0;
        end
    endtask

    reg [31:0] r;
    task wr(input [2:0] a, input [31:0] wd); access(1, a, wd, r); endtask
    task rd(input [2:0] a);                  access(0, a, 0,  r); endtask

    localparam STATUS = 0, KEYS0 = 1, KEYS1 = 2, MOUSE = 3, BUTTONS = 4, LEDS = 5,
               CTRL = 6, NONE = 7;
    localparam KEY = 1, MOVED = 2, TXBUSY = 4, LOST = 8, GONE = 16, FERR = 32, SYNC = 64;
    localparam KIE = 1, MIE = 2, TXEN = 4;

    task expect(input [2:0] a, input [31:0] want, input [8*40-1:0] what);
        begin rd(a); check(r, want, what); end
    endtask

    // The first report in the queue, taken: KEYS0 then KEYS1, as the bytes of the
    // report (modifiers in 63..56).
    task expect_report(input [63:0] want, input [8*40-1:0] what);
        reg [31:0] k0;
        begin
            rd(KEYS0); k0 = r;
            rd(KEYS1);
            check({k0[7:0], k0[15:8], k0[23:16], k0[31:24]}, want[63:32], what);
            check({r[7:0],  r[15:8],  r[23:16],  r[31:24]},  want[31:0],  what);
        end
    endtask

    task expect_count(input integer n, input [8*40-1:0] what);
        begin rd(STATUS); check((r >> 16) & 32'hF, n, what); end
    endtask

    task ms(input integer n);
        #(n * 1_000_000);
    endtask

    // ================================================================ the mouse, added up
    integer want_x = 0, want_y = 0, want_w = 0;     // what was sent and not yet read
    integer read_x = 0, read_y = 0, read_w = 0;
    reg [7:0] last_buttons = 0;

    function integer s8(input [7:0] v);
        s8 = v[7] ? v - 256 : v;
    endfunction
    function integer s16(input [15:0] v);
        s16 = v[15] ? v - 65536 : v;
    endfunction
    function [15:0] w16(input integer v);
        w16 = v;
    endfunction
    function [7:0] w8(input integer v);
        w8 = v;
    endfunction

    task send_mouse(input [7:0] btn, input [7:0] dx, input [7:0] dy, input [7:0] wh);
        begin
            kb.mouse(btn, dx, dy, wh);
            want_x = want_x + s8(dx);
            want_y = want_y + s8(dy);
            want_w = want_w + s8(wh);
            last_buttons = btn;
        end
    endtask

    task read_mouse;
        begin
            rd(MOUSE);
            read_x = read_x + s16(r[15:0]);
            read_y = read_y + s16(r[31:16]);
            rd(BUTTONS);
            read_w = read_w + s8(r[15:8]);
        end
    endtask

    // ================================================================ the test
    integer i, n, frames0;
    reg [63:0] rep;
    reg        reading;

    initial begin
        repeat (10) @(posedge clk);
        reset <= 0;
        repeat (5) @(posedge clk);

        // ---- 1. after reset
        expect(STATUS, 32'h0000FF00, "STATUS after reset");
        expect(KEYS0, 0, "KEYS0 empty");
        expect(KEYS1, 0, "KEYS1 empty");
        expect(MOUSE, 0, "MOUSE after reset");
        expect(BUTTONS, 0, "BUTTONS after reset");
        expect(LEDS, 0, "LEDS after reset");
        expect(CTRL, 0, "CTRL after reset");
        expect(NONE, 0, "+28");
        check(irq, 0, "irq after reset");
        wr(LEDS, 3);                                    // TXEN is 0: nothing goes out
        ms(3);
        check(kb.all, 0, "bytes sent with TXEN at 0");
        check(kbd_tx, 1, "kbd_tx at rest");
        expect(LEDS, 3, "LEDS as written");
        wr(LEDS, 0);

        // ---- 2. the chip starts
        kb.short_frame(8'h86);
        kb.status(8'hFF);
        kb.short_frame(8'h89);
        kb.status(8'hFF);
        expect(STATUS, 32'h0000FF00 | GONE, "STATUS after the start");
        wr(STATUS, GONE);
        expect(STATUS, 32'h0000FF00, "GONE cleared");

        // ---- 3. Q down, up
        wr(CTRL, KIE);
        kb.keyboard(64'h0000_1400_0000_0000, 3);
        check(irq, 1, "irq with a report waiting");
        kb.status(8'h30);                               // between them, as the chip does
        kb.keyboard(64'h0000_1400_0000_0000, 1);
        kb.keyboard(64'h0, 4);
        expect_count(2, "Q: reports waiting");
        rd(KEYS0); check(r, 32'h0014_0000, "Q: KEYS0");
        rd(KEYS0); check(r, 32'h0014_0000, "Q: KEYS0 does not take");
        rd(KEYS1); check(r, 0, "Q: KEYS1");
        expect_report(64'h0, "Q up");
        expect_count(0, "Q: all taken");
        check(irq, 0, "irq with the queue empty");
        expect(STATUS, 32'h00003000, "STATUS: ECHO 30");
        wr(CTRL, 0);

        // ---- 4. the bytes in their places
        kb.keyboard(64'h0200_0000_0000_0000, 3);        // the left Shift
        kb.keyboard(64'h0200_0400_0000_0000, 3);        // and A
        kb.keyboard(64'h0000_0416_0709_0A0B, 3);        // A S D F G H
        kb.keyboard(64'h0000_0101_0101_0101, 3);        // and J: too many
        kb.keyboard(64'h0, 3);
        expect_report(64'h0200_0000_0000_0000, "Shift");
        expect_report(64'h0200_0400_0000_0000, "Shift A");
        rd(KEYS0); check(r, 32'h1604_0000, "six keys: KEYS0");
        rd(KEYS1); check(r, 32'h0B0A_0907, "six keys: KEYS1");
        expect_report(64'h0000_0101_0101_0101, "ErrorRollOver");
        expect_report(64'h0, "all up");
        expect(STATUS, 32'h00003000, "STATUS after the keys");

        // ---- 5. the queue full
        for (i = 1; i <= 10; i = i + 1)
            kb.keyboard({16'h0000, i[7:0] + 8'h1D, 40'h0}, 1);  // 1 2 3 ... 0
        rd(STATUS);
        check(r & (LOST | KEY), LOST | KEY, "ten reports: LOST");
        check((r >> 16) & 32'hF, 8, "ten reports: 8 kept");
        for (i = 1; i <= 8; i = i + 1)
            expect_report({16'h0000, i[7:0] + 8'h1D, 40'h0}, "the queue, in order");
        expect_count(0, "the queue emptied");
        wr(STATUS, LOST);
        expect(STATUS, 32'h00003000, "LOST cleared");
        kb.keyboard(64'h0, 2);
        expect_report(64'h0, "after the queue was full");

        // ---- 6. the mouse
        wr(CTRL, MIE);
        send_mouse(8'h00, 8'h05, 8'hFE, 8'h00);
        check(irq, 1, "irq: the mouse moved");
        send_mouse(8'h00, 8'h57, 8'hAB, 8'h01);         // 57 AB 01 inside the frame
        send_mouse(8'h00, 8'h07, 8'h00, 8'h00);
        send_mouse(8'h01, 8'h00, 8'h00, 8'h00);         // the left button down
        send_mouse(8'h01, 8'hF9, 8'h03, 8'h00);
        send_mouse(8'h01, 8'h01, 8'h57, 8'hAB);
        send_mouse(8'h00, 8'h00, 8'h00, 8'hFF);
        expect_count(0, "mouse: no keyboard report");
        rd(STATUS); check(r & (MOVED | SYNC), MOVED, "mouse: MOVED, no SYNC");
        rd(MOUSE);
        check(r, {w16(want_y), w16(want_x)}, "MOUSE sums");
        check(irq, 0, "irq after MOUSE is read");
        rd(STATUS); check(r & MOVED, 0, "MOVED after MOUSE is read");
        rd(MOUSE); check(r, 0, "MOUSE read twice");
        rd(BUTTONS); check(r, {16'd0, w8(want_w), 8'h00}, "BUTTONS");
        rd(BUTTONS); check(r, 0, "BUTTONS: the wheel taken");
        want_x = 0; want_y = 0; want_w = 0;
        send_mouse(8'h02, 8'h80, 8'h7F, 8'h00);         // the extremes
        rd(MOUSE); check(r, 32'h007F_FF80, "MOUSE: -128, +127");
        rd(BUTTONS); check(r, 32'h0000_0002, "BUTTONS: the right one");
        want_x = 0; want_y = 0; want_w = 0;
        wr(CTRL, 0);

        // 400 random reports, back to back, while the program reads all the time.
        reading = 1;
        fork
            begin
                for (n = 0; n < 400; n = n + 1)
                    send_mouse($random, $random, $random, $random);
                reading = 0;
            end
            begin
                while (reading) read_mouse;
            end
        join
        read_mouse;
        check(read_x, want_x, "the random mouse: X");
        check(read_y, want_y, "the random mouse: Y");
        check(read_w, want_w, "the random mouse: wheel");
        rd(BUTTONS); check(r[7:0], last_buttons, "the random mouse: buttons");
        rd(STATUS); check(r & 32'h0000_00FF, 0, "STATUS after the random mouse");

        // ---- 7. bytes that begin no frame, a kind we do not know, a frame cut short
        kb.junk(8'hAB); kb.junk(8'h01); kb.junk(8'h57); kb.junk(8'h12); kb.junk(8'h57);
        kb.keyboard(64'h0000_2C00_0000_0000, 1);        // the space bar
        rd(STATUS); check(r & SYNC, SYNC, "junk: SYNC");
        expect_report(64'h0000_2C00_0000_0000, "space after junk");
        wr(STATUS, SYNC);
        kb.short_frame(8'h83);                          // a kind of states 0/1
        kb.keyboard(64'h0, 1);
        rd(STATUS); check(r & SYNC, SYNC, "unknown kind: SYNC");
        expect_report(64'h0, "space up after an unknown kind");
        wr(STATUS, SYNC);
        kb.cut_frame(3);                                // 57 AB 01 00 00 00, then nothing
        ms(6);
        rd(STATUS); check(r & (SYNC | KEY), SYNC, "frame cut short: SYNC, no report");
        kb.keyboard(64'h0000_0500_0000_0000, 1);        // B
        expect_report(64'h0000_0500_0000_0000, "B after a frame cut short");
        wr(STATUS, SYNC);

        // ---- 8. a byte without its stop bit
        kb.no_stop(8'h57);
        kb.keyboard(64'h0, 1);
        rd(STATUS); check(r & FERR, FERR, "FERR");
        expect_report(64'h0, "B up after a bad byte");
        wr(STATUS, FERR | SYNC);
        expect(STATUS, 32'h00003000, "FERR cleared");

        // ---- 9. the keyboard's LEDs
        wr(LEDS, 3'b010);                               // Caps Lock, TXEN still 0
        ms(2);
        check(kb.all, 0, "LEDS written with TXEN at 0");
        frames0 = kb.frames;
        wr(CTRL, TXEN);                                 // goes out now
        rd(STATUS); check(r & TXBUSY, TXBUSY, "TXBUSY");
        ms(2);
        check(kb.frames, frames0 + 1, "TXEN: one keep-alive");
        check(kb.leds, 3'b010, "TXEN: Caps Lock sent");
        expect(STATUS, 32'h00003200, "ECHO 32");
        wr(LEDS, 3'b101);                               // Num Lock and Scroll Lock
        ms(2);
        check(kb.frames, frames0 + 2, "LEDS: one more keep-alive");
        check(kb.leds, 3'b101, "LEDS: Num and Scroll sent");
        expect(STATUS, 32'h00003500, "ECHO 35");
        wr(LEDS, 3'b001);                               // three writes in a row
        wr(LEDS, 3'b011);
        wr(LEDS, 3'b111);
        ms(3);
        check(kb.frames, frames0 + 4, "three writes: two keep-alives");
        check(kb.leds, 3'b111, "three writes: the last LEDs");
        expect(STATUS, 32'h00003700, "ECHO 37");
        frames0 = kb.frames;
        #(3 * KEEP * TICK + 1_000_000);                 // the keep-alive, by itself
        check(kb.frames, frames0 + 3, "the keep-alive repeats");
        check(kb.leds, 3'b111, "the keep-alive's LEDs");
        // keys typed while frames go out the other way
        fork
            kb.keyboard(64'h0000_0600_0000_0000, 4);
            begin wr(LEDS, 3'b000); wr(LEDS, 3'b100); end
        join
        expect_report(64'h0000_0600_0000_0000, "C while LEDs go out");
        ms(2);
        check(kb.leds, 3'b100, "LEDs while C is typed");
        wr(CTRL, 0);                                    // stop
        ms(1);
        frames0 = kb.frames;
        n = kb.all;
        #(3 * KEEP * TICK);
        check(kb.all, n, "TXEN at 0: nothing more");
        check(kb.bad, 0, "the module saw nothing wrong");
        kb.keyboard(64'h0, 1);
        expect_report(64'h0, "C up");
        expect(STATUS, 32'h00003400, "STATUS after the LEDs");

        // ---- 10. the chip 3 % fast, then 3 % slow
        kb.bit_ns = 0.97e9 / 115200.0;
        kb.keyboard(64'h0400_1D00_0000_0000, 2);        // left Alt + Z
        send_mouse(8'h00, 8'h10, 8'hF0, 8'h01);
        kb.bit_ns = 1.03e9 / 115200.0;
        kb.keyboard(64'h0, 2);
        send_mouse(8'h00, 8'h10, 8'hF0, 8'h01);
        kb.bit_ns = 1.0e9 / 115200.0;
        expect_report(64'h0400_1D00_0000_0000, "Alt Z, 3 % fast");
        expect_report(64'h0, "Alt Z up, 3 % slow");
        rd(MOUSE); check(r, 32'hFFE0_0020, "MOUSE, 3 % fast and slow");
        rd(BUTTONS); check(r, 32'h0000_0200, "the wheel, 3 % fast and slow");
        expect(STATUS, 32'h00003400, "no error at 3 %");

        // ---- 11. a held key, then the keyboard goes away
        kb.keyboard(64'h0000_2800_0000_0000, 3);        // Return held
        kb.short_frame(8'h86);                          // unplugged
        kb.keyboard(64'h0, 3);                          // plugged again: nothing down
        expect_report(64'h0000_2800_0000_0000, "Return");
        expect_report(64'h0, "Return up after the replug");
        rd(STATUS); check(r & (GONE | KEY), GONE, "the replug: GONE");

        if (errors == 0) $display("keyboard_tb: all passed");
        else             $display("keyboard_tb: %0d errors", errors);
        $finish;
    end

    // A watchdog: the whole test takes about 400 ms of simulated time.
    initial begin
        #2_000_000_000;
        $display("keyboard_tb: timeout");
        $finish;
    end
endmodule
