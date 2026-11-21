// uart_rx.v: the receiver of the mp32's serial port.
//
//   A byte comes as ten bits on one wire, each held for the same time: a start
//   bit at 0, the eight bits, the lowest first, and a stop bit at 1. When nothing
//   comes, the wire rests at 1. The receiver from chapter 19 of the book, with
//   three changes:
//
//   - The bit time is not fixed: div, from the UART's DIV register, is the number
//     of ticks of one bit. At 63 MHz and 115,200 baud: 547 (115,174 baud, 0.02 %
//     slow).
//   - The wire comes from outside, from the BL616 by the USB-C socket, not in step
//     with our clock: it goes through two flip-flops first, so that a change that
//     arrives just at an edge cannot make a flip-flop behind it unsure.
//   - A byte whose stop bit is 0 is not thrown away silently: frame_err is 1
//     during one tick, so the UART can count it.
//
//   When the wire falls to 0, the receiver waits half a bit, to the middle of the
//   start bit, and looks again: still 0, it is a start bit; back at 1, it was a
//   glitch. Then it looks once a bit, in the middle of each.
//
//   div must be at least 4. A change of div takes effect at the next byte.

module uart_rx #(
    parameter W = 16                        // width of div
) (
    input  wire         clk,
    input  wire         reset,              // synchronous, active high
    input  wire [W-1:0] div,                // ticks of one bit
    input  wire         rx,                 // the wire: 1 when nothing comes
    output reg  [7:0]   data,               // the last byte that arrived
    output reg          valid,              // 1 during one tick: data has just arrived
    output reg          frame_err           // 1 during one tick: a byte without its stop bit
);
    // ================================================================ the two flip-flops
    reg rx_meta = 1, rx_sync = 1;
    always @(posedge clk) begin
        rx_meta <= rx;
        rx_sync <= rx_meta;
    end

    // ================================================================ the bits
    reg [W-1:0] count;                      // ticks to wait before the middle of the next bit
    reg [3:0]   which;                      // 0: waiting; 1: the start bit; 2..9: the eight
                                            // bits; 10: the stop bit
    reg [7:0]   bits;

    always @(posedge clk) begin
        valid     <= 0;
        frame_err <= 0;
        if (reset) begin
            which <= 0;
            count <= 0;
            bits  <= 0;
            data  <= 0;
        end else if (which == 0) begin
            if (rx_sync == 0) begin
                which <= 1;
                count <= div >> 1;
            end
        end else if (count != 0) begin
            count <= count - 1'b1;
        end else begin
            count <= div - 1'b1;
            if (which == 1) begin
                which <= (rx_sync == 0) ? 4'd2 : 4'd0;
            end else if (which <= 9) begin
                bits  <= {rx_sync, bits[7:1]};
                which <= which + 1'b1;
            end else begin
                if (rx_sync) begin
                    data  <= bits;
                    valid <= 1;
                end else
                    frame_err <= 1;
                which <= 0;
            end
        end
    end
endmodule
