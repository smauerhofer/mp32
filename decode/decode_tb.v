// decode_tb.v: tests decode.v with the real parts behind it: the cache and the SDRAM
// controller (../cache), the SDRAM model, and the video unit (../display2), whose
// display runs on its own pixel clock all the while.
//
//   make test        (see the makefile)
//
//   1. Nothing: reads of addresses where nothing is give 0 at once; writes there
//      change nothing anywhere.
//   2. The SDRAM: words and single bytes, at both ends of the 8 MB and in the
//      write-through region; 0x0080_0000 must not reach the SDRAM.
//   3. The video unit: the two bases, the font RAM, the mode RAM, writes of single
//      bytes (cpu_be), and the palette (checked inside the unit, since it cannot be
//      read).
//   4. Random reads and writes of the SDRAM, the font RAM and the mode RAM, mixed,
//      every read checked against a model.
// It reports how many ticks the accesses of the video unit took.

`timescale 1ns / 1ps

module decode_tb;
    parameter CLK_MHZ = 100;
    parameter OPS     = 6000;

    reg pclk = 0;  always #19.84 pclk = ~pclk;              // 25.2 MHz
    reg clk  = 0;  always #(500.0 / CLK_MHZ) clk = ~clk;

    // ------------------------------------------------------------ a raster
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
    reg         reset = 1;
    reg         cpu_sel = 0, cpu_we = 0;
    reg  [3:0]  cpu_be = 0;
    reg  [31:0] cpu_addr = 0, cpu_wdata = 0;
    wire [31:0] cpu_rdata;
    wire        cpu_ready;

    wire        mem_sel, mem_we, mem_ready;
    wire [3:0]  mem_be;
    wire [22:0] mem_addr;
    wire [31:0] mem_wdata, mem_rdata;

    wire        vid_sel, vid_we, vid_ready;
    wire [3:0]  vid_be;
    wire [17:0] vid_addr;
    wire [31:0] vid_wdata, vid_rdata;

    wire         v_req, v_valid, v_ack;
    wire [22:4]  v_addr;
    wire [6:0]   v_count;
    wire [31:0]  v_word;

    wire [7:0]  red, green, blue;
    wire        visible_delayed, hsync_delayed, vsync_delayed;

    wire        sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_wen_n;
    wire [3:0]  sd_dqm;
    wire [10:0] sd_addr;
    wire [1:0]  sd_ba;
    wire [31:0] sd_dq;

    decode dut (
        .cpu_sel(cpu_sel), .cpu_we(cpu_we), .cpu_be(cpu_be), .cpu_addr(cpu_addr),
        .cpu_wdata(cpu_wdata), .cpu_rdata(cpu_rdata), .cpu_ready(cpu_ready),
        .mem_sel(mem_sel), .mem_we(mem_we), .mem_be(mem_be), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ready(mem_ready),
        .vid_sel(vid_sel), .vid_we(vid_we), .vid_be(vid_be), .vid_addr(vid_addr),
        .vid_wdata(vid_wdata), .vid_rdata(vid_rdata), .vid_ready(vid_ready)
    );

    cache #(.CLK_MHZ(CLK_MHZ)) memory (
        .clk(clk), .clk_sdram(1'b0), .reset(reset),
        .cpu_sel(mem_sel), .cpu_we(mem_we), .cpu_be(mem_be), .cpu_addr(mem_addr),
        .cpu_wdata(mem_wdata), .cpu_rdata(mem_rdata), .cpu_ready(mem_ready),
        .vid_req(v_req), .vid_addr(v_addr), .vid_count(v_count),
        .vid_word(v_word), .vid_valid(v_valid), .vid_ack(v_ack),
        .O_sdram_clk(sd_clk), .O_sdram_cke(sd_cke), .O_sdram_cs_n(sd_cs_n),
        .O_sdram_ras_n(sd_ras_n), .O_sdram_cas_n(sd_cas_n), .O_sdram_wen_n(sd_wen_n),
        .O_sdram_dqm(sd_dqm), .O_sdram_addr(sd_addr), .O_sdram_ba(sd_ba),
        .IO_sdram_dq(sd_dq)
    );

    sdram_model chip (
        .clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
        .we_n(sd_wen_n), .dqm(sd_dqm), .addr(sd_addr), .ba(sd_ba), .dq(sd_dq)
    );

    video #(.FONT_FILE(""), .PALETTE_FILE(""), .MODE_FILE("")) screen (
        .clk(pclk), .x(x), .y(y), .visible(visible), .hsync(hsync), .vsync(vsync),
        .red(red), .green(green), .blue(blue),
        .visible_delayed(visible_delayed), .hsync_delayed(hsync_delayed),
        .vsync_delayed(vsync_delayed),
        .cpu_clk(clk), .cpu_sel(vid_sel), .cpu_we(vid_we), .cpu_be(vid_be),
        .cpu_addr(vid_addr), .cpu_wdata(vid_wdata), .cpu_rdata(vid_rdata),
        .cpu_ready(vid_ready),
        .mem_req(v_req), .mem_addr(v_addr), .mem_count(v_count),
        .mem_word(v_word), .mem_valid(v_valid), .mem_ack(v_ack)
    );

    // ------------------------------------------------------------ the bus
    integer errors = 0, ticks, longest_video_write = 0, longest_video_read = 0;

    task access(input we, input [31:0] a, input [3:0] be, input [31:0] wd,
                output [31:0] rd);
        begin
            cpu_sel   <= 1;
            cpu_we    <= we;
            cpu_addr  <= a;
            cpu_be    <= be;
            cpu_wdata <= wd;
            ticks = 1;
            @(posedge clk);
            while (!cpu_ready) begin
                @(posedge clk);
                ticks = ticks + 1;
                if (ticks > 100000) begin
                    $display("FAIL: access to %08h never ends", a);
                    $finish;
                end
            end
            rd = cpu_rdata;
            cpu_sel <= 0;
            if (a[31:28] == 4'hF) begin
                if (we  && ticks > longest_video_write) longest_video_write = ticks;
                if (!we && ticks > longest_video_read)  longest_video_read  = ticks;
            end
        end
    endtask

    reg [31:0] dummy;
    task write(input [31:0] a, input [3:0] be, input [31:0] wd);
        access(1, a, be, wd, dummy);
    endtask

    task check(input [31:0] a, input [31:0] want, input [31:0] mask);
        reg [31:0] got;
        begin
            access(0, a, 4'b0000, 0, got);
            if ((got & mask) !== (want & mask)) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("FAIL: read %08h gave %08h, expected %08h (mask %08h)",
                             a, got, want, mask);
            end
        end
    endtask

    function [31:0] lanes(input [3:0] be);
        lanes = {{8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}};
    endfunction

    // ------------------------------------------------------------ the model
    // Words that have been written: the SDRAM in four places, the font RAM, the
    // mode RAM. Which bytes are known in m_known.
    localparam N = 4096 + 2048 + 180;
    reg [31:0] m_word  [0:N-1];
    reg [3:0]  m_known [0:N-1];

    function [31:0] place(input integer n);       // the address of model word n
        begin
            if (n < 4096)        place = (n / 1024) * 32'h0020_0000 + 32'h0000_0100
                                         + (n % 1024) * 4 + ((n / 1024) == 3 ? 32'h0018_0000 : 0);
            else if (n < 6144)   place = 32'hF002_0000 + (n - 4096) * 4;
            else                 place = 32'hF003_1000 + (n - 6144) * 4;
        end
    endfunction
    // n / 1024 = 3 puts the fourth place at 0x0078_0100: the write-through region.

    task m_write(input integer n, input [3:0] be, input [31:0] wd);
        begin
            write(place(n), be, wd);
            m_word[n]  = (m_word[n] & ~lanes(be)) | (wd & lanes(be));
            m_known[n] = m_known[n] | be;
        end
    endtask

    task m_check(input integer n);
        check(place(n), m_word[n], lanes(m_known[n]));
    endtask

    // ------------------------------------------------------------ the test
    integer i, n, k;
    reg [3:0] be;
    initial begin
        for (i = 0; i < N; i = i + 1) m_known[i] = 0;
        repeat (4) @(posedge clk);
        reset <= 0;

        // 1. Nothing.
        check(32'h0080_0000, 0, 32'hFFFF_FFFF);
        if (ticks != 1) begin $display("FAIL: nothing took %0d ticks", ticks); errors = errors + 1; end
        check(32'h1234_5678, 0, 32'hFFFF_FFFF);
        check(32'hF004_0000, 0, 32'hFFFF_FFFF);
        check(32'hEFFF_FFFC, 0, 32'hFFFF_FFFF);
        check(32'hF003_0000, 0, 32'hFFFF_FFFF);         // the video unit, but nothing there
        write(32'hF004_0020, 4'b1111, 32'hDEAD_BEEF);   // nowhere: must not reach a base
        if (screen.text_base !== 32'h0078_0000) begin
            $display("FAIL: a write past the video unit reached text_base"); errors = errors + 1;
        end
        $display("1. nothing: %0d errors", errors);

        // 2. The SDRAM. (The first access waits for its power-up.)
        write(32'h0000_0000, 4'b1111, 32'h0123_4567);
        write(32'h007F_FFFC, 4'b1111, 32'h89AB_CDEF);
        write(32'h0078_0000, 4'b1111, 32'h1111_2222);   // write-through region
        write(32'h0000_0004, 4'b0001, 32'h0000_00AA);   // single bytes
        write(32'h0000_0004, 4'b0100, 32'h00BB_0000);
        check(32'h0000_0000, 32'h0123_4567, 32'hFFFF_FFFF);
        check(32'h007F_FFFC, 32'h89AB_CDEF, 32'hFFFF_FFFF);
        check(32'h0078_0000, 32'h1111_2222, 32'hFFFF_FFFF);
        check(32'h0000_0004, 32'h00BB_00AA, 32'h00FF_00FF);
        write(32'h0080_0000, 4'b1111, 32'hDEAD_BEEF);   // past the SDRAM: must not wrap
        write(32'h00FF_FFFC, 4'b1111, 32'hDEAD_BEEF);   //   round to 0 or to the top
        check(32'h0000_0000, 32'h0123_4567, 32'hFFFF_FFFF);
        check(32'h007F_FFFC, 32'h89AB_CDEF, 32'hFFFF_FFFF);
        $display("2. SDRAM: %0d errors", errors);

        // 3. The video unit, a word at a time.
        write(32'hF003_0020, 4'b1111, 32'h0078_1230);   // text_base
        write(32'hF003_0024, 4'b1111, 32'h0079_4560);   // pixel_base
        check(32'hF003_0020, 32'h0078_1230, 32'hFFFF_FFFF);
        check(32'hF003_0024, 32'h0079_4560, 32'hFFFF_FFFF);
        if (screen.text_base !== 32'h0078_1230 || screen.pixel_base !== 32'h0079_4560) begin
            $display("FAIL: the bases inside the video unit are %08h, %08h",
                     screen.text_base, screen.pixel_base);
            errors = errors + 1;
        end
        write(32'hF003_0020, 4'b0010, 32'h0000_AB00);   // one byte of text_base
        check(32'hF003_0020, 32'h0078_AB30, 32'hFFFF_FFFF);
        write(32'hF003_0020, 4'b1111, 32'h0078_0000);   // the defaults again
        write(32'hF003_0024, 4'b1111, 32'h0079_0000);

        write(32'hF002_0000, 4'b1111, 32'h4433_2211);   // the font RAM
        write(32'hF002_1FFC, 4'b1111, 32'h8877_6655);   // its last word (font 3)
        check(32'hF002_0000, 32'h4433_2211, 32'hFFFF_FFFF);
        check(32'hF002_1FFC, 32'h8877_6655, 32'hFFFF_FFFF);
        if (screen.font[0] !== 32'h4433_2211) begin
            $display("FAIL: the font RAM's first word is %08h", screen.font[0]); errors = errors + 1;
        end

        write(32'hF003_1000, 4'b1111, 32'hF0F0_0FF0);   // the mode RAM
        write(32'hF003_12CC, 4'b1111, 32'h0102_0408);   // its last word
        write(32'hF003_12CC, 4'b1000, 32'hFF00_0000);   // and its last byte alone
        check(32'hF003_1000, 32'hF0F0_0FF0, 32'hFFFF_FFFF);
        check(32'hF003_12CC, 32'hFF02_0408, 32'hFFFF_FFFF);
        check(32'hF003_12D0, 0, 32'hFFFF_FFFF);         // past it: nothing

        write(32'hF003_0414, 4'b1111, 32'h0033_2211);   // palette entry 5: R 11 G 22 B 33
        write(32'hF003_07FC, 4'b1111, 32'h00CC_BBAA);   // entry 255
        write(32'hF003_07FC, 4'b0010, 32'h0000_5500);   // and only its green
        check(32'hF003_0414, 0, 32'hFFFF_FFFF);         // write only: reads 0
        if (screen.palette[5] !== 32'h0033_2211 || screen.palette[255] !== 32'h00CC_55AA) begin
            $display("FAIL: palette entries 5, 255 are %08h, %08h",
                     screen.palette[5], screen.palette[255]);
            errors = errors + 1;
        end
        $display("3. video unit: %0d errors; the longest word write took %0d ticks, read %0d",
                 errors, longest_video_write, longest_video_read);

        // 4. Random, mixed.
        for (i = 0; i < OPS; i = i + 1) begin
            n = $urandom % N;
            if ($urandom % 2) begin
                case ($urandom % 3)
                    0:       be = 4'b1111;
                    1:       be = 4'b0001 << ($urandom % 4);
                    default: be = $urandom;
                endcase
                m_write(n, be, $urandom);
            end else
                m_check(n);
        end
        for (n = 0; n < N; n = n + 1)                    // read back all that was written
            if (m_known[n] != 0) m_check(n);
        $display("4. random: %0d errors", errors);

        $display("video unit: the longest word write took %0d ticks, the longest read %0d",
                 longest_video_write, longest_video_read);
        $display("SDRAM model: %0d timing errors", chip.errors);
        errors = errors + chip.errors;
        if (errors == 0) $display("PASS: decode");
        else             $display("FAIL: decode, %0d errors", errors);
        $finish;
    end
endmodule
