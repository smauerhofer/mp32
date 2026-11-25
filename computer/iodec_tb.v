// iodec_tb.v: tests the board's registers of iodec.v (LEDS, BUTTONS, TICKS, CTRL) and
// the buttons' interrupt (line 5, vector 21), at 42 MHz.
//
//   make test-iodec
// or by hand:
//   iverilog -g2005 -s iodec_tb -o iodec_tb.vvp iodec_tb.v iodec.v ../cpu/irqc.v
//   vvp iodec_tb.vvp
//
// DEBOUNCE is 4 here (16 ticks), so a press takes a few ticks, not 12.5 ms.
//
// It checks: CTRL after reset (S1 the reset, no interrupt); S1IE taken only with
// S1INT; a press of S1 in reset mode sets no flag; S1 and S2 presses, debounced (a
// bounce shorter than 16 ticks sets nothing; a long press sets its flag once); the
// flags cleared by a 1 and left by a 0; io_be; the irq through the controller
// (PENDING bit 5, NUMBER 21) only with the enable; a reset puts CTRL back to 0.

`timescale 1ns/1ps

module iodec_tb;
    localparam real TICK = 23.810;        // 42 MHz
    localparam DB = 4;
    reg clk = 0;
    always #(TICK / 2) clk = ~clk;

    reg         reset = 1;
    reg         io_sel = 0, io_we = 0;
    reg  [3:0]  io_be = 4'hF;
    reg  [15:0] io_addr = 0;
    reg  [31:0] io_wdata = 0;
    wire [31:0] io_rdata;
    wire        io_ready;
    wire [5:0]  leds;
    reg  [1:0]  buttons = 2'b00;
    wire        s1_reset, irq;
    wire [7:0]  irq_num;

    iodec #(.DEBOUNCE(DB)) dut (
        .clk(clk), .reset(reset),
        .io_sel(io_sel), .io_we(io_we), .io_be(io_be), .io_addr(io_addr),
        .io_wdata(io_wdata), .io_rdata(io_rdata), .io_ready(io_ready),
        .uart_sel(), .uart_rdata(32'h0), .uart_ready(1'b0),
        .sd_sel(), .sd_rdata(32'h0), .sd_ready(1'b0),
        .flash_sel(), .flash_rdata(32'h0), .flash_ready(1'b0),
        .kbd_sel(), .kbd_rdata(32'h0), .kbd_ready(1'b0),
        .audio_sel(), .audio_addr(), .audio_rdata(32'h0), .audio_ready(1'b0),
        .vid_sel(), .vid_addr(), .vid_rdata(32'h0), .vid_ready(1'b0),
        .leds(leds), .buttons(buttons), .s1_reset(s1_reset),
        .irq_lines(8'h00), .irq(irq), .irq_num(irq_num),
        .irq_ack(1'b0), .irq_ack_num(8'h00)
    );

    integer errors = 0;

    task check(input [31:0] got_v, input [31:0] want, input [8*40-1:0] what);
        if (got_v !== want) begin
            errors = errors + 1;
            $display("%t %0s: %h, expected %h", $realtime, what, got_v, want);
        end
    endtask

    reg [31:0] rd;

    task access(input we, input [3:0] be, input [15:0] addr, input [31:0] wdata);
        begin
            @(negedge clk);
            io_sel = 1; io_we = we; io_be = be; io_addr = addr; io_wdata = wdata;
            @(posedge clk);
            while (!io_ready) @(posedge clk);
            #1 rd = io_rdata;
            @(negedge clk);
            io_sel = 0; io_we = 0; io_be = 4'hF;
        end
    endtask

    task write(input [15:0] addr, input [31:0] wdata);
        access(1'b1, 4'hF, addr, wdata);
    endtask

    task read(input [15:0] addr);
        access(1'b0, 4'hF, addr, 32'h0);
    endtask

    // a button down for n ticks, then up for long enough to settle
    task hold(input integer b, input integer n);
        begin
            @(negedge clk) buttons[b] = 1'b1;
            repeat (n) @(negedge clk);
            buttons[b] = 1'b0;
            repeat ((1 << DB) + 4) @(negedge clk);
        end
    endtask

    localparam CTRL = 16'h020C, BUTTONS = 16'h0204, LEDS = 16'h0200,
               PENDING = 16'h0400, MASK = 16'h0404, NUMBER = 16'h0408;

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk) reset = 0;

        // ---- after reset: S1 the reset, nothing enabled, no flags
        read(CTRL);           check(rd, 32'h0, "CTRL after reset");
        check(s1_reset, 1, "s1_reset after reset");
        check(irq, 0, "irq after reset");

        // the LEDs still work
        write(LEDS, 32'h2A);  read(LEDS); check(rd, 32'h2A, "LEDS");

        // ---- S1IE without S1INT stays 0
        write(CTRL, 32'h2);   read(CTRL); check(rd, 32'h0, "S1IE without S1INT");
        check(s1_reset, 1, "s1_reset, S1IE alone");

        // ---- S1 in reset mode sets no flag (iodec is not reset here: top.v would be)
        hold(0, 40);          read(CTRL); check(rd, 32'h0, "S1 pressed in reset mode");

        // ---- S2: a bounce shorter than 16 ticks sets nothing, a long press sets S2F
        hold(1, 5);           read(CTRL); check(rd, 32'h0, "S2 bounce");
        read(BUTTONS);        check(rd, 32'h0, "BUTTONS, up");
        @(negedge clk) buttons[1] = 1'b1;
        repeat (3) @(negedge clk);
        read(BUTTONS);        check(rd, 32'h2, "BUTTONS, S2 down (not debounced)");
        repeat (40) @(negedge clk);
        buttons[1] = 1'b0;
        repeat (30) @(negedge clk);
        read(CTRL);           check(rd, 32'h200, "S2F after a press");
        check(irq, 0, "no irq: S2IE is 0");
        read(PENDING);        check(rd, 32'h0, "PENDING, S2IE 0");

        // a 0 leaves the flag, a 1 clears it
        write(CTRL, 32'h0);   read(CTRL); check(rd, 32'h200, "S2F after writing 0");
        access(1'b1, 4'hE, CTRL, 32'h200);   // io_be[0] = 0: the flag is in byte 1
        read(CTRL);           check(rd, 32'h0, "S2F cleared");

        // ---- S2 with S2IE: the irq on line 5
        write(MASK, 32'h20);
        write(CTRL, 32'h4);   read(CTRL); check(rd, 32'h4, "CTRL = S2IE");
        hold(1, 30);
        read(CTRL);           check(rd, 32'h204, "S2F with S2IE");
        read(PENDING);        check(rd, 32'h20, "PENDING line 5");
        read(NUMBER);         check(rd, 21, "NUMBER: vector 21");
        check(irq, 1, "irq, S2");
        write(CTRL, 32'h204); read(CTRL); check(rd, 32'h4, "S2F served");
        check(irq, 0, "irq after S2F served");

        // one press, one flag, however long it is held
        hold(1, 200);
        read(CTRL);           check(rd, 32'h204, "S2F, a long press");
        write(CTRL, 32'h204);
        repeat (50) @(negedge clk);
        read(CTRL);           check(rd, 32'h4, "no second flag after a long press");

        // ---- S1 as a button
        write(CTRL, 32'h1);   read(CTRL); check(rd, 32'h1, "CTRL = S1INT");
        check(s1_reset, 0, "s1_reset with S1INT");
        hold(0, 30);
        read(CTRL);           check(rd, 32'h101, "S1F, S1IE 0");
        check(irq, 0, "no irq: S1IE 0");
        write(CTRL, 32'h3);   read(CTRL); check(rd, 32'h103, "S1INT, S1IE, old flag");
        check(irq, 1, "irq at once: an old press");
        write(CTRL, 32'h103); read(CTRL); check(rd, 32'h3, "S1F served");
        check(irq, 0, "irq after S1F served");
        hold(0, 30);
        read(NUMBER);         check(rd, 21, "NUMBER, S1");
        check(irq, 1, "irq, S1");

        // both enabled, both pressed
        write(CTRL, 32'h7);
        hold(1, 30);
        read(CTRL);           check(rd, 32'h307, "S1F and S2F");
        write(CTRL, 32'h107); read(CTRL); check(rd, 32'h207, "only S1F cleared");
        check(irq, 1, "irq, S2F left");
        write(CTRL, 32'h207); check(irq, 0, "irq, both served");

        // back to reset mode: S1IE goes with it
        write(CTRL, 32'h6);   read(CTRL); check(rd, 32'h4, "back to S1 the reset");
        check(s1_reset, 1, "s1_reset again");
        hold(0, 30);          read(CTRL); check(rd, 32'h4, "S1 in reset mode, no flag");

        // ---- a reset: all back to 0
        write(CTRL, 32'h7);
        hold(1, 30);
        @(negedge clk) reset = 1;
        @(negedge clk) reset = 0;
        read(CTRL);           check(rd, 32'h0, "CTRL after a second reset");
        check(s1_reset, 1, "s1_reset after a second reset");

        if (errors == 0) $display("iodec: all tests passed");
        else             $display("iodec: %0d errors", errors);
        $finish;
    end
endmodule
