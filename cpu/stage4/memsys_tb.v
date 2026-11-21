// memsys_tb.v: tests memsys.v: the memory bus, the block RAM, the cache and the SDRAM
// controller together, against the model of the SDRAM, at 63 MHz.
//
//   make test-memsys
// or by hand:
//   iverilog -g2005 -o memsys_tb.vvp memsys_tb.v memsys.v membus.v bram.v \
//            ../../cache/cache.v ../../cache/sdram.v ../../cache/sdram_model.v
//   vvp memsys_tb.vvp
//
// Three masters run at the same time, as in the processor:
//   - stage 4: random reads and writes (words and single bytes) in four 4 KB regions
//     of the SDRAM far apart (so lines are thrown out of the cache and fetched again
//     all the time; the last one is in the write-through region), in the block RAM,
//     in the I/O range and in the unmapped space;
//   - fetch: random line reads in the same SDRAM regions and the block RAM;
//   - the video unit: now and then a row burst from another part of the SDRAM.
// Every read (word or line) is checked against what was written (bytes never written
// are not checked). At the end everything that was written is read back. The SDRAM
// model checks the SDRAM's timing and the refresh all along.
//
// The simulation uses EXT_CLK = 0 (the model cannot tell a good SDRAM clock phase from
// a bad one; on the board, at 63 MHz, see memsys.v).

