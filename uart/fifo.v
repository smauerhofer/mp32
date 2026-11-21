// fifo.v: a queue of bytes for the serial port, first in, first out.
//
//   The queue from chapter 21 of the book, with three changes:
//
//   - Its size is a parameter: 2^BITS bytes, all of them usable. A counter of
//     BITS+1 bits says how many wait, so full and empty look different without
//     keeping one place free.
//   - The first byte is shown at once (head), not one tick later: the memory is
//     small enough for the chip's LUT RAM, which is read without a clock. take in
//     the same tick removes it.
//   - full is an output: the transmitter's queue must make the processor wait
//     instead of losing the byte.
//
//   put while full is ignored (the byte is lost: the receiver's queue counts that
//   as an overrun), unless take comes in the same tick: a byte leaves and the new
//   one takes its place. take while empty is ignored.

module fifo #(
    parameter BITS = 4                      // 2^BITS bytes
) (
    input  wire          clk,
    input  wire          reset,             // synchronous, active high: empties it
    input  wire          put,
    input  wire [7:0]    data,
    input  wire          take,
    output wire [7:0]    head,              // the first byte, when ready
    output wire          ready,             // 1: at least one byte waits
    output wire          full,              // 1: no more room
    output reg  [BITS:0] used               // how many bytes wait
);
    localparam SIZE = 1 << BITS;

    reg [7:0]      bytes [0:SIZE-1];
    reg [BITS-1:0] in, out;

    assign ready = (used != 0);
    assign full  = (used == SIZE);
    assign head  = bytes[out];

    wire do_take = take & ready;
    wire do_put  = put & (~full | do_take);

    always @(posedge clk) begin
        if (do_put)
            bytes[in] <= data;
        if (reset) begin
            in   <= 0;
            out  <= 0;
            used <= 0;
        end else begin
            if (do_put)  in  <= in + 1'b1;
            if (do_take) out <= out + 1'b1;
            used <= used + do_put - do_take;
        end
    end
endmodule
