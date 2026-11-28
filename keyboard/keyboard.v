// keyboard.v: the keyboard and the mouse of the mp32 computer, as an I/O device.
//
//   A USB keyboard and a USB mouse plug into a CH9350L module (the KAmod USB HID
//   Extender of chapter 21 of the book, its DEVICE side). The chip is their USB host
//   and speaks to us on a serial line, 115,200 baud 8N1. Unlike the book, the line
//   goes both ways: the chip sends the reports of the keyboard and the mouse, and we
//   send it the state of the keyboard's LEDs (Num Lock, Caps Lock, Scroll Lock), which
//   it passes on to the keyboard. We play the part of the chip's twin, the "upper
//   computer" of its datasheet (Kamami's HOST module).
//
//     kbd_rx   42   from the module's TXD
//     kbd_tx   41   to the module's RXD
//
//   The module's jumpers, as in the book, but WITHOUT the jumper between GND and RXD
//   on row P3: RXD gets our wire instead. (With that jumper on, our pin 41 would drive
//   a wire tied to GND: take the jumper off before connecting pin 41.)
//     SEL off                  the DEVICE side (lower computer)
//     STAT0 on, STAT1 off      working state 2: keyboard + relative mouse
//     BAUD0, BAUD1 off         115,200 baud
//
// ---------------------------------------------------------------- what comes, and what goes
//   Every frame starts 57 AB, then a byte that says what it carries, then exactly that
//   many bytes. Frames are cut by their length, not by looking for 57 AB: a mouse's
//   bytes can hold 57 and AB (the book's chapter 21, and esp-ch9350).
//
//     57 AB 01  + 8   a keyboard report: modifiers, 0, six key codes (USB HID boot)
//     57 AB 02  + 4   a mouse report: buttons, dx, dy, wheel (signed bytes)
//     57 AB 04  + 7   an absolute mouse (states 3/4): taken and ignored
//     57 AB 80  + 1   status: FF at start, then 3N: N the lock keys held down now
//     57 AB 10  + 4   VID/PID: taken and ignored
//     57 AB 12  + 8   a keep-alive (from another upper computer): taken and ignored
//     57 AB 82  + 1   a heartbeat (states 0/1): taken and ignored
//     57 AB 86        a device was plugged in or out (sets GONE)
//     57 AB 87, 89    other messages: nothing follows
//   Any other kind: the frame is dropped, and the next 57 starts over.
//
//   A frame whose bytes stop coming for TIMEOUT ticks is dropped (SYNC): the next 57
//   starts over. Frames come back to back, a byte every 87 us.
//
//   In both directions the chip repeats a keyboard report 3 or 4 times (kvm-serial
//   saw it, and the book's model plays it). A report equal to the last one received
//   is dropped here: a report is a state, and the same state twice says nothing new.
//   Mouse reports are never dropped: each one is a movement.
//
//   What we send, the keep-alive of an upper computer (kvm-serial, CH9350L_PROTO.md,
//   seen on the wire between two chips in state 2):
//
//     57 AB 12  00 00  00 00  LED  07  AC 20
//               PID 1  PID 2       status, version (as a real upper chip sends them)
//
//   LED: bit 0 Num Lock, bit 1 Caps Lock, bit 2 Scroll Lock, as USB orders them. The
//   chip passes them on to the keyboard and does not answer. Its own 57 AB 80 3N
//   (ECHO in STATUS) comes when a lock key goes down or up on the keyboard: N the lock
//   keys held, in the same bits (Caps Lock held: 32, let go: 30). Seen on the board,
//   2026-11-28; kvm-serial's CH9350L_PROTO.md gives the same. A frame goes out
//   when LEDS is written, when TXEN goes to 1, and every KEEP ticks while TXEN is 1
//   (a real upper chip sends one about every second).
//
// ---------------------------------------------------------------- the registers
//   Eight 32-bit registers, picked by io_addr[4:2] (the I/O decoder gives io_sel):
//
//     +0   STATUS  read:  bit  0     KEY    a keyboard report waits in the queue
//                         bit  1     MOUSE  a mouse report came since MOUSE was read
//                         bit  2     TXBUSY a frame to the module is going out
//                         bit  3     LOST   a keyboard report came with the queue
//                                           full, and was lost (stays 1)
//                         bit  4     GONE   57 AB 86: a device was plugged in or out
//                                           (stays 1)
//                         bit  5     FERR   a byte without its stop bit (stays 1)
//                         bit  6     SYNC   bytes that began no frame, or a frame cut
//                                           short (stays 1)
//                         bits 15..8 ECHO   the byte of the last 57 AB 80: FF after
//                                           reset and at the chip's start; then 3N,
//                                           N the lock keys held down (not LEDS)
//                         bits 19..16       how many keyboard reports wait
//                  write: a 1 in bit 3, 4, 5 or 6 clears that bit
//
//     +4   KEYS0   read:  the first report in the queue, bytes 0 to 3: bits 7..0 the
//                         modifiers (bit 0 left Ctrl, 1 left Shift, 2 left Alt, 3 left
//                         GUI, 4..7 the same on the right), bits 15..8 reserved (0),
//                         bits 23..16 the first key code, bits 31..24 the second.
//                         Reads 0 when the queue is empty. Does not take the report.
//     +8   KEYS1   read:  bytes 4 to 7: the third to the sixth key code, the third in
//                         bits 7..0. Reading KEYS1 takes the report from the queue:
//                         read KEYS0 first. Reads 0 when the queue is empty.
//                         (01 in all six places: too many keys down, "ErrorRollOver")
//
//     +12  MOUSE   read:  bits 15..0 the sum of dx, bits 31..16 the sum of dy, since the
//                         last read (signed, 16 bits each; right and down are positive).
//                         Reading takes them: the sums go back to 0, and MOUSE in
//                         STATUS too, unless a report came in the meantime.
//     +16  BUTTONS read:  bits 7..0 the buttons now (bit 0 left, 1 right, 2 middle),
//                         bits 15..8 the sum of the wheel since the last read (signed).
//                         Reading takes the wheel's sum.
//
//     +20  LEDS    read/write: bits 2..0 the keyboard's LEDs: bit 0 Num Lock, bit 1 Caps
//                         Lock, bit 2 Scroll Lock. A write sends them (with TXEN at 1).
//
//     +24  CTRL    bit 0 KIE:  irq while a keyboard report waits
//                  bit 1 MIE:  irq while MOUSE is 1
//                  bit 2 TXEN: send to the module (LEDS, and the keep-alive). At 0
//                              nothing more goes out (a frame already started is
//                              finished) and the wire kbd_tx rests at 1.
//                  after reset 0: no irq, nothing sent
//
//     +28  -       reads 0
//
//   The queue holds 2^Q_BITS reports (8): about 8 key changes the program has not yet
//   read. At the fastest a report comes every 0.95 ms.
//
// ---------------------------------------------------------------- handshake
//   The cache's handshake (see membus.v), as in uart.v: io_sel and the rest are held
//   until io_ready is 1; that tick ends the access, and io_rdata is valid in it.
//   io_ready is a register: an access takes two ticks.

