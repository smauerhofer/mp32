// decode.v: the processor's 32-bit address space, cut into the parts that answer.
//
//   0x0000_0000 - 0x007F_FFFF   SDRAM, 8 MB, through the cache (../cache/cache.v)
//   0xF000_0000 - 0xF003_FFFF   the video unit (../display2/video.v), its own
//                               addresses plus 0xF000_0000:
//       0xF002_0000 -              font RAM (2,048 bytes a font, 4 rows a word)
//       0xF003_0020                text_base
//       0xF003_0024                pixel_base
//       0xF003_0400 - 0xF003_07FF  palette: one word an entry, 0x00BBGGRR (write only)
//       0xF003_1000 - 0xF003_12CF  mode RAM: 3 words a row
//   anything else               nothing: a read gives 0, a write does nothing, and
//                               either ends at once
//
// The SDRAM's default places for the screen (see video.v and cache.v):
//   0x0078_0000   text,   19,200 bytes   (text_base)
//   0x0079_0000   pixels, 307,200 bytes  (pixel_base)
//   0x0078_0000 - 0x007F_FFFF is the cache's write-through region.
//
// ---------------------------------------------------------------- the buses
// All three are 32 bits wide, on clk, with the same handshake: the processor sets
// cpu_sel, cpu_we, cpu_be, cpu_addr and cpu_wdata and holds them until cpu_ready is
// 1. That tick ends the access; for a read, cpu_rdata is valid during it.
//   cpu_be:    one bit for each byte of the word, bit 0 for bits 7..0 (the byte at
//              address 4n, little-endian). A write writes the bytes whose bits are 1.
//              A read always returns the whole word.
//   cpu_addr:  bits 1..0 do not count; cpu_be picks the bytes.
// The decoder only steers: cpu_sel goes to the part the address is in, and that
// part's cpu_ready and cpu_rdata come back. It holds nothing and adds no tick.

module decode (
    // The processor
    input  wire        cpu_sel,
    input  wire        cpu_we,
    input  wire [3:0]  cpu_be,
    input  wire [31:0] cpu_addr,
    input  wire [31:0] cpu_wdata,
    output wire [31:0] cpu_rdata,
    output wire        cpu_ready,

    // The cache
    output wire        mem_sel,
    output wire        mem_we,
    output wire [3:0]  mem_be,
    output wire [22:0] mem_addr,
    output wire [31:0] mem_wdata,
    input  wire [31:0] mem_rdata,
    input  wire        mem_ready,

    // The video unit
    output wire        vid_sel,
    output wire        vid_we,
    output wire [3:0]  vid_be,
    output wire [17:0] vid_addr,
    output wire [31:0] vid_wdata,
    input  wire [31:0] vid_rdata,
    input  wire        vid_ready
);
    wire is_mem   = (cpu_addr[31:23] == 9'h000);       // 0x0000_0000 - 0x007F_FFFF
    wire is_video = (cpu_addr[31:18] == 14'h3C00);     // 0xF000_0000 - 0xF003_FFFF

    assign mem_sel   = cpu_sel & is_mem;
    assign mem_we    = cpu_we;
    assign mem_be    = cpu_be;
    assign mem_addr  = cpu_addr[22:0];
    assign mem_wdata = cpu_wdata;

    assign vid_sel   = cpu_sel & is_video;
    assign vid_we    = cpu_we;
    assign vid_be    = cpu_be;
    assign vid_addr  = cpu_addr[17:0];
    assign vid_wdata = cpu_wdata;

    assign cpu_ready = cpu_sel & (is_mem   ? mem_ready :
                                  is_video ? vid_ready : 1'b1);
    assign cpu_rdata = is_mem   ? mem_rdata :
                       is_video ? vid_rdata : 32'h0;
endmodule
