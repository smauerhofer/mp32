// video.v: a 640 x 480 video unit: 60 rows x 80 columns of 8 x 8 blocks, each
// block text or graphics as a bit of its own says, the text and the pixels in the
// SDRAM.
//
//   A text block:     a character. Each character is a 32-bit word:
//                         byte 0   the character's code
//                         byte 1   the font (of FONTS fonts in the font RAM)
//                         byte 2   the paper color (0 - 255)
//                         byte 3   the ink color   (0 - 255)
//   A graphics block: 8 x 8 pixels, 1 byte each: a color (0 - 255).
//
//   Both take their colors from the same palette of 256 entries of 24 bits.
//
// Which blocks are graphics: the mode RAM, 4,800 bits, one for each block: 1 for
// graphics, 0 for text. Any pattern of blocks goes: windows, frames, a picture with
// a caption cut into it, ...
//   row r, column c:   bit c%32 of word r*3 + c/32
//   (3 words a row, 180 words, 720 bytes; bits 31..16 of each row's third word are
//   not used)
//
// ---------------------------------------------------------------- the screen
// Two registers say where the text and the pixels are in the SDRAM (byte addresses,
// 0 - 0x7FFFFF, taken as multiples of 16: their low 4 bits do not count):
//
//   text:    60 rows of 80 words, 320 bytes a row (19,200 bytes in all)
//            the character of row r, column c:   text_base + r*320 + c*4
//   pixels:  480 lines of 640 bytes (307,200 bytes in all)
//            pixel (x, y):                       pixel_base + y*640 + x
//            (row r has lines 8r - 8r+7)
//
// Every block has both its character and its pixels, whatever it shows: the places
// count up the same whatever the mode RAM says, so changing it moves nothing.
//
// The SDRAM must have what the processor wrote, not the cache only: text and pixels
// must be in the cache's write-through region (0x780000 - 0x7FFFFF by default,
// 512 KB). The default bases are 0x780000 (text) and 0x790000 (pixels).
//
// ---------------------------------------------------------------- the fetch
// Block memory of 512 words of 32 bits, in two halves, one for the even and one for
// the odd lines and rows. Each half has a line of pixels (160 words) and a row of
// text (80 words). While the display draws from one half, the other is filled for
// what comes next: at the start of each line (x = 0) the display asks for the line
// after it.
//   - its row's text (320 bytes), if it is the first line of a row and the row has
//     a block of text
//   - its pixels (640 bytes), if its row has a block of graphics
// The display knows a row's 80 bits before it needs them: in the horizontal blank
// of line 6 of each row it reads the next row's 3 words from the mode RAM (row 0's
// in the blank of line 523), and takes them up at the end of line 7.
// Both come as row bursts of the SDRAM controller: the row of the SDRAM is opened
// once and a 32-bit word comes in every tick. A burst stays in one kilobyte of the
// SDRAM, so 320 or 640 bytes take one or two bursts. At 100 MHz a line's pixels
// take about 180 ticks, its text about 100, of the 3,175 ticks of a line (31.75 us).
//
// ---------------------------------------------------------------- processor side
// A 32-bit bus on the processor's clock, cpu_clk, which is also the clock of the
// cache and the SDRAM. Addresses are 18 bits, byte addresses of words: bits 1..0 do
// not count. cpu_be has a bit for each byte of the word, bit 0 for bits 7..0 (the
// byte at address 4n, little-endian); a write writes the bytes whose bits are 1, a
// read returns the whole word.
//
//   0x20000 -           font RAM: FONTS fonts of 2,048 bytes (0x20000 + 2048*f
//                       for font f): 8 bytes for each of 256 characters, the top
//                       row first, bit 7 the pixel on the left. A word holds 4 rows:
//                       the top row of a character in bits 7..0 of its first word.
//   0x30020             text_base   (bits 31..23 are kept but do not count)
//   0x30024             pixel_base
//   0x30400 - 0x307FF   palette: 256 words, 0x00BBGGRR: red in bits 7..0, green in
//                       15..8, blue in 23..16. Write only (reads give 0: the display
//                       reads the palette in every tick).
//   0x31000 - 0x312CF   mode RAM: 3 words for each of the 60 rows: the word at
//                       0x31000 + r*12 + 4*j holds columns 32*j - 32*j+31 of row r
//                       (bit i is column 32*j + i): 1 graphics, 0 text
//
// The handshake: the processor sets cpu_sel, cpu_we, cpu_be, cpu_addr and cpu_wdata
// and holds them until cpu_ready is 1. That tick ends the access; for a read,
// cpu_rdata is valid during it.
//   - a write, anywhere:                       cpu_ready at once, in the same tick
//   - a read of a register:                    cpu_ready at once, in the same tick
//   - a read of the font RAM or the mode RAM:  cpu_ready a few ticks later
// The two RAMs have a single read port each, and the display needs them. The
// display reads the font in 1 of the 8 ticks of every 8-pixel cell; a read of the
// processor takes another. The request crosses to the pixel clock and the answer
// comes back, through two flip-flops each way.
//
// The registers live on cpu_clk. A base that changes while a frame is drawn takes
// effect at once; a change of the mode RAM shows from the next row the display has
// not read yet. So change the layout during the vertical blank if you want no frame
// to be drawn half one way, half the other.
//
// ---------------------------------------------------------------- the SDRAM side
// mem_req, mem_addr, mem_count, mem_word, mem_valid and mem_ack, on cpu_clk, go to
// the cache's video port and through it to the SDRAM controller, which serves them
// ahead of the cache (see sdram.v, "the row burst"). mem_req, mem_addr and mem_count
// are held until mem_ack; a word comes in each tick mem_valid is 1, mem_ack with the
// last one.
//
// ---------------------------------------------------------------- display side
// The same ports as the book's display.v, fed by its raster. The picture comes out
// 9 ticks after the raster: 8 for the reads of a cell (the cell is fetched during
// one cell and shown during the next) and 1 for the palette. The three *_delayed
// outputs are delayed to match, so the encoders downstream need no change.
//
// Block memory: 1 block for the line buffer, 1 for the palette, 1 for the mode RAM,
// 1 for each font. The files that fill them at the start hold words, one a line, in
// hex: fonts (512 words a font), palette (256 words, 00BBGGRR), modes (180 words).

