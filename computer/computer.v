// computer.v: the mp32 computer, without the board: the processor, its memory, the
// I/O devices and the picture.
//
//   ../cpu/cpu.v                 the processor (the five stages)
//   ../cpu/stage4/memsys.v       the memory system: the bus, the block RAM with the
//                                boot program, the cache, the SDRAM controller
//   iodec.v                      the I/O decoder (the address map of the devices)
//   ../uart/uart.v               the serial port (to the PC, over the USB-C cable)
//   ../sdcard/sdcard.v           the microSD card
//   ../audio/audio.v             the sound: I2S to the board's MAX98357A
//   ../display2/video.v          the picture: text and graphics from the SDRAM
//   raster.v, tmds.v             the raster and the HDMI encoders (the book's)
//
// Two clocks:
//   clk        the processor's, 42 MHz (126 / 3). The memory system, the I/O devices
//              and the video unit's processor side tick with it.
//   pixel_clk  25.2 MHz: the raster, the video unit's display side, the encoders.
//              The video unit hands over between the two (see video.v).
//
// The HDMI codes come out on pixel_clk; top.v serializes them onto the pins. The
// SDRAM pins go straight out: their names are those the chip's SDRAM is wired to.
//
// The memory files: BOOT, the block RAM's contents (the linker's boot.hex, one
// 16-byte line per row), FONT_FILE and PALETTE_FILE for the video unit.

