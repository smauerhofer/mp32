// sdram_model.v: a model of the GW2AR-18's SDRAM for simulation only.
//
// 4 banks x 2,048 rows x 256 columns x 32 bits. It does what the controller needs
// (bursts of 4, with or without auto-precharge, READs one after the other in an open
// row, PRECHARGE ALL, AUTO REFRESH, LOAD MODE REGISTER) and complains about anything
// that would go wrong in the real chip:
//   - a command before 200 us of power-up, or before the mode register is loaded
//   - ACTIVE to a bank that is open or still precharging (tRP, tRC)
//   - READ/WRITE to a closed bank, too soon after ACTIVE (tRCD), or not on a 16-byte
//     boundary (column % 4 != 0)
//   - a READ that would cut the burst of the READ before short (under 4 ticks apart)
//   - REFRESH while a bank is open or precharging
//   - more than REFRESH_MAX_NS between two refreshes
// Each complaint adds 1 to errors.

`timescale 1ns/1ps

module sdram_model #(
    parameter real REFRESH_MAX_NS = 15625.0,   // 4,096 rows in 64 ms
    parameter real T_RCD = 18.0,
    parameter real T_RP  = 18.0,
    parameter real T_RAS = 42.0,
    parameter real T_RC  = 60.0,
    parameter real T_WR  = 12.0,
    parameter real T_POWERUP = 200000.0
) (
    input  wire        clk,
    input  wire        cke,
    input  wire        cs_n,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [3:0]  dqm,
    input  wire [10:0] addr,
    input  wire [1:0]  ba,
    inout  wire [31:0] dq
);
    reg [31:0] mem [0:(1 << 21) - 1];         // {bank, row, column}

    integer errors    = 0;
    integer refreshes = 0;
    integer reads     = 0;
    integer writes    = 0;

    reg        mode_set = 0;
    reg [2:0]  cl = 3'd2;
    reg        bank_open [0:3];
    reg [10:0] open_row  [0:3];
    real       t_active  [0:3];
    real       bank_free [0:3];
    real       t_cke = -1.0, t_ref = 0.0, t_edge = 0.0, period = 0.0;

    // read data on its way out: what goes on dq at edge number e, for the next 16 edges
    integer    edge_no = 0;
    reg        out_on   [0:15];
    reg [20:0] out_addr [0:15];
    real       t_read   [0:3];          // the bank's last READ
    integer    k;
    reg [31:0] dq_drv;
    reg        dq_en = 0;
    assign #1 dq = dq_en ? dq_drv : 32'bz;    // valid 1 ns after the edge (tAC)

    // write burst coming in
    integer    wr_left = 0;
    reg [20:0] wr_addr;

    integer b;
    initial begin
        for (b = 0; b < 4; b = b + 1) begin
            bank_open[b] = 0; bank_free[b] = 0.0; t_active[b] = 0.0; t_read[b] = -1.0e9;
        end
        for (b = 0; b < 16; b = b + 1) out_on[b] = 0;
    end

    function real max2(input real a, input real c);
        max2 = (a > c) ? a : c;
    endfunction

    // quiet = 1: a complaint is counted, but not shown (a test bench that expects some,
    // e.g. the missed refreshes while the computer is held in reset, sets it then)
    reg quiet = 1'b0;
    task fail(input [8*64-1:0] what);
        begin
            errors = errors + 1;
            if (errors <= 20 && !quiet) $display("%t SDRAM MODEL: %0s", $realtime, what);
        end
    endtask

    task write_word(input [20:0] a);
        begin
            if (!dqm[0]) mem[a][7:0]   = dq[7:0];
            if (!dqm[1]) mem[a][15:8]  = dq[15:8];
            if (!dqm[2]) mem[a][23:16] = dq[23:16];
            if (!dqm[3]) mem[a][31:24] = dq[31:24];
        end
    endtask

    always @(posedge clk) begin : edge_
        real now;
        now    = $realtime;
        period = now - t_edge;
        t_edge = now;

        if (cke && t_cke < 0.0) t_cke = now;

        // ---- data of bursts under way
        if (wr_left > 0) begin
            write_word(wr_addr);
            wr_addr = wr_addr + 1;
            wr_left = wr_left - 1;
        end
        edge_no = edge_no + 1;
        if (out_on[edge_no % 16]) begin
            dq_drv <= mem[out_addr[edge_no % 16]];
            dq_en  <= 1'b1;
            out_on[edge_no % 16] = 0;
        end else
            dq_en  <= 1'b0;

        // ---- refresh watchdog
        if (mode_set && now - t_ref > REFRESH_MAX_NS) begin
            fail("refresh interval exceeded");
            t_ref = now;
        end

        // ---- the command
        if (cke && !cs_n && {ras_n, cas_n, we_n} != 3'b111) begin
            if (t_cke < 0.0 || now - t_cke < T_POWERUP)
                fail("command before 200 us of power-up");

            case ({ras_n, cas_n, we_n})
            3'b011: begin                                           // ACTIVE
                if (!mode_set)               fail("ACTIVE before LOAD MODE");
                if (bank_open[ba])           fail("ACTIVE to an open bank");
                if (now < bank_free[ba] - 0.01) fail("ACTIVE too soon (tRP/tRC)");
                bank_open[ba] = 1;
                open_row[ba]  = addr;
                t_active[ba]  = now;
            end
            3'b101, 3'b100: begin                                   // READ, WRITE
                if (!bank_open[ba])          fail("READ/WRITE to a closed bank");
                if (now - t_active[ba] < T_RCD - 0.01) fail("READ/WRITE too soon (tRCD)");
                if (addr[1:0] != 2'b00)      fail("burst not on a 16-byte boundary");
                if (now - t_read[ba] < 4 * period - 0.01) fail("READ cuts a burst short");
                if (addr[10]) bank_open[ba] = 0;              // auto-precharge
                if (we_n) begin
                    reads   = reads + 1;
                    t_read[ba] = now;
                    for (k = 0; k < 4; k = k + 1) begin
                        out_on[(edge_no + cl + k) % 16]   = 1;
                        out_addr[(edge_no + cl + k) % 16] = {ba, open_row[ba], addr[7:0]} + k;
                    end
                    bank_free[ba] = max2(now + 4 * period, t_active[ba] + T_RAS) + T_RP;
                end else begin
                    writes  = writes + 1;
                    wr_addr = {ba, open_row[ba], addr[7:0]};
                    write_word(wr_addr);
                    wr_addr = wr_addr + 1;
                    wr_left = 3;
                    bank_free[ba] = max2(now + 3 * period + max2(T_WR, 2 * period),
                                         t_active[ba] + T_RAS) + T_RP;
                end
                bank_free[ba] = max2(bank_free[ba], t_active[ba] + T_RC);
            end
            3'b010: begin                                           // PRECHARGE
                for (b = 0; b < 4; b = b + 1)
                    if (addr[10] || ba == b) begin
                        bank_open[b] = 0;
                        bank_free[b] = max2(bank_free[b], now + T_RP);
                    end
            end
            3'b001: begin                                           // AUTO REFRESH
                for (b = 0; b < 4; b = b + 1) begin
                    if (bank_open[b])              fail("REFRESH with a bank open");
                    if (now < bank_free[b] - 0.01) fail("REFRESH too soon (tRP/tRC)");
                    bank_free[b] = now + T_RC;
                end
                refreshes = refreshes + 1;
                t_ref     = now;
            end
            3'b000: begin                                           // LOAD MODE REGISTER
                for (b = 0; b < 4; b = b + 1)
                    if (bank_open[b] || now < bank_free[b] - 0.01)
                        fail("LOAD MODE with a bank busy");
                if (addr[2:0] != 3'b010) fail("burst length is not 4");
                if (addr[3])             fail("burst is not sequential");
                if (addr[9])             fail("single-word writes");
                cl       = addr[6:4];
                mode_set = 1;
                t_ref    = now;
            end
            default: fail("unknown command");
            endcase
        end
    end
endmodule
