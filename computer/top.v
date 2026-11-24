// top.v: the mp32 computer on the Tang Nano 20K.
//
//   pll.v          the clocks: 126 MHz (HDMI), 25.2 MHz (pixels), 42 MHz (processor)
//   computer.v     the computer itself
//   serializer.v   the HDMI serializers (the book's), and the chip's LVDS pairs
//
// The board:
//   S1 (btn1)      held: reset. The computer starts again from the block RAM.
//   S2 (btn2)      a button the program can read (BUTTONS, bit 1)
//   6 LEDs         what the program writes to LEDS (lit when the pin is low)
//   USB-C          the serial port to the PC (the BL616), 115,200 baud 8N1
//   HDMI           640 x 480 at 60 Hz
//   microSD        in SPI mode
//   SPI flash      the 8 MB flash that holds the bitstream; read by the boot loader
//                  (pins 59 .. 62; gowin_pack --mspi_as_gpio makes them ours)
//   speaker        the MAX98357A (I2S), a 4 or 8 ohm speaker on the 2-pin header
//   SDRAM          the 8 MB inside the chip
//
// Reset: while the PLLs settle and while S1 is held, and 16 ticks after; synchronous
// to the processor's clock.
module top #(
    parameter CPU_PLL = 0                   // see pll.v
) (
    input  wire        clk,                 // the board's 27 MHz
    input  wire        btn1,
    input  wire        btn2,
    output wire [5:0]  led,
    input  wire        uart_rx,
    output wire        uart_tx,
    output wire        sd_clk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_cs_n,
    output wire        flash_clk,
    output wire        flash_mosi,
    input  wire        flash_miso,
    output wire        flash_cs_n,
    output wire        hp_bck,
    output wire        hp_ws,
    output wire        hp_din,
    output wire        pa_en,
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_d_p,
    output wire [2:0]  tmds_d_n,

    // the SDRAM inside the chip (these names are the ones its pins are wired to)
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_wen_n,
    output wire [3:0]  O_sdram_dqm,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    inout  wire [31:0] IO_sdram_dq
);
    // ================================================================ the clocks
    wire pixel_clk, fast_clk, cpu_clk, locked;

    pll #(.CPU_PLL(CPU_PLL)) clocks (
        .clk(clk), .pixel_clk(pixel_clk), .fast_clk(fast_clk), .cpu_clk(cpu_clk),
        .locked(locked)
    );

    // ================================================================ reset, buttons, serial in
    // Each through two flip-flops on cpu_clk (they change when a finger decides).
    reg [1:0] s1 = 2'b11, s2 = 2'b00, rx = 2'b11;
    reg [4:0] hold = 5'd0;
    reg       reset = 1'b1;

    always @(posedge cpu_clk) begin
        s1 <= {s1[0], btn1};
        s2 <= {s2[0], btn2};
        rx <= {rx[0], uart_rx};
        if (!locked | s1[1]) begin hold <= 5'd0; reset <= 1'b1; end
        else if (!hold[4])   begin hold <= hold + 5'd1; reset <= 1'b1; end
        else                 reset <= 1'b0;
    end

    // ================================================================ the computer
    wire [5:0] leds;
    wire [9:0] blue_code, green_code, red_code;

    computer mp32 (
        .clk(cpu_clk), .pixel_clk(pixel_clk), .reset(reset),
        .buttons({s2[1], s1[1]}), .leds(leds),
        .uart_rx(rx[1]), .uart_tx(uart_tx),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),
        .flash_clk(flash_clk), .flash_mosi(flash_mosi), .flash_miso(flash_miso),
        .flash_cs_n(flash_cs_n),
        .hp_bck(hp_bck), .hp_ws(hp_ws), .hp_din(hp_din), .pa_en(pa_en),
        .tmds_blue(blue_code), .tmds_green(green_code), .tmds_red(red_code),
        .O_sdram_clk(O_sdram_clk), .O_sdram_cke(O_sdram_cke), .O_sdram_cs_n(O_sdram_cs_n),
        .O_sdram_ras_n(O_sdram_ras_n), .O_sdram_cas_n(O_sdram_cas_n),
        .O_sdram_wen_n(O_sdram_wen_n), .O_sdram_dqm(O_sdram_dqm),
        .O_sdram_addr(O_sdram_addr), .O_sdram_ba(O_sdram_ba), .IO_sdram_dq(IO_sdram_dq),
        .pc()
    );

    assign led = ~leds;                     // an LED is lit when its pin is low

    // ================================================================ HDMI
    wire [2:0] serial;

    serializer blue_serializer (
        .pixel_clk(pixel_clk), .fast_clk(fast_clk), .reset(~locked),
        .code(blue_code), .serial(serial[0])
    );
    serializer green_serializer (
        .pixel_clk(pixel_clk), .fast_clk(fast_clk), .reset(~locked),
        .code(green_code), .serial(serial[1])
    );
    serializer red_serializer (
        .pixel_clk(pixel_clk), .fast_clk(fast_clk), .reset(~locked),
        .code(red_code), .serial(serial[2])
    );

    TLVDS_OBUF blue_pair  (.I(serial[0]), .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    TLVDS_OBUF green_pair (.I(serial[1]), .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    TLVDS_OBUF red_pair   (.I(serial[2]), .O(tmds_d_p[2]), .OB(tmds_d_n[2]));
    TLVDS_OBUF clock_pair (.I(pixel_clk), .O(tmds_clk_p),  .OB(tmds_clk_n));
endmodule
