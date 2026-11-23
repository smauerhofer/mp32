// computer_tb.v: the whole mp32 computer (computer.v) with the model of the SDRAM,
// running the boot program (boot.s, as build/boot.hex).
//
//   make test
//
// The clocks as on the board: 42 MHz for the processor, 25.2 MHz for the pixels. The
// serial port runs at 42 MHz / 16 here (UART_DIV = 16), so the bytes do not take long.
// The test bench plays the PC on the serial port. It checks:
//   1. that the computer says "mp32 ready\r\n" on the serial port;
//   2. that it wrote the same on the screen: row 0 of the text in the SDRAM, each
//      character with its colors (ink 14, paper 6), and the rest of the row blank;
//   3. that it echoes what it is sent ("hi" and a CR) on the serial port and on the
//      screen (row 1), and that the LEDs count the bytes (1 + 3 = 4);
//   4. that the boot program beeps: the amplifier on (pa_en), and on the I2S wires
//      the tone, +4000 for 53 samples, then -4000; each sample on both channels;
//   5. that the SDRAM model saw no timing errors, and the video unit fetched lines.

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

    wire        sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_wen_n;
    wire [3:0]  sd_dqm;
    wire [10:0] sd_addr;
    wire [1:0]  sd_ba;
    wire [31:0] sd_dq;

    computer #(.UART_DIV(DIV)) dut (
        .clk(clk), .pixel_clk(pixel_clk), .reset(reset),
        .buttons(2'b00), .leds(leds), .uart_rx(rx), .uart_tx(tx),
        .sd_clk(), .sd_mosi(), .sd_miso(1'b1), .sd_cs_n(),
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

    // a byte address of the SDRAM -> the model's word (as sdram.v lays it out)
    function [20:0] chip_index(input [22:0] a);
        chip_index = {a[11:10], a[22:12], a[9:2]};
    endfunction

    integer errors = 0;
    task fail(input [8*60-1:0] what);
        begin errors = errors + 1; if (errors <= 20) $display("FAIL: %0s", what); end
    endtask

    // ---------------------------------------------------------------- the PC's side
    // what comes in on tx, as a string
    reg [8*64-1:0] got = 0;
    integer        n_got = 0;
    integer        i;
    reg [7:0]      b;
    always begin
        @(negedge tx);                          // a start bit
        #(BIT * 1.5);
        for (i = 0; i < 8; i = i + 1) begin b[i] = tx; #(BIT); end
        if (tx !== 1'b1) fail("a byte without its stop bit");
        got = {got[8*63-1:0], b};
        n_got = n_got + 1;
    end

    task send(input [7:0] c);
        integer k;
        begin
            rx = 0; #(BIT);
            for (k = 0; k < 8; k = k + 1) begin rx = c[k]; #(BIT); end
            rx = 1; #(BIT * 2);
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

    // ---------------------------------------------------------------- the test
    integer t0;
    initial begin
        repeat (8) @(posedge clk);
        reset = 0;
        // 1. the banner: 12 bytes (the SDRAM's power-up, 200 us, and the screen's
        // clearing come first)
        t0 = $time;
        wait (n_got == 12 || $time > 30_000_000);
        if (n_got != 12) begin
            $display("FAIL: the banner did not come (%0d bytes, pc %h)", n_got, pc);
            errors = errors + 1;
        end else if (got[8*12-1:0] !== {"mp32 ready", 8'd13, 8'd10})
            begin fail("the banner is wrong"); for (i = 11; i >= 0; i = i - 1) $write("%h ", got[8*i +: 8]); $write("\n"); end
        $display("banner after %0.2f ms", ($time - t0) / 1.0e6);

        // 2. the screen, row 0
        #2000;
        check_row(0, "mp32 ready", 10);
        check_row(1, "", 0);

        // 3. the echo
        send("h"); send("i"); send(8'd13);
        wait (n_got == 15 || $time > 40_000_000);
        #100000;                                // the CR clears the next row first
        if (got[8*3-1:0] !== {"hi", 8'd13}) begin fail("the echo is wrong"); $display("%h", got[8*3-1:0]); end
        check_row(1, "hi", 2);
        if (leds !== 6'd4) begin
            errors = errors + 1;
            $display("FAIL: LEDs %0d, expected 4", leds);
        end

        // 4. the beep (started after the banner)
        wait (minus || $time > 50_000_000);
        if (pa_en !== 1'b1) fail("the amplifier is not on");
        if (!minus) fail("the tone never went to -4000");
        if (plus != 53) begin
            errors = errors + 1;
            $display("FAIL: the tone: %0d samples of +4000, expected 53", plus);
        end
        $display("the beep: %0d samples of +4000, then -4000, %0d frames heard", plus, frames);

        // 5.
        if (chip.errors != 0) begin
            errors = errors + chip.errors;
            $display("FAIL: %0d SDRAM timing errors", chip.errors);
        end
        if (fetches < 10) fail("the video unit fetched almost nothing");
        $display("%0d bytes on the serial port, %0d video fetches, SDRAM: %0d reads, %0d writes, %0d refreshes",
                 n_got, fetches, chip.reads, chip.writes, chip.refreshes);
        $display("simulated %0.2f ms", $time / 1.0e6);
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
