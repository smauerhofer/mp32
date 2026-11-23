// irqc.v: the interrupt controller of the mp32 processor: 8 lines from the devices,
// with priorities and nesting.
//
// ---------------------------------------------------------------- the lines
// A device asks on its line while its irq is 1 (a level), until its handler has
// served it; each device says how (a register to read or write). A device whose cause
// is only a moment (the display's horizontal and vertical interrupts) keeps it in a
// flag of its own until the handler clears it, so its line is a level too.
//
// Line k is vector 16 + k. The lower the line, the higher its priority: line 0 first.
//
// ---------------------------------------------------------------- in service
// When the processor takes a device's INTR it says so (ack, ack_num): that line goes
// in service, its bit in ISR = 1. While a line is in service, the processor is only
// interrupted by lines of a higher priority (lower number): not by itself, not by the
// lines below it. So a handler may set I again (SEI) early, once it has saved what it
// must: only a more urgent device can then interrupt it, and it can still be
// interrupted by that one, which nests.
//
// The handler ends with an EOI (end of interrupt): a write to EOI takes the line of
// the highest priority in service out of service (the handler's own: a handler that
// was interrupted is always of a lower priority than the one that interrupted it, and
// that one has had its EOI by the time it returns). Do the EOI with I = 0, just
// before RTI, so no line below gets in between.
//
//   irq     = 1 while a line asks, its MASK bit is 1, and it is of a higher priority
//             than every line in service
//   irq_num = 16 + the lowest such line
//
// ---------------------------------------------------------------- the registers
//   +0   PENDING  read: the lines that ask now (bit k = line k), whatever MASK and ISR say
//   +4   MASK     bit k = 1: line k may interrupt. Read: as written. After reset 0.
//   +8   NUMBER   read: the vector the processor is offered now (16 + k), 0 if none
//   +12  ISR      read: the lines in service. Write (any value): EOI.
//
// The bus: io_sel with io_we, io_be, io_addr (bits 3..2 of the address) and io_wdata;
// a write takes effect at the edge, io_rdata is valid while io_sel is 1. The I/O decoder
// gives the answer's io_ready.

module irqc (
    input  wire        clk,
    input  wire        reset,          // synchronous, active high

    // ---- the devices
    input  wire [7:0]  lines,          // 1 = the device asks

    // ---- the processor
    output wire        irq,
    output reg  [7:0]  irq_num,
    input  wire        ack,            // a device's INTR taken at this edge
    input  wire [7:0]  ack_num,        // its number

    // ---- the registers
    input  wire        io_sel,
    input  wire        io_we,
    input  wire [3:0]  io_be,
    input  wire [1:0]  io_addr,        // the word: 0 PENDING, 1 MASK, 2 NUMBER, 3 ISR / EOI
    input  wire [31:0] io_wdata,
    output reg  [31:0] io_rdata
);
    reg  [7:0] mask;
    reg  [7:0] isr;

    // the lines of a higher priority than the highest one in service: those below its bit
    wire [7:0] top     = isr & (~isr + 8'd1);          // the lowest bit of ISR set, one-hot
    wire [7:0] allowed = (isr == 8'd0) ? 8'hFF : (top - 8'd1);
    wire [7:0] wants   = lines & mask & allowed;

    assign irq = |wants;
    integer k;
    always @* begin
        irq_num = 8'd0;
        for (k = 7; k >= 0; k = k - 1)
            if (wants[k]) irq_num = 8'd16 + k;
    end

    // a device's INTR taken: its line in service (only vectors 16 .. 23 are lines)
    wire [7:0] taken = (ack && ack_num[7:3] == 5'b00010) ? (8'd1 << ack_num[2:0]) : 8'd0;
    wire       eoi   = io_sel & io_we & (io_addr == 2'd3);

    always @(posedge clk)
        if (reset) begin
            mask <= 8'h00;
            isr  <= 8'h00;
        end else begin
            if (io_sel & io_we & (io_addr == 2'd1) & io_be[0]) mask <= io_wdata[7:0];
            isr <= (eoi ? (isr & ~top) : isr) | taken;
        end

    always @*
        case (io_addr)
            2'd0:    io_rdata = {24'h0, lines};
            2'd1:    io_rdata = {24'h0, mask};
            2'd2:    io_rdata = {24'h0, irq_num};
            default: io_rdata = {24'h0, isr};
        endcase
endmodule
