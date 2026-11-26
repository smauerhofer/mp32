// memsys.v: the memory system of the mp32 processor.
//
//   What stage 4 (memory access, words) and stage 1 (fetch, 16-byte lines) reach:
//
//     membus.v    the bus: stage 4 before stage 1, the address map, the block RAM
//     cache.v     the cache in front of the 8 MB SDRAM, with the SDRAM controller
//                 (sdram.v) under it, which also serves the video unit
//
//   and the ports to the outside: the I/O range (to the I/O devices), the video
//   port (row bursts straight from the SDRAM, ahead of the cache) and the SDRAM pins.
//
// ---------------------------------------------------------------- the address map
//   0x0000_0000 - 0x007F_FFFF   SDRAM, 8 MB, through the cache
//   0xF000_0000 - 0xF000_1FFF   block RAM, 8 KB (BRAM_INIT: loaded with the FPGA)
//   0xFFFF_0000 - 0xFFFF_FFFF   I/O, 64 KB (io_*)
//   anything else               nothing: reads 0, writes ignored
//
// ---------------------------------------------------------------- handshakes
// Every port has the cache's handshake: sel and the rest held until ready, which
// ends the access. Stage 4: d_*; fetch: line_*; the I/O devices: io_*. See membus.v.
//
// ---------------------------------------------------------------- the clock
// clk is the processor's clock, CLK_MHZ MHz (for the SDRAM's timing and refresh): 42
// MHz, 126 / 3 from the display's PLL. Up to about 60 MHz the inverted clock is
// enough for the SDRAM (EXT_CLK = 0, sdram.v). Above it, the SDRAM needs its own
// clock: EXT_CLK = 1 and clk_sdram from a second output of the PLL, at the same
// frequency, shifted in phase; RD_LAT goes with that phase. Both must be found on the
// board.

module memsys #(
    parameter        CLK_MHZ    = 42,
    parameter        CAS        = 2,
    parameter        RD_LAT     = CAS + 1,
    parameter        EXT_CLK    = 0,
    parameter        RD_NEG     = 0,                  // see sdram.v
    parameter        INDEX_BITS = 9,                  // cache: 2^9 lines of 16 bytes
    parameter [22:0] WT_FROM    = 23'h780000,         // write-through (the video's)
    parameter [22:0] WT_TO      = 23'h7FFFFF,
    parameter [31:0] BRAM_BASE  = 32'hF000_0000,
    parameter        BRAM_BITS  = 13,
    parameter        BRAM_INIT  = ""
) (
    input  wire         clk,
    input  wire         clk_sdram,      // with EXT_CLK = 1: the SDRAM's clock
    input  wire         reset,          // synchronous, active high

    // ---- stage 4: memory access
    input  wire         d_sel,
    input  wire         d_we,
    input  wire [3:0]   d_be,
    input  wire [31:0]  d_addr,
    input  wire [31:0]  d_wdata,
    output wire [31:0]  d_rdata,
    output wire         d_ready,

    // ---- stage 1: fetch
    input  wire         line_sel,
    input  wire [31:4]  line_addr,
    output wire [127:0] line_data,
    output wire         line_ready,

    // ---- the I/O devices
    output wire         io_sel,
    output wire         io_we,
    output wire [3:0]   io_be,
    output wire [15:0]  io_addr,
    output wire [31:0]  io_wdata,
    input  wire [31:0]  io_rdata,
    input  wire         io_ready,

    // ---- the video unit: row bursts from the SDRAM
    input  wire         vid_req,
    input  wire [22:4]  vid_addr,
    input  wire [6:0]   vid_count,
    output wire [31:0]  vid_word,
    output wire         vid_valid,
    output wire         vid_ack,

    // ---- the SDRAM
    output wire         O_sdram_clk,
    output wire         O_sdram_cke,
    output wire         O_sdram_cs_n,
    output wire         O_sdram_ras_n,
    output wire         O_sdram_cas_n,
    output wire         O_sdram_wen_n,
    output wire [3:0]   O_sdram_dqm,
    output wire [10:0]  O_sdram_addr,
    output wire [1:0]   O_sdram_ba,
    inout  wire [31:0]  IO_sdram_dq
);
    // ================================================================ the bus
    wire         c_sel, c_we;
    wire [3:0]   c_be;
    wire [22:0]  c_addr;
    wire [31:0]  c_wdata;
    wire [127:0] c_rline;
    wire         c_ready;

    membus #(
        .BRAM_BASE(BRAM_BASE), .BRAM_BITS(BRAM_BITS), .BRAM_INIT(BRAM_INIT)
    ) bus (
        .clk(clk), .reset(reset),
        .d_sel(d_sel), .d_we(d_we), .d_be(d_be), .d_addr(d_addr), .d_wdata(d_wdata),
        .d_rdata(d_rdata), .d_ready(d_ready),
        .line_sel(line_sel), .line_addr(line_addr), .line_data(line_data),
        .line_ready(line_ready),
        .c_sel(c_sel), .c_we(c_we), .c_be(c_be), .c_addr(c_addr), .c_wdata(c_wdata),
        .c_rline(c_rline), .c_ready(c_ready),
        .io_sel(io_sel), .io_we(io_we), .io_be(io_be), .io_addr(io_addr),
        .io_wdata(io_wdata), .io_rdata(io_rdata), .io_ready(io_ready)
    );

    // ================================================================ the cache and the SDRAM
    cache #(
        .INDEX_BITS(INDEX_BITS), .CLK_MHZ(CLK_MHZ), .CAS(CAS), .RD_LAT(RD_LAT),
        .WT_FROM(WT_FROM), .WT_TO(WT_TO), .EXT_CLK(EXT_CLK), .RD_NEG(RD_NEG)
    ) cache (
        .clk(clk), .clk_sdram(clk_sdram), .reset(reset),
        .cpu_sel(c_sel), .cpu_we(c_we), .cpu_be(c_be), .cpu_addr(c_addr),
        .cpu_wdata(c_wdata), .cpu_rdata(), .cpu_rline(c_rline), .cpu_ready(c_ready),
        .vid_req(vid_req), .vid_addr(vid_addr), .vid_count(vid_count),
        .vid_word(vid_word), .vid_valid(vid_valid), .vid_ack(vid_ack),
        .O_sdram_clk(O_sdram_clk), .O_sdram_cke(O_sdram_cke), .O_sdram_cs_n(O_sdram_cs_n),
        .O_sdram_ras_n(O_sdram_ras_n), .O_sdram_cas_n(O_sdram_cas_n),
        .O_sdram_wen_n(O_sdram_wen_n), .O_sdram_dqm(O_sdram_dqm),
        .O_sdram_addr(O_sdram_addr), .O_sdram_ba(O_sdram_ba), .IO_sdram_dq(IO_sdram_dq)
    );
endmodule