`timescale 1ns/1ps

module memsys_tb;
    parameter CLK_MHZ = 63;
    parameter OPS     = 6000;            // stage 4's accesses

    reg clk = 0;
    always #(500.0 / CLK_MHZ) clk = ~clk;

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

    wire         io_sel, io_we;
    wire [3:0]   io_be;
    wire [15:0]  io_addr;
    wire [31:0]  io_wdata;
    reg  [31:0]  io_rdata = 0;
    reg          io_ready = 0;

    reg          vid_req = 0;
    reg  [22:4]  vid_addr = 0;
    reg  [6:0]   vid_count = 0;
    wire [31:0]  vid_word;
    wire         vid_valid, vid_ack;

    wire        sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_wen_n;
    wire [3:0]  sd_dqm;
    wire [10:0] sd_addr;
    wire [1:0]  sd_ba;
    wire [31:0] sd_dq;

    memsys #(.CLK_MHZ(CLK_MHZ), .EXT_CLK(0)) dut (
        .clk(clk), .clk_sdram(1'b0), .reset(reset),
        .d_sel(d_sel), .d_we(d_we), .d_be(d_be), .d_addr(d_addr), .d_wdata(d_wdata),
        .d_rdata(d_rdata), .d_ready(d_ready),
        .line_sel(line_sel), .line_addr(line_addr), .line_data(line_data),
        .line_ready(line_ready),
        .io_sel(io_sel), .io_we(io_we), .io_be(io_be), .io_addr(io_addr),
        .io_wdata(io_wdata), .io_rdata(io_rdata), .io_ready(io_ready),
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

    integer errors = 0, seed = 13, i, k;
    integer n_data = 0, n_lines = 0, n_bursts = 0, n_io = 0;

    task fail(input [8*48-1:0] what);
        begin
            errors = errors + 1;
            if (errors <= 20) $display("%t %0s", $realtime, what);
        end
    endtask

    // ================================================================ the reference
    // 4 SDRAM regions of 4 KB (index 0 .. 4095 words), the block RAM (8 KB, 2048
    // words), the I/O (64 words). known: which bytes were written.
    localparam W_SD = 4096, W_BR = 2048, W_IO = 64;
    reg [31:0] ref_w   [0:W_SD + W_BR + W_IO - 1];
    reg [3:0]  ref_k   [0:W_SD + W_BR + W_IO - 1];

    function [31:0] sd_base(input [1:0] r);
        case (r)
            0: sd_base = 32'h0000_0000;
            1: sd_base = 32'h002A_0000;
            2: sd_base = 32'h0055_0000;
            default: sd_base = 32'h007F_0000;      // write-through region
        endcase
    endfunction

    // the reference index of an address, or -1 (unmapped)
    function integer ridx(input [31:0] a);
        begin
            if (a[31:23] == 0) begin
                case (a[22:12])
                    11'h000: ridx = 0    + a[11:2];
                    11'h2A0: ridx = 1024 + a[11:2];
                    11'h550: ridx = 2048 + a[11:2];
                    11'h7F0: ridx = 3072 + a[11:2];
                    default: ridx = -1;
                endcase
            end else if (a[31:13] == 19'h78000)  ridx = W_SD + a[12:2];   // 0xF000_0000
            else if (a[31:16] == 16'hFFFF)        ridx = W_SD + W_BR + a[7:2];
            else                                  ridx = -1;
        end
    endfunction

    task ref_write(input [31:0] a, input [3:0] be, input [31:0] d);
        integer x, b;
        begin
            x = ridx(a);
            if (x >= 0)
                for (b = 0; b < 4; b = b + 1)
                    if (be[b]) begin ref_w[x][8*b +: 8] = d[8*b +: 8]; ref_k[x][b] = 1; end
        end
    endtask

    // check a word read against the reference, the bytes known
    task check_word(input [31:0] a, input [31:0] got, input [8*24-1:0] who);
        integer x, b;
        begin
            x = ridx(a);
            if (x < 0) begin
                if (got !== 0) begin fail("unmapped read not 0"); end
            end else
                for (b = 0; b < 4; b = b + 1)
                    if (ref_k[x][b] && got[8*b +: 8] !== ref_w[x][8*b +: 8]) begin
                        fail(who);
                        if (errors <= 20) $display("   [%h] byte %0d: got %h, expected %h",
                                                   a, b, got[8*b +: 8], ref_w[x][8*b +: 8]);
                    end
        end
    endtask

    // ================================================================ the I/O model
    reg [31:0] io_mem [0:63];
    integer    io_wait = -1;
    always @(posedge clk) begin
        io_ready <= 0;
        if (io_sel && !io_ready) begin
            if (io_wait < 0) io_wait = $random(seed) & 3;
            if (io_wait == 0) begin
                io_ready <= 1;
                if (io_we) begin
                    for (k = 0; k < 4; k = k + 1)
                        if (io_be[k]) io_mem[io_addr[7:2]][8*k +: 8] <= io_wdata[8*k +: 8];
                end else
                    io_rdata <= io_mem[io_addr[7:2]];
                io_wait = -1;
            end else io_wait = io_wait - 1;
        end
    end

    // ================================================================ random addresses
    function [31:0] rand_addr(input integer dummy);
        reg [31:0] x;
        begin
            x = $random(seed);
            case (x[31:29] % 7)
                0, 1, 2, 3: rand_addr = sd_base(x[28:27]) | x[11:0];
                4, 5:       rand_addr = 32'hF000_0000 | x[12:0];
                default:    rand_addr = x[26] ? (32'hFFFF_0000 | x[7:0])      // I/O
                                              : (32'h4000_0000 | x[15:0]);    // nothing
            endcase
        end
    endfunction

    // ================================================================ master: stage 4
    reg running = 0, d_done = 0;
    reg [31:0] h_addr;  reg h_we;  reg [3:0] h_be;  reg [31:0] h_wdata;
    always @(posedge clk) begin
        if (d_sel && d_ready) begin
            if (d_we) ref_write(d_addr, d_be, d_wdata);
            else      check_word(d_addr, d_rdata, "stage 4 read");
            if (d_addr[31:16] == 16'hFFFF) n_io = n_io + 1;
            n_data = n_data + 1;
            d_sel <= 0;
            if (n_data >= OPS) d_done <= 1;
        end else if (!d_sel && running && !d_done && ($random(seed) & 1)) begin
            h_addr = rand_addr(0);
            h_we = $random(seed);
            h_be = ($random(seed) & 1) ? 4'hF : (4'b0001 << ($random(seed) & 3));
            d_sel <= 1; d_we <= h_we; d_addr <= {h_addr[31:2], 2'b00};
            d_be <= h_be; d_wdata <= $random(seed);
        end
    end

    // ================================================================ master: fetch
    integer bb;
    reg [31:0] la;
    always @(posedge clk) begin
        if (line_sel && line_ready) begin
            for (bb = 0; bb < 4; bb = bb + 1)
                check_word({line_addr, 4'h0} + 4 * bb, line_data[32*bb +: 32], "fetch line");
            n_lines = n_lines + 1;
            line_sel <= 0;
        end else if (!line_sel && running && !d_done && ($random(seed) & 1)) begin
            la = rand_addr(0);
            if (la[31:16] == 16'hFFFF || la[31:24] == 8'h40) la = sd_base(la[1:0]) | la[11:0];
            line_sel <= 1; line_addr <= la[31:4];
        end
    end

    // ================================================================ the video unit
    integer v_words = 0, v_want = 0;
    always @(posedge clk) begin
        if (vid_valid) v_words = v_words + 1;
        if (vid_ack) begin
            vid_req <= 0; n_bursts = n_bursts + 1;
            if (v_words != v_want) fail("video burst: wrong number of words");
        end else if (!vid_req && running && !d_done && ($random(seed) % 200) == 0) begin
            vid_req <= 1;
            vid_addr <= {9'h100, 6'd0, 4'h0} | {($random(seed) & 9'h0FF), 10'h0};  // its own kilobyte
            vid_count <= 1 + ($random(seed) & 31);
            v_words = 0;
        end
        if (vid_req && !vid_ack && v_words == 0) v_want = 4 * vid_count;
    end

    // ================================================================ run
    initial begin
        for (i = 0; i < W_SD + W_BR + W_IO; i = i + 1) begin ref_w[i] = 0; ref_k[i] = 0; end
        for (i = 0; i < 64; i = i + 1) io_mem[i] = 0;
        // the block RAM starts as 0: known
        for (i = W_SD; i < W_SD + W_BR; i = i + 1) ref_k[i] = 4'hF;

        repeat (4) @(posedge clk);
        #1 reset = 0;
        running = 1;
        wait (d_done);
        wait (!line_sel && !vid_req);
        running = 0;
        repeat (4) @(posedge clk);

        // read back everything written, through stage 4's port
        for (i = 0; i < W_SD + W_BR + W_IO; i = i + 1)
            if (ref_k[i] != 0 && !(i >= W_SD && i < W_SD + W_BR && ref_k[i] == 4'hF && ref_w[i] == 0)) begin
                @(posedge clk); #1;
                d_sel = 1; d_we = 0; d_be = 4'hF;
                d_addr = (i < W_SD)        ? sd_base(i / 1024) | ((i % 1024) * 4) :
                         (i < W_SD + W_BR) ? 32'hF000_0000 | ((i - W_SD) * 4) :
                                             32'hFFFF_0000 | ((i - W_SD - W_BR) * 4);
                h_addr = d_addr;
                @(posedge clk); while (!d_ready) @(posedge clk);
                check_word(d_addr, d_rdata, "read back");
                #1 d_sel = 0;
            end

        $display("%0d stage 4 accesses (%0d to I/O), %0d lines fetched, %0d video bursts, %0d SDRAM model complaints",
                 n_data, n_io, n_lines, n_bursts, chip.errors);
        if (chip.errors != 0) errors = errors + chip.errors;
        if (n_lines < 1000 || n_bursts < 5) fail("too few accesses: the test did not test much");
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
