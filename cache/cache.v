// cache.v: a cache in front of the 8 MB of SDRAM of the Tang Nano 20K.
//
//   Direct-mapped, write-back, write-allocate.
//   Lines of 16 bytes, aligned to 16 bytes, read and written as one SDRAM burst of 4.
//   2^INDEX_BITS lines: 512 by default, so 8 KB.
//   The SDRAM controller under it (sdram.v) also keeps the SDRAM refreshed; that
//   needs nothing from the processor.
//
// Block memory: the data is 512 x 128 bits (4 blocks), the tags 512 x 12 bits
// (1 block). 256 lines take the same 4 + 1 blocks, so 512 costs nothing more.
//
// ---------------------------------------------------------------- addresses
// Byte addresses, 23 bits, 0x000000 - 0x7FFFFF. With INDEX_BITS = 9:
//
//   bits  22..13   12..4   3..2           1..0
//         tag      index   word in line   ignored: cpu_be picks the bytes
//
// ---------------------------------------------------------------- the processor side
// A 32-bit bus on clk, the clock of the cache and of the SDRAM. The same handshake as
// the video unit: the processor sets cpu_sel, cpu_we, cpu_be, cpu_addr and cpu_wdata
// and holds them until cpu_ready is 1. That tick ends the access; for a read,
// cpu_rdata is valid during it.
//   cpu_be:   one bit for each byte of the word, bit 0 for bits 7..0 (the byte at
//             address 4n, little-endian). A read always returns the whole word.
//             A byte bus uses one bit of it, after (cpu_addr[1:0]).
//
//   - a hit, read or write:           cpu_ready 1 tick after cpu_sel (2 ticks in all)
//   - a miss on a clean or empty line: one burst read, then as a hit
//   - a miss on a dirty line:          one burst write of the old line, one burst
//                                      read of the new one, then as a hit
//   A refresh due at the time adds its few ticks. After reset the cache first clears
//   its tags (512 ticks) and the SDRAM goes through its 200 us power-up; accesses wait.
//
// cpu_rline is the whole 16-byte line the word of a read comes from (the byte at
// offset k in bits 8k+7..8k), valid in the same tick as cpu_rdata. The fetch stage
// reads its lines with it: a read of the line's first word, then cpu_rline.
//
// A write to a line that is not in the cache reads the line first (write-allocate),
// then writes the bytes into it. A line goes back to the SDRAM only when another
// line takes its place. Nothing else may write the SDRAM behind the cache's back.
//
// ---------------------------------------------------------------- write-through
// The video unit reads its pictures and text straight from the SDRAM, so what the
// processor writes there must not wait in the cache for long. Writes to WT_FROM - WT_TO
// (byte addresses, whole lines: the low 4 bits do not count) go into the cache, which
// keeps the line clean, and into the write-combining buffer: one line, a copy of the
// cached one, "pending". It goes to the SDRAM (one burst of 16 bytes)
//   - when the processor writes to another line of the region: that line waits for it,
//   - before any miss: the cache reads nothing from the SDRAM with a line pending,
//   - at the latest WC_TICKS ticks after it became pending (counted from the first
//     write, not the last: a loop on one byte cannot keep it out of the SDRAM).
// So 16 bytes written one after the other cost one burst, not 16, and the video unit
// sees what was written at the latest about WC_TICKS ticks later (plus a burst of the
// video unit and a refresh that may be in the way): 512 ticks are 12 us at 42 MHz, less
// than one line of the screen. A byte loop may take up to WC_TICKS / 16 ticks a byte
// and still fill each line with one burst.
//   - a write hit there:   cpu_ready as any hit, 1 tick after cpu_sel; if another
//                          line is pending, it goes out first (about 8 ticks more)
//   - a write miss there:  the pending line out, the line read, then as a hit
// Reads there are as anywhere else. By default the region is the top 512 KB,
// 0x780000 - 0x7FFFFF, where the video unit's screen goes (326,400 bytes).
// Set WT_FROM > WT_TO for no such region.
//
// The pending line is always in the cache too, the same: it is clean there, so it is
// never written back on its own, and it cannot be thrown out (that takes a miss, and a
// miss writes the pending line first). So reads of it, and fetches, see the new bytes.
//
// ---------------------------------------------------------------- the video port
// vid_req, vid_addr, vid_count, vid_word, vid_valid and vid_ack go straight through to
// the SDRAM controller (its vreq, vaddr, vcount, vword, vvalid and vack): row bursts
// for the video unit, ahead of the cache's own reads. They do not look into the
// cache, which is why the video region must be write-through.
//
// ---------------------------------------------------------------- the SDRAM's clock
// EXT_CLK and clk_sdram go to the SDRAM controller: see sdram.v. Above about 60 MHz
// the SDRAM needs a phase-shifted clock from the PLL.

