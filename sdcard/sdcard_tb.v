// sdcard_tb.v: tests sdcard.v against a model of a card in SPI mode.
//
//   make test-sdcard
// or by hand:
//   iverilog -g2005 -o sdcard_tb.vvp sdcard_tb.v sdcard.v
//   vvp sdcard_tb.vvp
//
// The model is not a real card: it is an SPI slave in mode 0 that answers every byte
// with the byte it got before, plus 1 (0xFF for the first byte after CS goes low). So
// every answer shows that the byte before it went out right, and the model keeps a list
// of all it got. It also checks the mode: MOSI must not change while SCLK is 1.
//
// It checks the registers after reset; the clocks with CS off (the card's start: 80
// clocks, no byte taken); CS; single bytes and four bytes at a time; a second write
// waiting for the first; CTRL read at once during a transfer; the SCLK period for
// several DIV; MOSI at 1 when idle. Then thousands of random transfers, all checked.

`timescale 1ns/1ps

module sdcard_tb;
    reg clk = 0;
    always #7.937 clk = ~clk;             // 63 MHz

    reg         reset = 1;
    reg         io_sel = 0, io_we = 0;
    reg  [3:2]  io_addr = 0;
    reg  [31:0] io_wdata = 0;
    wire [31:0] io_rdata;
    wire        io_ready;

    wire sd_clk, sd_mosi, sd_cs_n;
    wire sd_miso;

    sdcard #(.DIV_INIT(8'd78)) dut (
        .clk(clk), .reset(reset),
        .io_sel(io_sel), .io_we(io_we), .io_be(4'hF), .io_addr(io_addr),
        .io_wdata(io_wdata), .io_rdata(io_rdata), .io_ready(io_ready),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n)
    );

    integer errors = 0;

    // ================================================================ the card's model
    reg  [7:0] in_sr = 0, out_sr = 8'hFF, next_out = 0;
    reg        have_next = 0;
    integer    nbits = 0;
    reg  [7:0] got [0:65535];             // every byte the card got
    integer    ngot = 0;
    integer    rises = 0;                 // rising edges of SCLK, CS or not

    assign sd_miso = sd_cs_n ? 1'b1 : out_sr[7];

    always @(negedge sd_cs_n) begin
        out_sr = 8'hFF; nbits = 0; have_next = 0;
    end

    always @(posedge sd_clk) begin
        rises = rises + 1;
        if (!sd_cs_n) begin
            in_sr = {in_sr[6:0], sd_mosi};
            nbits = nbits + 1;
            if (nbits == 8) begin
                got[ngot] = in_sr; ngot = ngot + 1;
                next_out = in_sr + 8'd1; have_next = 1;
                nbits = 0;
            end
        end
    end

    always @(negedge sd_clk) begin
        if (!sd_cs_n) begin
            if (have_next) begin out_sr = next_out; have_next = 0; end
            else           out_sr = {out_sr[6:0], 1'b1};
        end
    end

    // mode 0: MOSI is stable while SCLK is 1
    always @(sd_mosi)
        if (sd_clk && !sd_cs_n) begin
            errors = errors + 1;
            $display("%t MOSI changed while SCLK was 1", $realtime);
        end

    // ================================================================ the bus
    // One access with the handshake: hold everything until io_ready, which ends it.
    task access(input we, input [1:0] a, input [31:0] wd, output [31:0] rd);
        begin
            io_sel <= 1; io_we <= we; io_addr <= a; io_wdata <= wd;
            @(posedge clk); #1;
            while (!io_ready) begin @(posedge clk); #1; end
            rd = io_rdata;
            @(posedge clk); #1;
            io_sel <= 0;
        end
    endtask

    reg [31:0] r;
    task wr(input [1:0] a, input [31:0] wd); access(1, a, wd, r); endtask
    task rd(input [1:0] a);                  access(0, a, 0,  r); endtask

    task check(input [31:0] got_v, input [31:0] want, input [8*32-1:0] what);
        if (got_v !== want) begin
            errors = errors + 1;
            $display("%t %0s: %h, expected %h", $realtime, what, got_v, want);
        end
    endtask

    localparam DATA = 0, DATA32 = 1, CTRL = 2;

    // the answer the model gives to byte b, with prev the byte before it (or none)
    function [7:0] answer(input first, input [7:0] prev);
        answer = first ? 8'hFF : prev + 8'd1;
    endfunction

    // ================================================================ SCLK period
    realtime t0, t1;
    task period(input [7:0] d);
        begin
            wr(CTRL, {16'd0, d, 8'd1});
            wr(DATA, 8'h55);                 // returns with the transfer running
            @(posedge sd_clk); t0 = $realtime;
            @(posedge sd_clk); t1 = $realtime;
            if ((t1 - t0) < 31.748 * (d + 1) - 1 || (t1 - t0) > 31.748 * (d + 1) + 1) begin
                errors = errors + 1;
                $display("DIV %0d: SCLK period %0.1f ns, expected %0.1f",
                         d, t1 - t0, 31.748 * (d + 1));
            end
            rd(DATA);                        // waits for the end
        end
    endtask

    // ================================================================ the test
    integer i, k, first_byte, nsent, n;
    reg [7:0]  prev, b, d4;
    reg [31:0] w, want;
    reg [7:0]  sent [0:65535];
    integer    seed = 7;

    // send one byte and check the answer
    task byte_io(input [7:0] v);
        begin
            wr(DATA, {$random(seed)} & 32'hFFFF_FF00 | v);   // upper bits ignored
            rd(DATA);
            check(r, {24'd0, answer(first_byte, prev)}, "byte answer");
            sent[nsent] = v; nsent = nsent + 1;
            first_byte = 0; prev = v;
        end
    endtask

    task word_io(input [31:0] v);
        begin
            wr(DATA32, v);
            rd(DATA32);
            want[31:24] = answer(first_byte, prev);
            want[23:16] = v[31:24] + 1;
            want[15:8]  = v[23:16] + 1;
            want[7:0]   = v[15:8]  + 1;
            check(r, want, "word answer");
            for (k = 3; k >= 0; k = k - 1) begin
                sent[nsent] = v >> (8 * k); nsent = nsent + 1;
            end
            first_byte = 0; prev = v[7:0];
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset <= 0;
        @(posedge clk); #1;

        // ---- after reset
        rd(CTRL);   check(r, {15'd0, 1'b0, 8'd78, 7'd0, 1'b0}, "CTRL after reset");
        check(sd_cs_n, 1, "CS after reset");
        check(sd_clk, 0, "SCLK after reset");
        check(sd_mosi, 1, "MOSI idle");

        // ---- the card's start: 80 clocks with CS off, at 399 kHz
        rises = 0;
        for (i = 0; i < 10; i = i + 1) wr(DATA, 8'hFF);
        rd(DATA);
        check(rises, 80, "clocks with CS off");
        check(ngot, 0, "bytes taken with CS off");

        // ---- CS on, faster
        wr(CTRL, {16'd0, 8'd1, 8'd1});
        rd(CTRL);   check(r, {15'd0, 1'b0, 8'd1, 7'd0, 1'b1}, "CTRL written");
        check(sd_cs_n, 0, "CS on");
        nsent = 0; first_byte = 1; prev = 0;

        // ---- single bytes, four bytes
        byte_io(8'h40); byte_io(8'h00); byte_io(8'h95); byte_io(8'hFF);
        word_io(32'hDEAD_BEEF);
        word_io(32'h0102_0304);
        byte_io(8'h77);

        // ---- a second write waits for the first; CTRL can be read meanwhile
        wr(DATA, 8'h11);
        rd(CTRL);   check(r[16], 1, "BUSY during a transfer");
        wr(DATA, 8'h22);
        rd(DATA);   check(r, 32'h12, "answer after two writes");
        sent[nsent] = 8'h11; sent[nsent+1] = 8'h22; nsent = nsent + 2; prev = 8'h22;
        rd(CTRL);   check(r[16], 0, "not BUSY after the read");
        check(sd_mosi, 1, "MOSI idle again");

        // ---- SCLK period
        for (i = 0; i < 6; i = i + 1) begin
            period(i);
            sent[nsent] = 8'h55; nsent = nsent + 1; prev = 8'h55;
        end
        period(78);
        sent[nsent] = 8'h55; nsent = nsent + 1; prev = 8'h55;

        // ---- random transfers, random speeds, now and then CS off and on again
        for (n = 0; n < 3000; n = n + 1) begin
            if (($random(seed) & 63) == 0) begin
                wr(CTRL, {16'd0, 8'd1, 8'd0});
                wr(DATA, 8'hFF);                          // clocks, not taken
                wr(CTRL, {16'd0, 8'd1, 8'd1});
                first_byte = 1;
            end
            if (($random(seed) & 15) == 0) begin
                d4 = $random(seed) & 3;
                wr(CTRL, {16'd0, d4, 8'd1});
            end
            if ($random(seed) & 1) byte_io($random(seed));
            else                   word_io($random(seed));
        end

        // ---- the card got exactly what was sent
        check(ngot, nsent, "bytes the card got");
        for (i = 0; i < nsent && i < ngot; i = i + 1)
            if (got[i] !== sent[i]) begin
                errors = errors + 1;
                if (errors < 20)
                    $display("byte %0d: the card got %h, sent %h", i, got[i], sent[i]);
            end

        if (errors == 0) $display("PASS (%0d bytes)", nsent);
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
