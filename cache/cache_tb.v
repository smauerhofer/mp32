// cache_tb.v: tests cache.v and sdram.v against sdram_model.v.
//
//   iverilog -g2005 -o cache_tb.vvp cache_tb.v cache.v sdram.v sdram_model.v
//   vvp cache_tb.vvp
//
// Another clock:  iverilog -g2005 -Pcache_tb.CLK_MHZ=54 -o ...
//
// It does thousands of random reads and writes, whole words and single bytes, in four
// 64 KB regions far apart in the 8 MB, so lines are thrown out and fetched again all
// the time. Every read is checked against what was written. Then it sits idle for
// 100 us (the refresh must go on), and reads back everything it ever wrote.
// The model checks the SDRAM's timing and the refresh all along.
//
// Region 3 (0x7F0000) is in the write-through region. After the idle time the SDRAM
// itself (the model's array, what the video unit would read) must hold everything
// written there. Then the write-combining buffer on its own:
//   - 4 KB written byte by byte, at 0x7E0000: exactly one burst for each 16 bytes,
//     and the SDRAM holds it all WC_TICKS ticks later;
//   - one word written again and again for 4 * WC_TICKS ticks: it must still reach
//     the SDRAM every WC_TICKS ticks or so (at least 3 bursts), and the last value too.

