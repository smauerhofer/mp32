// video_tb.v: tests video.v together with the cache and the SDRAM it reads from.
//
//   make test                  (see the makefile; at 100 MHz)
//   make test-clocks           at 54 and 100 MHz
//
// The circuit: the video unit, the cache (../cache/cache.v) with its SDRAM controller
// (../cache/sdram.v), and the model of the SDRAM (../cache/sdram_model.v), which
// checks every timing of the chip. The processor's clock, clk, is also the clock of
// the cache and the SDRAM; the pixel clock is unrelated.
//
// The SDRAM starts with text.hex at 0x780000 and pixels.hex at 0x790000, the mode
// RAM with modes.hex (the demo, see tools/make_demo.py). The test:
//   1. The video unit's bus (32 bits, byte enables): writes and reads back the font
//      RAM, the mode RAM and the registers, whole words and single bytes.
//   2. The processor writes a few characters through the cache (write-through), in
//      a glyph of its own in font 3.
//   3. Frames, each checked pixel by pixel against a model, and written to a BMP:
//        mixed.bmp     the demo: row 0 text; rows 1-49 graphics in columns 0-59 with
//                      a caption of text cut in, a text window in columns 60-79;
//                      rows 50-59 text with a small picture of graphics
//        text.bmp      all text (mode RAM all 0)
//        graphics.bmp  all graphics (all 1: no text is fetched), with a box
//                      the processor drew through the cache; while it is drawn, the
//                      processor reads and writes at random all the time (the cache
//                      against the video's bursts)
//        shape.bmp     graphics in a disc of blocks and a checkerboard, in text, with
//                      64 entries of the palette changed
//        scrolled.bmp  the demo with pixel_base 5 lines (3,200 bytes) and text_base
//                      2 rows (640 bytes) on
//   4. That nothing but black comes out where the raster says "not visible".
//   5. The SDRAM model's count of timing errors, which must be 0.
// It also reports how long the longest fetch of a line took, against the time it
// has (a whole line), and the longest wait of the processor.

