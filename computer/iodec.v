// iodec.v: the I/O decoder of the mp32 computer. The memory system's I/O port
// (stage4/memsys.v: io_*, the range 0xFFFF_0000 - 0xFFFF_FFFF, io_addr = bits 15..0)
// goes to the device its address picks:
//
//   0xFFFF_0000 - 0xFFFF_00FF   the serial port (../uart/uart.v): +0 DATA, +4 STATUS,
//                               +8 DIV, +12 CTRL
//   0xFFFF_0100 - 0xFFFF_01FF   the microSD card (../sdcard/sdcard.v): +0 DATA,
//                               +4 DATA32, +8 CTRL
//   0xFFFF_0200 - 0xFFFF_02FF   the board, here:
//                               +0 LEDS     bits 5..0, 1 = lit (read: as written)
//                               +4 BUTTONS  read: bit 0 S1, bit 1 S2 (1 = pressed)
//                               +8 TICKS    read: the ticks of the processor's clock
//                                           since reset (counts on, 32 bits)
//   0xFFFF_0300 - 0xFFFF_03FF   the sound (../audio/audio.v): +0 DATA, +4 STATUS,
//                               +8 CTRL, +12 DIV, +16 TONE, +20 LEN, +24 BSTATUS,
//                               +28 BLEN, +32 READY
//   0xFFFF_0400 - 0xFFFF_04FF   the interrupt controller, here:
//                               +0 PENDING  read: the devices that ask (bit k = line k)
//                               +4 MASK     bit k = 1: line k may interrupt (read: as
//                                           written; after reset 0)
//                               +8 NUMBER   read: the vector the processor gets now
//                                           (16 + k), 0 if none
//                               Lines: 0 the serial port, 1 the sound. A device asks
//                               while its irq is 1, until its handler has served it
//                               (each device says how). irq = 1 while a line asks and
//                               its mask bit is 1; irq_num = 16 + the lowest such line.
//   0xFFFF_C000 - 0xFFFF_CFFF   the sound's sample memory: two banks of 1024 samples,
//                               two to a word (bank 0 at C000, bank 1 at C800)
//   0xFFFF_8000 - 0xFFFF_BFFF   the video unit (../display2/video.v), whose own
//                               addresses (18 bits) are mapped so:
//                               0xFFFF_8000 - 0x9FFF  font RAM      video 0x20000 - 0x21FFF
//                               0xFFFF_A000 - 0xAFFF  registers     video 0x30000 - 0x30FFF
//                                   (0xA020 text_base, 0xA024 pixel_base,
//                                    0xA400 - 0xA7FF the palette)
//                               0xFFFF_B000 - 0xBFFF  mode RAM      video 0x31000 - 0x31FFF
//   anything else               reads 0, writes are ignored
//
// The handshake is the cache's (see stage4/membus.v): io_sel and the rest are held
// until io_ready is 1. Each device answers on its own; the decoder only routes io_sel
// to it and its io_rdata and io_ready back. The board's registers and the addresses
// with nothing there answer in the tick after io_sel.