module keyboard #(
    parameter [15:0] DIV     = 16'd365,         // ticks of a bit: 115,200 baud at 42 MHz
    parameter        TIMEOUT = 210_000,         // ticks: 5 ms at 42 MHz, a frame cut short
    parameter        KEEP    = 42_000_000,      // ticks: 1 s at 42 MHz, the keep-alive
    parameter        Q_BITS  = 3                // the queue: 2^Q_BITS reports
) (
    input  wire        clk,
    input  wire        reset,           // synchronous, active high

    // ---- the I/O bus
    input  wire        io_sel,
    input  wire        io_we,
    input  wire [3:0]  io_be,           // not used: every write is taken whole
    input  wire [4:2]  io_addr,
    input  wire [31:0] io_wdata,
    output reg  [31:0] io_rdata,
    output reg         io_ready,

    // ---- to the processor's interrupt
    output wire        irq,

    // ---- the wires
    input  wire        kbd_rx,          // from the module's TXD
    output wire        kbd_tx           // to the module's RXD
);
    localparam R_STATUS = 3'd0, R_KEYS0 = 3'd1, R_KEYS1 = 3'd2, R_MOUSE = 3'd3,
               R_BUTTONS = 3'd4, R_LEDS = 3'd5, R_CTRL = 3'd6;

    // ================================================================ the bus
    // commit: the tick that ends an access. capture: the tick before, in which io_rdata
    // takes the value the processor will read.
    wire commit  = io_sel & io_ready;
    wire capture = io_sel & ~io_ready;
    wire wr      = commit & io_we;
    wire rd      = commit & ~io_we;

    // ================================================================ the receiver
    wire [7:0] rx_byte;
    wire       rx_valid, rx_ferr;

    uart_rx #(.W(16)) receiver (
        .clk(clk), .reset(reset), .div(DIV), .rx(kbd_rx),
        .data(rx_byte), .valid(rx_valid), .frame_err(rx_ferr)
    );

    // ================================================================ the frames
    // where: 0 waiting for 57; 1 for AB; 2 for the kind; 3 the bytes of the frame.
    localparam F_57 = 2'd0, F_AB = 2'd1, F_KIND = 2'd2, F_DATA = 2'd3;

    reg  [1:0]  where;
    reg  [7:0]  kind;
    reg  [3:0]  need;                   // bytes of the frame still to come
    reg  [63:0] bytes;                  // the frame's bytes, the last one in bits 7..0
    reg  [17:0] quiet;                  // ticks since the last byte, within a frame
                                        // (TIMEOUT must fit: below 262,144)
    reg         junk;                   // 1 during one tick: a byte that began no frame

    // How many bytes follow each kind; 0 for a frame with nothing more, 15 for a kind
    // we do not know (the frame is dropped).
    function [3:0] length(input [7:0] k);
        case (k)
            8'h01:                      length = 4'd8;
            8'h02:                      length = 4'd4;
            8'h04:                      length = 4'd7;
            8'h10:                      length = 4'd4;
            8'h12:                      length = 4'd8;
            8'h80, 8'h82:               length = 4'd1;
            8'h86, 8'h87, 8'h89:        length = 4'd0;
            default:                    length = 4'd15;
        endcase
    endfunction

    // One tick each, when a frame is complete:
    reg kbd_frame, mouse_frame, status_frame, plug_frame;

    // The last byte of a frame is the one arriving now: the whole frame is
    // {bytes[55:0], rx_byte} for 8 bytes, {bytes[23:0], rx_byte} for 4.
    wire [63:0] frame8 = {bytes[55:0], rx_byte};

    always @(posedge clk) begin
        kbd_frame    <= 0;
        mouse_frame  <= 0;
        status_frame <= 0;
        plug_frame   <= 0;
        junk         <= 0;
        if (reset) begin
            where <= F_57;
            kind  <= 0;
            need  <= 0;
            bytes <= 0;
            quiet <= 0;
        end else if (rx_valid) begin
            quiet <= 0;
            case (where)
                F_57: begin
                    if (rx_byte == 8'h57) where <= F_AB;
                    else                  junk  <= 1;
                end
                F_AB: begin
                    if (rx_byte == 8'hAB) where <= F_KIND;
                    else begin
                        junk  <= 1;                     // the 57 before began nothing
                        where <= (rx_byte == 8'h57) ? F_AB : F_57;
                    end
                end
                F_KIND: begin
                    kind <= rx_byte;
                    need <= length(rx_byte);
                    case (length(rx_byte))
                        4'd0:  begin where <= F_57; plug_frame <= (rx_byte == 8'h86); end
                        4'd15: begin where <= F_57; junk <= 1; end
                        default: where <= F_DATA;
                    endcase
                end
                F_DATA: begin
                    bytes <= frame8;
                    need  <= need - 1'b1;
                    if (need == 4'd1) begin
                        where        <= F_57;
                        kbd_frame    <= (kind == 8'h01);
                        mouse_frame  <= (kind == 8'h02);
                        status_frame <= (kind == 8'h80);
                    end
                end
            endcase
        end else if (where != F_57) begin
            if (quiet == TIMEOUT[17:0]) begin
                where <= F_57;
                junk  <= 1;
                quiet <= 0;
            end else
                quiet <= quiet + 1'b1;
        end
    end

    // The frame, one tick after its last byte: bytes holds it, the last byte in 7..0.
    // A keyboard report, byte 0 (modifiers) in 63..56; a mouse report in 31..0.

    // ================================================================ the keyboard's reports
    localparam Q_SIZE = 1 << Q_BITS;

    reg  [63:0]     queue [0:Q_SIZE-1];
    reg  [Q_BITS-1:0] q_in, q_out;
    reg  [Q_BITS:0] q_used;
    reg  [63:0]     last;               // the last report received, kept or not

    wire        q_ready = (q_used != 0);
    wire        q_full  = (q_used == Q_SIZE);
    wire [63:0] q_head  = queue[q_out];

    // A read of KEYS1 takes the report it showed: took says whether there was one.
    reg  took;
    wire q_take = rd & (io_addr == R_KEYS1) & took;
    wire new_report = kbd_frame & (bytes != last);
    wire q_put  = new_report & (~q_full | q_take);

    always @(posedge clk) begin
        if (q_put)
            queue[q_in] <= bytes;
        if (reset) begin
            q_in   <= 0;
            q_out  <= 0;
            q_used <= 0;
            last   <= 64'h0;            // a first report of nothing down says nothing new
        end else begin
            if (kbd_frame)  last <= bytes;
            // A device plugged in or out: the next report goes in whatever it holds,
            // so that keys held when the keyboard went away are seen to come up.
            if (plug_frame) last <= 64'hFFFF_FFFF_FFFF_FFFF;
            if (q_put)     q_in  <= q_in + 1'b1;
            if (q_take)    q_out <= q_out + 1'b1;
            q_used <= q_used + q_put - q_take;
        end
    end

    // ================================================================ the mouse
    // The sums: a read takes what it showed (io_rdata at commit), so a report that
    // came between the two ticks of the read is not lost.
    reg  [15:0] sum_x, sum_y;
    reg  [7:0]  sum_wheel;
    reg  [7:0]  buttons;
    reg         moved;                  // MOUSE in STATUS
    reg         since;                  // a report came since MOUSE was captured

    wire [15:0] dx    = {{8{bytes[23]}}, bytes[23:16]};
    wire [15:0] dy    = {{8{bytes[15]}}, bytes[15:8]};
    wire [7:0]  dw    = bytes[7:0];
    wire        take_xy    = rd & (io_addr == R_MOUSE);
    wire        take_wheel = rd & (io_addr == R_BUTTONS);

    always @(posedge clk) begin
        if (reset) begin
            sum_x     <= 0;
            sum_y     <= 0;
            sum_wheel <= 0;
            buttons   <= 0;
            moved     <= 0;
            since     <= 0;
        end else begin
            sum_x     <= sum_x - (take_xy ? io_rdata[15:0] : 16'd0)
                               + (mouse_frame ? dx : 16'd0);
            sum_y     <= sum_y - (take_xy ? io_rdata[31:16] : 16'd0)
                               + (mouse_frame ? dy : 16'd0);
            sum_wheel <= sum_wheel - (take_wheel ? io_rdata[15:8] : 8'd0)
                                   + (mouse_frame ? dw : 8'd0);
            if (mouse_frame) buttons <= bytes[31:24];

            if (capture & ~io_we & (io_addr == R_MOUSE)) since <= mouse_frame;
            else if (mouse_frame)                        since <= 1;

            if (take_xy) moved <= since | mouse_frame;
            else if (mouse_frame) moved <= 1;
        end
    end

    // ================================================================ the transmitter
    reg  [2:0]  leds;
    reg         kie, mie, txen;
    reg         sending, again;         // again: send once more when this frame is out
    reg  [3:0]  sent;                   // bytes of the frame already handed over
    reg  [2:0]  leds_out;               // the LEDs of the frame going out
    reg  [25:0] keep;                   // ticks since the last frame, while TXEN is 1
    wire        tx_busy;

    // The frame: 57 AB 12, PID 1, PID 2, LED, status, version.
    reg [7:0] tx_byte;
    always @*
        case (sent)
            4'd0:    tx_byte = 8'h57;
            4'd1:    tx_byte = 8'hAB;
            4'd2:    tx_byte = 8'h12;
            4'd7:    tx_byte = {5'd0, leds_out};
            4'd8:    tx_byte = 8'h07;
            4'd9:    tx_byte = 8'hAC;
            4'd10:   tx_byte = 8'h20;
            default: tx_byte = 8'h00;               // 3..6: the two PIDs
        endcase

    wire tx_send = sending & ~tx_busy;              // busy is 1 from the next tick on
    wire tx_line;

    uart_tx #(.W(16)) transmitter (
        .clk(clk), .reset(reset), .div(DIV),
        .send(tx_send), .data(tx_byte), .tx(tx_line), .busy(tx_busy)
    );
    assign kbd_tx = tx_line;

    wire leds_written = wr & (io_addr == R_LEDS);
    wire ctrl_written = wr & (io_addr == R_CTRL);
    wire keep_due     = txen & (keep == KEEP[25:0]);
    wire ask          = txen & leds_written
                      | ~txen & ctrl_written & io_wdata[2]
                      | keep_due;

    always @(posedge clk) begin
        if (reset) begin
            leds     <= 0;
            kie      <= 0;
            mie      <= 0;
            txen     <= 0;
            sending  <= 0;
            again    <= 0;
            sent     <= 0;
            leds_out <= 0;
            keep     <= 0;
        end else begin
            if (leds_written) leds <= io_wdata[2:0];
            if (ctrl_written) begin
                kie  <= io_wdata[0];
                mie  <= io_wdata[1];
                txen <= io_wdata[2];
            end

            keep <= (~txen | ask) ? 26'd0 : keep + 1'b1;

            if (tx_send) begin
                sent <= sent + 1'b1;
                if (sent == 4'd10) begin
                    sending <= 0;
                    sent    <= 0;
                end
            end

            // A frame asked for: now, or after the one going out (with the LEDs as
            // they will be then). The LEDs written in this tick go out: leds_out
            // takes io_wdata directly.
            if (ask) begin
                if (sending & ~(tx_send & sent == 4'd10)) again <= 1;
                else begin
                    sending  <= 1;
                    leds_out <= leds_written ? io_wdata[2:0] : leds;
                end
            end else if (again & ~sending) begin
                again    <= 0;
                sending  <= 1;
                leds_out <= leds;
            end

            if (ctrl_written & ~io_wdata[2]) begin  // TXEN off: what waits is dropped
                again <= 0;
            end
        end
    end

    // ================================================================ status, and the read
    reg [7:0] echo;
    reg       lost, gone, ferr, sync;

    always @(posedge clk) begin
        if (reset) begin
            echo <= 8'hFF;
            lost <= 0;
            gone <= 0;
            ferr <= 0;
            sync <= 0;
        end else begin
            // A clear in the same tick as a new event: the event wins.
            if (wr & (io_addr == R_STATUS)) begin
                if (io_wdata[3]) lost <= 0;
                if (io_wdata[4]) gone <= 0;
                if (io_wdata[5]) ferr <= 0;
                if (io_wdata[6]) sync <= 0;
            end
            if (status_frame)               echo <= bytes[7:0];
            if (new_report & ~q_put)        lost <= 1;
            if (plug_frame)                 gone <= 1;
            if (rx_ferr)                    ferr <= 1;
            if (junk)                       sync <= 1;
        end
    end

    wire [7:0] q_count = q_used;        // widened to 8 bits for STATUS

    always @(posedge clk) begin
        if (reset) begin
            io_ready <= 0;
            io_rdata <= 0;
            took     <= 0;
        end else begin
            io_ready <= capture;
            took     <= (io_addr == R_KEYS1) & q_ready;
            case (io_addr)
                R_STATUS:  io_rdata <= {12'd0, q_count[3:0], echo,
                                        1'b0, sync, ferr, gone, lost,
                                        sending | tx_busy, moved, q_ready};
                R_KEYS0:   io_rdata <= q_ready ? {q_head[39:32], q_head[47:40],
                                                  q_head[55:48], q_head[63:56]} : 32'd0;
                R_KEYS1:   io_rdata <= q_ready ? {q_head[7:0],   q_head[15:8],
                                                  q_head[23:16], q_head[31:24]} : 32'd0;
                R_MOUSE:   io_rdata <= {sum_y, sum_x};
                R_BUTTONS: io_rdata <= {16'd0, sum_wheel, buttons};
                R_LEDS:    io_rdata <= {29'd0, leds};
                R_CTRL:    io_rdata <= {29'd0, txen, mie, kie};
                default:   io_rdata <= 32'd0;
            endcase
        end
    end

    assign irq = (kie & q_ready) | (mie & moved);
endmodule
