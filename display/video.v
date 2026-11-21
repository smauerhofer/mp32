// video.v: a 640 x 480 video unit, text and graphics, mixed row by row.
//
//   Text:     80 x 60 characters of 8 x 8 pixels. Each character has its own two
//             colors (ink and paper) out of a palette of 16. The font is in RAM.
//   Graphics: 640 x 480 pixels, 1 bit each: 2 colors out of a palette of 2.
//
// The screen is cut into 60 rows of 8 lines, the rows of the text. Each row is
// text or graphics, as one bit of the register "row modes" says. So the top of the
// screen can be text and the rest graphics, or a status line, a picture and a
// command line, or anything else.
//
// Block memory: 19 blocks for the video RAM, 1 for the font RAM (of the chip's 46).
// Both are simple dual-port memories: one port writes, the other reads. (A true
// dual-port block, where both ports read and write, takes two of the chip's 46
// sites with the current nextpnr.)
//
// ---------------------------------------------------------------- the video RAM
// 38,912 bytes (19 blocks). Graphics and text share it.
//   graphics: 80 bytes for each line, 8 pixels in each byte, bit 7 the one on the
//             left. Pixel (x, y) is bit 7 - x%8 of byte y*80 + x/8. A graphics row
//             always shows its own lines: lines 0-479 are bytes 0 - 38,399.
//   text:     the text rows are counted from the top, skipping graphics rows:
//             the first text row on the screen is text row 0, the next is 1, and so
//             on. Text row k, column c:
//                 its character is at  text_base  + k*80 + c
//                 its colors are at    color_base + k*80 + c
//                 (the ink in the four high bits, the paper in the four low bits)
//             Put the text where the screen does not show it as graphics: in the
//             bytes of the lines its own rows cover, or in bytes 38,400 - 38,911,
//             which no line shows. Ten text rows cover 6,400 bytes of lines and
//             need only 1,600.
//
// ---------------------------------------------------------------- processor side
// A byte bus on the processor's own clock, cpu_clk, which need not have anything
// to do with the pixel clock. Addresses are 18 bits:
//
//   0x00000 - 0x097FF   video RAM, 38,912 bytes
//   0x20000 - 0x207FF   font RAM: 8 bytes for each of 256 characters, the top
//                       row first, bit 7 the pixel on the left
//   0x30010 - 0x30017   row modes: bit i of byte j is row 8*j + i (rows 0-59);
//                       1 for graphics, 0 for text
//   0x30020, 0x30021    text_base,  low byte, high byte
//   0x30022, 0x30023    color_base, low byte, high byte
//   0x30100 - 0x3013F   text palette: 16 colors, 4 bytes each: red, green, blue, unused
//   0x30200 - 0x30207   graphics palette: 2 colors, the same way (0 for the bits at 0)
//
// The handshake: the processor sets cpu_sel, cpu_we, cpu_addr and cpu_wdata and
// holds them until cpu_ready is 1. That tick ends the access; for a read, cpu_rdata
// is valid during it.
//   - a write, anywhere:                       cpu_ready at once, in the same tick
//   - a read of a register:                    cpu_ready at once, in the same tick
//   - a read of the video RAM or the font RAM: cpu_ready a few ticks later
// The two memories each have a single read port, and the display needs it. The
// display reads in 2 of the 8 ticks of every 8-pixel cell; a read of the processor
// takes one of the others. The request crosses to the pixel clock and the answer
// comes back, through two flip-flops each way.
//
// The registers live on cpu_clk. The row modes and the two bases cross to the pixel
// clock through two flip-flops; the palettes are read as they are. A register that
// changes while a frame is drawn takes effect at once, so change the layout during
// the vertical blank if you want no frame to be drawn half one way, half the other.
//
// ---------------------------------------------------------------- display side
// The same ports as the book's display.v, fed by its raster. One difference: the
// picture comes out 8 ticks after the raster, not 1, because a character needs
// three memory reads one after the other (its code, its colors, its row in the
// font). The three *_delayed outputs are delayed to match, so the encoders
// downstream need no change.

