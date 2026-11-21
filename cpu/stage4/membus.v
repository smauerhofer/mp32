// membus.v: the memory bus of the mp32 processor.
//
//   Two masters: stage 4 (memory access, 32-bit words) and stage 1 (fetch, 16-byte
//   lines). Stage 4 has priority over stage 1.
//   Three slaves, picked by the address: the SDRAM (through the cache), the mapped
//   block RAM (bram.v, inside this module) and the I/O range.
//
// ---------------------------------------------------------------- the address map
//   0x0000_0000 - 0x007F_FFFF   SDRAM, 8 MB, through the cache
//   BRAM_BASE   + 2^BRAM_BITS   block RAM (default 0xF000_0000 - 0xF000_1FFF, 8 KB)
//   0xFFFF_0000 - 0xFFFF_FFFF   I/O, 64 KB (io_addr = bits 15..0)
//   anything else               nothing: reads 0, writes are ignored, done at once
//
// ---------------------------------------------------------------- the masters
// Both use the cache's handshake: the master sets its sel and the rest and holds them
// until its ready is 1; that tick ends the access, and the data read is valid in it.
//
//   stage 4: d_sel, d_we, d_be (4 bits), d_addr, d_wdata  ->  d_rdata, d_ready
//   stage 1: line_sel, line_addr[31:4] (reads only)       ->  line_data, line_ready
//
// When both ask in the same tick, stage 4 gets the bus. An access that has started is
// never broken off: if stage 1 already has the bus, stage 4 waits until its line is
// in, then goes first.
//
// ---------------------------------------------------------------- the slaves
// They all answer with a whole line, rline: the cache gives the line it holds (its
// cpu_rline), the block RAM is a line wide, the I/O gives its word in all 4 places.
// Stage 4 takes its word out of the line with d_addr[3:2].
//
//   cache:  c_sel, c_we, c_be, c_addr[22:0], c_wdata   ->  c_rline, c_ready
//   I/O:    io_sel, io_we, io_be, io_addr[15:0], io_wdata  ->  io_rdata, io_ready
//
// A slave sees the same handshake: its inputs are held from sel until its ready.

module membus #(
    parameter [31:0] BRAM_BASE = 32'hF000_0000,   // aligned to 2^BRAM_BITS
    parameter        BRAM_BITS = 13,              // 8 KB
    parameter        BRAM_INIT = ""
) (
    input  wire         clk,
    input  wire         reset,          // synchronous, active high

    // master: stage 4, memory access
    input  wire         d_sel,
    input  wire         d_we,
    input  wire [3:0]   d_be,
    input  wire [31:0]  d_addr,
    input  wire [31:0]  d_wdata,
    output wire [31:0]  d_rdata,
    output wire         d_ready,

    // master: stage 1, fetch
    input  wire         line_sel,
    input  wire [31:4]  line_addr,
    output wire [127:0] line_data,
    output wire         line_ready,

    // slave: the cache
    output wire         c_sel,
    output wire         c_we,
    output wire [3:0]   c_be,
    output wire [22:0]  c_addr,
    output wire [31:0]  c_wdata,
    input  wire [127:0] c_rline,
    input  wire         c_ready,

    // slave: the I/O
    output wire         io_sel,
    output wire         io_we,
    output wire [3:0]   io_be,
    output wire [15:0]  io_addr,
    output wire [31:0]  io_wdata,
    input  wire [31:0]  io_rdata,
    input  wire         io_ready
);
    // ================================================================ who has the bus
    // owner: the master whose access is going on (NONE between accesses). grant: who
    // has it in this tick: the owner, or, when there is none, stage 4 before stage 1.
    localparam [1:0] NONE = 2'd0, DATA = 2'd1, FETCH = 2'd2;

    reg  [1:0] owner;
    wire [1:0] grant = (owner != NONE) ? owner :
                       d_sel           ? DATA  :
                       line_sel        ? FETCH : NONE;

    // the bus: what the master with the grant asks for
    wire         b_sel   = (grant != NONE);
    wire         b_we    = (grant == DATA) & d_we;
    wire [31:0]  b_addr  = (grant == DATA) ? d_addr : {line_addr, 4'b0000};
    wire [3:0]   b_be    = d_be;
    wire [31:0]  b_wdata = d_wdata;

    // ================================================================ which slave
    wire to_sdram = (b_addr[31:23] == 9'd0);
    wire to_bram  = (b_addr[31:BRAM_BITS] == BRAM_BASE[31:BRAM_BITS]);
    wire to_io    = (b_addr[31:16] == 16'hFFFF);
    wire to_none  = !(to_sdram | to_bram | to_io);

    // the cache
    assign c_sel   = b_sel & to_sdram;
    assign c_we    = b_we;
    assign c_be    = b_be;
    assign c_addr  = b_addr[22:0];
    assign c_wdata = b_wdata;

    // the block RAM: the word goes in its place in the line
    wire         m_sel = b_sel & to_bram;
    wire [127:0] m_rline;
    wire         m_ready;
    bram #(.BITS(BRAM_BITS), .INIT(BRAM_INIT)) block_ram (
        .clk(clk), .reset(reset),
        .sel(m_sel), .we(b_we), .be({12'h000, b_be} << {b_addr[3:2], 2'b00}),
        .addr(b_addr[BRAM_BITS-1:4]), .wdata({4{b_wdata}}),
        .rline(m_rline), .ready(m_ready)
    );

    // the I/O
    assign io_sel   = b_sel & to_io;
    assign io_we    = b_we;
    assign io_be    = b_be;
    assign io_addr  = b_addr[15:0];
    assign io_wdata = b_wdata;

    // ================================================================ the answer
    wire b_ready = to_sdram ? c_ready : to_bram ? m_ready : to_io ? io_ready : b_sel;
    wire [127:0] b_rline = to_sdram ? c_rline : to_bram ? m_rline :
                           to_io    ? {4{io_rdata}} : 128'h0;

    assign d_ready    = (grant == DATA)  & b_ready;
    assign line_ready = (grant == FETCH) & b_ready;
    assign d_rdata    = b_rline[{d_addr[3:2], 5'b00000} +: 32];
    assign line_data  = b_rline;

    // the owner keeps the bus until its ready
    always @(posedge clk)
        if (reset)        owner <= NONE;
        else if (b_ready) owner <= NONE;
        else              owner <= grant;
endmodule
