// sdcard.v: the microSD card of the mp32 computer, in SPI mode, as an I/O device.
//
//   The card is driven by software: this module only moves bytes. It sends a byte (or
//   four) on MOSI and takes in the byte (or four) that comes back on MISO at the same
//   time, and it holds the card's chip select. Everything else - the reset to SPI mode,
//   CMD0, CMD8, ACMD41, reading and writing 512-byte blocks, the CRCs - is up to the
//   program, which keeps the hardware small and lets the protocol be fixed in software.
//
// ---------------------------------------------------------------- the card's pins
//   In SPI mode the card uses four of its six lines (Tang Nano 20K pins):
//
//     sd_clk    83   CLK     the clock, from us
//     sd_mosi   82   CMD     data to the card
//     sd_miso   84   DAT0    data from the card
//     sd_cs_n   81   DAT3    chip select, active low
//
//   DAT1 (85) and DAT2 (80) are not used in SPI mode. See sdcard.cst.
//
// ---------------------------------------------------------------- the registers
//   Three 32-bit registers, picked by io_addr[3:2] (the I/O decoder gives io_sel):
//
//     +0  DATA    write: send the byte in bits 7..0
//                 read:  the byte received during the last transfer (bits 7..0)
//     +4  DATA32  write: send four bytes, bits 31..24 first
//                 read:  the last four bytes received, the first one in bits 31..24
//     +8  CTRL    bit  0     CS: 1 selects the card (sd_cs_n = 0)
//                 bits 15..8 DIV: SCLK = clk / (2 * (DIV + 1))
//                 bit  16    BUSY (read only): a transfer is running
//                 after reset: CS = 0, DIV = DIV_INIT
//     +12         reads 0, writes ignored
//
//   Every access to DATA and DATA32, and a write to CTRL, waits (io_ready stays 0) while
//   a transfer runs. So a program never polls BUSY: it writes DATA and reads DATA, and
//   the read comes back when the byte is in. Two writes in a row are fine too: the
//   second waits for the first. A read of CTRL is answered at once.
//
//   Reading a block of 512 bytes is 128 times "write DATA32 0xFFFFFFFF, read DATA32".
//
// ---------------------------------------------------------------- the clock
//   The card must be started at 100 to 400 kHz; afterwards up to 25 MHz. At 63 MHz:
//     DIV = 78   399 kHz   (DIV_INIT, for the start)
//     DIV = 1    15.75 MHz (the normal speed)
//     DIV = 0    31.5 MHz  too fast for an SD card in default speed - don't.
//
// ---------------------------------------------------------------- the SPI mode
//   Mode 0: SCLK rests at 0, MOSI changes after a falling edge, MISO is taken on the
//   rising edge. A transfer starts with SCLK at 0 and MOSI already showing the first
//   bit; it ends DIV+1 ticks after the last falling edge. MOSI rests at 1 (the card
//   wants 0xFF while it is not being sent anything).
//
// ---------------------------------------------------------------- handshake
//   The cache's handshake (see membus.v): io_sel and the rest are held until io_ready
//   is 1; that tick ends the access, and io_rdata is valid in it. io_ready is a register:
//   an access takes at least two ticks.

module sdcard #(
    parameter [7:0] DIV_INIT = 8'd78              // 399 kHz at 63 MHz
) (
    input  wire        clk,
    input  wire        reset,          // synchronous, active high

    // ---- the I/O bus
    input  wire        io_sel,
    input  wire        io_we,
    input  wire [3:0]  io_be,          // not used: every write is taken whole
    input  wire [3:2]  io_addr,
    input  wire [31:0] io_wdata,
    output reg  [31:0] io_rdata,
    output reg         io_ready,

    // ---- the card
    output reg         sd_clk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_cs_n
);
    localparam R_DATA = 2'd0, R_DATA32 = 2'd1, R_CTRL = 2'd2;

    // ================================================================ the registers
    reg        cs;
    reg [7:0]  div;

    // ================================================================ the shifter
    reg        busy;
    reg [5:0]  bits;                   // bits still to go: 8 or 32 at the start
    reg [7:0]  count;                  // ticks in this half of the SCLK period
    reg [31:0] tx;                     // the bit going out is tx[31]
    reg [31:0] rx;                     // bits come in at rx[0]

    assign sd_mosi = busy ? tx[31] : 1'b1;
    assign sd_cs_n = ~cs;

    // ================================================================ the bus
    // An access has to wait while a transfer runs, except a read of CTRL.
    wire waits  = busy & ~(io_addr == R_CTRL & ~io_we);
    // The tick that ends an access: here a write takes effect.
    wire commit = io_sel & io_ready;
    wire start  = commit & io_we & (io_addr == R_DATA | io_addr == R_DATA32);

    always @(posedge clk) begin
        if (reset) begin
            io_ready <= 0;
            io_rdata <= 0;
        end else begin
            io_ready <= io_sel & ~io_ready & ~waits;
            case (io_addr)
                R_DATA:   io_rdata <= {24'd0, rx[7:0]};
                R_DATA32: io_rdata <= rx;
                R_CTRL:   io_rdata <= {15'd0, busy, div, 7'd0, cs};
                default:  io_rdata <= 32'd0;
            endcase
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            cs  <= 0;
            div <= DIV_INIT;
        end else if (commit & io_we & io_addr == R_CTRL) begin
            cs  <= io_wdata[0];
            div <= io_wdata[15:8];
        end
    end

    // ================================================================ the transfer
    // io_ready was only set while busy was 0, and only start makes busy 1: so a
    // transfer never starts while another runs.
    always @(posedge clk) begin
        if (reset) begin
            busy   <= 0;
            sd_clk <= 0;
            bits   <= 0;
            count  <= 0;
            tx     <= 32'hFFFF_FFFF;
            rx     <= 0;
        end else if (start) begin
            busy   <= 1;
            sd_clk <= 0;
            count  <= 0;
            if (io_addr == R_DATA) begin
                bits <= 6'd8;
                tx   <= {io_wdata[7:0], 24'hFF_FFFF};
            end else begin
                bits <= 6'd32;
                tx   <= io_wdata;
            end
        end else if (busy) begin
            if (count != div)
                count <= count + 8'd1;
            else begin
                count <= 0;
                if (bits == 0)                     // the last low half is over
                    busy <= 0;
                else if (!sd_clk) begin            // rising edge: take MISO in
                    sd_clk <= 1;
                    rx     <= {rx[30:0], sd_miso};
                end else begin                     // falling edge: next bit out
                    sd_clk <= 0;
                    tx     <= {tx[30:0], 1'b1};
                    bits   <= bits - 6'd1;
                end
            end
        end
    end
endmodule
