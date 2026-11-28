// forth_tb.v: the whole mp32 computer (../computer/computer.v) boots the FORTH kernel
// (build/forth.img, from the SPI flash's model) and the test bench talks to it, as the
// PC on the serial port and as a keyboard on the CH9350L's wire.
//
//   make test           everything (about half an hour of simulation)
//   make test-quick     only the boot and the screen (-DSCREEN_ONLY)
//
// The serial port and the keyboard's line run at 42 MHz / 16 here (2.6 Mbaud), so the
// bytes do not take long; everything else is as on the board. The test bench sends a
// line (and a CR, as a terminal does), and waits for what FORTH answers: the echo of
// the line, then what it prints, then " ok". It checks:
//
//   - the banner on the serial port and on the screen (below the loader's lines)
//   - the interpreter, numbers in all bases, the stacks, arithmetic and division
//   - compiling: : ; (inlining, calls, tail calls), IF ELSE THEN, BEGIN UNTIL /
//     WHILE REPEAT, DO LOOP +LOOP LEAVE ?DO I J, FOR NEXT, RECURSE, CREATE DOES>,
//     VARIABLE, CONSTANT (24 and 32 bits), ." S" ABORT", POSTPONE, EVALUATE
//   - the errors: an unknown word, the stack's limits (the hardware's exceptions 9
//     and 8), division by 0, compile only, CATCH and THROW; FORTH goes on after each
//   - a line typed on the keyboard (key codes, Shift, Enter), which KEY gets from the
//     same input queue
//   - the SD card (its model, with CMD9, CMD10, CMD24), left in the middle of a block
//     at first (FORTH must start it all the same): its capacity and CID, LOAD of
//     a source block (a header with $900DF00D, 56 lines of 72), NEW-SOURCE, LINE,
//     written back (FLUSH) and read again, LIST, a block that is not a source block,
//     the end of the card, FONT into the font RAM
//   - the prompt "> " in front of every line
//   - the comments ( ), //, /* */ (over lines at the terminal and in a block)
//   - the screen: the echo and the answers in green on black, PAGE, AT-XY, scrolling

`timescale 1ns/1ps

module forth_tb;
    reg clk = 0, pixel_clk = 0;
    always #11.905 clk = ~clk;                 // 42 MHz
    always #19.841 pixel_clk = ~pixel_clk;     // 25.2 MHz

    localparam DIV = 16;                       // ticks of a bit on the serial lines
    localparam real BIT = DIV * 23.81;         // ns

    reg         reset = 1;
    reg  [1:0]  buttons = 2'b00;        // bit 1: S2
    reg         rx = 1;
    wire        tx;
    wire [5:0]  leds;
    wire [31:0] pc;
    wire        f_clk, f_mosi, f_miso, f_cs_n;
    wire        c_clk, c_mosi, c_miso, c_cs_n;
    wire        k_rx, k_tx;

    wire        sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_wen_n;
    wire [3:0]  sd_dqm;
    wire [10:0] sd_addr;
    wire [1:0]  sd_ba;
    wire [31:0] sd_dq;

    computer #(.UART_DIV(DIV), .KBD_DIV(DIV), .BOOT("boot.hex")) dut (
        .clk(clk), .pixel_clk(pixel_clk), .reset(reset),
        .buttons(buttons), .leds(leds), .uart_rx(rx), .uart_tx(tx),
        .sd_clk(c_clk), .sd_mosi(c_mosi), .sd_miso(c_miso), .sd_cs_n(c_cs_n),
        .flash_clk(f_clk), .flash_mosi(f_mosi), .flash_miso(f_miso), .flash_cs_n(f_cs_n),
        .hp_bck(), .hp_ws(), .hp_din(), .pa_en(),
        .kbd_rx(k_rx), .kbd_tx(k_tx),
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

    // the card up to the fonts (block 16384 on, FONT_LBA), 8 MB and a bit
    localparam CARD = (16384 + 16) * 512;
    sd_model #(.SIZE(CARD)) card (
        .sclk(c_clk), .cs_n(c_cs_n), .mosi(c_mosi), .miso(c_miso)
    );

    ch9350 kbd (.tx(k_rx), .rx(k_tx));

    function [20:0] chip_index(input [22:0] a);
        chip_index = {a[11:10], a[22:12], a[9:2]};
    endfunction

    localparam [15:0] CRLF = {8'd13, 8'd10};

    integer errors = 0;

    // ---------------------------------------------------------------- the PC's side
    reg [7:0] log [0:262143];
    integer   n_got = 0;
    integer   i, ri;
    reg [7:0] b;
    always begin
        @(negedge tx);
        #(BIT * 1.5);
        for (ri = 0; ri < 8; ri = ri + 1) begin b[ri] = tx; #(BIT); end
        if (tx !== 1'b1) begin errors = errors + 1; $display("FAIL: a byte without its stop bit"); end
        log[n_got] = b;
        n_got = n_got + 1;
`ifdef LIVE
        $write("%c", b); $fflush;
