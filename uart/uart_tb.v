// uart_tb.v: tests uart.v (with uart_rx.v, uart_tx.v and fifo.v) at 42 MHz.
//
//   make test-uart
// or by hand:
//   iverilog -g2005 -s uart_tb -o uart_tb.vvp uart_tb.v uart.v uart_rx.v uart_tx.v fifo.v
//   vvp uart_tb.vvp
//
// The PC is a model at the other end of the two wires: it sends bytes on uart_rx at
// any speed, even without a stop bit, and reads every byte that comes on uart_tx,
// checking its start and stop bits. With loop at 1, uart_tx goes straight back into
// uart_rx instead.
//
// It checks the registers after reset; the bit time of the transmitter; writes that
// wait while the queue is full; bytes received, the empty read, the queue full and
// OVR; FERR; a PC 3 % too fast and 3 % too slow; both interrupts. Then thousands of
// random bytes in a loop at several speeds, written and read back, all checked.

`timescale 1ns/1ps

module uart_tb;
    localparam real TICK = 23.810;        // 42 MHz
    reg clk = 0;
    always #(TICK / 2) clk = ~clk;

    reg         reset = 1;
    reg         io_sel = 0, io_we = 0;
    reg  [3:2]  io_addr = 0;
    reg  [31:0] io_wdata = 0;
    wire [31:0] io_rdata;
    wire        io_ready;
    wire        irq;

    reg  loop  = 0;
    reg  pc_tx = 1;                       // what the PC sends
    wire uart_tx;
    wire uart_rx = loop ? uart_tx : pc_tx;

    uart #(.DIV_INIT(16'd365), .RX_BITS(6), .TX_BITS(4)) dut (
        .clk(clk), .reset(reset),
        .io_sel(io_sel), .io_we(io_we), .io_be(4'hF), .io_addr(io_addr),
        .io_wdata(io_wdata), .io_rdata(io_rdata), .io_ready(io_ready),
        .irq(irq), .uart_rx(uart_rx), .uart_tx(uart_tx)
    );

    integer errors = 0;

    task check(input [31:0] got_v, input [31:0] want, input [8*32-1:0] what);
        if (got_v !== want) begin
            errors = errors + 1;
            if (errors < 30)
                $display("%t %0s: %h, expected %h", $realtime, what, got_v, want);
        end
    endtask

    // ================================================================ the PC: receiving
    // Every byte that comes on uart_tx, in got[]. mon_bit is the bit time it expects.
    real       mon_bit = 365 * TICK;
    reg  [7:0] got [0:65535];
    integer    ngot = 0, mi;
    reg  [7:0] mb;

    always begin
        @(negedge uart_tx);
        #(mon_bit / 2);
        if (uart_tx !== 1'b0) begin
            errors = errors + 1;
            $display("%t uart_tx: a start bit shorter than half a bit", $realtime);
        end else begin
            for (mi = 0; mi < 8; mi = mi + 1) begin
                #(mon_bit);
                mb[mi] = uart_tx;
            end
            #(mon_bit);
            if (uart_tx !== 1'b1) begin
                errors = errors + 1;
                $display("%t uart_tx: no stop bit", $realtime);
            end
            got[ngot] = mb;
            ngot = ngot + 1;
        end
    end

    // ================================================================ the PC: sending
    task pc_send(input [7:0] b, input real bit_ns, input stop);
        integer i;
        begin
            pc_tx = 0; #(bit_ns);
            for (i = 0; i < 8; i = i + 1) begin pc_tx = b[i]; #(bit_ns); end
            pc_tx = stop; #(bit_ns);
            pc_tx = 1;
            if (!stop) #(2 * bit_ns);     // back at 1 for a while: the receiver starts over
        end
    endtask

    // ================================================================ the bus
    task access(input we, input [1:0] a, input [31:0] wd, output [31:0] rd);
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
    task wr(input [1:0] a, input [31:0] wd); access(1, a, wd, r); endtask
    task rd(input [1:0] a);                  access(0, a, 0,  r); endtask

    localparam DATA = 0, STATUS = 1, DIV = 2, CTRL = 3;
    localparam RXA = 1, TXF = 2, TXE = 4, OVR = 8, FERR = 16;

    task wait_txe;
        begin
            rd(STATUS);
            while (!(r & TXE)) begin repeat (50) @(posedge clk); rd(STATUS); end
            #(mon_bit);                   // the PC has the last byte
        end
    endtask

    // ================================================================ the test
    integer    i, n, k, chunk, nsent, nread, start_got, seed = 11;
    reg [7:0]  sent [0:65535];
    reg [15:0] d;
    real       t0, t1, bit_ns;

    initial begin
        repeat (4) @(posedge clk);
        #1 reset = 0;
        repeat (2) @(posedge clk);

        // ---- after reset
        rd(STATUS); check(r, TXE, "STATUS after reset");
        rd(DIV);    check(r, 365, "DIV after reset");
        rd(CTRL);   check(r, 0,   "CTRL after reset");
        rd(DATA);   check(r, 0,   "DATA, nothing received");
        check(irq, 0, "irq after reset");
        check(uart_tx, 1, "uart_tx at rest");

        // ---- one byte out, and its bit time: 0x55 changes the wire at every bit
        wr(DATA, 32'h55);
        @(negedge uart_tx); t0 = $realtime;
        @(posedge uart_tx); t1 = $realtime;
        if (t1 - t0 < 365 * TICK - 1 || t1 - t0 > 365 * TICK + 1) begin
            errors = errors + 1;
            $display("bit time %0.1f ns, expected %0.1f", t1 - t0, 365 * TICK);
        end
        rd(STATUS); check(r & TXE, 0, "TXE while sending");
        wait_txe;
        check(ngot, 1, "bytes the PC got");
        check(got[0], 8'h55, "the byte the PC got");

        // ---- 40 bytes in a row: the queue fills, the writes wait, none is lost
        start_got = ngot;
        for (i = 0; i < 17; i = i + 1) wr(DATA, 8'h30 + i);
        rd(STATUS);                       // one byte is going out, 16 wait
        check(r & 32'hFF_00FF, {8'd16, 16'd0} | TXF, "STATUS with the queue full");
        for (i = 17; i < 40; i = i + 1) wr(DATA, 8'h30 + i);
        wait_txe;
        check(ngot - start_got, 40, "bytes the PC got, 40 in a row");
        for (i = 0; i < 40; i = i + 1)
            check(got[start_got + i], 8'h30 + i, "byte of the 40");

        // ---- one byte in
        pc_send(8'hA5, 365 * TICK, 1);
        repeat (10) @(posedge clk);
        rd(STATUS); check(r, {16'd1, 8'd0} | RXA | TXE, "STATUS with a byte received");
        rd(DATA);   check(r, 32'h1A5, "DATA: the byte");
        rd(DATA);   check(r, 0,       "DATA: nothing more");
        rd(STATUS); check(r, TXE,     "STATUS after reading it");

        // ---- 64 bytes fill the queue, two more are lost: OVR
        for (i = 0; i < 66; i = i + 1) pc_send(i * 3, 365 * TICK, 1);
        repeat (10) @(posedge clk);
        rd(STATUS); check(r, {16'd64, 8'd0} | RXA | TXE | OVR, "STATUS after 66 bytes");
        for (i = 0; i < 64; i = i + 1) begin
            rd(DATA); check(r, 32'h100 | ((i * 3) & 8'hFF), "DATA: byte of the 64");
        end
        rd(DATA);   check(r, 0, "DATA after the 64");
        wr(STATUS, OVR);
        rd(STATUS); check(r, TXE, "STATUS after clearing OVR");

        // ---- a byte without its stop bit: FERR, and nothing in the queue
        pc_send(8'h77, 365 * TICK, 0);
        rd(STATUS); check(r, TXE | FERR, "STATUS after a byte without a stop bit");
        wr(STATUS, FERR);
        rd(STATUS); check(r, TXE, "STATUS after clearing FERR");

        // ---- a PC that is 3 % fast, then 3 % slow
        for (k = 0; k < 2; k = k + 1) begin
            bit_ns = (k == 0 ? 0.97 : 1.03) * 365 * TICK;
            for (i = 0; i < 10; i = i + 1) pc_send(8'hC0 + i + 16 * k, bit_ns, 1);
            repeat (10) @(posedge clk);
            for (i = 0; i < 10; i = i + 1) begin
                rd(DATA); check(r, 32'h1C0 + i + 16 * k, "DATA from a PC 3 % off");
            end
            rd(STATUS); check(r, TXE, "STATUS after the PC 3 % off");
        end

        // ---- RXIE: irq while a byte waits
        wr(CTRL, 1);
        check(irq, 0, "irq, RXIE, nothing received");
        pc_send(8'h11, 365 * TICK, 1);
        repeat (10) @(posedge clk);
        check(irq, 1, "irq, RXIE, a byte received");
        rd(DATA);
        repeat (2) @(posedge clk);
        check(irq, 0, "irq, RXIE, the byte read");

        // ---- TXIE: irq while the transmitter's queue is empty
        wr(CTRL, 2);
        check(irq, 1, "irq, TXIE, queue empty");
        start_got = ngot;
        for (i = 0; i < 3; i = i + 1) wr(DATA, 8'hE0 + i);
        check(irq, 0, "irq, TXIE, bytes waiting");
        wait_txe;
        check(irq, 1, "irq, TXIE, all sent");
        wr(CTRL, 0);
        check(irq, 0, "irq, CTRL = 0");
        check(ngot - start_got, 3, "bytes the PC got with TXIE");

        // ---- the loop: random bytes, random chunks, several speeds
        loop = 1;
        nsent = 0; nread = 0;
        start_got = ngot;
        for (n = 0; n < 400; n = n + 1) begin
            if (n % 40 == 0) begin
                // a new speed, while nothing is under way
                case ((n / 40) % 5)
                    0: d = 42;            // 1,000,000 baud
                    1: d = 16;            // 2,625,000 baud
                    2: d = 34;
                    3: d = 46;            // 921,600 baud (0.9 % slow)
                    4: d = 365;           // 115,200 baud
                endcase
                wr(DIV, d);
                mon_bit = d * TICK;
            end
            chunk = 1 + ($unsigned($random(seed)) % (d == 365 ? 4 : 24));
            for (i = 0; i < chunk; i = i + 1) begin
                sent[nsent] = $random(seed);
                wr(DATA, sent[nsent]);
                nsent = nsent + 1;
                if ($random(seed) & 1) begin   // now and then, read what came meanwhile
                    rd(DATA);
                    if (r[8]) begin
                        check(r[7:0], sent[nread], "loop: byte read back");
                        nread = nread + 1;
                    end
                end
            end
            while (nread < nsent) begin
                rd(DATA);
                if (r[8]) begin
                    check(r[7:0], sent[nread], "loop: byte read back");
                    nread = nread + 1;
                end
            end
            rd(STATUS); check(r & (OVR | FERR | RXA), 0, "loop: STATUS");
        end
        wait_txe;
        check(ngot - start_got, nsent, "loop: bytes on the wire");
        for (i = 0; i < nsent && i < ngot - start_got; i = i + 1)
            check(got[start_got + i], sent[i], "loop: byte on the wire");

        if (errors == 0) $display("PASS (%0d bytes in the loop)", nsent);
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #500_000_000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