module iodec (
    input  wire        clk,
    input  wire        reset,          // synchronous, active high

    // ---- from the memory system
    input  wire        io_sel,
    input  wire        io_we,
    input  wire [3:0]  io_be,
    input  wire [15:0] io_addr,
    input  wire [31:0] io_wdata,
    output reg  [31:0] io_rdata,
    output reg         io_ready,

    // ---- the serial port
    output wire        uart_sel,
    input  wire [31:0] uart_rdata,
    input  wire        uart_ready,

    // ---- the microSD card
    output wire        sd_sel,
    input  wire [31:0] sd_rdata,
    input  wire        sd_ready,

    // ---- the sound
    output wire        audio_sel,
    output wire [12:0] audio_addr,     // bit 12: the sample memory
    input  wire [31:0] audio_rdata,
    input  wire        audio_ready,

    // ---- the video unit
    output wire        vid_sel,
    output wire [17:0] vid_addr,
    input  wire [31:0] vid_rdata,
    input  wire        vid_ready,

    // ---- the board
    output reg  [5:0]  leds,           // 1 = lit
    input  wire [1:0]  buttons,        // 1 = pressed (already on clk)
    // ---- the interrupt controller
    input  wire [7:0]  irq_lines,      // the devices' irq (line 0 the serial port, 1 the sound)
    output wire        irq,            // to the processor
    output reg  [7:0]  irq_num
);
    // ================================================================ which device
    wire is_uart  = (io_addr[15:8] == 8'h00);
    wire is_sd    = (io_addr[15:8] == 8'h01);
    wire is_board = (io_addr[15:8] == 8'h02) | (io_addr[15:8] == 8'h04);   // the board, the interrupt controller
    wire is_amem  = (io_addr[15:12] == 4'hC);         // 0xC000 - 0xCFFF
    wire is_audio = (io_addr[15:8] == 8'h03) | is_amem;
    wire is_font  = (io_addr[15:13] == 3'b100);       // 0x8000 - 0x9FFF
    wire is_regs  = (io_addr[15:12] == 4'hA);
    wire is_modes = (io_addr[15:12] == 4'hB);
    wire is_vid   = is_font | is_regs | is_modes;
    wire is_none  = !(is_uart | is_sd | is_board | is_audio | is_vid);

    assign uart_sel = io_sel & is_uart;
    assign sd_sel   = io_sel & is_sd;
    assign audio_sel = io_sel & is_audio;
    assign audio_addr = is_amem ? {1'b1, io_addr[11:0]} : {5'b00000, io_addr[7:0]};
    assign vid_sel  = io_sel & is_vid;
    assign vid_addr = is_font ? {5'b10000, io_addr[12:0]} :
                      is_regs ? {6'b110000, io_addr[11:0]} :
                                {6'b110001, io_addr[11:0]};

    // ================================================================ the interrupt controller
    reg  [7:0]  irq_mask;
    wire [7:0]  irq_asks = irq_lines & irq_mask;
    assign irq = |irq_asks;
    integer k;
    always @* begin
        irq_num = 8'd0;
        for (k = 7; k >= 0; k = k - 1)
            if (irq_asks[k]) irq_num = 8'd16 + k;
    end

    // ================================================================ the board
    reg  [31:0] ticks;
    reg         here_ready;            // the board's registers, and nothing: a tick
    wire        here_sel = io_sel & (is_board | is_none);

    always @(posedge clk) begin
        if (reset) begin
            leds       <= 6'h00;
            irq_mask   <= 8'h00;
            ticks      <= 32'h0;
            here_ready <= 1'b0;
        end else begin
            ticks      <= ticks + 32'd1;
            here_ready <= here_sel & !here_ready;
            if (here_sel & !here_ready & io_we & (io_addr[15:8] == 8'h02) & (io_addr[7:2] == 6'd0) & io_be[0])
                leds <= io_wdata[5:0];
            if (here_sel & !here_ready & io_we & (io_addr[15:8] == 8'h04) & (io_addr[7:2] == 6'd1) & io_be[0])
                irq_mask <= io_wdata[7:0];
        end
    end

    reg [31:0] here_rdata;
    always @*
        if (!is_board)                 here_rdata = 32'h0;
        else if (io_addr[10])          // 0xFFFF_04xx: the interrupt controller
            case (io_addr[7:2])
                6'd0:    here_rdata = {24'h0, irq_lines};
                6'd1:    here_rdata = {24'h0, irq_mask};
                6'd2:    here_rdata = {24'h0, irq_num};
                default: here_rdata = 32'h0;
            endcase
        else case (io_addr[7:2])
            6'd0:    here_rdata = {26'h0, leds};
            6'd1:    here_rdata = {30'h0, buttons};
            6'd2:    here_rdata = ticks;
            default: here_rdata = 32'h0;
        endcase

    // ================================================================ the answer
    always @* begin
        if (is_uart)      begin io_rdata = uart_rdata; io_ready = uart_ready; end
        else if (is_sd)   begin io_rdata = sd_rdata;   io_ready = sd_ready;   end
        else if (is_audio) begin io_rdata = audio_rdata; io_ready = audio_ready; end
        else if (is_vid)  begin io_rdata = vid_rdata;  io_ready = vid_ready;  end
        else              begin io_rdata = here_rdata; io_ready = here_ready; end
    end
endmodule