`timescale 1ns / 1ps

module video_tb;
    parameter CLK_MHZ = 100;

    // ------------------------------------------------------------ clocks
    reg pclk = 0;  always #19.84 pclk = ~pclk;              // 25.2 MHz
    reg clk  = 0;  always #(500.0 / CLK_MHZ) clk = ~clk;    // processor, cache, SDRAM

    // ------------------------------------------------------------ a raster
    // 640 x 480 at 60 Hz: 800 positions per line, 525 lines, syncs active low.
    reg [9:0] x = 0, y = 0;
    always @(posedge pclk) begin
        if (x == 799) begin
            x <= 0;
            y <= (y == 524) ? 10'd0 : y + 10'd1;
        end else
            x <= x + 10'd1;
    end
    wire visible = (x < 640) && (y < 480);
    wire hsync   = ~((x >= 656) && (x < 752));
    wire vsync   = ~((y >= 490) && (y < 492));

    // ------------------------------------------------------------ the circuit
    localparam [22:0] WINDOW     = 23'h780000;      // the 512 KB the model follows
    localparam [31:0] TEXT_AT    = 32'h780000;
    localparam [31:0] PIXELS_AT  = 32'h790000;
    localparam        DELAY     = 9;                // the picture's ticks behind the raster

    reg         reset = 1;

    // the video unit's bus
    reg         v_sel = 0, v_we = 0;
    reg  [3:0]  v_be = 0;
    reg  [17:0] v_addr = 0;
    reg  [31:0] v_wdata = 0;
    wire [31:0] v_rdata;
    wire        v_ready;

    // the cache's bus
    reg         c_sel = 0, c_we = 0;
    reg  [3:0]  c_be = 0;
    reg  [22:0] c_addr = 0;
    reg  [31:0] c_wdata = 0;
    wire [31:0] c_rdata;
    wire        c_ready;

    // the video's port into the cache
    wire         vid_req, vid_valid, vid_ack;
    wire [22:4]  vid_addr;
    wire [6:0]   vid_count;
    wire [31:0]  vid_word;

    wire [7:0]  red, green, blue;
    wire        visible_delayed, hsync_delayed, vsync_delayed;

    wire        sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_wen_n;
    wire [3:0]  sd_dqm;
    wire [10:0] sd_addr;
    wire [1:0]  sd_ba;
    wire [31:0] sd_dq;

    video #(.FONT_FILE("fonts.hex"), .PALETTE_FILE("palette.hex"),
            .MODE_FILE("modes.hex"),
            .TEXT_BASE(TEXT_AT), .PIXEL_BASE(PIXELS_AT)) dut (
        .clk(pclk), .x(x), .y(y), .visible(visible), .hsync(hsync), .vsync(vsync),
        .red(red), .green(green), .blue(blue),
        .visible_delayed(visible_delayed), .hsync_delayed(hsync_delayed),
        .vsync_delayed(vsync_delayed),
        .cpu_clk(clk), .cpu_sel(v_sel), .cpu_we(v_we), .cpu_be(v_be),
        .cpu_addr(v_addr), .cpu_wdata(v_wdata), .cpu_rdata(v_rdata), .cpu_ready(v_ready),
        .mem_req(vid_req), .mem_addr(vid_addr), .mem_count(vid_count),
        .mem_word(vid_word), .mem_valid(vid_valid), .mem_ack(vid_ack)
    );

    cache #(.CLK_MHZ(CLK_MHZ)) memory (
        .clk(clk), .clk_sdram(1'b0), .reset(reset),
        .cpu_sel(c_sel), .cpu_we(c_we), .cpu_be(c_be), .cpu_addr(c_addr),
        .cpu_wdata(c_wdata), .cpu_rdata(c_rdata), .cpu_ready(c_ready),
        .vid_req(vid_req), .vid_addr(vid_addr), .vid_count(vid_count),
        .vid_word(vid_word), .vid_valid(vid_valid), .vid_ack(vid_ack),
        .O_sdram_clk(sd_clk), .O_sdram_cke(sd_cke), .O_sdram_cs_n(sd_cs_n),
        .O_sdram_ras_n(sd_ras_n), .O_sdram_cas_n(sd_cas_n), .O_sdram_wen_n(sd_wen_n),
        .O_sdram_dqm(sd_dqm), .O_sdram_addr(sd_addr), .O_sdram_ba(sd_ba),
        .IO_sdram_dq(sd_dq)
    );

    sdram_model chip (
        .clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
        .we_n(sd_wen_n), .dqm(sd_dqm), .addr(sd_addr), .ba(sd_ba), .dq(sd_dq)
    );

    // ------------------------------------------------------------ the model
    // Its own copies of the 512 KB window, the fonts, the palette and the registers,
    // kept up to date by every write this test bench makes. It shares nothing with
    // the circuit.
    reg [7:0]  m_vid  [0:524287];           // bytes 0x780000 - 0x7FFFFF
    reg [7:0]  m_font [0:8191];             // bytes
    reg [31:0] m_pal  [0:255];              // 0x00BBGGRR
    reg [31:0] m_mode [0:179];
    reg [31:0] demo_modes [0:179];
    reg [31:0] font_words [0:2047];
    reg [31:0] m_text_base, m_pixel_base;
    integer    errors = 0;

    // The model of the SDRAM keeps words at {bank, row, column}.
    function [20:0] chip_index(input [22:0] a);
        chip_index = {a[11:10], a[22:12], a[9:2]};
    endfunction

    integer n;
    reg [7:0] demo_text   [0:19199];
    reg [7:0] demo_pixels [0:307199];
    initial begin
        for (n = 0; n < 524288; n = n + 1) m_vid[n] = 8'h00;
        $readmemh("text.hex", demo_text);
        $readmemh("pixels.hex", demo_pixels);
        for (n = 0; n < 19200; n = n + 1)  m_vid[TEXT_AT - WINDOW + n]   = demo_text[n];
        for (n = 0; n < 307200; n = n + 1) m_vid[PIXELS_AT - WINDOW + n] = demo_pixels[n];
        // the SDRAM: the whole window, 4 bytes to a word, little-endian
        for (n = 0; n < 524288; n = n + 4)
            chip.mem[chip_index(WINDOW + n)] =
                {m_vid[n + 3], m_vid[n + 2], m_vid[n + 1], m_vid[n]};
        $readmemh("fonts.hex", font_words);
        for (n = 0; n < 8192; n = n + 1) m_font[n] = font_words[n / 4] >> (8 * (n % 4));
        $readmemh("palette.hex", m_pal);
        $readmemh("modes.hex", demo_modes);
        for (n = 0; n < 180; n = n + 1) m_mode[n] = demo_modes[n];
        m_text_base  = TEXT_AT;
        m_pixel_base = PIXELS_AT;
    end

    // A byte of the window, from a byte address in the SDRAM.
    function [7:0] vid_byte(input [31:0] a);
        vid_byte = m_vid[a[18:0]];
    endfunction

    function [23:0] rgb(input [31:0] w);           // 0x00BBGGRR to RRGGBB
        rgb = {w[7:0], w[15:8], w[23:16]};
    endfunction

    function [23:0] expected(input integer px, input integer py);
        integer r, a;
        reg [7:0] code, font, paper, ink, g;
        reg [31:0] mw;
        begin
            r  = py / 8;
            mw = m_mode[r * 3 + px / 256];
            if (mw[(px / 8) % 32])
                expected = rgb(m_pal[vid_byte({m_pixel_base[31:4], 4'h0} + py * 640 + px)]);
            else begin
                a     = {m_text_base[31:4], 4'h0} + r * 320 + (px / 8) * 4;
                code  = vid_byte(a);
                font  = vid_byte(a + 1);
                paper = vid_byte(a + 2);
                ink   = vid_byte(a + 3);
                g     = m_font[font[1:0] * 2048 + code * 8 + py % 8];
                expected = rgb(g[7 - px % 8] ? m_pal[ink] : m_pal[paper]);
            end
        end
    endfunction

    // ------------------------------------------------------------ the video unit's bus
    function [31:0] lanes(input [3:0] be);
        lanes = {{8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}};
    endfunction

    task v_write(input [17:0] a, input [3:0] be, input [31:0] d);
        integer k;
        begin
            @(negedge clk);
            v_addr = a; v_be = be; v_wdata = d; v_sel = 1; v_we = 1;
            @(negedge clk);
            while (!v_ready) @(negedge clk);
            v_sel = 0; v_we = 0;
            // keep the model in step
            if (a[17:16] == 2'b10 && a[15:0] < 8192) begin
                for (k = 0; k < 4; k = k + 1)
                    if (be[k]) m_font[{a[12:2], 2'b00} + k] = d[8 * k +: 8];
            end
            else if (a[17:12] == 6'h31 && a[11:0] < 720)
                m_mode[a[9:2]] = (m_mode[a[9:2]] & ~lanes(be)) | (d & lanes(be));
            else if (a[17:2] == 16'hC008) m_text_base  = (m_text_base  & ~lanes(be)) | (d & lanes(be));
            else if (a[17:2] == 16'hC009) m_pixel_base = (m_pixel_base & ~lanes(be)) | (d & lanes(be));
            else if (a[17:10] == 8'hC1)
                m_pal[a[9:2]] = (m_pal[a[9:2]] & ~lanes(be)) | (d & lanes(be));
        end
    endtask

    integer ticks, longest_read = 0;
    task v_check(input [17:0] a, input [31:0] want);
        begin
            @(negedge clk);
            v_addr = a; v_be = 4'b0000; v_sel = 1; v_we = 0;
            ticks = 1;
            @(negedge clk);
            while (!v_ready) begin @(negedge clk); ticks = ticks + 1; end
            v_sel = 0;
            if (ticks > longest_read) longest_read = ticks;
            if (v_rdata !== want) begin
                $display("FAIL: video bus read %05h gave %08h, expected %08h", a, v_rdata, want);
                errors = errors + 1;
            end
        end
    endtask

    // The mode RAM, all 180 words, by a rule:
    //   0: all text   1: all graphics   2: the demo
    //   3: a disc of blocks (center row 30, column 40, radius 22) and a checkerboard
    //      in rows 2 - 9, columns 2 - 77
    function mode_of(input integer rule, input integer r, input integer c);
        reg [31:0] dw;
        begin
            dw = demo_modes[r * 3 + c / 32];
            case (rule)
                0: mode_of = 0;
                1: mode_of = 1;
                2: mode_of = dw[c % 32];
                default: mode_of = ((r - 30) * (r - 30) + (c - 40) * (c - 40) / 4 < 22 * 22 / 4)
                                    || (r >= 2 && r < 10 && c >= 2 && c < 78 && ((r + c) % 2));
            endcase
        end
    endfunction

    task set_modes(input integer rule);
        integer r, j, k;
        reg [31:0] v;
        for (r = 0; r < 60; r = r + 1)
            for (j = 0; j < 3; j = j + 1) begin
                for (k = 0; k < 32; k = k + 1)
                    v[k] = (32 * j + k < 80) ? mode_of(rule, r, 32 * j + k) : 1'b0;
                v_write(18'h31000 + r * 12 + j * 4, 4'b1111, v);
            end
    endtask

    task set_bases(input [31:0] text_at, input [31:0] pixels_at);
        begin
            v_write(18'h30020, 4'b1111, text_at);
            v_write(18'h30024, 4'b1111, pixels_at);
        end
    endtask

    task set_color(input [7:0] number, input [23:0] rgb);
        begin
            v_write(18'h30400 + 4 * number, 4'b1111, {8'h00, rgb[7:0], rgb[15:8], rgb[23:16]});
        end
    endtask

    // ------------------------------------------------------------ the cache's bus
    integer c_ticks, c_longest = 0, c_accesses = 0;

    task c_access(input we, input [22:0] a, input [3:0] be, input [31:0] wd,
                  output [31:0] rd);
        begin
            c_sel   <= 1;
            c_we    <= we;
            c_addr  <= a;
            c_be    <= be;
            c_wdata <= wd;
            c_ticks = 1;
            @(posedge clk);
            while (!c_ready) begin @(posedge clk); c_ticks = c_ticks + 1; end
            rd = c_rdata;
            c_sel <= 0;
            c_accesses = c_accesses + 1;
            if (c_ticks > c_longest) c_longest = c_ticks;
        end
    endtask

    // A word into the window, through the cache.
    task c_write_word(input [22:0] a, input [31:0] d);
        reg [31:0] dummy;
        begin
            c_access(1, a, 4'b1111, d, dummy);
            if (a[22:19] == WINDOW[22:19]) begin
                m_vid[{a[18:2], 2'd0}]     = d[7:0];
                m_vid[{a[18:2], 2'd0} + 1] = d[15:8];
                m_vid[{a[18:2], 2'd0} + 2] = d[23:16];
                m_vid[{a[18:2], 2'd0} + 3] = d[31:24];
            end
        end
    endtask

    // ---- what the processor's own memory (0x000000 - 0x00FFFF) should hold
    reg [31:0] ref_word  [0:16383];
    reg        ref_known [0:16383];

    task c_random;
        reg [31:0] got, wd;
        reg [13:0] w;
        reg [18:0] v;
        begin
            case ($urandom % 4)
            0: begin                                   // write a word of its own
                w = $urandom; wd = $urandom;
                c_access(1, {w, 2'b00}, 4'b1111, wd, got);
                ref_word[w] = wd; ref_known[w] = 1;
            end
            1: begin                                   // read a word of its own
                w = $urandom;
                c_access(0, {w, 2'b00}, 4'b0000, 0, got);
                if (ref_known[w] && got !== ref_word[w]) begin
                    $display("FAIL: cache read %06h gave %08h, expected %08h",
                             {w, 2'b00}, got, ref_word[w]);
                    errors = errors + 1;
                end
            end
            2: begin                                   // read the screen through the cache
                v = (PIXELS_AT - WINDOW) + $urandom % 307200;
                v = {v[18:2], 2'b00};
                c_access(0, WINDOW + v, 4'b0000, 0, got);
                if (got !== {m_vid[v + 3], m_vid[v + 2], m_vid[v + 1], m_vid[v]}) begin
                    $display("FAIL: cache read %06h gave %08h, expected %02h%02h%02h%02h",
                             WINDOW + v, got, m_vid[v + 3], m_vid[v + 2], m_vid[v + 1], m_vid[v]);
                    errors = errors + 1;
                end
            end
            default: begin                             // far away: lines thrown out
                w = $urandom;
                c_access(1, 23'h400000 + {w, 2'b00}, 4'b1111, $urandom, got);
            end
            endcase
        end
    endtask

    // ------------------------------------------------------------ the fetch: how long?
    // Ticks of clk from the job's start to its end. A line has 800 pixel ticks.
    integer fetch_ticks = 0, fetch_longest = 0, fetches = 0;
    always @(posedge clk) begin
        if (dut.busy) fetch_ticks = fetch_ticks + 1;
        else if (fetch_ticks != 0) begin
            fetches = fetches + 1;
            if (fetch_ticks > fetch_longest) fetch_longest = fetch_ticks;
            fetch_ticks = 0;
        end
    end

    // ------------------------------------------------------------ frame capture
    integer bmp, px, py, frame_errors, black_errors;
    reg capturing = 0;
    reg [23:0] picture [0:640*480-1];

    always @(posedge pclk) begin
        if (!visible_delayed && {red, green, blue} !== 24'h000000) black_errors = black_errors + 1;
        if (capturing && visible_delayed) begin
            // the picture is DELAY ticks behind the raster
            px = (x + 800 - DELAY) % 800;
            py = y;
            picture[py * 640 + px] = {red, green, blue};
            if ({red, green, blue} !== expected(px, py)) begin
                if (frame_errors < 5)
                    $display("FAIL: pixel (%0d,%0d) is %06h, expected %06h",
                             px, py, {red, green, blue}, expected(px, py));
                frame_errors = frame_errors + 1;
            end
        end
    end

    task frame(input [8*32-1:0] name);
        integer i;
        begin
            // wait for the start of a frame, then take one whole frame
            wait (y == 524); wait (y == 0);
            frame_errors = 0;
            capturing = 1;
            wait (y == 480);
            capturing = 0;
            $display("%0s: %0d of 307200 pixels differ from the model", name, frame_errors);
            errors = errors + frame_errors;
            bmp = $fopen(name, "wb");
            // a 24-bit BMP, top line first (negative height)
            $fwrite(bmp, "BM");
            put32(54 + 640 * 480 * 3); put32(0); put32(54);
            put32(40); put32(640); put32(-480);
            $fwrite(bmp, "%c%c%c%c", 1, 0, 24, 0);
            put32(0); put32(640 * 480 * 3); put32(2835); put32(2835); put32(0); put32(0);
            for (i = 0; i < 640 * 480; i = i + 1)
                $fwrite(bmp, "%c%c%c", picture[i][7:0], picture[i][15:8], picture[i][23:16]);
            $fclose(bmp);
        end
    endtask

    task put32(input integer v);
        $fwrite(bmp, "%c%c%c%c", v[7:0], v[15:8], v[23:16], v[31:24]);
    endtask

    // ------------------------------------------------------------ the test
    integer i, j;
    initial begin
        black_errors = 0;
        for (i = 0; i < 16384; i = i + 1) ref_known[i] = 0;
        repeat (4) @(posedge clk);
        reset <= 0;

        // 1. The video unit's bus.
        v_check(18'h00000, 32'h0);                     // nothing there: 0
        v_check(18'h20208, 32'hCCCC_7830);             // font 0, 'A', rows 0-3
        v_check(18'h20A08, 32'hEEEE_7C38);             // font 1 (bold): the same rows
        v_write(18'h21FFC, 4'b1111, 32'h8142_2418);    // last word of font 3
        v_check(18'h21FFC, 32'h8142_2418);
        v_write(18'h21FFC, 4'b0100, 32'h00FF_0000);    // one byte of it
        v_check(18'h21FFC, 32'h81FF_2418);
        v_check(18'h22000, 32'h0);                     // past the 4 fonts: nothing
        v_check(18'h31000, m_mode[0]);                 // the mode RAM from modes.hex
        v_check(18'h3100C, m_mode[3]);                 // row 1, columns 0-31
        v_check(18'h31010, m_mode[4]);                 // row 1, columns 32-63
        v_check(18'h312CC, m_mode[179]);               // row 59, columns 64-79
        v_write(18'h312CC, 4'b1111, 32'h1234_A5A5); v_check(18'h312CC, 32'h1234_A5A5);
        v_write(18'h312CC, 4'b0001, 32'h0000_00FF); v_check(18'h312CC, 32'h1234_A5FF);
        v_write(18'h312CC, 4'b1111, demo_modes[179]);
        v_check(18'h312D0, 32'h0);                     // past the mode RAM: nothing
        v_check(18'h30020, 32'h0078_0000);             // text_base
        v_check(18'h30024, 32'h0079_0000);             // pixel_base
        v_write(18'h30020, 4'b1000, 32'h5A00_0000);    // bits 31..24: kept
        v_check(18'h30020, 32'h5A78_0000);
        v_write(18'h30020, 4'b1111, 32'h0078_0000);
        v_check(18'h30028, 32'h0);                     // nothing there
        v_check(18'h30404, 32'h0);                     // the palette: write only

        // A glyph of our own: character 1 of font 3, a smiley, two words.
        v_write(18'h21808, 4'b1111, 32'h81A5_423C);
        v_write(18'h2180C, 4'b1111, 32'h3C42_99A5);
        $display("video bus: %0d errors", errors);

        // 2. Eight smileys at the end of row 59, written by the processor through the
        //    cache: code 1, font 3, paper 0, ink 16 + 30*i. (The first access waits
        //    for the SDRAM's power-up.)
        for (i = 0; i < 8; i = i + 1)
            c_write_word(TEXT_AT + 59 * 320 + (70 + i) * 4,
                         {8'd16 + 8'd30 * i[7:0], 8'd0, 8'd3, 8'd1});

        // 3. The demo.
        frame("mixed.bmp");

        // All text.
        set_modes(0);
        frame("text.bmp");

        // All graphics, with a box drawn through the cache in color 196 (red), 4 pixels
        // wide, at (100,100) - (539,379), a word (4 pixels) at a time.
        for (i = 100; i < 380; i = i + 1)
            for (j = 100 / 4; j < 540 / 4; j = j + 1)
                if (i < 104 || i >= 376 || j == 25 || j == 134)
                    c_write_word(PIXELS_AT + i * 640 + j * 4, {4{8'd196}});
        set_modes(1);

        // The processor reads and writes all through the frame.
        c_longest = 0; c_accesses = 0; fetch_longest = 0; fetches = 0;
        fork
            frame("graphics.bmp");
            begin : traffic
                while (!capturing) @(posedge clk);
                while (capturing) c_random;
            end
        join
        $display("during that frame: %0d accesses of the processor, the longest took %0d ticks",
                 c_accesses, c_longest);
        $display("                   %0d fetches, the longest took %0d of the %0d ticks of a line",
                 fetches, fetch_longest, 800 * CLK_MHZ * 1000 / 25200);

        // Graphics in a disc and a checkerboard of blocks, in text, with the palette
        // changed: entries 16 - 79 a ramp of red.
        set_modes(3);
        for (i = 16; i < 80; i = i + 1) set_color(i, {i[5:0], 2'b11, 8'h00, 8'h20});
        frame("shape.bmp");

        // The demo with the pixels 5 lines on and the text 2 rows on.
        set_modes(2);
        set_bases(TEXT_AT + 640, PIXELS_AT + 3200);
        frame("scrolled.bmp");

        // 4., 5.
        $display("the longest read of the video bus took %0d ticks", longest_read);
        $display("black outside the picture: %0d errors", black_errors);
        errors = errors + black_errors;
        $display("SDRAM: %0d line reads, %0d line writes, %0d refreshes, %0d timing errors",
                 chip.reads, chip.writes, chip.refreshes, chip.errors);
        errors = errors + chip.errors;
        $display("simulated %0.2f ms at %0d MHz", $realtime / 1.0e6, CLK_MHZ);
        if (errors == 0) $display("PASS: video");
        else             $display("FAIL: video, %0d errors", errors);
        $finish;
    end
endmodule
