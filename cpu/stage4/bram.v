// bram.v: the block RAM mapped into the address space of the mp32 processor.
//
//   2^BITS bytes (8 KB by default), 128 bits (one 16-byte line) wide, so the fetch
//   stage reads a whole line in one access and can run a program from it, e.g. the
//   first code after reset.
//
// The same handshake as the cache: sel, we, be, addr and wdata are held until ready
// is 1. ready comes 1 tick after sel (the block RAM reads at the edge); rline is
// valid in that tick. be has one bit for each byte of the line, bit k for the byte
// at offset k (bits 8k+7..8k).
//
// On the GW2AR the 8 KB take 4 block RAMs (512 x 32 each, with byte enables).
// INIT, if not empty, is a $readmemh file loaded with the FPGA: one 128-bit line per
// row, as 32 hex digits.

module bram #(
    parameter BITS = 13,               // 2^BITS bytes
    parameter INIT = ""
) (
    input  wire              clk,
    input  wire              reset,
    input  wire              sel,
    input  wire              we,
    input  wire [15:0]       be,
    input  wire [BITS-1:4]   addr,     // the line
    input  wire [127:0]      wdata,
    output reg  [127:0]      rline,
    output reg               ready
);
    localparam LINES = 1 << (BITS - 4);

    reg [127:0] ram [0:LINES-1];

    integer i;
    initial begin
        for (i = 0; i < LINES; i = i + 1) ram[i] = 128'h0;
        if (INIT != "") $readmemh(INIT, ram);
    end

    always @(posedge clk) begin
        if (sel & ~ready & we)
            for (i = 0; i < 16; i = i + 1)
                if (be[i]) ram[addr][8*i +: 8] <= wdata[8*i +: 8];
        rline <= ram[addr];
    end

    // ready in the tick after sel, for one tick
    always @(posedge clk)
        if (reset) ready <= 1'b0;
        else       ready <= sel & ~ready;
endmodule
