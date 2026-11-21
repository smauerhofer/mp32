// uart.v: the serial port of the mp32 computer, as an I/O device.
//
//   The Tang Nano 20K has a serial port on its USB-C cable already: the BL616, the
//   chip that loads the FPGA, is also a USB serial port for the PC (a COM port on
//   Windows). Two pins of the FPGA go to it, the ones chapter 19 of the book uses:
//
//     uart_rx   70   from the BL616 (the PC sends)
//     uart_tx   69   to the BL616   (the PC receives)
//
//   See uart.cst. A USB serial adapter at 3.3 V on two other pins works the same.
//
//   The bytes go 8N1: a start bit, eight bits, no parity, one stop bit. The speed
//   is set by DIV, the ticks of one bit: from reset DIV_INIT, 115,200 baud at 42 MHz.
//
// ---------------------------------------------------------------- the registers
//   Four 32-bit registers, picked by io_addr[3:2] (the I/O decoder gives io_sel):
//
//     +0   DATA    write: put the byte in bits 7..0 in the transmitter's queue. While
//                         the queue is full the write waits (io_ready stays 0), so a
//                         program can write bytes in a row and never loses one.
//                  read:  bit 8 VALID: 1 if a byte was there; bits 7..0 the byte, which
//                         leaves the receiver's queue. Empty: reads 0 (VALID = 0) at
//                         once - a read never waits, so a program that polls cannot hang.
//
//     +4   STATUS  read:  bit  0     RXA   the receiver's queue holds a byte
//                         bit  1     TXF   the transmitter's queue is full
//                         bit  2     TXE   all sent: the queue is empty and the last
//                                          stop bit is out (wait for it before DIV)
//                         bit  3     OVR   a byte came while the receiver's queue
//                                          was full, and was lost (stays 1)
//                         bit  4     FERR  a byte came without its stop bit (stays 1)
//                         bits 15..8       how many bytes the receiver's queue holds
//                         bits 23..16      how many the transmitter's queue holds
//                  write: a 1 in bit 3 or 4 clears OVR or FERR
//
//     +8   DIV     bits 15..0: ticks of one bit, at least 16. At 42 MHz:
//                         365  115,200 baud   (DIV_INIT; 0.1 % fast)
//                         46   921,600 baud   (0.9 % slow)
//                         42   1,000,000 baud
//                  The receiver takes a new DIV at the next byte, the transmitter at
//                  the next bit: change it when TXE is 1 and nothing comes.
//
//     +12  CTRL    bit 0 RXIE: irq while the receiver's queue holds a byte
//                  bit 1 TXIE: irq while the transmitter's queue is empty (room for
//                              2^TX_BITS bytes)
//                  after reset 0: no irq
//
//   The queues: 2^RX_BITS bytes for the receiver, 2^TX_BITS for the transmitter. At
//   115,200 baud a byte comes every 87 us: 64 bytes give a program 5.5 ms to look.
//
// ---------------------------------------------------------------- handshake
//   The cache's handshake (see membus.v), as in sdcard.v: io_sel and the rest are held
//   until io_ready is 1; that tick ends the access, and io_rdata is valid in it.
//   io_ready is a register: an access takes at least two ticks.

