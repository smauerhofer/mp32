// leds_tb.v: tests leds.v at 42 MHz.
//
//   make test
// or by hand:
//   iverilog -g2005 -s leds_tb -o leds_tb.vvp leds_tb.v leds.v
//   vvp leds_tb.vvp
//
// It checks the register after reset; writes and reads back; that the pins are the
// register inverted; that bits 31..6, io_be[0] = 0 and the other addresses leave it
// alone; that those addresses read 0; that every access takes two ticks; and that
// reset puts the LEDs off again.

`timescale 1ns/1ps

module leds_tb;
    localparam real TICK = 23.810;        // 42 MHz
    reg clk = 0;
    always #(TICK / 2) clk = ~clk;

    reg         reset = 1;
    reg         io_sel = 0, io_we = 0;
    reg  [3:0]  io_be = 4'hF;
    reg  [7:2]  io_addr = 0;
    reg  [31:0] io_wdata = 0;
    wire [31:0] io_rdata;
    wire        io_ready;
    wire [5:0]  led;

    leds dut (
        .clk(clk), .reset(reset),
        .io_sel(io_sel), .io_we(io_we), .io_be(io_be), .io_addr(io_addr),
        .io_wdata(io_wdata), .io_rdata(io_rdata), .io_ready(io_ready),
        .led(led)
    );

    integer errors = 0;

    task check(input [31:0] got_v, input [31:0] want, input [8*32-1:0] what);
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
            io_sel = 1; io_we = we; io_be = be; io_addr = addr[7:2]; io_wdata = wdata;
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

    integer i;

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk) reset = 0;

        // after reset: off
        read(8'h00);  check(rd, 32'h0, "LEDS after reset");
        check(led, 6'b111111, "pins after reset");
        check(io_ready, 0, "io_ready at rest");

        // each LED alone, then all
        for (i = 0; i < 6; i = i + 1) begin
            write(8'h00, 32'h1 << i);
            read(8'h00);  check(rd, 32'h1 << i, "LEDS, one lit");
            check(led, {26'h0, ~(6'h1 << i)}, "pins, one lit");
        end
        write(8'h00, 32'h3F);
        read(8'h00);  check(rd, 32'h3F, "LEDS, all lit");
        check(led, 6'b000000, "pins, all lit");

        // bits 31..6 are ignored
        write(8'h00, 32'hFFFF_FF95);
        read(8'h00);  check(rd, 32'h15, "LEDS, upper bits ignored");
        check(led, {26'h0, ~6'h15}, "pins, upper bits ignored");

        // io_be[0] = 0: no write
        access(1'b1, 4'hE, 8'h00, 32'h2A);
        read(8'h00);  check(rd, 32'h15, "LEDS after a write without io_be[0]");

        // the other addresses: read 0, writes ignored
        for (i = 4; i < 256; i = i + 4) begin
            write(i[7:0], 32'h2A);
            read(i[7:0]); check(rd, 32'h0, "another address reads 0");
        end
        read(8'h00);  check(rd, 32'h15, "LEDS after writes elsewhere");

        // random values, written and read back
        for (i = 0; i < 200; i = i + 1) begin : rnd
            reg [31:0] v;
            v = $random;
            write(8'h00, v);
            read(8'h00);  check(rd, {26'h0, v[5:0]}, "LEDS, random");
            check(led, {26'h0, ~v[5:0]}, "pins, random");
        end

        // reset: off again
        write(8'h00, 32'h3F);
        @(negedge clk) reset = 1;
        @(negedge clk) reset = 0;
        read(8'h00);  check(rd, 32'h0, "LEDS after a second reset");
        check(led, 6'b111111, "pins after a second reset");

        if (errors == 0) $display("leds: all tests passed");
        else             $display("leds: %0d errors", errors);
        $finish;
    end
endmodule
