// video_tb.v: tests video.v.
//   1. The processor bus: writes and reads back the video RAM, the font RAM and
//      every register.
//   2. Three frames, each checked pixel by pixel against a model of what it should
//      be, and written to a BMP file:
//        mixed.bmp     row 0 text, rows 1-49 graphics, rows 50-59 text (the demo)
//        text.bmp      all 60 rows text
//        graphics.bmp  all 60 rows graphics
//   3. That nothing but black comes out where the raster says "not visible".
//   4. That the processor can read the memories while the display draws: during
//      the last frame, a second process reads random bytes all the time.
// The processor runs on its own clock, unrelated to the pixel clock.
`timescale 1ns / 1ps

module video_tb;
    // ------------------------------------------------------------ clocks
    reg clk = 0;      always #19.84 clk = ~clk;        // 25.2 MHz
    reg cpu_clk = 0;  always #18.52 cpu_clk = ~cpu_clk; // 27 MHz, unrelated

    // ------------------------------------------------------------ a raster
    // 640 x 480 at 60 Hz: 800 positions per line, 525 lines, syncs active low.
    reg [9:0] x = 0, y = 0;
    always @(posedge clk) begin
        if (x == 799) begin
            x <= 0;
            y <= (y == 524) ? 10'd0 : y + 10'd1;
        end else
            x <= x + 10'd1;
    end
    wire visible = (x < 640) && (y < 480);
    wire hsync   = ~((x >= 656) && (x < 752));
    wire vsync   = ~((y >= 490) && (y < 492));

    // ------------------------------------------------------------ the unit
    localparam [63:0] DEMO_ROWS  = 64'h0003_FFFF_FFFF_FFFE;
    localparam [15:0] DEMO_TEXT  = 16'd32000;
    localparam [15:0] DEMO_COLOR = 16'd32880;

    reg         cpu_sel = 0, cpu_we = 0;
    reg  [17:0] cpu_addr = 0;
    reg  [7:0]  cpu_wdata = 0;
    wire [7:0]  cpu_rdata;
    wire        cpu_ready;
    wire [7:0]  red, green, blue;
    wire        visible_delayed, hsync_delayed, vsync_delayed;

    video #(.VRAM_FILE("vram.hex"), .FONT_FILE("font.hex"),
            .ROW_MODES(DEMO_ROWS), .TEXT_BASE(DEMO_TEXT), .COLOR_BASE(DEMO_COLOR)) dut (
        .clk(clk), .x(x), .y(y), .visible(visible), .hsync(hsync), .vsync(vsync),
        .red(red), .green(green), .blue(blue),
        .visible_delayed(visible_delayed), .hsync_delayed(hsync_delayed),
        .vsync_delayed(vsync_delayed),
        .cpu_clk(cpu_clk), .cpu_sel(cpu_sel), .cpu_we(cpu_we),
        .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_rdata(cpu_rdata),
        .cpu_ready(cpu_ready)
    );

    // ------------------------------------------------------------ the model
    // Its own copies of the memories and registers, kept up to date by every
    // write this test bench makes. It shares nothing with the circuit.
    reg [7:0]  m_vram [0:38911];
    reg [7:0]  m_font [0:2047];
    reg [23:0] m_text [0:15];
    reg [23:0] m_gfx  [0:1];
    reg [63:0] m_rows;
    reg [15:0] m_text_base, m_color_base;
    integer    m_k [0:59];                  // which text row each row is
    integer errors = 0;

    initial begin
        $readmemh("vram.hex", m_vram);
        $readmemh("font.hex", m_font);
        m_text[0]=24'h000000; m_text[1]=24'hFFFFFF; m_text[2]=24'h880000; m_text[3]=24'hAAFFEE;
        m_text[4]=24'hCC44CC; m_text[5]=24'h00CC55; m_text[6]=24'h0000AA; m_text[7]=24'hEEEE77;
        m_text[8]=24'hDD8855; m_text[9]=24'h664400; m_text[10]=24'hFF7777; m_text[11]=24'h333333;
        m_text[12]=24'h777777; m_text[13]=24'hAAFF66; m_text[14]=24'h0088FF; m_text[15]=24'hBBBBBB;
        m_gfx[0]=24'h000000; m_gfx[1]=24'hAAFF66;
        m_rows = DEMO_ROWS; m_text_base = DEMO_TEXT; m_color_base = DEMO_COLOR;
    end

    task number_text_rows;
        integer r, k;
        begin
            k = 0;
            for (r = 0; r < 60; r = r + 1) begin
                m_k[r] = k;
                if (!m_rows[r]) k = k + 1;
            end
        end
    endtask

    function [23:0] expected(input integer px, input integer py);
        integer r, place;
        reg [7:0] ch, at, g, vb;
        begin
            r = py / 8;
            if (m_rows[r]) begin
                vb = m_vram[py * 80 + px / 8];
                expected = m_gfx[vb[7 - px % 8]];
            end else begin
                place = m_k[r] * 80 + px / 8;
                ch = m_vram[(m_text_base + place) % 65536];
                at = m_vram[(m_color_base + place) % 65536];
                g  = m_font[ch * 8 + py % 8];
                expected = g[7 - px % 8] ? m_text[at[7:4]] : m_text[at[3:0]];
            end
        end
    endfunction

    // ------------------------------------------------------------ bus helpers
    task write(input [17:0] a, input [7:0] d);
        begin
            @(negedge cpu_clk);
            cpu_addr = a; cpu_wdata = d; cpu_sel = 1; cpu_we = 1;
            @(negedge cpu_clk);
            while (!cpu_ready) @(negedge cpu_clk);
            cpu_sel = 0; cpu_we = 0;
            // keep the model in step
            if (a < 38912)                     m_vram[a] = d;
            else if (a[17:16] == 2'b10)        m_font[a[10:0]] = d;
            else if (a[17:3] == 15'h6002)      m_rows[8 * a[2:0] +: 8] = d;
            else if (a == 18'h30020)           m_text_base[7:0]   = d;
            else if (a == 18'h30021)           m_text_base[15:8]  = d;
            else if (a == 18'h30022)           m_color_base[7:0]  = d;
            else if (a == 18'h30023)           m_color_base[15:8] = d;
            else if (a[17:6] == 12'hC04 && a[1:0] != 3)
                m_text[a[5:2]] = (a[1:0] == 0) ? {d, m_text[a[5:2]][15:0]} :
                                 (a[1:0] == 1) ? {m_text[a[5:2]][23:16], d, m_text[a[5:2]][7:0]} :
                                                 {m_text[a[5:2]][23:8], d};
            else if (a[17:3] == 15'h6040 && a[1:0] != 3)
                m_gfx[a[2]] = (a[1:0] == 0) ? {d, m_gfx[a[2]][15:0]} :
                              (a[1:0] == 1) ? {m_gfx[a[2]][23:16], d, m_gfx[a[2]][7:0]} :
                                              {m_gfx[a[2]][23:8], d};
        end
    endtask

    integer ticks, longest = 0, reads = 0;
    task read_check(input [17:0] a, input [7:0] want);
        begin
            @(negedge cpu_clk);
            cpu_addr = a; cpu_sel = 1; cpu_we = 0;
            ticks = 1;
            @(negedge cpu_clk);
            while (!cpu_ready) begin @(negedge cpu_clk); ticks = ticks + 1; end
            cpu_sel = 0;
            reads = reads + 1;
            if (ticks > longest) longest = ticks;
            if (cpu_rdata !== want) begin
                $display("FAIL: read %05h gave %02h, expected %02h", a, cpu_rdata, want);
                errors = errors + 1;
            end
        end
    endtask

    task set_rows(input [63:0] rows);
        integer j;
        for (j = 0; j < 8; j = j + 1) write(18'h30010 + j, rows[8 * j +: 8]);
    endtask

    // ------------------------------------------------------------ frame capture
    integer bmp, px, py, frame_errors, black_errors;
    reg capturing = 0;
    reg [23:0] picture [0:640*480-1];

    always @(posedge clk) begin
        if (!visible_delayed && {red, green, blue} !== 24'h000000) black_errors = black_errors + 1;
        if (capturing && visible_delayed) begin
            // the picture is 8 ticks behind the raster
            px = (x + 800 - 8) % 800;
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
            number_text_rows;
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

    task put32(input integer n);
        $fwrite(bmp, "%c%c%c%c", n[7:0], n[15:8], n[23:16], n[31:24]);
    endtask

    // ------------------------------------------------------------ the test
    integer i;
    initial begin
        black_errors = 0;

        // 1. The bus.
        read_check(18'h00000, m_vram[0]);              // from vram.hex
        write(18'h00123, 8'hA5);       read_check(18'h00123, 8'hA5);
        write(18'h097FF, 8'h3C);       read_check(18'h097FF, 8'h3C);  // last byte
        read_check(18'h09800, 8'h00);                  // past the end: nothing, 0
        read_check(18'h20208, 8'h30);                  // first row of 'A' in font.hex
        write(18'h207F8, 8'h81);       read_check(18'h207F8, 8'h81);
        read_check(18'h30010, 8'hFE);                  // row modes from the parameter
        read_check(18'h30016, 8'h03);
        read_check(18'h30020, 8'h00); read_check(18'h30021, 8'h7D);   // text_base 32000
        read_check(18'h30022, 8'h70); read_check(18'h30023, 8'h80);   // color_base 32880
        read_check(18'h30138, 8'h00);                  // text color 14, red
        read_check(18'h30139, 8'h88);                  //                green
        read_check(18'h3013A, 8'hFF);                  //                blue
        read_check(18'h30205, 8'hFF);                  // graphics color 1, green
        write(18'h30204, 8'h12); write(18'h30205, 8'h34); write(18'h30206, 8'h56);
        read_check(18'h30204, 8'h12); read_check(18'h30205, 8'h34); read_check(18'h30206, 8'h56);
        write(18'h30204, 8'hAA); write(18'h30205, 8'hFF); write(18'h30206, 8'h66);  // back

        // A new glyph for character 1 (a smiley), shown in the last text row.
        write(18'h20008, 8'h3C); write(18'h20009, 8'h42); write(18'h2000A, 8'hA5);
        write(18'h2000B, 8'h81); write(18'h2000C, 8'hA5); write(18'h2000D, 8'h99);
        write(18'h2000E, 8'h42); write(18'h2000F, 8'h3C);
        for (i = 0; i < 6; i = i + 1) begin
            write(32000 + 10 * 80 + 72 + i, 1);
            write(32880 + 10 * 80 + 72 + i, {i[3:0] + 4'd8, 4'd6});
        end
        $display("bus: %0d errors", errors);

        // 2. The demo: text, graphics, text.
        frame("mixed.bmp");

        // All text. Text rows 11 on are whatever the bytes after the demo's text are.
        set_rows(64'h0);
        repeat (2000) @(posedge clk);
        frame("text.bmp");

        // All graphics, with the processor reading all the time.
        set_rows({4'h0, {60{1'b1}}});
        repeat (2000) @(posedge clk);
        reads = 0; longest = 0;
        fork
            frame("graphics.bmp");
            begin : reader
                integer a;
                while (!capturing) @(posedge cpu_clk);
                while (capturing) begin
                    a = $urandom % 38912;
                    read_check(a, m_vram[a]);
                    a = $urandom % 2048;
                    read_check(18'h20000 + a, m_font[a]);
                end
            end
        join
        $display("reads during the frame: %0d, the longest took %0d processor ticks",
                 reads, longest);

        $display("black outside the picture: %0d errors", black_errors);
        errors = errors + black_errors;
        if (errors == 0) $display("PASS: video");
        else             $display("FAIL: video, %0d errors", errors);
        $finish;
    end
endmodule
