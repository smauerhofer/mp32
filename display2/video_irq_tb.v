// video_irq_tb.v: tests the interrupts of the video unit (video.v): the line
// interrupt and the frame interrupt, their flags and registers.
//
//   make test-irq
//
// A raster of 800 x 525 on the 25.2 MHz pixel clock, the processor's bus on 42 MHz
// (no SDRAM: the fetch is left waiting, which the interrupts do not need). Checked:
//   1. the registers: IRQ_LINE, IRQ_CTRL read back; LINE, IRQ_STATUS
//   2. the line interrupt at IRQ_LINE: the flag rises once a frame, a few ticks after
//      x = 640 of that line; irq_line only while LIE is 1; a write of 1 clears it
//   3. EVERY: one line interrupt for each of the 525 lines of a frame, LINE following
//   4. the frame interrupt: once a frame, after x = 640 of line 479; irq_frame only
//      while FIE is 1; the two flags are cleared one at a time

`timescale 1ns/1ps

module video_irq_tb;
    reg pclk = 0, clk = 0;
    always #19.841 pclk = ~pclk;          // 25.2 MHz
    always #11.905 clk  = ~clk;           // 42 MHz

    // ---- the raster
    reg  [9:0] x = 0, y = 0;
    always @(posedge pclk) begin
        if (x == 10'd799) begin
            x <= 0;
            y <= (y == 10'd524) ? 10'd0 : y + 10'd1;
        end else x <= x + 10'd1;
    end

    // ---- the video unit
    reg         sel = 0, we = 0;
    reg  [3:0]  be = 4'hF;
    reg  [17:0] addr = 0;
    reg  [31:0] wdata = 0;
    wire [31:0] rdata;
    wire        ready, irq_line, irq_frame;

    video #(.FONT_FILE(""), .PALETTE_FILE("")) dut (
        .clk(pclk), .x(x), .y(y), .visible(x < 640 && y < 480), .hsync(1'b1), .vsync(1'b1),
        .red(), .green(), .blue(), .visible_delayed(), .hsync_delayed(), .vsync_delayed(),
        .cpu_clk(clk), .cpu_sel(sel), .cpu_we(we), .cpu_be(be), .cpu_addr(addr),
        .cpu_wdata(wdata), .cpu_rdata(rdata), .cpu_ready(ready),
        .irq_line(irq_line), .irq_frame(irq_frame),
        .mem_req(), .mem_addr(), .mem_count(), .mem_word(32'h0), .mem_valid(1'b0), .mem_ack(1'b0)
    );

    localparam [17:0] IRQ_LINE = 18'h30028, IRQ_CTRL = 18'h3002C, IRQ_STATUS = 18'h30030,
                      LINE = 18'h30034;

    integer errors = 0;
    task fail(input [8*60-1:0] what);
        begin errors = errors + 1; $display("%t FAIL: %0s", $realtime, what); end
    endtask

    task wr(input [17:0] a, input [31:0] d);
        begin
            @(negedge clk); sel = 1; we = 1; addr = a; wdata = d; be = 4'hF;
            @(posedge clk); while (!ready) @(posedge clk);
            #1 sel = 0; we = 0;
        end
    endtask
    task rd(input [17:0] a, output [31:0] d);
        begin
            @(negedge clk); sel = 1; we = 0; addr = a;
            @(posedge clk); while (!ready) @(posedge clk);
            d = rdata;
            #1 sel = 0;
        end
    endtask
    task expect_reg(input [17:0] a, input [31:0] want, input [8*40-1:0] what);
        reg [31:0] got;
        begin
            rd(a, got);
            if (got !== want) begin
                errors = errors + 1;
                $display("%t FAIL: %0s: got %h, expected %h", $realtime, what, got, want);
            end
        end
    endtask

    // ---- where the flags rise: the raster when a flag goes from 0 to 1
    reg [1:0] flags_was = 0;
    integer   line_rises = 0, frame_rises = 0;
    reg [9:0] line_rise_x, line_rise_y, frame_rise_x, frame_rise_y;
    always @(posedge clk) begin
        if (dut.irq_flags[0] && !flags_was[0]) begin
            line_rises = line_rises + 1; line_rise_x = x; line_rise_y = y;
        end
        if (dut.irq_flags[1] && !flags_was[1]) begin
            frame_rises = frame_rises + 1; frame_rise_x = x; frame_rise_y = y;
        end
        flags_was = dut.irq_flags;
    end

    reg [31:0] v;
    integer    n, last;

    initial begin
        // ---- 1. the registers
        expect_reg(IRQ_CTRL, 32'h0, "IRQ_CTRL after the start");
        wr(IRQ_LINE, 32'hFFFF_F000 | 10'd100);
        expect_reg(IRQ_LINE, 32'd100, "IRQ_LINE");
        wr(IRQ_CTRL, 32'hFFFF_FFF8);
        expect_reg(IRQ_CTRL, 32'h0, "IRQ_CTRL: only bits 2..0");

        // ---- 2. the line interrupt at line 100, off: the flag rises, irq_line stays 0
        wait (y == 10'd101); wait (y == 10'd102);
        if (line_rises != 1) fail("the line flag did not rise once at line 100");
        if (line_rise_y != 10'd100 || line_rise_x < 10'd640 || line_rise_x > 10'd650)
            $display("   (rose at x %0d, y %0d)", line_rise_x, line_rise_y);
        if (line_rise_y != 10'd100 || line_rise_x < 10'd640 || line_rise_x > 10'd650)
            fail("the line flag rose at the wrong place");
        if (irq_line) fail("irq_line while LIE is 0");
        expect_reg(IRQ_STATUS, 32'h1, "IRQ_STATUS after line 100");
        expect_reg(LINE, 32'd100, "LINE after line 100");
        wr(IRQ_CTRL, 32'h1);                               // LIE: the flag is still up
        @(posedge clk); @(posedge clk);
        if (!irq_line) fail("irq_line not 1 with LIE and the flag");
        wr(IRQ_STATUS, 32'h2);                             // clears FRAME only
        if (!irq_line) fail("a write of FRAME cleared LINE");
        wr(IRQ_STATUS, 32'h1);
        @(posedge clk);
        if (irq_line) fail("irq_line after the flag was cleared");
        // the next frame: once more at line 100
        n = line_rises;
        wait (y == 10'd99); wait (y == 10'd101);
        if (line_rises != n + 1 || !irq_line) fail("no line interrupt in the next frame");
        wr(IRQ_STATUS, 32'h1);

        // ---- 3. EVERY: a line interrupt for each line; LINE follows
        wait (y == 10'd200);
        wr(IRQ_CTRL, 32'h5);                               // LIE, EVERY
        wait (y == 10'd0);
        wr(IRQ_STATUS, 32'h1);                             // the last frame's
        n = line_rises;
        // the handler: clears the flag each time, reads LINE
        last = -1;
        while (y != 10'd524 || x < 10'd700) begin
            @(posedge clk);
            if (irq_line) begin
                rd(LINE, v);
                if (last >= 0 && v != last + 1) begin
                    errors = errors + 1;
                    $display("%t FAIL: LINE %0d after %0d", $realtime, v, last);
                end
                last = v;
                wr(IRQ_STATUS, 32'h1);
            end
        end
        if (line_rises - n != 525)
            $display("   %0d line interrupts in a frame", line_rises - n);
        if (line_rises - n != 525) fail("EVERY: not 525 line interrupts in a frame");
        wr(IRQ_CTRL, 32'h0);
        wr(IRQ_STATUS, 32'h3);

        // ---- 4. the frame interrupt
        n = frame_rises;
        wait (y == 10'd478); wait (y == 10'd481);
        if (frame_rises != n + 1) fail("the frame flag did not rise once");
        if (frame_rise_y != 10'd479 || frame_rise_x < 10'd640 || frame_rise_x > 10'd650)
            fail("the frame flag rose at the wrong place");
        if (irq_frame) fail("irq_frame while FIE is 0");
        wr(IRQ_CTRL, 32'h2);
        @(posedge clk);
        if (!irq_frame) fail("irq_frame not 1 with FIE and the flag");
        if (irq_line) fail("irq_line while LIE is 0");
        wr(IRQ_STATUS, 32'h2);
        @(posedge clk);
        if (irq_frame) fail("irq_frame after the flag was cleared");
        expect_reg(IRQ_STATUS, 32'h1, "IRQ_STATUS: LINE stays (line 100 passed)");

        $display("%0d line, %0d frame interrupts", line_rises, frame_rises);
        if (errors == 0) $display("PASS: video interrupts");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end

    initial begin #100_000_000; $display("FAIL: timeout"); $finish; end
endmodule
