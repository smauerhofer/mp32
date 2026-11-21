// sdram.v: the controller of the SDRAM inside the Tang Nano 20K's chip (GW2AR-18).
//
// The chip carries 64 Mbit of SDRAM: 4 banks of 2,048 rows of 256 columns, each
// column 32 bits wide. That is 8 MB, byte addresses 0x000000 - 0x7FFFFF.
//
// This controller moves whole cache lines: 16 bytes, aligned to 16 bytes, which are
// four columns read or written in one burst of 4. A line never crosses a row.
//
//   byte address bits  22..12   11..10   9..4          3..0
//                      row      bank     column / 4    byte in the line
//
// So consecutive kilobytes sit in different banks.
//
// Two ports ask: the cache, for lines (read and write), and the video unit, for
// bursts (read only).
//
// ---------------------------------------------------------------- the row burst
// The video unit asks for vcount units of 16 bytes from vaddr on, all in the same
// kilobyte (the same row of the same bank: vaddr[9:4] + vcount <= 64). The row is
// opened once, a READ of 4 words goes out every 4 ticks (the last one with
// auto-precharge), and the words come back one a tick, without a gap: vword, with
// vvalid at 1, in the order of their addresses. So vcount units take about
// 4*vcount + 8 ticks: 40 units (640 bytes) about 170 ticks.
//
// Every access opens the row, reads or writes its burst with auto-precharge, and so
// closes the row again on its own ("closed page"). Between accesses every bank is
// idle, so a refresh can go in at any time.
//
// ---------------------------------------------------------------- refresh
// One AUTO REFRESH every REFRESH_NS, 7.8 us by default: that is 8,192 in 64 ms, twice
// what a 4K-refresh part needs. A refresh that is due goes ahead of a waiting request;
// an access of the cache under way is short (under 25 ticks), a burst of the video
// unit at most about 270 ticks: neither holds a refresh off for long.
//
// ---------------------------------------------------------------- who goes first
// When the controller is idle it takes, in this order:
//   1. a refresh that is due
//   2. a read of the video unit (vreq)
//   3. a request of the cache (req)
// An access under way is never cut short. A burst of the video unit lasts up to
// about 4*64 + 8 ticks; meanwhile the cache waits. The video's data is due a whole
// line of the screen later, so it never waits for long: at most one access of the
// cache and one refresh. A burst is long, so a refresh may wait for one: REFRESH_NS
// leaves room for that (twice as many refreshes as the chip needs).
//
// ---------------------------------------------------------------- the handshakes
// The cache raises req with we, addr and (for a write) wline, and holds them until
// ack is 1. ack lasts one tick, and ends the request:
//   - a read:  rline holds the line during that tick (and after, until the next read)
//   - a write: wline has been sent; the cache may change it from the next tick on
// The cache may raise its next request in the tick after ack (or keep req at 1 and
// change the other three): the controller only takes a request when it is idle, and
// it is never idle in the tick after ack.
//
// The video unit does the same with vreq, vaddr and vcount, and gets its words in
// vword (vvalid at 1, one a tick) and vack in the tick of the last word. It may raise
// its next request in the tick after vack, as the cache may.
//
// ---------------------------------------------------------------- clocking
// The SDRAM gets the inverted clock (O_sdram_clk = ~clk). Commands and write data
// change on the rising edge of clk and the SDRAM samples them half a period later.
// Read data leaves the SDRAM tAC (about 6 ns) after its edge and is sampled here on
// the rising edge of clk, RD_LAT = CAS + 1 ticks after the READ went out, which is
// half a period after it turned valid. This needs half a period > tAC plus the wires:
// fine up to about 60 MHz.
//
// For a faster clock (100 MHz) set EXT_CLK = 1 and bring a second output of the PLL,
// at the same frequency and shifted in phase, to clk_sdram: O_sdram_clk is then that
// clock. Its phase and RD_LAT go together: RD_LAT counts the ticks of clk from the
// READ on the pins to the first word sampled. Both have to be found on the board
// (the simulation's model of the SDRAM gives its data 1 ns after its edge, and so
// cannot tell a good phase from a bad one).
//
// ---------------------------------------------------------------- reset
// reset (synchronous, active high) starts the power-up sequence: 200 us of NOPs,
// PRECHARGE ALL, 8 AUTO REFRESH, LOAD MODE REGISTER (burst of 4, sequential,
// CAS latency CAS). Requests wait until it is done.