module video #(
    parameter FONT_BITS    = 2,              // FONTS = 2^FONT_BITS fonts, at most 16
    parameter FONT_FILE    = "fonts.hex",    // initial contents of the font RAM
    parameter PALETTE_FILE = "palette.hex",  // initial palette: 256 words, 00BBGGRR
    parameter MODE_FILE    = "",             // initial mode RAM: 180 words; "": all text
    parameter [31:0] TEXT_BASE   = 32'h780000,  // initial text_base
    parameter [31:0] PIXEL_BASE  = 32'h790000   // initial pixel_base
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
    input  wire [3:0]  cpu_be,
    input  wire [17:0] cpu_addr,
    input  wire [31:0] cpu_wdata,
    output wire [31:0] cpu_rdata,
    output wire        cpu_ready,

    // The SDRAM, through the cache's video port, on cpu_clk
    output reg          mem_req,
    output wire [22:4]  mem_addr,
    output wire [6:0]   mem_count,
    input  wire [31:0]  mem_word,
    input  wire         mem_valid,
    input  wire         mem_ack
);
    localparam FONT_BYTES = 2048 << FONT_BITS;
    localparam FW         = 9 + FONT_BITS;      // word address bits of the font RAM

    // ================================================================ memories
    // The four written by the processor are words, written a byte at a time where
    // cpu_be says so (one block each, with the block's byte enables).
    reg [31:0] linebuf [0:511];     // {half, word}: words 0-159 pixels, 160-239 text
    reg [31:0] font    [0:(FONT_BYTES/4)-1];
    reg [31:0] palette [0:255];     // 0x00BBGGRR
    reg [31:0] modes   [0:255];     // 180 used: 3 words a row

    integer m;
    initial begin
        for (m = 0; m < 256; m = m + 1) modes[m] = 32'h0;
        if (MODE_FILE != "")    $readmemh(MODE_FILE, modes, 0, 179);
        if (FONT_FILE != "")    $readmemh(FONT_FILE, font);
        if (PALETTE_FILE != "") $readmemh(PALETTE_FILE, palette);
    end

    // ================================================================ processor side
    wire is_font = (cpu_addr[17:16] == 2'b10) & (cpu_addr[15:0] < FONT_BYTES);
    wire is_mode = (cpu_addr[17:12] == 6'h31)  & (cpu_addr[11:0] < 12'd720);
    wire is_regs = (cpu_addr[17:12] == 6'h30);                   // 0x30000 - 0x30FFF
    wire write   = cpu_sel & cpu_we;

    wire at_bases   = is_regs & (cpu_addr[15:3]  == 13'h0004);   // 0x30020, 0x30024
    wire at_palette = is_regs & (cpu_addr[15:10] == 6'b000001);  // 0x30400 - 0x307FF

    // ---- writes: straight into the write ports, on cpu_clk, a byte where cpu_be is 1
    integer i;
    always @(posedge cpu_clk)
        for (i = 0; i < 4; i = i + 1)
            if (write & is_font & cpu_be[i])
                font[cpu_addr[FW+1:2]][8*i +: 8] <= cpu_wdata[8*i +: 8];

    always @(posedge cpu_clk)
        for (i = 0; i < 4; i = i + 1)
            if (write & is_mode & cpu_be[i])
                modes[cpu_addr[9:2]][8*i +: 8] <= cpu_wdata[8*i +: 8];

    always @(posedge cpu_clk)
        for (i = 0; i < 4; i = i + 1)
            if (write & at_palette & cpu_be[i])
                palette[cpu_addr[9:2]][8*i +: 8] <= cpu_wdata[8*i +: 8];

    // ---- the registers
    reg [31:0] text_base   = TEXT_BASE;
    reg [31:0] pixel_base  = PIXEL_BASE;

    always @(posedge cpu_clk)
        for (i = 0; i < 4; i = i + 1)
            if (write & at_bases & cpu_be[i]) begin
                if (cpu_addr[2]) pixel_base[8*i +: 8] <= cpu_wdata[8*i +: 8];
                else             text_base[8*i +: 8]  <= cpu_wdata[8*i +: 8];
            end

    wire [31:0] regs_value = at_bases ? (cpu_addr[2] ? pixel_base : text_base) : 32'h0;

    // ---- reads of the font RAM and the mode RAM: a request crosses to the pixel clock
    // Toggle handshake: the processor side flips request; the display side, once it
    // has the word, flips answer to match. Each crosses through two flip-flops.
    localparam IDLE = 2'd0, ASKED = 2'd1, DONE = 2'd2;
    reg  [1:0]    state = IDLE;
    reg           request = 0;          // cpu_clk
    reg  [FW-1:0] read_address = 0;     // cpu_clk, a word address, steady while asked
    reg           read_mode = 0;        // cpu_clk, the same: the mode RAM, not the font
    reg  [1:0]    answer_sync = 0;      // the answer, brought over to cpu_clk
    reg  [31:0]   read_value = 0;       // cpu_clk
    reg           answer = 0;           // clk
    reg  [31:0]   answer_value = 0;     // clk, steady once answer has flipped

    wire ram_read = cpu_sel & ~cpu_we & (is_font | is_mode);

    always @(posedge cpu_clk) begin
        answer_sync <= {answer_sync[0], answer};
        case (state)
            IDLE: if (ram_read) begin
                read_address <= is_mode ? {{(FW-8){1'b0}}, cpu_addr[9:2]} : cpu_addr[FW+1:2];
                read_mode    <= is_mode;
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
    wire nothing_there = ~(is_font | is_mode | is_regs);
    assign cpu_ready = cpu_sel & (cpu_we | is_regs | nothing_there | (state == DONE));
    assign cpu_rdata = is_regs ? regs_value : nothing_there ? 32'h0 : read_value;

    // ================================================================ the fetch
    // On cpu_clk. The display hands over a job at the start of each line: the line
    // that comes next, and whether it needs its row's text, its pixels or both. The
    // job's fields are steady for a whole line after job_toggle flips, so only
    // job_toggle needs the two flip-flops.
    reg       job_toggle = 0;           // clk
    reg       job_text   = 0;           // clk: the row's text
    reg       job_pixels = 0;           // clk: the line's pixels
    reg [8:0] job_y      = 0;           // clk: the line

    reg  [1:0]  job_sync = 0;           // cpu_clk
    reg         job_seen = 0;
    reg         busy     = 0;
    reg         f_pixels = 0;           // the pixels are still to come after the text
    reg  [8:0]  f_y      = 0;
    reg  [22:4] f_addr   = 0;           // the next unit of 16 bytes to ask for
    reg  [6:0]  f_left   = 0;           // units still to ask for
    reg  [8:0]  f_write  = 0;           // where the next word goes in the buffer

    // Where things start, in units of 16 bytes:
    //   the text of row r:   text_base  + r*20     (320 bytes a row)
    //   the pixels of line y: pixel_base + y*40     (640 bytes a line)
    wire [5:0]  job_row     = job_y[8:3];
    wire [22:4] text_start  = text_base[22:4]  + {job_row, 4'b0} + {job_row, 2'b0};
    wire [22:4] pixel_start = pixel_base[22:4] + {f_y, 5'b0} + {f_y, 3'b0};

    // A burst stays in its kilobyte: at most the units up to its end.
    wire [6:0]  room = 7'd64 - {1'b0, f_addr[9:4]};
    assign mem_addr  = f_addr;
    assign mem_count = (f_left < room) ? f_left : room;

    initial mem_req = 0;

    always @(posedge cpu_clk) begin
        job_sync <= {job_sync[0], job_toggle};

        if (mem_valid) f_write <= f_write + 9'd1;

        if (!busy) begin
            if (job_sync[1] != job_seen) begin
                job_seen <= job_sync[1];
                busy     <= 1;
                mem_req  <= 1;
                f_y      <= job_y;
                if (job_text) begin                 // the text first
                    f_pixels <= job_pixels;
                    f_addr   <= text_start;
                    f_left   <= 7'd20;
                    f_write  <= {job_row[0], 8'd160};
                end else begin                      // the pixels only
                    f_pixels <= 0;
                    f_addr   <= pixel_base[22:4] + {job_y, 5'b0} + {job_y, 3'b0};
                    f_left   <= 7'd40;
                    f_write  <= {job_y[0], 8'd0};
                end
            end
        end else if (mem_ack) begin
            if (f_left != mem_count) begin          // the rest of this part
                f_addr <= f_addr + mem_count;
                f_left <= f_left - mem_count;
            end else if (f_pixels) begin            // the text is in; now the pixels
                f_pixels <= 0;
                f_addr   <= pixel_start;
                f_left   <= 7'd40;
                f_write  <= {f_y[0], 8'd0};
            end else begin                          // the job is done
                busy    <= 0;
                mem_req <= 0;
            end
        end
    end

    always @(posedge cpu_clk)
        if (mem_valid) linebuf[f_write] <= mem_word;

    // ================================================================ display side
    // The display works in cells of 8 pixels across. During the 8 ticks of one cell
    // it fetches what that cell needs, and during the 8 ticks of the next cell it
    // shows it, one pixel a tick through the palette.
    //
    //   phase 0: ask the line buffer for pixels 0-3 (graphics) or the character (text)
    //   phase 1: ask for pixels 4-7 (graphics); pixels 0-3 or the character arrive
    //   phase 2: ask the font RAM for the character's row; pixels 4-7 arrive
    //   phase 3: the row of the font arrives
    //   phase 4: ask for the processor's byte of the font, if it wants one
    //   phase 5: the processor's byte arrives
    //   phase 7: what was fetched moves to the registers shown during the next cell

    reg [1:0]  request_sync = 0;
    always @(posedge clk) request_sync <= {request_sync[0], request};
    wire processor_waits = (request_sync[1] != answer);

    wire [2:0] phase  = x[2:0];
    wire [6:0] column = x[9:3];                 // 0 to 99; 0 to 79 are visible
    wire [5:0] row    = y[8:3];                 // 0 to 59 visible
    wire [2:0] line   = y[2:0];

    // ---- the bits of the rows, out of the mode RAM
    // In the horizontal blank of line 6 of a row (reads at x = 720 - 722), the 3 words
    // of the next row go into next_bits; at the end of line 7 they become row_bits,
    // the bits of the row now drawn. Row 0's are read in line 523 and taken up after
    // line 524. The mode RAM's read port is the processor's in phase 4 of every cell;
    // x = 720 - 722 are phases 0 - 2.
    reg  [79:0] next_bits = 0, row_bits = 0;
    wire        reading   = ((line == 3'd6) & (row < 6'd60)) | (y == 10'd523);
    wire [5:0]  bits_row  = (y == 10'd523) ? 6'd0 : row + 6'd1;
    wire        cpu_turn  = (phase == 3'd4);
    wire [1:0]  bits_word = x[1:0];                  // x = 720, 721, 722: words 0, 1, 2
    wire [7:0]  modes_a   = cpu_turn ? read_address[7:0]
                                     : {1'b0, bits_row, 1'b0} + {2'b0, bits_row} + bits_word;
    reg  [31:0] modes_q;
    always @(posedge clk) modes_q <= modes[modes_a];

    always @(posedge clk) begin
        if (reading) case (x)
            10'd721: next_bits[31:0]  <= modes_q;     // read at x = 720
            10'd722: next_bits[63:32] <= modes_q;
            10'd723: next_bits[79:64] <= modes_q[15:0];
            default: ;
        endcase
        if (x == 10'd799 && (((line == 3'd7) && (row < 6'd60)) || y == 10'd524))
            row_bits <= next_bits;
    end

    // Is this cell graphics? Rows past 59 and columns past 79 (the blanks) are text.
    wire cell_graphics = (row < 6'd60) & (column < 7'd80) & row_bits[column];

    // ---- the job for the next line, handed over at x = 0
    // Its row is the next one if it starts a row (its bits are in next_bits), else
    // this one (row_bits).
    wire [9:0]  next_y      = (y == 10'd524) ? 10'd0 : y + 10'd1;
    wire [79:0] next_row    = (next_y[2:0] == 3'd0) ? next_bits : row_bits;
    wire        next_pixels = |next_row;
    wire        next_text   = (next_y[2:0] == 3'd0) & ~(&next_row);

    always @(posedge clk)
        if (x == 10'd0 && next_y < 10'd480 && (next_pixels || next_text)) begin
            job_text   <= next_text;
            job_pixels <= next_pixels;
            job_y      <= next_y[8:0];
            job_toggle <= ~job_toggle;
        end

    // ---- reading the line buffer and the font
    // A line of pixels is in the half of its line, a row of text in the half of its row.
    wire [8:0] buf_a = cell_graphics ? {y[0],   column, phase == 3'd1}
                                     : {row[0], 8'd160 + {1'b0, column}};
    reg  [31:0] buf_q;
    always @(posedge clk) buf_q <= linebuf[buf_a];

    reg  [31:0]   char_word = 0;                     // the character's word
    // A word of the font holds 4 rows of a character: the row of 'line' is its byte
    // line[1:0].
    wire [FW-1:0] font_a_video = (phase == 3'd4) ? read_address
                                                 : {char_word[8 +: FONT_BITS], char_word[7:0], line[2]};
    reg  [31:0]   font_q_video;
    always @(posedge clk) font_q_video <= font[font_a_video];
    wire [31:0]   font_shifted = font_q_video >> {line[1:0], 3'b000};

    // What is fetched for the next cell, and what is shown in this one.
    reg        fetch_graphics = 0, show_graphics = 0;
    reg [31:0] next_left = 0, next_right = 0;     // pixels 0-3, 4-7
    reg [7:0]  next_font_row = 0;
    reg [63:0] shown_pixels = 0;                  // graphics: pixel p in byte p
    reg [7:0]  shown_bits = 0, shown_paper = 0, shown_ink = 0;
    reg        serving = 0;                       // a processor read is under way

    always @(posedge clk) begin
        case (phase)
            3'd0: fetch_graphics <= cell_graphics;
            3'd1: begin char_word <= buf_q; next_left <= buf_q; end
            3'd2: next_right <= buf_q;
            3'd3: next_font_row <= font_shifted[7:0];
            3'd4: serving <= processor_waits & cpu_turn;
            3'd5: if (serving) begin
                answer_value <= read_mode ? modes_q : font_q_video;
                answer       <= ~answer;
                serving      <= 0;
            end
            3'd7: begin
                shown_pixels  <= {next_right, next_left};
                shown_bits    <= next_font_row;
                shown_paper   <= char_word[23:16];
                shown_ink     <= char_word[31:24];
                show_graphics <= fetch_graphics;
            end
            default: ;
        endcase
    end

    // The pixel of this tick is pixel number 'phase' of the cell before: its color
    // number now, its color out of the palette one tick later.
    wire [63:0] pixels_shifted = shown_pixels >> {phase, 3'b000};
    wire        bit_now        = shown_bits[3'd7 - phase];
    wire [7:0]  number         = show_graphics ? pixels_shifted[7:0] :
                                 bit_now       ? shown_ink : shown_paper;
    reg  [31:0] color;                            // 0x00BBGGRR
    always @(posedge clk) color <= palette[number];

    // The three signals of the raster, 9 ticks late.
    reg [8:0] visible_line = 0, hsync_line = 9'h1FF, vsync_line = 9'h1FF;
    always @(posedge clk) begin
        visible_line <= {visible_line[7:0], visible};
        hsync_line   <= {hsync_line[7:0],   hsync};
        vsync_line   <= {vsync_line[7:0],   vsync};
    end
    assign visible_delayed = visible_line[8];
    assign hsync_delayed   = hsync_line[8];
    assign vsync_delayed   = vsync_line[8];

    assign red   = visible_delayed ? color[7:0]   : 8'h00;
    assign green = visible_delayed ? color[15:8]  : 8'h00;
    assign blue  = visible_delayed ? color[23:16] : 8'h00;
endmodule
