// computer_tb.v: the whole mp32 computer (computer.v) with models of the SDRAM, the SPI
// flash and the microSD card, running the boot loader (boot.s, as build/boot.hex),
// which loads the operating system os.s (build/os.img, made by mp32img).
//
//   make test
//
// The clocks as on the board: 42 MHz for the processor, 25.2 MHz for the pixels. The
// serial port runs at 42 MHz / 16 here (UART_DIV = 16), so the bytes do not take long.
// The test bench plays the PC on the serial port. Three boots, each from reset:
//
//   1. from the flash: the image at $400000. Then the operating system's own checks:
//      "mp32 ready" on the serial port and the screen (row 0, ink 14, paper 6), the
//      echo of what it is sent ("hi" and a CR) on both, the LEDs counting the bytes
//      (1 + 3 = 4), the beep (+4000 for 53 samples, then -4000, on both channels),
//      VEC = 0. The echo runs on the serial port's interrupt, through the vector table
//      at 0.
//   2. from the card: the flash erased ("no image"), the card holds the image from
//      block 0 (SDHC: start, ACMD41 busy at first, CMD58, CMD17 block after block).
//   3. from the serial port: the flash holds the image with one byte of its payload
//      changed ("bad checksum"), there is no card ("no card"); the test bench sends
//      three bytes of noise, then the image.
//   4. from an older card, SDSC: byte addresses, CMD16; the flash erased.
//
// Before boots 2 and 3 the start of the SDRAM is cleared, so the operating system
// can only run if it was loaded again. At the end: no SDRAM timing errors, and the
// video unit fetched lines.
//
// A reset starts the SDRAM controller's power-up again: 200 us of NOPs, without
// refreshes. The model, which already holds data, counts the refreshes missed then
// ("refresh interval exceeded"); the test bench counts them apart and does not hold
// them against the computer (after a reset the loader loads everything again).

