// leds.v: the six LEDs of the Tang Nano 20K, as an I/O device of the mp32 computer.
//
//   The LEDs are in a row along one edge of the board, on pins 15 to 20 (see
//   leds.cst); led[0], on pin 15, is the one nearest the USB-C port. An LED is lit
//   when its pin is low: this device inverts, once, at the pin, so that a program
//   writes 1 for "lit".
//
// ---------------------------------------------------------------- the register
//   One 32-bit register, at +0 of the device's range (the I/O decoder gives io_sel;
//   in the computer: 0xFFFF_0200):
//
//     +0   LEDS    write: bits 5..0, one per LED, 1 = lit (bits 31..6 are ignored;
//                         the write is taken only with io_be[0])
//                  read:  bits 5..0 as written, bits 31..6 0
//
//   The other addresses of the range read 0; writes to them are ignored.
//   After reset all six LEDs are off.
//
// ---------------------------------------------------------------- handshake
//   The cache's handshake (see membus.v), as in uart.v and sdcard.v: io_sel and the
//   rest are held until io_ready is 1; that tick ends the access, and io_rdata is
//   valid in it. io_ready is a register: an access takes two ticks. A write is taken
//   in the first.

module leds (
    input  wire        clk,
    input  wire        reset,           // synchronous, active high

    // ---- the I/O bus
    input  wire        io_sel,
    input  wire        io_we,
    input  wire [3:0]  io_be,
    input  wire [7:2]  io_addr,
    input  wire [31:0] io_wdata,
    output wire [31:0] io_rdata,
    output reg         io_ready,

    // ---- the pins
    output wire [5:0]  led              // active low
);
    reg  [5:0] value;                   // 1 = lit
    wire       is_leds = (io_addr == 6'd0);

    always @(posedge clk) begin
        if (reset) begin
            value    <= 6'h00;
            io_ready <= 1'b0;
        end else begin
            io_ready <= io_sel & !io_ready;
            if (io_sel & !io_ready & io_we & is_leds & io_be[0])
                value <= io_wdata[5:0];
        end
    end

    assign io_rdata = is_leds ? {26'h0, value} : 32'h0;
    assign led      = ~value;
endmodule