module video #(
    parameter VRAM_FILE  = "",            // optional: initial contents of the video RAM
    parameter FONT_FILE  = "font.hex",    // initial contents of the font RAM
    parameter [63:0] ROW_MODES  = 64'h0,  // initial row modes: all text
    parameter [15:0] TEXT_BASE  = 16'h0000,
    parameter [15:0] COLOR_BASE = 16'h2000
) (
    // The display, on the pixel clock
    input  wire       clk,
    input  wire [9:0] x,
    input  wire [9:0] y,
    input  wire       visible,
    input  wire       hsync,
    input  wire       vsync,
    output wire [7:0] red,
    output wire [7:0] green,
    output wire [7:0] blue,
    output wire       visible_delayed,
    output wire       hsync_delayed,
    output wire       vsync_delayed,

    // The processor, on its own clock
    input  wire        cpu_clk,
    input  wire        cpu_sel,
    input  wire        cpu_we,
    input  wire [17:0] cpu_addr,
    input  wire [7:0]  cpu_wdata,
    output wire [7:0]  cpu_rdata,
    output wire        cpu_ready
);
    localparam VRAM_BYTES = 38912;

    // ================================================================ memories
    reg [7:0] vram [0:VRAM_BYTES-1];
    reg [7:0] font [0:2047];

    initial begin
        if (VRAM_FILE != "") $readmemh(VRAM_FILE, vram);
        if (FONT_FILE != "") $readmemh(FONT_FILE, font);
    end

    // ================================================================ processor side
    wire is_vram = (cpu_addr[17:16] == 2'b00) & (cpu_addr[15:0] < VRAM_BYTES);
    wire is_font = (cpu_addr[17:16] == 2'b10);
    wire is_regs = (cpu_addr[17:16] == 2'b11);
    wire write   = cpu_sel & cpu_we;

    // ---- writes: straight into the write ports, on cpu_clk
    always @(posedge cpu_clk)
        if (write & is_vram) vram[cpu_addr[15:0]] <= cpu_wdata;

    always @(posedge cpu_clk)
        if (write & is_font) font[cpu_addr[10:0]] <= cpu_wdata;

    // ---- the registers
    reg [63:0] row_modes  = ROW_MODES;
    reg [15:0] text_base  = TEXT_BASE;
    reg [15:0] color_base = COLOR_BASE;
    reg [23:0] text_palette     [0:15];
    reg [23:0] graphics_palette [0:1];

    initial begin
        // The text palette: the 16 colors of the Commodore 64, the palette the book
        // uses, so the colors of its files mean the same here.
        text_palette[0]  = 24'h000000;  // black
        text_palette[1]  = 24'hFFFFFF;  // white
        text_palette[2]  = 24'h880000;  // red
        text_palette[3]  = 24'hAAFFEE;  // cyan
        text_palette[4]  = 24'hCC44CC;  // purple
        text_palette[5]  = 24'h00CC55;  // green
        text_palette[6]  = 24'h0000AA;  // blue
        text_palette[7]  = 24'hEEEE77;  // yellow
        text_palette[8]  = 24'hDD8855;  // orange
        text_palette[9]  = 24'h664400;  // brown
        text_palette[10] = 24'hFF7777;  // light red
        text_palette[11] = 24'h333333;  // dark gray
        text_palette[12] = 24'h777777;  // gray
        text_palette[13] = 24'hAAFF66;  // light green
        text_palette[14] = 24'h0088FF;  // light blue
        text_palette[15] = 24'hBBBBBB;  // light gray
        // The graphics palette: black for the bits at 0, light green for the bits at 1.
        graphics_palette[0] = 24'h000000;
        graphics_palette[1] = 24'hAAFF66;
    end

    wire [3:0] text_entry     = cpu_addr[5:2];
    wire       graphics_entry = cpu_addr[2];
    wire       at_rows     = is_regs & (cpu_addr[15:3] == 13'h0002);  // 0x30010 - 0x30017
    wire       at_bases    = is_regs & (cpu_addr[15:2] == 14'h0008);  // 0x30020 - 0x30023
    wire       at_text     = is_regs & (cpu_addr[15:6] == 10'h004);   // 0x30100 - 0x3013F
    wire       at_graphics = is_regs & (cpu_addr[15:3] == 13'h0040);  // 0x30200 - 0x30207

    function [23:0] put_byte(input [23:0] old, input [1:0] which_byte, input [7:0] value);
        case (which_byte)
            2'd0:    put_byte = {value, old[15:0]};
            2'd1:    put_byte = {old[23:16], value, old[7:0]};
            2'd2:    put_byte = {old[23:8], value};
            default: put_byte = old;
        endcase
    endfunction

    function [7:0] get_byte(input [23:0] color, input [1:0] which_byte);
        case (which_byte)
            2'd0:    get_byte = color[23:16];
            2'd1:    get_byte = color[15:8];
            2'd2:    get_byte = color[7:0];
            default: get_byte = 8'h00;
        endcase
    endfunction

    integer i;
    always @(posedge cpu_clk) begin
        if (write & at_rows)
            for (i = 0; i < 8; i = i + 1)
                if (cpu_addr[2:0] == i) row_modes[8*i +: 8] <= cpu_wdata;
        if (write & at_bases)
            case (cpu_addr[1:0])
                2'd0: text_base[7:0]   <= cpu_wdata;
                2'd1: text_base[15:8]  <= cpu_wdata;
                2'd2: color_base[7:0]  <= cpu_wdata;
                2'd3: color_base[15:8] <= cpu_wdata;
            endcase
        if (write & at_text)     text_palette[text_entry] <=
                                     put_byte(text_palette[text_entry], cpu_addr[1:0], cpu_wdata);
        if (write & at_graphics) graphics_palette[graphics_entry] <=
                                     put_byte(graphics_palette[graphics_entry], cpu_addr[1:0], cpu_wdata);
    end

    wire [63:0] rows_shifted = row_modes >> {cpu_addr[2:0], 3'b000};
    reg  [7:0]  bases_value;
    always @(*)
        case (cpu_addr[1:0])
            2'd0:    bases_value = text_base[7:0];
            2'd1:    bases_value = text_base[15:8];
            2'd2:    bases_value = color_base[7:0];
            default: bases_value = color_base[15:8];
        endcase

    wire [7:0] regs_value = at_rows     ? rows_shifted[7:0] :
                            at_bases    ? bases_value :
                            at_text     ? get_byte(text_palette[text_entry], cpu_addr[1:0]) :
                            at_graphics ? get_byte(graphics_palette[graphics_entry], cpu_addr[1:0]) :
                                          8'h00;

    // ---- reads of the two memories: a request crosses to the pixel clock
    // Toggle handshake: the processor side flips request; the display side, once it
    // has the byte, flips answer to match. Each crosses through two flip-flops.
    localparam IDLE = 2'd0, ASKED = 2'd1, DONE = 2'd2;
    reg  [1:0]  state = IDLE;
    reg         request = 0;            // cpu_clk
    reg  [15:0] read_address = 0;       // cpu_clk, steady while a request is open
    reg         read_font = 0;          // cpu_clk, steady while a request is open
    reg  [1:0]  answer_sync = 0;        // the answer, brought over to cpu_clk
    reg  [7:0]  read_value = 0;         // cpu_clk
    reg         answer = 0;             // clk
    reg  [7:0]  answer_value = 0;       // clk, steady once answer has flipped

    wire memory_read = cpu_sel & ~cpu_we & (is_vram | is_font);

    always @(posedge cpu_clk) begin
        answer_sync <= {answer_sync[0], answer};
        case (state)
            IDLE: if (memory_read) begin
                read_address <= is_font ? {5'b0, cpu_addr[10:0]} : cpu_addr[15:0];
                read_font    <= is_font;
                request      <= ~request;
                state        <= ASKED;
            end
            ASKED: if (answer_sync[1] == request) begin
                read_value <= answer_value;
                state      <= DONE;
            end
            default: state <= IDLE;     // DONE: cpu_ready is 1 for this one tick
        endcase
    end

    // A read of an address where nothing is answers 0 at once.
    wire nothing_there = ~(is_vram | is_font | is_regs);
    assign cpu_ready = cpu_sel & (cpu_we | is_regs | nothing_there | (state == DONE));
    assign cpu_rdata = is_regs ? regs_value : nothing_there ? 8'h00 : read_value;

    // ================================================================ display side
    // The display works in cells of 8 pixels across. During the 8 ticks of one cell
    // it fetches what that cell needs, and during the 8 ticks of the next cell it
    // shows it. Hence the delay of 8.
    //
    //   phase 0: ask the video RAM for the character (text) or the byte (graphics)
    //   phase 1: ask for the colors (text); the character or byte arrives
    //   phase 2: ask the font RAM for the character's row; the colors arrive
    //   phase 3: the row of the font arrives
    //   phase 4: ask for the processor's byte, if it wants one
    //   phase 5: the processor's byte arrives
    //   phase 7: what was fetched moves to the registers shown during the next cell

    // The registers the display uses, brought over to clk.
    reg [63:0] rows_1 = ROW_MODES,  rows_2 = ROW_MODES;
    reg [15:0] text_1 = TEXT_BASE,  text_2 = TEXT_BASE;
    reg [15:0] color_1 = COLOR_BASE, color_2 = COLOR_BASE;
    reg [1:0]  request_sync = 0;
    always @(posedge clk) begin
        rows_1  <= row_modes;  rows_2  <= rows_1;
        text_1  <= text_base;  text_2  <= text_1;
        color_1 <= color_base; color_2 <= color_1;
        request_sync <= {request_sync[0], request};
    end
    wire processor_waits = (request_sync[1] != answer);

    wire [2:0] phase  = x[2:0];
    wire [6:0] column = x[9:3];                 // 0 to 99; 0 to 79 are visible
    wire [5:0] row    = y[8:3];                 // 0 to 59 visible
    wire [2:0] line   = y[2:0];

    // Is this row graphics? Rows past 59 (in the vertical blank) are taken as text.
    wire row_graphics = (row < 6'd60) & rows_2[row];

    // How many text rows came before this one, in this frame.
    reg [5:0] text_row = 0;
    always @(posedge clk)
        if (x == 10'd799) begin
            if (y == 10'd524)                               text_row <= 0;
            else if ((line == 3'd7) & (row < 6'd60) & ~row_graphics) text_row <= text_row + 6'd1;
        end

    // text_row * 80 + column, and y * 80: multiplications by constants, a few additions.
    wire [15:0] text_place    = {text_row, 6'b0} + {text_row, 4'b0} + column;
    wire [15:0] graphics_byte = {y, 6'b0} + {y, 4'b0} + column;

    reg fetch_graphics = 0;                     // the kind of the cell being fetched
    reg show_graphics  = 0;                     // the kind of the cell being shown

    reg [15:0] vram_a_video;
    always @(*) begin
        if (phase == 3'd4)      vram_a_video = read_address;           // the processor's turn
        else if (row_graphics)  vram_a_video = graphics_byte;          // 8 pixels
        else if (phase == 3'd1) vram_a_video = color_2 + text_place;   // the colors
        else                    vram_a_video = text_2 + text_place;    // the character
    end

    reg [7:0] vram_q_video;
    always @(posedge clk) vram_q_video <= vram[vram_a_video];

    reg  [7:0]  character = 0;
    wire [10:0] font_a_video = (phase == 3'd4) ? read_address[10:0] : {character, line};
    reg  [7:0]  font_q_video;
    always @(posedge clk) font_q_video <= font[font_a_video];

    // What is fetched for the next cell, and what is shown in this one.
    reg [7:0] next_first = 0, next_colors = 0, next_row = 0;
    reg [7:0] shown_colors = 0, shown_bits = 0;
    reg       serving = 0;                      // a processor read is under way

    always @(posedge clk) begin
        case (phase)
            3'd0: fetch_graphics <= row_graphics;
            3'd1: begin character <= vram_q_video; next_first <= vram_q_video; end
            3'd2: next_colors <= vram_q_video;
            3'd3: next_row <= font_q_video;
            3'd4: serving <= processor_waits;
            3'd5: if (serving) begin
                answer_value <= read_font ? font_q_video : vram_q_video;
                answer       <= ~answer;
                serving      <= 0;
            end
            3'd7: begin
                // Graphics: the byte itself is the 8 pixels. Text: the row of the font.
                shown_bits    <= fetch_graphics ? next_first : next_row;
                shown_colors  <= next_colors;
                show_graphics <= fetch_graphics;
            end
            default: ;
        endcase
    end

    // The three signals of the raster, 8 ticks late.
    reg [7:0] visible_line = 0, hsync_line = 8'hFF, vsync_line = 8'hFF;
    always @(posedge clk) begin
        visible_line <= {visible_line[6:0], visible};
        hsync_line   <= {hsync_line[6:0],   hsync};
        vsync_line   <= {vsync_line[6:0],   vsync};
    end
    assign visible_delayed = visible_line[7];
    assign hsync_delayed   = hsync_line[7];
    assign vsync_delayed   = vsync_line[7];

    // The pixel shown now is pixel number 'phase' of the cell before.
    wire       bit_now     = shown_bits[3'd7 - phase];
    wire [3:0] text_number = bit_now ? shown_colors[7:4] : shown_colors[3:0];

    wire [23:0] color = ~visible_delayed ? 24'h000000 :
                        show_graphics    ? graphics_palette[bit_now] :
                                           text_palette[text_number];

    assign red   = color[23:16];
    assign green = color[15:8];
    assign blue  = color[7:0];
endmodule
