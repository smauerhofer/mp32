// uart_tx.v: the transmitter of the mp32's serial port, the receiver's twin.
//
//   It sends a byte as ten bits on one wire: a start bit at 0, the eight bits of
//   the byte, the lowest first, and a stop bit at 1. Each bit lasts div ticks (the
//   UART's DIV register). Between two bytes the wire rests at 1. The transmitter
//   from chapter 19 of the book, with div instead of a fixed number.
//
//   send at 1 during one tick, while busy is 0, starts a byte. busy is 1 from the
//   next tick until the stop bit is over: 10 * div ticks. A byte sent while busy is
//   1 is ignored (the UART never does that: it waits for busy to be 0).
//
//   div must be at least 2. A change of div takes effect at the next bit.

module uart_tx #(
    parameter W = 16                        // width of div
) (
    input  wire         clk,
    input  wire         reset,              // synchronous, active high
    input  wire [W-1:0] div,                // ticks of one bit
    input  wire         send,               // 1 during one tick: send data
    input  wire [7:0]   data,
    output wire         tx,                 // the wire
    output wire         busy                // 1 while a byte is going out
);
    reg [9:0]   bits;                       // the bits still to go; the one on the wire is bit 0
    reg [3:0]   left;                       // how many: 0 when nothing is going out
    reg [W-1:0] count;                      // ticks before the next bit

    always @(posedge clk) begin
        if (reset) begin
            bits  <= 10'h3FF;
            left  <= 0;
            count <= 0;
        end else if (left == 0) begin
            if (send) begin
                bits  <= {1'b1, data, 1'b0};    // stop bit, the byte, start bit first
                left  <= 10;
                count <= div - 1'b1;
            end
        end else if (count != 0) begin
            count <= count - 1'b1;
        end else begin
            bits  <= {1'b1, bits[9:1]};
            left  <= left - 1'b1;
            count <= div - 1'b1;
        end
    end

    assign tx   = bits[0];
    assign busy = (left != 0);
endmodule
