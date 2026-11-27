// computer.v: the mp32 computer, without the board: the processor, its memory, the
// I/O devices and the picture.
//
//   ../cpu/cpu.v                 the processor (the five stages)
//   ../cpu/stage4/memsys.v       the memory system: the bus, the block RAM with the
//                                boot loader, the cache, the SDRAM controller
//   iodec.v                      the I/O decoder (the address map of the devices),
//                                with the interrupt controller (../cpu/irqc.v)
//   ../uart/uart.v               the serial port (to the PC, over the USB-C cable)
//   ../sdcard/sdcard.v           the microSD card, and (a second one) the SPI flash
//   ../audio/audio.v             the sound: I2S to the board's MAX98357A
//   ../keyboard/keyboard.v       the keyboard and the mouse: a CH9350L module on a
//                                serial line both ways (reports in, the LEDs out)
//   ../timer/timer.v             two timers: regular interrupts, fast and slow
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
    parameter [7:0]  AUDIO_DIV    = 8'd7,          // 46,875 Hz at 42 MHz
    parameter [15:0] KBD_DIV      = 16'd365,       // the keyboard's module: 115,200 baud
    // when the SDRAM's read data is taken, see ../cache/sdram.v: RD_LAT = 3 (CAS + 1)
    // and RD_NEG = 0 for the simulation's model; on the board (top.v) RD_NEG = 1,
    // 2 1/2 ticks (at 3 every word came one late, at 2 the bits flickered)
    parameter        RD_LAT       = 3,
    parameter        RD_NEG       = 0
) (
    input  wire        clk,
    input  wire        pixel_clk,
    input  wire        reset,           // synchronous to clk, active high

    // ---- the board
    input  wire [1:0]  buttons,         // 1 = pressed, already on clk
    output wire [5:0]  leds,            // 1 = lit
    output wire        s1_reset,        // 1: S1 is the reset (iodec.v, CTRL.S1INT = 0)
    input  wire        uart_rx,
    output wire        uart_tx,
    output wire        sd_clk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_cs_n,
    output wire        flash_clk,       // the SPI flash (the one with the bitstream)
    output wire        flash_mosi,
    input  wire        flash_miso,
    output wire        flash_cs_n,
    output wire        hp_bck,          // the sound: I2S to the MAX98357A
    output wire        hp_ws,
    output wire        hp_din,
    output wire        pa_en,           // its amplifier on
    input  wire        kbd_rx,          // the keyboard's module: its TXD, already on clk
    output wire        kbd_tx,          // to its RXD

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

    wire         irq, irq_ack;      // the interrupt controller (in iodec.v) and back
    wire [7:0]   irq_num, irq_ack_num;

    cpu #(.RESET_PC(32'hF000_0000), .VEC_RESET(32'hF000_0000)) processor (
        .clk(clk), .reset(reset), .irq(irq), .irq_num(irq_num),
        .irq_ack(irq_ack), .irq_ack_num(irq_ack_num),
        .line_sel(line_sel), .line_addr(line_addr), .line_data(line_data),
        .line_ready(line_ready),
        .data_sel(data_sel), .data_we(data_we), .data_be(data_be), .data_addr(data_addr),
        .data_wdata(data_wdata), .data_rdata(data_rdata), .data_ready(data_ready),
        .pc(pc), .t(), .s(), .r(), .l(), .psp(), .rsp(), .fp(), .flags(), .ie()
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

    memsys #(.CLK_MHZ(CLK_MHZ), .EXT_CLK(0), .RD_LAT(RD_LAT), .RD_NEG(RD_NEG),
             .BRAM_INIT(BOOT)) memory (
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
    wire        flash_sel, flash_ready;
    wire        audio_sel, audio_ready;
    wire        kbd_sel, kbd_ready;
    wire        kbd_irq;            // the keyboard: a report waits, or the mouse moved
    wire        timer_sel, timer_ready;
    wire        timer0_irq, timer1_irq; // the timers: the fast one, the slow one
    wire [12:0] audio_addr;
    wire        uart_irq;           // the serial port: a byte came, or room to send
    wire        audio_irq;          // the sound: the queue half empty, or a bank played
    wire        line_irq, frame_irq;    // the display: a line, the vertical blank
    wire [31:0] uart_rdata, sd_rdata, flash_rdata, vid_rdata, audio_rdata, kbd_rdata;
    wire [31:0] timer_rdata;
    wire [17:0] vid_addr;

    iodec io (
        .clk(clk), .reset(reset),
        .io_sel(io_sel), .io_we(io_we), .io_be(io_be), .io_addr(io_addr),
        .io_wdata(io_wdata), .io_rdata(io_rdata), .io_ready(io_ready),
        .uart_sel(uart_sel), .uart_rdata(uart_rdata), .uart_ready(uart_ready),
        .sd_sel(sd_sel), .sd_rdata(sd_rdata), .sd_ready(sd_ready),
        .flash_sel(flash_sel), .flash_rdata(flash_rdata), .flash_ready(flash_ready),
        .kbd_sel(kbd_sel), .kbd_rdata(kbd_rdata), .kbd_ready(kbd_ready),
        .timer_sel(timer_sel), .timer_rdata(timer_rdata), .timer_ready(timer_ready),
        .audio_sel(audio_sel), .audio_addr(audio_addr), .audio_rdata(audio_rdata), .audio_ready(audio_ready),
        .vid_sel(vid_sel), .vid_addr(vid_addr), .vid_rdata(vid_rdata), .vid_ready(vid_ready),
        .leds(leds), .buttons(buttons), .s1_reset(s1_reset),
        // line 5, the buttons, is made in iodec.v
        .irq_lines({timer1_irq, timer0_irq, 1'b0, kbd_irq, uart_irq, audio_irq, frame_irq, line_irq}),
        .irq(irq), .irq_num(irq_num), .irq_ack(irq_ack), .irq_ack_num(irq_ack_num)
    );

    uart #(.DIV_INIT(UART_DIV)) serial (
        .clk(clk), .reset(reset),
        .io_sel(uart_sel), .io_we(io_we), .io_be(io_be), .io_addr(io_addr[3:2]),
        .io_wdata(io_wdata), .io_rdata(uart_rdata), .io_ready(uart_ready),
        .irq(uart_irq),                                    // line 3: vector 19
        .uart_rx(uart_rx), .uart_tx(uart_tx)
    );

    sdcard card (
        .clk(clk), .reset(reset),
        .io_sel(sd_sel), .io_we(io_we), .io_be(io_be), .io_addr(io_addr[3:2]),
        .io_wdata(io_wdata), .io_rdata(sd_rdata), .io_ready(sd_ready),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n)
    );

    // The SPI flash: the same SPI master as the card, at 21 MHz from the start (DIV 0;
    // its READ, 0x03, goes up to 50 MHz).
    sdcard #(.DIV_INIT(8'd0)) flash (
        .clk(clk), .reset(reset),
        .io_sel(flash_sel), .io_we(io_we), .io_be(io_be), .io_addr(io_addr[3:2]),
        .io_wdata(io_wdata), .io_rdata(flash_rdata), .io_ready(flash_ready),
        .sd_clk(flash_clk), .sd_mosi(flash_mosi), .sd_miso(flash_miso), .sd_cs_n(flash_cs_n)
    );

    audio #(.DIV_INIT(AUDIO_DIV)) sound (
        .clk(clk), .reset(reset),
        .io_sel(audio_sel), .io_we(io_we), .io_be(io_be), .io_addr(audio_addr[12:2]),
        .io_wdata(io_wdata), .io_rdata(audio_rdata), .io_ready(audio_ready),
        .irq(audio_irq),                                   // line 2: vector 18
        .hp_bck(hp_bck), .hp_ws(hp_ws), .hp_din(hp_din), .pa_en(pa_en)
    );

    keyboard #(.DIV(KBD_DIV)) keys (
        .clk(clk), .reset(reset),
        .io_sel(kbd_sel), .io_we(io_we), .io_be(io_be), .io_addr(io_addr[4:2]),
        .io_wdata(io_wdata), .io_rdata(kbd_rdata), .io_ready(kbd_ready),
        .irq(kbd_irq),                                     // line 4: vector 20
        .kbd_rx(kbd_rx), .kbd_tx(kbd_tx)
    );

    timer #(.CLK_HZ(CLK_MHZ * 1_000_000)) timers (
        .clk(clk), .reset(reset),
        .io_sel(timer_sel), .io_we(io_we), .io_be(io_be), .io_addr(io_addr[5:2]),
        .io_wdata(io_wdata), .io_rdata(timer_rdata), .io_ready(timer_ready),
        .irq0(timer0_irq),                                 // line 6: vector 22
        .irq1(timer1_irq)                                  // line 7: vector 23
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
        .irq_line(line_irq), .irq_frame(frame_irq),            // lines 0, 1: vectors 16, 17
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