`timescale 1ns/1ps

module computer_tb;
    reg clk = 0, pixel_clk = 0;
    always #11.905 clk = ~clk;                 // 42 MHz
    always #19.841 pixel_clk = ~pixel_clk;     // 25.2 MHz

    localparam DIV = 16;                       // ticks of a bit on the serial port
    localparam real BIT = DIV * 23.81;         // ns

    reg         reset = 1;
    reg         rx = 1;
    wire        tx;
    wire [5:0]  leds;
    wire [31:0] pc;
    wire        bck, ws, din, pa_en;
    wire        f_clk, f_mosi, f_miso, f_cs_n;
    wire        c_clk, c_mosi, c_miso, c_cs_n;

    wire        sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_wen_n;
    wire [3:0]  sd_dqm;
    wire [10:0] sd_addr;
    wire [1:0]  sd_ba;
    wire [31:0] sd_dq;

    computer #(.UART_DIV(DIV)) dut (
        .clk(clk), .pixel_clk(pixel_clk), .reset(reset),
        .buttons(2'b00), .leds(leds), .uart_rx(rx), .uart_tx(tx),
        .sd_clk(c_clk), .sd_mosi(c_mosi), .sd_miso(c_miso), .sd_cs_n(c_cs_n),
        .flash_clk(f_clk), .flash_mosi(f_mosi), .flash_miso(f_miso), .flash_cs_n(f_cs_n),
        .hp_bck(bck), .hp_ws(ws), .hp_din(din), .pa_en(pa_en),
        .tmds_blue(), .tmds_green(), .tmds_red(),
        .O_sdram_clk(sd_clk), .O_sdram_cke(sd_cke), .O_sdram_cs_n(sd_cs_n),
        .O_sdram_ras_n(sd_ras_n), .O_sdram_cas_n(sd_cas_n), .O_sdram_wen_n(sd_wen_n),
        .O_sdram_dqm(sd_dqm), .O_sdram_addr(sd_addr), .O_sdram_ba(sd_ba),
        .IO_sdram_dq(sd_dq), .pc(pc)
    );

    sdram_model chip (
        .clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
        .we_n(sd_wen_n), .dqm(sd_dqm), .addr(sd_addr), .ba(sd_ba), .dq(sd_dq)
    );

    flash_model #(.BASE(24'h400000)) flash (
        .sclk(f_clk), .cs_n(f_cs_n), .mosi(f_mosi), .miso(f_miso)
    );

    sd_model card (
        .sclk(c_clk), .cs_n(c_cs_n), .mosi(c_mosi), .miso(c_miso)
    );

    // a byte address of the SDRAM -> the model's word (as sdram.v lays it out)
    function [20:0] chip_index(input [22:0] a);
        chip_index = {a[11:10], a[22:12], a[9:2]};
    endfunction

    localparam [15:0] CRLF = {8'd13, 8'd10};

    integer errors = 0;
    task fail(input [8*60-1:0] what);
        begin errors = errors + 1; if (errors <= 20) $display("FAIL: %0s", what); end
    endtask

    // ---------------------------------------------------------------- the image
    reg [7:0] img [0:65535];
    integer   img_size, fd;
    initial begin
        fd = $fopen("os.img", "rb");
        if (fd == 0) begin $display("FAIL: no os.img"); $finish; end
        img_size = $fread(img, fd);
        $fclose(fd);
    end

    // ---------------------------------------------------------------- the PC's side
    // everything that comes in on tx
    reg [7:0] log [0:16383];
    integer   n_got = 0;
    integer   i, ri;
    reg [7:0] b;
    always begin
        @(negedge tx);                          // a start bit
        #(BIT * 1.5);
        for (ri = 0; ri < 8; ri = ri + 1) begin b[ri] = tx; #(BIT); end
        if (tx !== 1'b1) fail("a byte without its stop bit");
        log[n_got] = b;
        n_got = n_got + 1;
    end

    task send(input [7:0] c);
        integer k;
        begin
            rx = 0; #(BIT);
            for (k = 0; k < 8; k = k + 1) begin rx = c[k]; #(BIT); end
            rx = 1; #(BIT);
        end
    endtask

    // where text s (its len bytes, the last one in bits 7..0) begins in the log at or
    // after from, or -1
    function integer find(input [8*64-1:0] s, input integer len, input integer from);
        integer p, q, ok;
        begin
            find = -1;
            for (p = from; p + len <= n_got && find < 0; p = p + 1) begin
                ok = 1;
                for (q = 0; q < len; q = q + 1)
                    if (log[p + q] !== s[8*(len-1-q) +: 8]) ok = 0;
                if (ok) find = p;
            end
        end
    endfunction

    // wait for text s (up to 64 characters, none of them 0) after mark; mark moves
    // past it
    integer mark = 0, at, len;
    task expect(input [8*64-1:0] s, input real ms);
        real deadline;
        begin
            len = 64;
            while (len > 0 && s[8*(len-1) +: 8] == 8'h00) len = len - 1;
            deadline = $realtime + ms * 1.0e6;
            at = find(s, len, mark);
            while (at < 0 && $realtime < deadline) begin
                #20000;
                at = find(s, len, mark);
            end
            if (at < 0) begin
                errors = errors + 1;
                $write("FAIL: never came: \"");
                for (i = len - 1; i >= 0; i = i - 1) $write("%c", s[8*i +: 8]);
                $write("\"; since then: \"");
                for (i = mark; i < n_got; i = i + 1)
                    $write("%c", (log[i] == 13) ? "|" : (log[i] == 10) ? " " : log[i]);
                $display("\" (pc %h)", pc);
                show_log;
                $display("FAIL: %0d errors", errors);
                $finish;
            end
            mark = at + len;
        end
    endtask

    task show_log;
        begin
            $write("the serial port so far:\n  ");
            for (i = 0; i < n_got; i = i + 1)
                if (log[i] == 10) $write("\n  "); else if (log[i] != 13) $write("%c", log[i]);
            $write("\n");
        end
    endtask

    // ---------------------------------------------------------------- the sound
    // The MAX98357A: the bits at the rising edges of BCLK, 16 after each change of
    // LRCLK and one BCLK of delay. The tone: how many samples of +4000 in a row, and
    // whether -4000 came after them.
    integer    sn = 0, plus = 0, frames = 0;
    reg        last_ws = 1, minus = 0;
    reg [15:0] sword = 0, sleft = 0;
    always @(posedge bck) begin
        if (ws != last_ws) sn = 0; else sn = sn + 1;
        last_ws = ws;
        if (sn >= 1 && sn <= 16) sword = {sword[14:0], din};
        if (sn == 16) begin
            if (!ws) sleft = sword;
            else begin
                frames = frames + 1;
                if (sword !== sleft) fail("the sound: left and right differ");
                if (sleft == 16'd4000 && !minus) plus = plus + 1;
                else if (sleft == -16'sd4000 && plus > 0) minus = 1;
                else if (sleft != 16'd0 && sleft != 16'd4000 && sleft != -16'sd4000)
                    fail("the sound: a sample that is not the tone");
            end
        end
    end

    // ---------------------------------------------------------------- the screen
    // the character in row r, column c, as the SDRAM holds it
    function [31:0] screen(input integer r, input integer c);
        screen = chip.mem[chip_index(23'h780000 + r * 320 + c * 4)];
    endfunction

    task check_row(input integer r, input [8*16-1:0] text, input integer len);
        integer c;
        reg [31:0] want;
        begin
            for (c = 0; c < 80; c = c + 1) begin
                want = {8'd14, 8'd6, 8'd0, (c < len) ? text[8*(len-1-c) +: 8] : 8'h20};
                if (screen(r, c) !== want) begin
                    errors = errors + 1;
                    if (errors <= 20)
                        $display("FAIL: screen row %0d column %0d: %h, expected %h", r, c, screen(r, c), want);
                end
            end
        end
    endtask

    // the video unit's fetches (a sign that the picture is drawn)
    integer fetches = 0;
    always @(posedge clk) if (dut.vmem_ack) fetches = fetches + 1;

    // ---------------------------------------------------------------- the boots
    integer reset_errors = 0, e0;
    task restart;
        integer a;
        begin
            e0 = chip.errors;
            chip.quiet = 1;                         // its complaints now are expected: counted, not shown
            reset = 1;
            repeat (8) @(posedge clk);
            for (a = 0; a < 16384; a = a + 4)       // no operating system left over
                chip.mem[chip_index(a)] = 32'h0;
            reset = 0;
            #250_000;                               // the power-up: 200 us, 8 refreshes
            reset_errors = reset_errors + (chip.errors - e0);
            chip.quiet = 0;
        end
    endtask

    // what the loader says for a good image from the flash or the card
    task expect_load(input real ms);
        begin
            expect("loading ", ms);
            expect({" bytes to 00000000 ok, start at 00000000", CRLF}, ms);
            expect({"mp32 ready", CRLF}, 10);
        end
    endtask

    integer t0, mark1;
    initial begin
        flash.load("os.img");
        card.load("os.img");
        repeat (8) @(posedge clk);

        // ================================================ 1. from the flash
        t0 = $time;
        reset = 0;
        expect({"mp32 boot", CRLF, "flash: "}, 10);
        expect_load(5);
        mark1 = mark;
        $display("1. from the flash: \"mp32 ready\" after %0.2f ms", ($time - t0) / 1.0e6);
        if (dut.processor.ex.vec_r !== 22'd0) fail("VEC is not 0");

        // the screen, row 0 (the operating system cleared what the loader wrote)
        #2000;
        check_row(0, "mp32 ready", 10);
        check_row(1, "", 0);

        // the echo, on the serial port's interrupt (vector 19, at 0 + 76)
        send("h"); send("i"); send(8'd13);
        expect({"hi", 8'd13}, 5);
        #100000;                                // the CR clears the next row first
        check_row(1, "hi", 2);
        if (leds !== 6'd4) begin
            errors = errors + 1;
            $display("FAIL: LEDs %0d, expected 4", leds);
        end

        // the beep (started after the banner)
        wait (minus || $time > t0 + 20_000_000);
        if (pa_en !== 1'b1) fail("the amplifier is not on");
        if (!minus) fail("the tone never went to -4000");
        if (plus != 53) begin
            errors = errors + 1;
            $display("FAIL: the tone: %0d samples of +4000, expected 53", plus);
        end
        $display("   the echo, the screen, the beep (%0d samples of +4000, then -4000)", plus);

        // ================================================ 2. from the card
        flash.erase;
        t0 = $time;
        restart;
        expect({"mp32 boot", CRLF, "flash: no image", CRLF, "sd card: "}, 10);
        expect_load(20);
        $display("2. from the card: \"mp32 ready\" after %0.2f ms (%0d commands, %0d blocks)",
                 ($time - t0) / 1.0e6, card.commands, card.blocks_read);
        if (card.blocks_read != (img_size + 511) / 512) fail("the card: not as many blocks as the image has");

        // ================================================ 3. from the serial port
        flash.load("os.img");
        flash.mem[100] = flash.mem[100] ^ 8'h01;    // one bit of the payload
        card.present = 0;
        t0 = $time;
        restart;
        expect({"mp32 boot", CRLF, "flash: loading "}, 10);
        expect({" bytes to 00000000 bad checksum", CRLF}, 10);
        expect({"sd card: no card", CRLF}, 10);
        expect({"serial port: send the image", CRLF}, 10);
        send(8'h00); send("m"); send("p");          // noise first
        for (i = 0; i < img_size; i = i + 1) send(img[i]);
        expect_load(5);
        $display("3. from the serial port: \"mp32 ready\" after %0.2f ms (%0d bytes sent)",
                 ($time - t0) / 1.0e6, img_size + 3);

        // ================================================ 4. from an SDSC card
        flash.erase;
        card.present = 1;
        card.sdhc = 0;
        card.blocks_read = 0;
        t0 = $time;
        restart;
        expect({"mp32 boot", CRLF, "flash: no image", CRLF, "sd card: "}, 10);
        expect_load(20);
        $display("4. from an SDSC card: \"mp32 ready\" after %0.2f ms (%0d blocks)",
                 ($time - t0) / 1.0e6, card.blocks_read);
        if (card.blocks_read != (img_size + 511) / 512) fail("the SDSC card: not as many blocks as the image has");

        // ================================================ the rest
        if (chip.errors != reset_errors) begin
            errors = errors + chip.errors - reset_errors;
            $display("FAIL: %0d SDRAM timing errors", chip.errors - reset_errors);
        end
        $display("SDRAM: %0d refreshes missed during the power-ups after a reset (not counted)", reset_errors);
        if (fetches < 10) fail("the video unit fetched almost nothing");
        show_log;
        $display("%0d bytes on the serial port, %0d video fetches, SDRAM: %0d reads, %0d writes, %0d refreshes",
                 n_got, fetches, chip.reads, chip.writes, chip.refreshes);
        $display("simulated %0.2f ms", $time / 1.0e6);
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
