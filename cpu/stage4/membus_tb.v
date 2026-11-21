// membus_tb.v: tests membus.v and bram.v.
//
//   make test-membus
// or by hand:
//   iverilog -g2005 -o membus_tb.vvp membus_tb.v membus.v bram.v
//   vvp membus_tb.vvp
//
// Both masters run at the same time: stage 4 does random reads and writes (bytes,
// halfwords, words) in the SDRAM, the block RAM, the I/O and the unmapped space;
// stage 1 reads random lines from the SDRAM, the block RAM and the unmapped space.
// The cache and the I/O are models that answer after a random 1 to 8 ticks and check
// that their inputs are held. Every read is checked against a reference of what was
// written. The bench also checks that stage 4 wins when both ask at once, that an
// access going on is never broken off, and that a ready only goes to its own master.

`timescale 1ns/1ps

module membus_tb;
    reg clk = 0;
    always #18.5 clk = ~clk;              // 27 MHz

    localparam [31:0] BRAM_BASE = 32'hF000_0000;
    localparam [31:0] IO_BASE   = 32'hFFFF_0000;
    localparam [31:0] NOWHERE   = 32'h4000_0000;

    reg          reset = 1;

    reg          d_sel = 0, d_we = 0;
    reg  [3:0]   d_be = 0;
    reg  [31:0]  d_addr = 0, d_wdata = 0;
    wire [31:0]  d_rdata;
    wire         d_ready;

    reg          line_sel = 0;
    reg  [31:4]  line_addr = 0;
    wire [127:0] line_data;
    wire         line_ready;

    wire         c_sel, c_we;
    wire [3:0]   c_be;
    wire [22:0]  c_addr;
    wire [31:0]  c_wdata;
    reg  [127:0] c_rline = 0;
    reg          c_ready = 0;

    wire         io_sel, io_we;
    wire [3:0]   io_be;
    wire [15:0]  io_addr;
    wire [31:0]  io_wdata;
    reg  [31:0]  io_rdata = 0;
    reg          io_ready = 0;

    membus #(.BRAM_BASE(BRAM_BASE), .BRAM_BITS(13)) dut (
        .clk(clk), .reset(reset),
        .d_sel(d_sel), .d_we(d_we), .d_be(d_be), .d_addr(d_addr), .d_wdata(d_wdata),
        .d_rdata(d_rdata), .d_ready(d_ready),
        .line_sel(line_sel), .line_addr(line_addr), .line_data(line_data),
        .line_ready(line_ready),
        .c_sel(c_sel), .c_we(c_we), .c_be(c_be), .c_addr(c_addr), .c_wdata(c_wdata),
        .c_rline(c_rline), .c_ready(c_ready),
        .io_sel(io_sel), .io_we(io_we), .io_be(io_be), .io_addr(io_addr),
        .io_wdata(io_wdata), .io_rdata(io_rdata), .io_ready(io_ready)
    );

    integer errors = 0, seed = 7, i;
    integer n_data = 0, n_fetch = 0, n_both = 0;

    task expect(input [127:0] got, input [127:0] want, input [8*32-1:0] what);
        begin
            if (got !== want) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("%t %0s: got %h, expected %h", $realtime, what, got, want);
            end
        end
    endtask

    // ================================================================ the reference
    // The SDRAM area used: 4 KB at 0; the block RAM: 8 KB; the I/O: 256 bytes.
    reg [7:0] sd_ref [0:4095];
    reg [7:0] br_ref [0:8191];
    reg [7:0] io_ref [0:255];

    function [7:0] ref_byte(input [31:0] a);
        if (a[31:23] == 0)                       ref_byte = sd_ref[a[11:0]];
        else if (a[31:13] == BRAM_BASE[31:13])   ref_byte = br_ref[a[12:0]];
        else if (a[31:16] == 16'hFFFF)           ref_byte = io_ref[a[7:0]];
        else                                     ref_byte = 8'h00;
    endfunction

    task ref_write(input [31:0] a, input [3:0] be, input [31:0] d);
        integer k;
        reg [31:0] b;
        begin
            for (k = 0; k < 4; k = k + 1)
                if (be[k]) begin
                    b = {a[31:2], 2'b00} + k;
                    if (b[31:23] == 0)                     sd_ref[b[11:0]] = d[8*k +: 8];
                    else if (b[31:13] == BRAM_BASE[31:13]) br_ref[b[12:0]] = d[8*k +: 8];
                    else if (b[31:16] == 16'hFFFF)         io_ref[b[7:0]]  = d[8*k +: 8];
                end
        end
    endtask

    function [31:0] ref_word(input [31:0] a);
        ref_word = {ref_byte({a[31:2], 2'd3}), ref_byte({a[31:2], 2'd2}),
                    ref_byte({a[31:2], 2'd1}), ref_byte({a[31:2], 2'd0})};
    endfunction

    function [127:0] ref_line(input [31:4] l);
        ref_line = {ref_word({l, 4'hC}), ref_word({l, 4'h8}),
                    ref_word({l, 4'h4}), ref_word({l, 4'h0})};
    endfunction

    // ================================================================ the cache model
    reg [127:0] c_mem [0:255];
    reg         c_busy = 0;
    reg         c_hwe;  reg [3:0] c_hbe;  reg [22:0] c_haddr;  reg [31:0] c_hwdata;
    integer     c_wait;

    always @(posedge clk) begin
        c_ready <= 0;
        if (c_sel && !c_ready) begin
            if (!c_busy) begin
                c_busy <= 1;
                c_hwe <= c_we; c_hbe <= c_be; c_haddr <= c_addr; c_hwdata <= c_wdata;
                c_wait = $random(seed) & 7;
            end else if (c_we !== c_hwe || c_addr !== c_haddr ||
                         (c_we && (c_be !== c_hbe || c_wdata !== c_hwdata))) begin
                errors = errors + 1;
                $display("%t cache inputs not held", $realtime);
            end
            if (c_wait == 0) begin
                c_ready <= 1;
                if (c_we) begin
                    for (i = 0; i < 4; i = i + 1)
                        if (c_be[i])
                            c_mem[c_addr[11:4]][32*c_addr[3:2] + 8*i +: 8] <= c_wdata[8*i +: 8];
                    c_rline <= 128'hx;
                end else
                    c_rline <= c_mem[c_addr[11:4]];
            end else
                c_wait = c_wait - 1;
        end else if (!c_sel && c_busy && !c_ready) begin
            errors = errors + 1;
            $display("%t cache access broken off", $realtime);
        end
        if (c_ready) c_busy <= 0;
    end

    // ================================================================ the I/O model
    reg [31:0] io_mem [0:63];
    reg        io_busy = 0;
    reg        io_hwe;  reg [15:0] io_haddr;
    integer    io_wait;

    always @(posedge clk) begin
        io_ready <= 0;
        if (io_sel && !io_ready) begin
            if (!io_busy) begin
                io_busy <= 1; io_hwe <= io_we; io_haddr <= io_addr;
                io_wait = $random(seed) & 7;
            end else if (io_we !== io_hwe || io_addr !== io_haddr) begin
                errors = errors + 1;
                $display("%t I/O inputs not held", $realtime);
            end
            if (io_wait == 0) begin
                io_ready <= 1;
                if (io_we) begin
                    for (i = 0; i < 4; i = i + 1)
                        if (io_be[i]) io_mem[io_addr[7:2]][8*i +: 8] <= io_wdata[8*i +: 8];
                    io_rdata <= 32'hx;
                end else
                    io_rdata <= io_mem[io_addr[7:2]];
            end else
                io_wait = io_wait - 1;
        end
        if (io_ready) io_busy <= 0;
    end

    // ================================================================ priority and fairness checks
    always @(posedge clk) if (!reset) begin
        if (d_ready && line_ready) begin
            errors = errors + 1;
            $display("%t both readies at once", $realtime);
        end
        // nobody on the bus, both ask: stage 4 must get it
        if (dut.owner == 0 && d_sel && line_sel) begin
            n_both = n_both + 1;
            if (dut.grant != 1) begin
                errors = errors + 1;
                $display("%t stage 1 got the bus before stage 4", $realtime);
            end
        end
        // an access going on keeps the bus
        if (dut.owner != 0 && dut.grant != dut.owner) begin
            errors = errors + 1;
            $display("%t an access was broken off", $realtime);
        end
    end

    // ================================================================ master: stage 4
    function [31:0] random_addr(input integer region);
        reg [31:0] r;
        begin
            r = $random(seed);
            case (region)
                0: random_addr = {20'h0, r[11:0]};
                1: random_addr = BRAM_BASE | r[12:0];
                2: random_addr = IO_BASE | r[7:0];
                default: random_addr = NOWHERE | r[15:0];
            endcase
        end
    endfunction

    reg running = 0;
    integer region;

    always @(posedge clk) begin
        if (d_sel && d_ready) begin
            if (d_we) ref_write(d_addr, d_be, d_wdata);
            else      expect(d_rdata, ref_word(d_addr), "stage 4 read");
            n_data = n_data + 1;
            d_sel <= 0;
        end else if (!d_sel && running && ($random(seed) & 1)) begin
            region = $random(seed) & 3;
            d_sel   <= 1;
            d_we    <= $random(seed);
            d_addr  <= random_addr(region);
            d_be    <= ($random(seed) & 1) ? 4'hF : (($random(seed) & 4'hF) | 4'h1);
            d_wdata <= $random(seed);
        end
    end

    // ================================================================ master: stage 1
    integer fregion;
    reg [31:0] fa;

    always @(posedge clk) begin
        if (line_sel && line_ready) begin
            expect(line_data, ref_line(line_addr), "stage 1 line");
            n_fetch = n_fetch + 1;
            line_sel <= 0;
        end else if (!line_sel && running && ($random(seed) & 1)) begin
            fregion = $random(seed) & 3;
            if (fregion == 2) fregion = 0;          // fetch reads no I/O
            fa = random_addr(fregion);
            line_sel  <= 1;
            line_addr <= fa[31:4];
        end
    end

    // ================================================================ run
    initial begin
        for (i = 0; i < 4096; i = i + 1) sd_ref[i] = 0;
        for (i = 0; i < 8192; i = i + 1) br_ref[i] = 0;
        for (i = 0; i < 256;  i = i + 1) io_ref[i] = 0;
        for (i = 0; i < 256;  i = i + 1) c_mem[i]  = 0;
        for (i = 0; i < 64;   i = i + 1) io_mem[i] = 0;

        repeat (2) @(posedge clk);
        #1 reset = 0; running = 1;
        repeat (200000) @(posedge clk);
        #1 running = 0;
        repeat (40) @(posedge clk);

        $display("%0d stage 4 accesses, %0d lines fetched, %0d times both asked at once",
                 n_data, n_fetch, n_both);
        if (n_data < 1000 || n_fetch < 1000 || n_both < 100) begin
            errors = errors + 1;
            $display("too few accesses: the test did not test much");
        end
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