module computer #(
    parameter        CLK_MHZ      = 42,
    parameter        BOOT         = "boot.hex",
    parameter        FONT_FILE    = "fonts.hex",
    parameter        PALETTE_FILE = "palette.hex",
    parameter [15:0] UART_DIV     = 16'd365,       // 115,200 baud at 42 MHz
    parameter [7:0]  AUDIO_DIV    = 8'd7           // 46,875 Hz at 42 MHz
) (
    input  wire        clk,
    input  wire        pixel_clk,
    input  wire        reset,           // synchronous to clk, active high

    // ---- the board
    input  wire [1:0]  buttons,         // 1 = pressed, already on clk
    output wire [5:0]  leds,            // 1 = lit
    input  wire        uart_rx,
    output wire        uart_tx,
    output wire        sd_clk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_cs_n,
    output wire        hp_bck,          // the sound: I2S to the MAX98357A
    output wire        hp_ws,
    output wire        hp_din,
    output wire        pa_en,           // its amplifier on

    // ---- the picture: the three HDMI codes, on pixel_clk
    output wire [9:0]  tmds_blue,
    output wire [9:0]  tmds_green,
    output wire [9:0]  tmds_red,

    // ---- the SDRAM
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_wen_n,
    output wire [3:0]  O_sdram_dqm,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    inout  wire [31:0] IO_sdram_dq,

    // ---- to look at (a test bench)
    output wire [31:0] pc
);
    // ================================================================ the processor
    wire         line_sel, line_ready;
    wire [31:4]  line_addr;
    wire [127:0] line_data;
    wire         data_sel, data_we, data_ready;
    wire [3:0]   data_be;
    wire [31:0]  data_addr, data_wdata, data_rdata;

    cpu #(.RESET_PC(32'hF000_0000), .GC_VECTOR(32'hF000_0010)) processor (
        .clk(clk), .reset(reset), .irq_pending(1'b0),     // no interrupts yet
        .line_sel(line_sel), .line_addr(line_addr), .line_data(line_data),
        .line_ready(line_ready),
        .data_sel(data_sel), .data_we(data_we), .data_be(data_be), .data_addr(data_addr),
        .data_wdata(data_wdata), .data_rdata(data_rdata), .data_ready(data_ready),
        .pc(pc), .t(), .s(), .r(), .l(), .psp(), .rsp(), .fp(), .flags()
    );

    // ================================================================ the memory system
    wire        io_sel, io_we, io_ready;
    wire [3:0]  io_be;
    wire [15:0] io_addr;
    wire [31:0] io_wdata, io_rdata;

    wire         vmem_req, vmem_valid, vmem_ack;
    wire [22:4]  vmem_addr;
    wire [6:0]   vmem_count;
    wire [31:0]  vmem_word;

    memsys #(.CLK_MHZ(CLK_MHZ), .EXT_CLK(0), .BRAM_INIT(BOOT)) memory (
        .clk(clk), .clk_sdram(1'b0), .reset(reset),
        .d_sel(data_sel), .d_we(data_we), .d_be(data_be), .d_addr(data_addr),
        .d_wdata(data_wdata), .d_rdata(data_rdata), .d_ready(data_ready),
        .line_sel(line_sel), .line_addr(line_addr), .line_data(line_data),
        .line_ready(line_ready),
        .io_sel(io_sel), .io_we(io_we), .io_be(io_be), .io_addr(io_addr),
        .io_wdata(io_wdata), .io_rdata(io_rdata), .io_ready(io_ready),
        .vid_req(vmem_req), .vid_addr(vmem_addr), .vid_count(vmem_count),
        .vid_word(vmem_word), .vid_valid(vmem_valid), .vid_ack(vmem_ack),
        .O_sdram_clk(O_sdram_clk), .O_sdram_cke(O_sdram_cke), .O_sdram_cs_n(O_sdram_cs_n),
        .O_sdram_ras_n(O_sdram_ras_n), .O_sdram_cas_n(O_sdram_cas_n),
        .O_sdram_wen_n(O_sdram_wen_n), .O_sdram_dqm(O_sdram_dqm),
        .O_sdram_addr(O_sdram_addr), .O_sdram_ba(O_sdram_ba), .IO_sdram_dq(IO_sdram_dq)
    );

    // ================================================================ the I/O devices
    wire        uart_sel, uart_ready, sd_sel, sd_ready, vid_sel, vid_ready;
    wire        audio_sel, audio_ready;
    wire [12:0] audio_addr;
    wire        audio_irq;          // the sound: the queue half empty, or a bank played
    wire [31:0] uart_rdata, sd_rdata, vid_rdata, audio_rdata;
    wire [17:0] vid_addr;

    iodec io (
        .clk(clk), .reset(reset),
        .io_sel(io_sel), .io_we(io_we), .io_be(io_be), .io_addr(io_addr),
        .io_wdata(io_wdata), .io_rdata(io_rdata), .io_ready(io_ready),
        .uart_sel(uart_sel), .uart_rdata(uart_rdata), .uart_ready(uart_ready),
        .sd_sel(sd_sel), .sd_rdata(sd_rdata), .sd_ready(sd_ready),
        .audio_sel(audio_sel), .audio_addr(audio_addr), .audio_rdata(audio_rdata), .audio_ready(audio_ready),
        .vid_sel(vid_sel), .vid_addr(vid_addr), .vid_rdata(vid_rdata), .vid_ready(vid_ready),
        .leds(leds), .buttons(buttons)
    );

    uart #(.DIV_INIT(UART_DIV)) serial (
        .clk(clk), .reset(reset),
        .io_sel(uart_sel), .io_we(io_we), .io_be(io_be), .io_addr(io_addr[3:2]),
        .io_wdata(io_wdata), .io_rdata(uart_rdata), .io_ready(uart_ready),
        .irq(),                                            // no interrupts yet
        .uart_rx(uart_rx), .uart_tx(uart_tx)
    );

    sdcard card (
        .clk(clk), .reset(reset),
        .io_sel(sd_sel), .io_we(io_we), .io_be(io_be), .io_addr(io_addr[3:2]),
        .io_wdata(io_wdata), .io_rdata(sd_rdata), .io_ready(sd_ready),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n)
    );

    audio #(.DIV_INIT(AUDIO_DIV)) sound (
        .clk(clk), .reset(reset),
        .io_sel(audio_sel), .io_we(io_we), .io_be(io_be), .io_addr(audio_addr[12:2]),
        .io_wdata(io_wdata), .io_rdata(audio_rdata), .io_ready(audio_ready),
        .irq(audio_irq),                                   // not to the processor yet
        .hp_bck(hp_bck), .hp_ws(hp_ws), .hp_din(hp_din), .pa_en(pa_en)
    );

    // ================================================================ the picture
    wire [9:0] x, y;
    wire       hsync, vsync, visible;

    raster scan (
        .clk(pixel_clk), .x(x), .y(y), .hsync(hsync), .vsync(vsync), .visible(visible)
    );

    wire [7:0] red, green, blue;
    wire       visible_d, hsync_d, vsync_d;

    video #(.FONT_FILE(FONT_FILE), .PALETTE_FILE(PALETTE_FILE), .MODE_FILE("")) picture (
        .clk(pixel_clk), .x(x), .y(y), .visible(visible), .hsync(hsync), .vsync(vsync),
        .red(red), .green(green), .blue(blue),
        .visible_delayed(visible_d), .hsync_delayed(hsync_d), .vsync_delayed(vsync_d),
        .cpu_clk(clk), .cpu_sel(vid_sel), .cpu_we(io_we), .cpu_be(io_be),
        .cpu_addr(vid_addr), .cpu_wdata(io_wdata), .cpu_rdata(vid_rdata),
        .cpu_ready(vid_ready),
        .mem_req(vmem_req), .mem_addr(vmem_addr), .mem_count(vmem_count),
        .mem_word(vmem_word), .mem_valid(vmem_valid), .mem_ack(vmem_ack)
    );

    tmds blue_encoder (
        .clk(pixel_clk), .data(blue), .control({vsync_d, hsync_d}), .visible(visible_d),
        .code(tmds_blue)
    );
    tmds green_encoder (
        .clk(pixel_clk), .data(green), .control(2'b00), .visible(visible_d),
        .code(tmds_green)
    );
    tmds red_encoder (
        .clk(pixel_clk), .data(red), .control(2'b00), .visible(visible_d),
        .code(tmds_red)
    );
endmodule