module sdram #(
    parameter CLK_MHZ    = 27,         // the frequency of clk, in MHz
    parameter CAS        = 2,          // CAS latency, 2 or 3
    parameter RD_LAT     = CAS + 1,    // ticks from READ out to the first word sampled
    parameter REFRESH_NS = 7800,       // one AUTO REFRESH this often
    parameter EXT_CLK    = 0           // 1: the SDRAM's clock is clk_sdram, not ~clk
) (
    input  wire         clk,
    input  wire         clk_sdram,     // used only with EXT_CLK = 1
    input  wire         reset,

    // The cache
    input  wire         req,
    input  wire         we,
    input  wire [22:4]  addr,          // the line's address: byte address bits 22..4
    input  wire [127:0] wline,         // word 0 (bytes 0-3) in bits 31..0
    output reg  [127:0] rline,
    output reg          ack,

    // The video unit: row bursts, read only, ahead of the cache
    input  wire         vreq,
    input  wire [22:4]  vaddr,         // the first unit of 16 bytes: byte address bits 22..4
    input  wire [6:0]   vcount,        // units of 16 bytes, 1 - 64, all in vaddr's kilobyte
    output reg  [31:0]  vword,
    output reg          vvalid,
    output reg          vack,

    // The SDRAM (the names of the chip's internal pins)
    output wire         O_sdram_clk,
    output reg          O_sdram_cke,
    output wire         O_sdram_cs_n,
    output wire         O_sdram_ras_n,
    output wire         O_sdram_cas_n,
    output wire         O_sdram_wen_n,
    output reg  [3:0]   O_sdram_dqm,
    output reg  [10:0]  O_sdram_addr,
    output reg  [1:0]   O_sdram_ba,
    inout  wire [31:0]  IO_sdram_dq
);
    // ================================================================ timing
    // In ticks of clk, rounded up, with a little margin over the data sheet.
    localparam integer T_RP   = (20 * CLK_MHZ + 999) / 1000;   // PRECHARGE to ACTIVE
    localparam integer T_RCD  = (20 * CLK_MHZ + 999) / 1000;   // ACTIVE to READ/WRITE
    localparam integer T_RC   = (70 * CLK_MHZ + 999) / 1000;   // ACTIVE to ACTIVE, REFRESH
    localparam integer T_WR0  = (15 * CLK_MHZ + 999) / 1000;
    localparam integer T_WR   = (T_WR0 < 2) ? 2 : T_WR0;        // last write data to precharge
    localparam integer T_MRD  = 3;                              // LOAD MODE to anything
    localparam integer T_INIT = 200 * CLK_MHZ + 100;            // 200 us after power-up
    localparam integer T_REFI = REFRESH_NS * CLK_MHZ / 1000;    // between refreshes

    // How many ticks each access lasts, the tick of the ACTIVE (or REFRESH) included.
    // One idle tick follows, so the next ACTIVE comes one tick later still.
    //   read:  the auto-precharge starts 4 ticks after the READ, then tRP; and all
    //          4 words must be in, plus the tick of ack
    //   write: the last word goes in 3 ticks after the WRITE, then tWR + tRP
    localparam integer RD_A    = T_RCD + 4 + T_RP;
    localparam integer RD_B    = T_RCD + RD_LAT + 4;
    localparam integer RD_C    = (RD_A > RD_B) ? RD_A : RD_B;
    localparam integer N_READ  = (RD_C > T_RC) ? RD_C : T_RC;
    localparam integer WR_A    = T_RCD + 3 + T_WR + T_RP;
    localparam integer N_WRITE = (WR_A > T_RC) ? WR_A : T_RC;
    localparam integer N_REF   = T_RC;

    // The mode register: burst of 4, sequential, CAS latency, burst writes.
    localparam [2:0]  CL   = CAS;
    localparam [10:0] MODE = {4'b0000, CL, 1'b0, 3'b010};

    // ================================================================ commands
    //                            cs_n ras_n cas_n we_n
    localparam [3:0] CMD_NOP       = 4'b0111;
    localparam [3:0] CMD_ACTIVE    = 4'b0011;
    localparam [3:0] CMD_READ      = 4'b0101;
    localparam [3:0] CMD_WRITE     = 4'b0100;
    localparam [3:0] CMD_PRECHARGE = 4'b0010;
    localparam [3:0] CMD_REFRESH   = 4'b0001;
    localparam [3:0] CMD_MODE      = 4'b0000;

    reg [3:0] cmd;
    assign {O_sdram_cs_n, O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n} = cmd;
    assign O_sdram_clk = EXT_CLK ? clk_sdram : ~clk;

    reg [31:0] dq_out;
    reg        dq_oe;
    assign IO_sdram_dq = dq_oe ? dq_out : 32'bz;

    // ================================================================ the machine
    localparam [2:0] S_INIT   = 3'd0,    // NOPs for 200 us
                     S_PRE    = 3'd1,    // PRECHARGE ALL went out
                     S_REF    = 3'd2,    // the 8 refreshes of the power-up
                     S_MODE   = 3'd3,    // LOAD MODE REGISTER went out
                     S_IDLE   = 3'd4,
                     S_ACCESS = 3'd5;    // a read, a write or a refresh

    localparam [1:0] OP_READ = 2'd0, OP_WRITE = 2'd1, OP_REFRESH = 2'd2, OP_BURST = 2'd3;

    reg [2:0]  state;
    reg [15:0] t;            // ticks since the state's first command
    reg [15:0] t_last;       // the last tick of this access
    reg [1:0]  op;
    reg  [6:0] count;        // the burst's units of 16 bytes
    reg [2:0]  nref;         // refreshes of the power-up so far
    reg [5:0]  col;          // the line's column / 4
    reg [15:0] ref_timer;
    reg        ref_pending;

    // Which tick of the access this is, counted from the WRITE / from the first word
    // read. Only the low bits count; the compares below pick the ticks.
    wire [15:0] tw = t - (T_RCD - 1);
    wire [15:0] tr = t - (T_RCD + RD_LAT - 1);
    wire [15:0] tb = t - (T_RCD - 1);           // ticks since the first READ was set

    // The last tick of a burst of vcount units (see N_READ): the last READ's
    // auto-precharge starts 4 ticks after it, then tRP; all words must be in.
    wire [15:0] burst_a    = T_RCD + {vcount, 2'b00} + T_RP;
    wire [15:0] burst_b    = T_RCD + RD_LAT + {vcount, 2'b00};
    wire [15:0] burst_c    = (burst_a > burst_b) ? burst_a : burst_b;
    wire [15:0] burst_last = ((burst_c > T_RC) ? burst_c : T_RC) - 1;
    wire [31:0] wword = (tw[1:0] == 2'd0) ? wline[31:0]  : (tw[1:0] == 2'd1) ? wline[63:32] :
                        (tw[1:0] == 2'd2) ? wline[95:64] :                      wline[127:96];

    always @(posedge clk) begin
        if (reset) begin
            state       <= S_INIT;
            t           <= 0;
            cmd         <= CMD_NOP;
            O_sdram_cke <= 1'b0;
            O_sdram_dqm <= 4'b1111;
            O_sdram_addr<= 0;
            O_sdram_ba  <= 0;
            dq_oe       <= 1'b0;
            ack         <= 1'b0;
            vack        <= 1'b0;
            vvalid      <= 1'b0;
            ref_pending <= 1'b0;
            ref_timer   <= T_REFI - 1;
        end else begin
            cmd  <= CMD_NOP;
            ack  <= 1'b0;
            vack   <= 1'b0;
            vvalid <= 1'b0;
            t   <= t + 1'b1;

            case (state)
            // ---------------------------------------------------- power-up
            S_INIT: begin
                O_sdram_cke <= 1'b1;
                if (t == T_INIT) begin
                    cmd              <= CMD_PRECHARGE;
                    O_sdram_addr[10] <= 1'b1;            // all banks
                    t                <= 0;
                    state            <= S_PRE;
                end
            end
            S_PRE:
                if (t == T_RP) begin
                    cmd   <= CMD_REFRESH;
                    nref  <= 0;
                    t     <= 0;
                    state <= S_REF;
                end
            S_REF:
                if (t == T_RC) begin
                    t <= 0;
                    if (nref == 3'd7) begin
                        cmd          <= CMD_MODE;
                        O_sdram_addr <= MODE;
                        O_sdram_ba   <= 2'b00;
                        state        <= S_MODE;
                    end else begin
                        cmd  <= CMD_REFRESH;
                        nref <= nref + 1'b1;
                    end
                end
            S_MODE:
                if (t == T_MRD) begin
                    O_sdram_dqm <= 4'b0000;
                    state       <= S_IDLE;
                end

            // ---------------------------------------------------- idle
            S_IDLE: begin
                t <= 0;
                if (ref_pending) begin
                    cmd         <= CMD_REFRESH;
                    ref_pending <= 1'b0;
                    op          <= OP_REFRESH;
                    t_last      <= N_REF - 1;
                    state       <= S_ACCESS;
                end else if (vreq) begin
                    cmd          <= CMD_ACTIVE;
                    O_sdram_ba   <= vaddr[11:10];
                    O_sdram_addr <= vaddr[22:12];
                    col          <= vaddr[9:4];
                    count        <= vcount;
                    op           <= OP_BURST;
                    t_last       <= burst_last;
                    state        <= S_ACCESS;
                end else if (req) begin
                    cmd          <= CMD_ACTIVE;
                    O_sdram_ba   <= addr[11:10];
                    O_sdram_addr <= addr[22:12];
                    col          <= addr[9:4];
                    op           <= we ? OP_WRITE : OP_READ;
                    t_last       <= we ? N_WRITE - 1 : N_READ - 1;
                    state        <= S_ACCESS;
                end
            end

            // ---------------------------------------------------- an access
            // t = 0 is the tick of the ACTIVE (or REFRESH) on the pins.
            S_ACCESS: begin
                if ((op == OP_READ || op == OP_WRITE) && t == T_RCD - 1) begin
                    cmd          <= (op == OP_WRITE) ? CMD_WRITE : CMD_READ;
                    O_sdram_addr <= {1'b1, 2'b00, col, 2'b00};   // A10: auto-precharge
                end

                // burst: READ k on the pins in tick T_RCD + 4k, k = 0 .. count-1; the
                // last one with auto-precharge. Word i sampled at the end of tick
                // T_RCD + RD_LAT - 1 + i, and shown in vword in the tick after.
                if (op == OP_BURST && tb[1:0] == 2'd0 && tb[15:2] < count) begin
                    cmd          <= CMD_READ;
                    O_sdram_addr <= {tb[15:2] == count - 1'b1, 2'b00,
                                     col + tb[7:2], 2'b00};
                end
                if (op == OP_BURST && tr < {count, 2'b00}) begin
                    vword  <= IO_sdram_dq;
                    vvalid <= 1'b1;
                    if (tr == {count, 2'b00} - 1'b1)
                        vack <= 1'b1;
                end

                // write: words 0-3 on the pins in ticks T_RCD .. T_RCD+3
                if (op == OP_WRITE && tw < 4) begin
                    dq_out <= wword;
                    dq_oe  <= 1'b1;
                end
                if (t == T_RCD + 3)
                    dq_oe <= 1'b0;
                if (op == OP_WRITE && t == T_RCD + 2)
                    ack <= 1'b1;                          // wline is no longer needed

                // read: words 0-3 sampled at the ends of ticks T_RCD+RD_LAT-1 ..
                if (op == OP_READ && tr < 4) case (tr[1:0])
                    2'd0: rline[31:0]   <= IO_sdram_dq;
                    2'd1: rline[63:32]  <= IO_sdram_dq;
                    2'd2: rline[95:64]  <= IO_sdram_dq;
                    2'd3: rline[127:96] <= IO_sdram_dq;
                endcase
                if (op == OP_READ && t == T_RCD + RD_LAT + 2)
                    ack <= 1'b1;                          // rline is complete

                if (t == t_last)
                    state <= S_IDLE;
            end

            default: state <= S_INIT;
            endcase

            // ---------------------------------------------------- the refresh timer
            // After the machine, so that a refresh falling due in the very tick one
            // goes out is not lost.
            if (ref_timer == 0) begin
                ref_timer   <= T_REFI - 1;
                ref_pending <= 1'b1;
            end else
                ref_timer <= ref_timer - 1'b1;
        end
    end
endmodule