`endif
    end

    task send(input [7:0] c);
        integer k;
        begin
            rx = 0; #(BIT);
            for (k = 0; k < 8; k = k + 1) begin rx = c[k]; #(BIT); end
            rx = 1; #(BIT);
        end
    endtask

    // a line (up to 96 characters, the last in bits 7..0), then a CR
    integer slen;
    task say(input [8*96-1:0] s);
        integer k;
        begin
            slen = 96;
            while (slen > 0 && s[8*(slen-1) +: 8] == 8'h00) slen = slen - 1;
            for (k = slen - 1; k >= 0; k = k - 1) send(s[8*k +: 8]);
            send(8'd13);
        end
    endtask

    function integer find(input [8*96-1:0] s, input integer len, input integer from);
        integer p, q, ok;
        begin
            find = -1;
            for (p = from; p + len <= n_got && find < 0; p = p + 1) begin
                ok = 1;
                for (q = 0; q < len && ok; q = q + 1)
                    if (log[p + q] !== s[8*(len-1-q) +: 8]) ok = 0;
                if (ok) find = p;
            end
        end
    endfunction

    task show_log;
        begin
            $write("the serial port:\n  ");
            for (i = 0; i < n_got; i = i + 1)
                if (log[i] == 10) $write("\n  "); else if (log[i] != 13) $write("%c", log[i]);
            $write("\n");
        end
    endtask

    // wait for text s after mark; mark moves past it
    integer mark = 0, at, len;
    task expect(input [8*96-1:0] s, input real ms);
        real deadline;
        begin
            len = 96;
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

    // a line, and what FORTH answers to it (then " ok" and CR LF)
    task check(input [8*96-1:0] line, input [8*96-1:0] answer);
        begin
            say(line);
            expect(answer, 300);            // (LIST: 65 lines, each scrolls 1.5 ms)
            expect({" ok", CRLF}, 300);
        end
    endtask

    // a line that FORTH answers with an error: the message, CR LF, no " ok"
    task check_error(input [8*96-1:0] line, input [8*96-1:0] message);
        integer m0;
        begin
            say(line);
            expect({message, CRLF}, 30);
            m0 = mark;
            #200000;
            if (find(" ok", 3, m0) == m0) begin
                errors = errors + 1;
                $display("FAIL: \" ok\" after an error");
            end
        end
    endtask

    // ---------------------------------------------------------------- the screen
    function [31:0] screen(input integer r, input integer c);
        screen = chip.mem[chip_index(23'h780000 + r * 320 + c * 4)];
    endfunction

    // row r begins with text (len characters, ASCII), green on black
    task check_row(input integer r, input [8*40-1:0] text, input integer n);
        integer c;
        reg [7:0]  ch;
        reg [31:0] want;
        begin
            for (c = 0; c < n; c = c + 1) begin
                ch   = text[8*(n-1-c) +: 8];
                want = {8'd82, 8'd0, 8'd0, (ch >= 8'h40) ? (ch & 8'h1F) : ch};
                if (screen(r, c) !== want) begin
                    errors = errors + 1;
                    if (errors <= 30)
                        $display("FAIL: screen row %0d column %0d: %h, expected %h", r, c, screen(r, c), want);
                end
            end
        end
    endtask

    // ---------------------------------------------------------------- the keyboard
    // a key pressed and let go: its USB code, with Shift or not
    task key(input [7:0] code, input shift);
        begin
            kbd.keyboard({shift ? 8'h02 : 8'h00, 8'h00, code, 40'h0}, 1);
            kbd.keyboard(64'h0, 1);
        end
    endtask

    // ---------------------------------------------------------------- the card
    // an image over the serial port (RECEIVE, INSTALL): the header, 8 bytes of
    // payload; bad: a header with a wrong magic number (and no payload)
    reg [31:0] img [0:9];
    task send_image(input bad);
        integer w, k;
        begin
            img[0] = bad ? 32'h3233706E : 32'h3233706D;
            img[1] = 0; img[2] = 8; img[3] = 0;
            img[8] = 32'h11223344; img[9] = 32'h55667788;
            img[4] = img[8] + img[9];
            img[5] = 0; img[6] = 0;
            img[7] = 0 - (img[0] + img[1] + img[2] + img[3] + img[4]);
            for (w = 0; w < (bad ? 8 : 10); w = w + 1)
                for (k = 0; k < 4; k = k + 1) send(img[w][8*k +: 8]);
        end
    endtask

    // text at byte a of the card (n characters, ASCII)
    task card_text(input integer a, input [8*64-1:0] text, input integer n);
        integer k;
        for (k = 0; k < n; k = k + 1) card.mem[a + k] = text[8*(n-1-k) +: 8];
    endtask

    function [7:0] font_byte(input integer k);
        font_byte = (k * 7 + 3) & 255;
    endfunction

    // ---------------------------------------------------------------- the test
    integer t0, row0;
    initial begin
        kbd.bit_ns    = BIT;
        kbd.rx_bit_ns = BIT;
        flash.load("forth.img");
        // the card: FORTH's blocks 0 .. 3 blank, block 3 a little program; font 1
        // (card sectors 8 * FONT_BLOCK + 4 ..) a pattern
        for (i = 0; i < 4 * 4096; i = i + 1) card.mem[i] = 8'h00;
        // block 3: a source block (the magic $900DF00D, then lines of 72)
        card.mem[3 * 4096] = 8'h0D; card.mem[3 * 4096 + 1] = 8'hF0;
        card.mem[3 * 4096 + 2] = 8'h0D; card.mem[3 * 4096 + 3] = 8'h90;
        card_text(3 * 4096 + 64,       "// block 3: a test, this line is a comment GREET", 48);
        card_text(3 * 4096 + 64 + 72,  ": GREET .\" hi from block 3 \" ;", 31);
        card_text(3 * 4096 + 64 + 144, "GREET /* a comment over", 23);
        card_text(3 * 4096 + 64 + 216, "two lines: GREET */ 42 .", 24);
        for (i = 0; i < 2048; i = i + 1) card.mem[(256 * 8 + 4) * 512 + i] = font_byte(i);
        card.present = 1;
        // the card as an old boot loader left it: in the middle of block 0 (COLD
        // looks at the card for the startup block)
        card.stale_block(16);
        repeat (8) @(posedge clk);
        t0 = $time;
        reset = 0;

        // ================================================ the boot
        expect({"mp32 boot", CRLF, "flash: loading "}, 10);
        expect({" ok, start at 00000000", CRLF}, 40);
        expect("mp32 FORTH, ", 20);
        expect({" bytes free", CRLF}, 20);
        $display("booted: the banner after %0.2f ms", ($time - t0) / 1.0e6);
        if (leds !== 6'h0F) begin errors = errors + 1; $display("FAIL: LEDs %b, expected 001111", leds); end
        #100000;
        // the loader's two lines, then the banner on row 2
        check_row(0, "mp32 boot", 9);
        check_row(2, "mp32 FORTH, ", 12);

`ifndef SCREEN_ONLY
        // ================================================ the interpreter
        check("1 2 + .", "1 2 + . 3 ");
        #100000;
        check_row(3, "> 1 2 + . 3  OK", 15);                        // below the banner
        check("HEX FF DECIMAL .", "255 ");
        check("$10 #10 %10 + + .", "28 ");
        check("-5 ABS . 7 NEGATE .", "5 -7 ");
        check("'A' .", "65 ");
        check("1 2 3 .S", "[3] 1 2 3 ");
        check(". . .", "3 2 1 ");
        check("2 3 4 ROT . . . 1 2 3 -ROT . . .", "2 4 3 2 1 3 ");
        check("7 2 /MOD . . -7 2 / . 7 -2 MOD .", "3 1 -3 1 ");
        check("1000 3 7 */ . 100000 100000 UM* SWAP U. U.", "428 1410065408 2 ");
        check("6 7 * . 10 3 MIN . 10 3 MAX . 1 4 LSHIFT .", "42 3 10 16 ");
        check("3 4 < . 4 3 < . 5 5 = . -1 0 U< . 0 0= .", "-1 0 -1 0 -1 ");
        check("3 4 <= . 4 4 <= . 5 4 <= . 3 4 >= . 4 4 >= . -5 4 >= .", "-1 -1 0 0 -1 0 ");
        check("-1 0 U<= . 0 -1 U<= . 5 5 U>= . 1 -1 U>= .", "0 -1 -1 0 ");
        check("-3 0<= . 0 0<= . 3 0<= . -3 0>= . 0 0>= . 3 0>= .", "-1 -1 0 0 -1 -1 ");
        check(": LE <= ; 2 3 LE . 3 2 LE .", "-1 0 ");               // inlined
        check("-1 U. 255 HEX . DECIMAL", "4294967295 FF ");

        // ================================================ compiling
        check(": SQ DUP * ;", "");
        check("7 SQ . 12 SQ .", "49 144 ");
        check(": A1 1+ ; : A2 A1 ; 5 A2 .", "6 ");                 // a tail call
        check(": SGN DUP 0< IF DROP -1 ELSE 0> IF 1 ELSE 0 THEN THEN ;", "");
        check("-5 SGN . 0 SGN . 9 SGN .", "-1 0 1 ");
        check(": CNT 0 BEGIN 1+ DUP 5 = UNTIL ; CNT .", "5 ");
        check(": W 1 BEGIN DUP 100 < WHILE 2* REPEAT ; W .", "128 ");
        check(": T1 5 0 DO I . LOOP ; T1", "0 1 2 3 4 ");
        check(": T2 3 0 DO 2 0 DO J 10 * I + . LOOP LOOP ; T2", "0 1 10 11 20 21 ");
        check(": T3 10 0 DO I 3 = IF LEAVE THEN I . LOOP ; T3", "0 1 2 ");
        check(": T4 10 0 DO I . 3 +LOOP ; T4", "0 3 6 9 ");
        check(": T5 0 10 DO I . -3 +LOOP ; T5", "10 7 4 1 ");
        check(": T6 0 0 ?DO I . LOOP 7 . ; T6", "7 ");
        check(": T7 3 FOR R@ . NEXT ; T7", "3 2 1 0 ");
        check(": T8 40 FOR R@ 2 MOD + NEXT ; 0 T8 .", "20 ");     // NEXT2, not UNEXT
        check(": FAC DUP 1 > IF DUP 1- RECURSE * THEN ; 10 FAC .", "3628800 ");
        check(": CON CREATE , DOES> @ ; 42 CON X X .", "42 ");
        check("VARIABLE V 5 V ! V @ . 3 V +! V ?", "5 8 ");
        check("100 CONSTANT C1 123456789 CONSTANT C2 C1 . C2 .", "100 123456789 ");
        check(": UV V @ C2 + ; UV .", "123456797 ");               // both inlined
        check(": HI .\" hello\" ; HI", "hello");
        check("S\" abc\" TYPE", "abc");
        check(": SS S\" xyz\" ; SS TYPE", "xyz");
        check(": EV S\" 2 3 * .\" EVALUATE ; EV", "6 ");
        check(": IM 1 . ; IMMEDIATE : U2 IM ; U2", "1 ");
        check(": P2 POSTPONE SQ ; IMMEDIATE : P3 P2 ; 3 P3 .", "9 ");
        check("3 ' SQ EXECUTE .", "9 ");
        check("CHAR Z . : CZ [CHAR] Y ; CZ .", "90 89 ");
        check("1 ( a comment ) 2 // 3 4 .", "");                  // comments
        check(". . 5 /* a */ 6 + .", "2 1 11 ");
        say("7 /* a comment over");                                 // over two lines
        say("two lines */ 8 + .");
        expect("15 ", 30);
        expect({" ok", CRLF}, 30);
        say(": CC /* in a */ 9 // a definition 10 .");             // compiling: no ok
        expect({"10 .", " ", CRLF}, 30);
        check("; CC .", "9 ");
        check_error("[CHAR] Z .", "[CHAR] compile only");

        // ================================================ errors
        check_error("FOO", "FOO ?");
        check_error("DROP", "stack underflow");
        check_error("1 0 /", "division by zero");
        check_error(": AQ IF ABORT\" bad\" THEN ; 1 AQ", "bad");
        check("0 AQ", "");
        check(": TC 1 0 / ; ' TC CATCH .", "-10 ");
        check(": TT 3 THROW ; ' TT CATCH . 5 .", "3 5 ");
        check_error(": RR RECURSE 1 ; RR", "return stack overflow"); // the hardware's limit
        check_error(": PP 1 RECURSE ; PP", "stack overflow");    // a tail call: a loop
        check("DEPTH .", "0 ");

        // ================================================ the keyboard
        key(8'h1F, 0); key(8'h2C, 0); key(8'h20, 0); key(8'h2C, 0);  // 2 3
        key(8'h2E, 1); key(8'h2C, 0); key(8'h37, 0);                   // + .
        key(8'h28, 0);                                                 // Enter
        expect("2 3 + . 5 ", 30);
        expect({" ok", CRLF}, 30);
        $display("the keyboard: \"2 3 + .\" typed, \"5\" answered");

        check("WORDS", "DUP ");
`endif

        // a line longer than the screen is wide (it wraps there)
        check(".( xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx) 1 .", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx1 ");

        // ================================================ the SD card
        check("3 LOAD", "hi from block 3 42 ");
        check("SD-BLOCKS . BLOCKS .", "17408 2176 ");
        check("SD-INFO", {"SDHC/SDXC card, 8 MB: 17408 blocks of 512 bytes, 2176 FORTH blocks of 4 KB", CRLF,
                          "maker 03, OEM SD, product MP32C, revision 1.0, serial 12345678, made 2026-11", CRLF});
        check("1 NEW-SOURCE S\" .( written by FORTH)\" 0 LINE SWAP MOVE UPDATE FLUSH", "");
        for (i = 0; i < 20; i = i + 1)
            if (card.mem[4096 + 64 + i] !== ((".( written by FORTH)" >> (8 * (19 - i))) & 8'hFF)) begin
                errors = errors + 1;
                $display("FAIL: the card's byte %0d: %h", 4096 + 64 + i, card.mem[4096 + 64 + i]);
            end
        if ({card.mem[4099], card.mem[4098], card.mem[4097], card.mem[4096]} !== 32'h900DF00D
            || card.mem[4100] !== 8'h00 || card.mem[4096 + 44] !== 8'h01 || card.mem[4096 + 63] !== 8'h00) begin
            errors = errors + 1;
            $display("FAIL: the source block's header on the card");
        end
        if (card.mem[2 * 4096 - 1] !== 8'h20) begin
            errors = errors + 1;
            $display("FAIL: the block's last byte on the card: %h", card.mem[2 * 4096 - 1]);
        end
        if (card.blocks_written != 8) begin
            errors = errors + 1;
            $display("FAIL: %0d blocks written to the card, expected 8", card.blocks_written);
        end
        check("EMPTY-BUFFERS 1 BLOCK 64 + 20 TYPE", ".( written by FORTH)");
        check("1 LIST", {"version 1", CRLF, " 0 .( written by FORTH)"});
        check_error("2 LIST", "not a source block");
        check_error("2 LOAD", "not a source block");
        check_error("2176 BLOCK", "invalid block number");           // the card's end
        check("1 2 FONT", "");
        for (i = 0; i < 2048; i = i + 1)
            if (dut.picture.font[512 * 2 + i / 4][8 * (i % 4) +: 8] !== font_byte(i)) begin
                errors = errors + 1;
                if (errors < 30) $display("FAIL: font 2, byte %0d: %h", i, dut.picture.font[512 * 2 + i / 4][8 * (i % 4) +: 8]);
            end
        $display("the card: LOAD, a block written back and read again, LIST, FONT (%0d blocks read, %0d written)",
                 card.blocks_read, card.blocks_written);

        // ================================================ the volume
        check_error("VOLUME", "no volume (NEW-VOLUME makes one)");
        say("S\" testcard\" NEW-VOLUME VOLUME");
        expect({"volume testcard", 8'd32}, 30);
        expect({" startup 0", CRLF, "  BOOT    "}, 30);
        expect({"  SOURCE         1024      64512", CRLF, "  DATA          65536          0", CRLF}, 30);
        expect({" ok", CRLF}, 30);
        if ({card.mem[3], card.mem[2], card.mem[1], card.mem[0]} !== 32'h900DCA4D) begin
            errors = errors + 1;
            $display("FAIL: no volume block on the card");
        end
        check("RANGE SOURCE . . RANGE fonts . .", "64512 1024 256 256 ");
        check("700 10 SET-RANGE games RANGE GAMES . .", "10 700 ");
        check_error("RANGE XYZ", "no such range");
        check("1 0 FONT", "");                                        // FONTS: 256 on
        if (dut.picture.font[3][31:24] !== font_byte(15)) begin
            errors = errors + 1;
            $display("FAIL: font 0 not from the range FONTS");
        end

        // ================================================ the source blocks' header
        check("3 SCR ! S\" greeting\" TITLE 1 CHAIN 1 SHADOW FLUSH", "");
        check("EMPTY-BUFFERS 3 LOAD", "hi from block 3 42 written by FORTH");  // and block 1
        check("1 3 INDEX", {"     3 greeting", 8'd32});
        check("3 DOC", " 0 .( written by FORTH)");
        check_error("1 DOC", "no shadow block");
        check("3 LIST", " next 1 shadow 1 version 1");
        card.mem[3 * 4096 + 64 + 300] = "X";                           // damaged
        check_error("EMPTY-BUFFERS 3 LOAD", "source block damaged (its CRC)");
        card.mem[3 * 4096 + 64 + 300] = 8'h00;
        check("EMPTY-BUFFERS 3 LOAD", "hi from block 3 ");

        // ================================================ the startup block
        say("3 STARTUP COLD");
        expect("mp32 FORTH, ", 30);
        expect({"startup block 3", CRLF}, 30);
        expect("hi from block 3 42 written by FORTH", 100);
        expect({"> "}, 30);
        buttons = 2'b10;                                               // S2 held
        say("COLD");
        expect({"S2: no startup block", CRLF, "> "}, 30);
        buttons = 2'b00;
        check("0 STARTUP", "");

        // ================================================ images over the serial port
        say("2000 RECEIVE");
        expect({"send the image", CRLF}, 30);
        send_image(0);
        expect({"received 8 bytes", CRLF, " ok", CRLF}, 100);
        if ({card.mem[2000 * 4096 + 7], card.mem[2000 * 4096 + 6], card.mem[2000 * 4096 + 5], card.mem[2000 * 4096 + 4],
             card.mem[2000 * 4096 + 3], card.mem[2000 * 4096 + 2], card.mem[2000 * 4096 + 1], card.mem[2000 * 4096]}
            !== 64'h55667788_11223344 || card.mem[2000 * 4096 + 8] !== 8'h00) begin
            errors = errors + 1;
            $display("FAIL: RECEIVE: the payload not on the card");
        end
        say("2000 RECEIVE");
        expect({"send the image", CRLF}, 30);
        send_image(1);
        expect({"bad image", CRLF}, 30);
        say("INSTALL");
        expect({"send the image", CRLF}, 30);
        send_image(0);
        expect({"installed from block 1 on: reset to boot it", CRLF, " ok", CRLF}, 100);
        if ({card.mem[4096 + 3], card.mem[4096 + 2], card.mem[4096 + 1], card.mem[4096]} !== 32'h3233706D
            || {card.mem[4096 + 35], card.mem[4096 + 34], card.mem[4096 + 33], card.mem[4096 + 32]} !== 32'h11223344) begin
            errors = errors + 1;
            $display("FAIL: INSTALL: the image not in block 1 (card sector 8)");
        end
        $display("the volume, the source blocks' header, the startup block, RECEIVE, INSTALL (%0d blocks written)",
                 card.blocks_written);

        // ================================================ the screen
        check("PAGE 0 59 AT-XY .( Z) CR .( Y)", {"Z", CRLF, "Y"});
        t0 = $time;
        // the second scroll (after " ok") ends with row 59 blank: about 1.5 ms
        // (the prompt, then the cursor, an inverted space, while KEY waits)
        while (screen(59, 2) !== {8'd82, 16'd0, 8'hA0} && $time < t0 + 20_000_000) #10000;
        $display("the screen: scrolled %0.2f ms after the \" ok\"", ($time - t0) / 1.0e6);
        #100000;
        check_row(57, "Z", 1);
        check_row(58, "Y OK", 4);
        check_row(59, "> ", 2);
        if (screen(59, 2) !== 32'h520000A0) begin
            errors = errors + 1;
            $display("FAIL: no cursor at row 59 column 2: %h", screen(59, 2));
        end
        for (i = 3; i < 80; i = i + 1)
            if (screen(59, i) !== 32'h52000020) begin
                errors = errors + 1;
                $display("FAIL: row 59 column %0d not blank: %h", i, screen(59, i));
            end
        check_row(0, "        ", 8);

        show_log;
        $display("%0d bytes on the serial port, SDRAM: %0d reads, %0d writes", n_got, chip.reads, chip.writes);
        $display("simulated %0.2f ms", $time / 1.0e6);
        if (chip.errors != 0) begin errors = errors + 1; $display("FAIL: %0d SDRAM errors", chip.errors); end
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