`timescale 1ns/1ps

module cache_tb;
    parameter CLK_MHZ = 27;
    parameter OPS     = 20000;

    reg clk = 0;
    always #(500.0 / CLK_MHZ) clk = ~clk;

    reg         reset = 1;
    reg         cpu_sel = 0, cpu_we = 0;
    reg  [3:0]  cpu_be = 0;
    reg  [22:0] cpu_addr = 0;
    reg  [31:0] cpu_wdata = 0;
    wire [31:0] cpu_rdata;
    wire        cpu_ready;

    wire        sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_wen_n;
    wire [3:0]  sd_dqm;
    wire [10:0] sd_addr;
    wire [1:0]  sd_ba;
    wire [31:0] sd_dq;

    cache #(.CLK_MHZ(CLK_MHZ)) dut (
        .clk(clk), .reset(reset),
        .cpu_sel(cpu_sel), .cpu_we(cpu_we), .cpu_be(cpu_be), .cpu_addr(cpu_addr),
        .cpu_wdata(cpu_wdata), .cpu_rdata(cpu_rdata), .cpu_ready(cpu_ready),
        .clk_sdram(1'b0),
        .vid_req(1'b0), .vid_addr(19'd0), .vid_count(7'd0),
        .vid_word(), .vid_valid(), .vid_ack(),
        .O_sdram_clk(sd_clk), .O_sdram_cke(sd_cke), .O_sdram_cs_n(sd_cs_n),
        .O_sdram_ras_n(sd_ras_n), .O_sdram_cas_n(sd_cas_n), .O_sdram_wen_n(sd_wen_n),
        .O_sdram_dqm(sd_dqm), .O_sdram_addr(sd_addr), .O_sdram_ba(sd_ba),
        .IO_sdram_dq(sd_dq)
    );

    sdram_model chip (
        .clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
        .we_n(sd_wen_n), .dqm(sd_dqm), .addr(sd_addr), .ba(sd_ba), .dq(sd_dq)
    );

    // ---- what the memory should hold: 4 regions of 64 KB, 16K words each
    reg [31:0] ref_word  [0:65535];
    reg [3:0]  ref_known [0:65535];     // which bytes have been written
    integer errors = 0, cycles = 0, accesses = 0, k;

    always @(posedge clk) cycles = cycles + 1;

    function [22:0] region_base(input [1:0] r);
        case (r)
            2'd0: region_base = 23'h000000;
            2'd1: region_base = 23'h2A0000;
            2'd2: region_base = 23'h550000;
            2'd3: region_base = 23'h7F0000;
        endcase
    endfunction

    // One access, started right after a rising edge; returns right after the edge
    // that ended it.
    task access(input we, input [22:0] a, input [3:0] be, input [31:0] wd,
                output [31:0] rd);
        begin
            cpu_sel   <= 1;
            cpu_we    <= we;
            cpu_addr  <= a;
            cpu_be    <= be;
            cpu_wdata <= wd;
            @(posedge clk);
            while (!cpu_ready) @(posedge clk);
            rd = cpu_rdata;
            cpu_sel <= 0;
            accesses = accesses + 1;
        end
    endtask

    task do_write(input [1:0] r, input [15:2] w, input [3:0] be, input [31:0] wd);
        reg [31:0] dummy;
        integer n;
        begin
            access(1, region_base(r) + {w, 2'b00}, be, wd, dummy);
            n = {r, w};
            for (k = 0; k < 4; k = k + 1)
                if (be[k]) ref_word[n][8*k +: 8] = wd[8*k +: 8];
            ref_known[n] = ref_known[n] | be;
        end
    endtask

    task do_read(input [1:0] r, input [15:2] w);
        reg [31:0] got, mask;
        integer n;
        begin
            access(0, region_base(r) + {w, 2'b00}, 4'b0000, 0, got);
            n = {r, w};
            mask = {{8{ref_known[n][3]}}, {8{ref_known[n][2]}},
                    {8{ref_known[n][1]}}, {8{ref_known[n][0]}}};
            if ((got & mask) !== (ref_word[n] & mask)) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("%t MISMATCH at %h: read %h, expected %h (mask %h)",
                             $realtime, region_base(r) + {w, 2'b00}, got, ref_word[n], mask);
            end
        end
    endtask

    // The model's word for a byte address (see sdram.v: row, bank, column)
    function [20:0] chip_index(input [22:0] a);
        chip_index = {a[11:10], a[22:12], a[9:2]};
    endfunction

    task check_chip(input [22:0] a, input [31:0] want, input [31:0] mask);
        begin
            if ((chip.mem[chip_index(a)] & mask) !== (want & mask)) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("%t SDRAM STALE at %h: holds %h, expected %h (mask %h)",
                             $realtime, a, chip.mem[chip_index(a)], want, mask);
            end
        end
    endtask

    task wait_ticks(input integer n);
        repeat (n) @(posedge clk);
    endtask

    integer op, gap, r_known, wr0, c0, i;
    reg [31:0] dummy, mask;
    reg [1:0]  r;
    reg [15:2] w;
    reg [3:0]  be;
    integer seed = 1;
    real t0;

    initial begin
        for (k = 0; k < 65536; k = k + 1) ref_known[k] = 0;

        repeat (4) @(posedge clk);
        reset <= 0;

        // ---- random traffic
        t0 = $realtime;
        for (op = 0; op < OPS; op = op + 1) begin
            r = $random(seed);
            // half the time a small, hot area (mostly hits), else anywhere in 64 KB
            if ($random(seed) & 1) w = $random(seed) & 14'h01FF;
            else                   w = $random(seed);

            if (($random(seed) & 7) < 3) begin
                case ($random(seed) & 3)
                    0, 1:    be = 4'b1111;
                    2:       be = 4'b0001 << ($random(seed) & 3);
                    default: be = $random(seed);
                endcase
                do_write(r, w, be, $random(seed));
            end else
                do_read(r, w);

            gap = $random(seed) & 3;               // sometimes a few idle ticks
            if (gap == 3) repeat ($random(seed) & 7) @(posedge clk);
        end
        $display("random traffic: %0d accesses in %0.1f us, %0d errors so far",
                 OPS, ($realtime - t0) / 1000.0, errors);

        // ---- idle: the refresh must go on without the processor
        repeat (100 * CLK_MHZ) @(posedge clk);

        // ---- read back all that was written
        r_known = 0;
        for (k = 0; k < 65536; k = k + 1)
            if (ref_known[k] != 0) begin
                do_read(k[15:14], k[13:0]);
                r_known = r_known + 1;
            end
        $display("read back %0d words", r_known);

        // ---- the write-through region in the SDRAM itself
        r_known = 0;
        for (k = 3 * 16384; k < 65536; k = k + 1)
            if (ref_known[k] != 0) begin
                mask = {{8{ref_known[k][3]}}, {8{ref_known[k][2]}},
                        {8{ref_known[k][1]}}, {8{ref_known[k][0]}}};
                check_chip(region_base(3) + {k[13:0], 2'b00}, ref_word[k], mask);
                r_known = r_known + 1;
            end
        $display("write-through region: %0d words checked in the SDRAM", r_known);

        // ---- write-combining: 4 KB byte by byte
        wait_ticks(dut.WC_TICKS + 50);
        wr0 = chip.writes; c0 = cycles;
        for (i = 0; i < 4096; i = i + 1)
            access(1, 23'h7E0000 + i, 4'b0001 << i[1:0], {4{i[7:0] ^ 8'h5A}}, dummy);
        $display("write-combining: 4096 byte writes in %0d ticks, %0d line writes",
                 cycles - c0, chip.writes - wr0);
        if (chip.writes - wr0 > 256) begin          // the last line may still be pending
            errors = errors + 1;
            $display("FAIL: more than one burst for 16 bytes");
        end
        wait_ticks(dut.WC_TICKS + 50);
        if (chip.writes - wr0 != 256) begin
            errors = errors + 1;
            $display("FAIL: %0d line writes, expected 256", chip.writes - wr0);
        end
        for (i = 0; i < 4096; i = i + 4)
            check_chip(23'h7E0000 + i, {4{i[7:0] ^ 8'h5A}} ^ 32'h03020100, 32'hFFFFFFFF);

        // ---- write-combining: one word, again and again
        wr0 = chip.writes; c0 = cycles; i = 0;
        while (cycles - c0 < 4 * dut.WC_TICKS) begin
            access(1, 23'h7E2000, 4'b1111, i, dummy);
            i = i + 1;
        end
        $display("write-combining: %0d writes to one word, %0d line writes",
                 i, chip.writes - wr0);
        if (chip.writes - wr0 < 3) begin
            errors = errors + 1;
            $display("FAIL: a line written again and again stays out of the SDRAM");
        end
        wait_ticks(dut.WC_TICKS + 50);
        check_chip(23'h7E2000, i - 1, 32'hFFFFFFFF);

        $display("SDRAM: %0d line reads, %0d line writes, %0d refreshes, %0d timing errors",
                 chip.reads, chip.writes, chip.refreshes, chip.errors);
        $display("simulated %0.2f ms at %0d MHz", $realtime / 1.0e6, CLK_MHZ);
        if (errors == 0 && chip.errors == 0 && chip.refreshes > 0)
            $display("PASS");
        else
            $display("FAIL: %0d data errors, %0d SDRAM errors", errors, chip.errors);
        $finish;
    end

    // a stuck simulation is a failure too
    initial begin
        #200_000_000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