module cache #(
    parameter INDEX_BITS = 9,          // 2^INDEX_BITS lines of 16 bytes
    parameter CLK_MHZ    = 27,         // the frequency of clk, in MHz
    parameter CAS        = 2,          // CAS latency of the SDRAM, 2 or 3
    parameter RD_LAT     = CAS + 1,    // see sdram.v
    parameter REFRESH_NS = 7800,       // see sdram.v
    parameter [22:0] WT_FROM = 23'h780000,   // the write-through region, see above
    parameter [22:0] WT_TO   = 23'h7FFFFF,
    parameter WC_TICKS   = 512,        // a pending line goes out at the latest this late (< 1024)
    parameter EXT_CLK    = 0,          // see sdram.v
    parameter RD_NEG     = 0           // see sdram.v
) (
    input  wire        clk,
    input  wire        clk_sdram,      // see sdram.v: used only with EXT_CLK = 1
    input  wire        reset,          // synchronous, active high

    // The processor
    input  wire        cpu_sel,
    input  wire        cpu_we,
    input  wire [3:0]  cpu_be,
    input  wire [22:0] cpu_addr,
    input  wire [31:0] cpu_wdata,
    output wire [31:0] cpu_rdata,
    output wire [127:0] cpu_rline,     // the whole line of a read
    output wire        cpu_ready,

    // The video unit: row bursts, on clk
    input  wire         vid_req,
    input  wire [22:4]  vid_addr,
    input  wire [6:0]   vid_count,
    output wire [31:0]  vid_word,
    output wire         vid_valid,
    output wire         vid_ack,

    // The SDRAM
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_wen_n,
    output wire [3:0]  O_sdram_dqm,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    inout  wire [31:0] IO_sdram_dq
);
    localparam LINES    = 1 << INDEX_BITS;
    localparam TAG_BITS = 19 - INDEX_BITS;

    wire [INDEX_BITS-1:0] index = cpu_addr[INDEX_BITS+3:4];
    wire [TAG_BITS-1:0]   tag   = cpu_addr[22:INDEX_BITS+4];

    // ================================================================ the SDRAM
    reg          mem_req;
    reg          mem_we;
    reg  [22:4]  mem_addr;
    reg  [127:0] evict_line;
    wire [127:0] mem_rline;
    wire         mem_ack;

    sdram #(
        .CLK_MHZ(CLK_MHZ), .CAS(CAS), .RD_LAT(RD_LAT), .REFRESH_NS(REFRESH_NS),
        .EXT_CLK(EXT_CLK), .RD_NEG(RD_NEG)
    ) sdram (
        .clk(clk), .clk_sdram(clk_sdram), .reset(reset),
        .req(mem_req), .we(mem_we), .addr(mem_addr),
        .wline(evict_line), .rline(mem_rline), .ack(mem_ack),
        .vreq(vid_req), .vaddr(vid_addr), .vcount(vid_count),
        .vword(vid_word), .vvalid(vid_valid), .vack(vid_ack),
        .O_sdram_clk(O_sdram_clk),     .O_sdram_cke(O_sdram_cke),
        .O_sdram_cs_n(O_sdram_cs_n),   .O_sdram_ras_n(O_sdram_ras_n),
        .O_sdram_cas_n(O_sdram_cas_n), .O_sdram_wen_n(O_sdram_wen_n),
        .O_sdram_dqm(O_sdram_dqm),     .O_sdram_addr(O_sdram_addr),
        .O_sdram_ba(O_sdram_ba),       .IO_sdram_dq(IO_sdram_dq)
    );

    // ================================================================ memories
    // Simple dual-port: one port writes, the other reads, always at the processor's
    // index. Its output belongs to the address of the tick before; the processor
    // holds its address, so in the tick after cpu_sel it belongs to that address.
    reg [127:0]        data_ram [0:LINES-1];
    reg [TAG_BITS+1:0] tag_ram  [0:LINES-1];    // {valid, dirty, tag}

    reg [127:0]        line_q;
    reg [TAG_BITS+1:0] tag_q;
    always @(posedge clk) begin
        line_q <= data_ram[index];
        tag_q  <= tag_ram[index];
    end

    wire                q_valid = tag_q[TAG_BITS+1];
    wire                q_dirty = tag_q[TAG_BITS];
    wire [TAG_BITS-1:0] q_tag   = tag_q[TAG_BITS-1:0];
    wire                hit     = q_valid & (q_tag == tag);

    // Is the processor's address in the write-through region?
    wire through = (cpu_addr[22:4] >= WT_FROM[22:4]) & (cpu_addr[22:4] <= WT_TO[22:4]);

    // ---- the write-combining buffer: one line of the region, pending (see above)
    reg         wc_valid;
    reg [22:4]  wc_addr;
    reg [127:0] wc_line;
    reg [9:0]   wc_timer;              // ticks left until it must go out
    wire        wc_same  = wc_valid & (wc_addr == {tag, index});
    wire        wc_other = wc_valid & ~wc_same;
    wire        wc_due   = wc_valid & (wc_timer == 0);

    // A write hit in the region that must wait for the pending line of another
    wire        wt_wait  = cpu_we & through & wc_other;

    // The line with the processor's bytes written into it
    function [31:0] merge(input [31:0] old, input [31:0] new, input [3:0] be);
        merge = {be[3] ? new[31:24] : old[31:24], be[2] ? new[23:16] : old[23:16],
                 be[1] ? new[15:8]  : old[15:8],  be[0] ? new[7:0]   : old[7:0]};
    endfunction

    wire [1:0] word = cpu_addr[3:2];
    wire [127:0] merged = {
        word == 2'd3 ? merge(line_q[127:96], cpu_wdata, cpu_be) : line_q[127:96],
        word == 2'd2 ? merge(line_q[95:64],  cpu_wdata, cpu_be) : line_q[95:64],
        word == 2'd1 ? merge(line_q[63:32],  cpu_wdata, cpu_be) : line_q[63:32],
        word == 2'd0 ? merge(line_q[31:0],   cpu_wdata, cpu_be) : line_q[31:0]};

    // ================================================================ the machine
    localparam [2:0] S_CLEAR = 3'd0,    // after reset: every tag to "not valid"
                     S_IDLE  = 3'd1,    // the memories read the processor's index
                     S_CHECK = 3'd2,    // hit or miss?
                     S_EVICT = 3'd3,    // the old, dirty line goes back to the SDRAM
                     S_FILL  = 3'd4,    // the new line comes in from the SDRAM
                     S_FLUSH = 3'd5;    // the pending line goes to the SDRAM

    reg [2:0]            state;
    reg [INDEX_BITS-1:0] clear_index;

    wire   hit_now   = (state == S_CHECK) & cpu_sel & hit;
    assign cpu_ready = hit_now & ~wt_wait;
    assign cpu_rline = line_q;
    assign cpu_rdata = (word == 2'd0) ? line_q[31:0]  : (word == 2'd1) ? line_q[63:32] :
                       (word == 2'd2) ? line_q[95:64] :                   line_q[127:96];

    // ---- the write ports
    reg                  data_we, tag_we;
    reg [INDEX_BITS-1:0] tag_wa;
    reg [127:0]          data_wd;
    reg [TAG_BITS+1:0]   tag_wd;

    always @* begin
        data_we = 1'b0;
        tag_we  = 1'b0;
        tag_wa  = index;
        data_wd = merged;
        tag_wd  = {2'b11, tag};
        case (state)
        S_CLEAR: begin
            tag_we = 1'b1;
            tag_wa = clear_index;
            tag_wd = 0;
        end
        S_CHECK:                           // a write hit: the bytes in, the line dirty
            if (cpu_sel & hit & cpu_we & ~wt_wait) begin   // (clean if it goes through)
                data_we = 1'b1;
                tag_we  = 1'b1;
                data_wd = merged;
                tag_wd  = {1'b1, ~through, tag};
            end
        S_FILL:                            // the new line in, clean
            if (mem_ack) begin
                data_we = 1'b1;
                tag_we  = 1'b1;
                data_wd = mem_rline;
                tag_wd  = {2'b10, tag};
            end
        default: ;
        endcase
    end

    always @(posedge clk) begin
        if (data_we) data_ram[index]  <= data_wd;
        if (tag_we)  tag_ram[tag_wa]  <= tag_wd;
    end

    // ---- the states
    always @(posedge clk) begin
        if (reset) begin
            state       <= S_CLEAR;
            clear_index <= 0;
            mem_req     <= 1'b0;
            mem_we      <= 1'b0;
            wc_valid    <= 1'b0;
            wc_timer    <= 0;
        end else begin
            if (wc_valid && wc_timer != 0)
                wc_timer <= wc_timer - 1'b1;

            case (state)
            S_CLEAR: begin
                clear_index <= clear_index + 1'b1;
                if (clear_index == LINES - 1)
                    state <= S_IDLE;
            end
            S_IDLE:
                if (wc_due) begin              // the pending line has waited long enough
                    mem_req    <= 1'b1;
                    mem_we     <= 1'b1;
                    mem_addr   <= wc_addr;
                    evict_line <= wc_line;
                    state      <= S_FLUSH;
                end else if (cpu_sel)
                    state <= S_CHECK;
            S_CHECK:
                if (!cpu_sel)
                    state <= S_IDLE;           // the processor gave up
                else if ((hit & ~cpu_we) | (hit & cpu_we & ~through))
                    state <= S_IDLE;           // done
                else if (hit & ~wt_wait) begin // a write in the region: into the buffer
                    wc_line  <= merged;
                    wc_addr  <= {tag, index};
                    wc_valid <= 1'b1;
                    if (!wc_valid)
                        wc_timer <= WC_TICKS;
                    state    <= S_IDLE;
                end else if (wc_valid) begin   // another line pending, or a miss: the
                    mem_req    <= 1'b1;        // pending line out first, then again
                    mem_we     <= 1'b1;
                    mem_addr   <= wc_addr;
                    evict_line <= wc_line;
                    state      <= S_FLUSH;
                end else begin                 // a miss
                    mem_req <= 1'b1;
                    if (q_valid & q_dirty) begin
                        mem_we     <= 1'b1;
                        mem_addr   <= {q_tag, index};
                        evict_line <= line_q;
                        state      <= S_EVICT;
                    end else begin
                        mem_we   <= 1'b0;
                        mem_addr <= {tag, index};
                        state    <= S_FILL;
                    end
                end
            S_EVICT:
                if (mem_ack) begin             // the old line is out; now read the new one
                    mem_we   <= 1'b0;
                    mem_addr <= {tag, index};
                    state    <= S_FILL;
                end
            S_FILL:
                if (mem_ack) begin             // the line is written into the memories in
                    mem_req <= 1'b0;           // this tick; read it again, as a hit
                    state   <= S_IDLE;
                end
            S_FLUSH:
                if (mem_ack) begin             // the pending line is out; the access (if
                    mem_req  <= 1'b0;          // any) starts again
                    wc_valid <= 1'b0;
                    state    <= S_IDLE;
                end
            default:
                state <= S_IDLE;
            endcase
        end
    end
endmodule