module uart #(
    parameter [15:0] DIV_INIT = 16'd365,        // 115,200 baud at 42 MHz
    parameter        RX_BITS  = 6,              // 64 bytes
    parameter        TX_BITS  = 4               // 16 bytes
) (
    input  wire        clk,
    input  wire        reset,           // synchronous, active high

    // ---- the I/O bus
    input  wire        io_sel,
    input  wire        io_we,
    input  wire [3:0]  io_be,           // not used: every write is taken whole
    input  wire [3:2]  io_addr,
    input  wire [31:0] io_wdata,
    output reg  [31:0] io_rdata,
    output reg         io_ready,

    // ---- to the processor's interrupt
    output wire        irq,

    // ---- the wires
    input  wire        uart_rx,
    output wire        uart_tx
);
    localparam R_DATA = 2'd0, R_STATUS = 2'd1, R_DIV = 2'd2, R_CTRL = 2'd3;

    // ================================================================ the registers
    reg [15:0] div;
    reg        rxie, txie;
    reg        ovr, ferr;

    // ================================================================ the receiver and its queue
    wire [7:0] rx_byte;
    wire       rx_valid, rx_ferr;

    uart_rx #(.W(16)) receiver (
        .clk(clk), .reset(reset), .div(div), .rx(uart_rx),
        .data(rx_byte), .valid(rx_valid), .frame_err(rx_ferr)
    );

    wire [7:0]       rx_head;
    wire             rx_ready, rx_full, rx_take;
    wire [RX_BITS:0] rx_used;

    fifo #(.BITS(RX_BITS)) rx_queue (
        .clk(clk), .reset(reset),
        .put(rx_valid), .data(rx_byte), .take(rx_take),
        .head(rx_head), .ready(rx_ready), .full(rx_full), .used(rx_used)
    );

    // ================================================================ the transmitter and its queue
    wire [7:0]       tx_head;
    wire             tx_ready, tx_full, tx_put;
    wire [TX_BITS:0] tx_used;
    wire             tx_busy;
    wire             tx_send = tx_ready & ~tx_busy;   // busy is 1 from the next tick on

    fifo #(.BITS(TX_BITS)) tx_queue (
        .clk(clk), .reset(reset),
        .put(tx_put), .data(io_wdata[7:0]), .take(tx_send),
        .head(tx_head), .ready(tx_ready), .full(tx_full), .used(tx_used)
    );

    uart_tx #(.W(16)) transmitter (
        .clk(clk), .reset(reset), .div(div),
        .send(tx_send), .data(tx_head), .tx(uart_tx), .busy(tx_busy)
    );

    wire txe = ~tx_ready & ~tx_busy;

    // ================================================================ the bus
    // Only a write of DATA with the queue full waits.
    wire waits  = io_we & (io_addr == R_DATA) & tx_full;
    // The tick that ends an access: here a write takes effect, and a read of DATA
    // takes its byte from the queue.
    wire commit = io_sel & io_ready;

    // A read of DATA shows the first byte in the tick before commit. took says whether
    // there was one; only then does commit take it. A byte that comes in between is
    // not taken: it was not read. Nothing else takes from the queue, and a byte that
    // comes does not change the first one, so the byte read is the one taken.
    reg took;

    assign tx_put  = commit &  io_we & (io_addr == R_DATA);
    assign rx_take = commit & ~io_we & (io_addr == R_DATA) & took;

    wire [7:0] rx_count = rx_used;      // widened (or cut) to 8 bits for STATUS
    wire [7:0] tx_count = tx_used;

    always @(posedge clk) begin
        if (reset) begin
            io_ready <= 0;
            io_rdata <= 0;
            took     <= 0;
        end else begin
            io_ready <= io_sel & ~io_ready & ~waits;
            took     <= (io_addr == R_DATA) & rx_ready;
            case (io_addr)
                R_DATA:   io_rdata <= rx_ready ? {23'd0, 1'b1, rx_head} : 32'd0;
                R_STATUS: io_rdata <= {8'd0, tx_count, rx_count,
                                       3'd0, ferr, ovr, txe, tx_full, rx_ready};
                R_DIV:    io_rdata <= {16'd0, div};
                R_CTRL:   io_rdata <= {30'd0, txie, rxie};
            endcase
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            div  <= DIV_INIT;
            rxie <= 0;
            txie <= 0;
            ovr  <= 0;
            ferr <= 0;
        end else begin
            if (commit & io_we & io_addr == R_DIV)
                div <= io_wdata[15:0];
            if (commit & io_we & io_addr == R_CTRL) begin
                rxie <= io_wdata[0];
                txie <= io_wdata[1];
            end
            // A new error wins over a clear in the same tick.
            if (commit & io_we & io_addr == R_STATUS) begin
                if (io_wdata[3]) ovr  <= 0;
                if (io_wdata[4]) ferr <= 0;
            end
            if (rx_valid & rx_full & ~rx_take) ovr  <= 1;
            if (rx_ferr)                       ferr <= 1;
        end
    end

    assign irq = (rxie & rx_ready) | (txie & ~tx_ready);
endmodule
