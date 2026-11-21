// echo_tb.v: tests echo.v, the board's first test of the serial port, at 27 MHz.
//
//   make test-echo
//
// The PC model reads the greeting, types "Hi!" and Enter, and expects them back,
// Enter as CR LF, and the last byte on the LEDs.

`timescale 1ns/1ps

module echo_tb;
    localparam real TICK = 37.037;        // 27 MHz
    localparam real BIT  = 234 * TICK;
    reg clk = 0;
    always #(TICK / 2) clk = ~clk;

    reg        pc_tx = 1;
    wire       uart_tx;
    wire [5:0] led;

    top dut (.clk(clk), .uart_rx(pc_tx), .uart_tx(uart_tx), .led(led));

    integer errors = 0;

    // ---- the PC receiving
    reg [7:0] got [0:255];
    integer   ngot = 0, mi;
    reg [7:0] mb;
    always begin
        @(negedge uart_tx);
        #(BIT / 2);
        for (mi = 0; mi < 8; mi = mi + 1) begin #(BIT); mb[mi] = uart_tx; end
        #(BIT);
        if (uart_tx !== 1'b1) begin errors = errors + 1; $display("no stop bit"); end
        got[ngot] = mb; ngot = ngot + 1;
    end

    // ---- the PC sending
    task pc_send(input [7:0] b);
        integer i;
        begin
            pc_tx = 0; #(BIT);
            for (i = 0; i < 8; i = i + 1) begin pc_tx = b[i]; #(BIT); end
            pc_tx = 1; #(BIT);
        end
    endtask

    reg [8*18-1:0] greeting = {"mp32 serial port", 8'h0D, 8'h0A};
    reg [8*5-1:0]  answer   = {"Hi!", 8'h0D, 8'h0A};
    integer i;

    initial begin
        #(20 * 10 * BIT);                 // the greeting is out
        if (ngot != 18) begin errors = errors + 1; $display("greeting: %0d bytes", ngot); end
        for (i = 0; i < 18; i = i + 1)
            if (got[i] !== greeting[8*(17-i) +: 8]) begin
                errors = errors + 1;
                $display("greeting byte %0d: %h", i, got[i]);
            end

        pc_send("H"); pc_send("i"); pc_send("!"); pc_send(8'h0D);
        #(30 * BIT);
        if (ngot != 23) begin errors = errors + 1; $display("echo: %0d bytes", ngot - 18); end
        for (i = 0; i < 5; i = i + 1)
            if (got[18 + i] !== answer[8*(4-i) +: 8]) begin
                errors = errors + 1;
                $display("echo byte %0d: %h", i, got[18 + i]);
            end
        if (led !== ~6'h0D) begin errors = errors + 1; $display("LEDs: %b", led); end

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
