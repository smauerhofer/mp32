// timer.v: two timers of the mp32 computer, for regular interrupts. They are the
// same; they differ only in their line of the interrupt controller, the two least
// urgent ones:
//
//   timer 0  line 6, vector 22   the fast one: e.g. 1 ms (MS, TICKS, the scheduler)
//   timer 1  line 7, vector 23   the slow one: e.g. 100 ms or 1 s (the cursor's
//                                blink, time-outs, the clock)
//
// Each counts the processor's ticks down, 32 bits: from PERIOD - 1 to 0, then it
// sets its flag F and starts again at PERIOD - 1. So an event comes every PERIOD
// ticks, exactly, whatever the handler does and how late it comes: at 42 MHz from
// 23.8 ns (PERIOD 1) to 102 s (PERIOD 0 = 2^32). FREQ says how many ticks are a
// second, so a program does not need to know the clock (42 MHz now, 63 MHz later).
//
// ---------------------------------------------------------------- the registers
//   io_addr[5:2]  (0xFFFF_0700 + 4 * that)
//     0  T0CTRL      timer 0
//     1  T0PERIOD
//     2  T0COUNT
//     4  T1CTRL      timer 1
//     5  T1PERIOD
//     6  T1COUNT
//     8  FREQ        read: the processor's ticks per second (CLK_HZ)
//   the others read 0, writes are ignored
//
//   CTRL
//     bit 0  EN       1: it counts. A one-shot timer clears it at its event.
//     bit 1  IE       1: F interrupts (irq = F & IE)
//     bit 2  ONESHOT  1: at 0 it stops (EN = 0, COUNT stays 0) instead of starting again
//     bit 8  F        read: the count reached 0 since F was cleared
//     bit 9  OVR      read: it reached 0 again while F was still 1: an event was lost
//                     write: a 1 in bit 8 or 9 clears F or OVR; a 0 leaves it
//     bits 2..0 are written with io_be[0], the clears with io_be[1].
//
//   PERIOD  the ticks from one event to the next (0 = 2^32). A write also starts the
//           count again: COUNT = PERIOD - 1 (EN as it is). Write it before EN.
//   COUNT   read: the ticks left until the next event, minus 1 (0: in this tick).
//           write: sets it (the next event after COUNT + 1 ticks, with EN).
//   PERIOD and COUNT take the bytes io_be picks; the others stay.
//
//   After reset: all 0, nothing counts, no irq.
//
// A handler: write CTRL with F (and OVR) to clear, e.g. 0x303 (EN, IE kept), then
// EOI, RTI. The flag that an event sets wins over a clear in the same tick.
//
// The cache's handshake, as the board's registers (iodec.v): io_sel and the rest are
// held until io_ready; io_ready is a register, so an access takes two ticks; a write
// takes effect in the first.

module timer #(
    parameter [31:0] CLK_HZ = 32'd42_000_000
) (
    input  wire        clk,
    input  wire        reset,          // synchronous, active high

    input  wire        io_sel,
    input  wire        io_we,
    input  wire [3:0]  io_be,
    input  wire [5:2]  io_addr,
    input  wire [31:0] io_wdata,
    output reg  [31:0] io_rdata,
    output reg         io_ready,

    output wire        irq0,           // timer 0: line 6 of the interrupt controller
    output wire        irq1            // timer 1: line 7
);
    wire we = io_sel & io_we & !io_ready;          // once, in the first tick

    wire [31:0] ctrl0, period0, count0, ctrl1, period1, count1;

    timer_one t0 (
        .clk(clk), .reset(reset),
        .we_ctrl(we & (io_addr == 4'd0)), .we_period(we & (io_addr == 4'd1)),
        .we_count(we & (io_addr == 4'd2)), .be(io_be), .wdata(io_wdata),
        .ctrl(ctrl0), .period(period0), .count(count0), .irq(irq0)
    );

    timer_one t1 (
        .clk(clk), .reset(reset),
        .we_ctrl(we & (io_addr == 4'd4)), .we_period(we & (io_addr == 4'd5)),
        .we_count(we & (io_addr == 4'd6)), .be(io_be), .wdata(io_wdata),
        .ctrl(ctrl1), .period(period1), .count(count1), .irq(irq1)
    );

    always @(posedge clk)
        if (reset) io_ready <= 1'b0;
        else       io_ready <= io_sel & !io_ready;

    always @*
        case (io_addr)
            4'd0:    io_rdata = ctrl0;
            4'd1:    io_rdata = period0;
            4'd2:    io_rdata = count0;
            4'd4:    io_rdata = ctrl1;
            4'd5:    io_rdata = period1;
            4'd6:    io_rdata = count1;
            4'd8:    io_rdata = CLK_HZ;
            default: io_rdata = 32'h0;
        endcase
endmodule

// One timer: its count, its period and its CTRL.
module timer_one (
    input  wire        clk,
    input  wire        reset,
    input  wire        we_ctrl,
    input  wire        we_period,
    input  wire        we_count,
    input  wire [3:0]  be,
    input  wire [31:0] wdata,
    output wire [31:0] ctrl,
    output reg  [31:0] period,
    output reg  [31:0] count,
    output wire        irq
);
    reg en, ie, oneshot, f, ovr;

    // the bytes be picks from new, the others from old
    function [31:0] merge(input [31:0] old, input [31:0] new, input [3:0] be);
        merge = { be[3] ? new[31:24] : old[31:24], be[2] ? new[23:16] : old[23:16],
                  be[1] ? new[15:8]  : old[15:8],  be[0] ? new[7:0]   : old[7:0] };
    endfunction

    wire [31:0] new_period = merge(period, wdata, be);
    wire        event_hit  = en & (count == 32'd0);
    wire        clear_f    = we_ctrl & be[1] & wdata[8];
    wire        clear_ovr  = we_ctrl & be[1] & wdata[9];

    assign ctrl = {22'h0, ovr, f, 5'h0, oneshot, ie, en};
    assign irq  = f & ie;

    always @(posedge clk)
        if (reset) begin
            en <= 1'b0; ie <= 1'b0; oneshot <= 1'b0; f <= 1'b0; ovr <= 1'b0;
            period <= 32'h0;
            count  <= 32'h0;
        end else begin
            // the count: a write first, then the event, then a tick
            if (we_period) begin
                period <= new_period;
                count  <= new_period - 32'd1;
            end else if (we_count)
                count <= merge(count, wdata, be);
            else if (event_hit)
                count <= oneshot ? 32'h0 : period - 32'd1;
            else if (en)
                count <= count - 32'd1;

            // CTRL: a one-shot stops at its event; a write of EN in the same tick wins
            if (event_hit & oneshot) en <= 1'b0;
            if (we_ctrl & be[0]) begin
                en      <= wdata[0];
                ie      <= wdata[1];
                oneshot <= wdata[2];
            end

            // the flags: set by the event (it wins over a clear), cleared by a 1
            f   <= (f & !clear_f) | event_hit;
            ovr <= (ovr & !clear_ovr) | (event_hit & f & !clear_f);
        end
endmodule
