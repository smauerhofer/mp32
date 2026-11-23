// audio.v: the sound of the mp32 computer, as an I/O device.
//
//   The Tang Nano 20K has a MAX98357A on it: a DAC and a 3 W class-D amplifier in one
//   chip, for a 4 or 8 ohm speaker on the board's 2-pin header. The FPGA talks to it
//   with I2S, three wires, plus one to switch the amplifier on:
//
//     hp_bck   56   BCLK  the bit clock; the chip takes a bit at its rising edge
//     hp_ws    55   LRCLK low: the left channel, high: the right one
//     hp_din   54   DIN   the bits, the most significant first
//     pa_en    51   1: the amplifier on (its SD_MODE pin), 0: off
//
//   (the pins of Sipeed's example, TangNano-20K-example/audio; see ../computer/top.cst)
//
//   The chip needs no master clock, but it needs one of its sample rates: 8, 16, 32,
//   44.1, 48, 88.2 or 96 kHz, within a few percent, and a BCLK of 32, 48 or 64 times
//   the sample rate. Here a frame is 64 BCLKs: two slots of 32, the left one and the
//   right one, each with its 16-bit sample in its first 16 bits after the bit of
//   delay (I2S: the sample starts one BCLK after LRCLK changes), the rest 0.
//
//   BCLK is the processor's clock divided by 2 * DIV, so the sample rate is
//   clk / (128 * DIV). At 42 MHz:
//
//       DIV    sample rate   the chip's rate
//        7     46,875 Hz     48 kHz  (-2.3 %)   from reset
//       10     32,813 Hz     32 kHz  (+2.5 %)
//       20     16,406 Hz     16 kHz  (+2.5 %)
//       41      8,004 Hz      8 kHz  (+0.1 %)
//
//   A divider, not a fractional one: the chip wants less than 0.5 ns of jitter.
//
//   The speaker is one: every sample goes to both slots, so whichever channel the
//   board's SD_MODE picks (left, or left and right mixed) plays it.
//
// ---------------------------------------------------------------- three sources
//   Each sample played is the sum of three, held at -32768 .. 32767:
//
//   the queue   samples the processor writes to DATA, one by one (64 of them wait)
//   the banks   the sample memory: two banks of block RAM, 1024 samples each. The
//               sound plays one bank from start to end, then switches to the other
//               by itself, while the processor fills the one not playing. A program
//               fills a bank, says so (READY), and fills the other while that plays.
//   the tone    a square wave, made here, for a beep without a program
//
// ---------------------------------------------------------------- the sample memory
//   At io_addr[12] = 1 (the I/O decoder maps it to $FFFF_C000 - $FFFF_CFFF), two
//   samples in each 32-bit word, the first in bits 15..0, the next in bits 31..16:
//
//     $FFFF_C000 - $FFFF_C7FF   bank 0: samples 0 .. 1023
//     $FFFF_C800 - $FFFF_CFFF   bank 1: samples 0 .. 1023
//
//   Write only (reads give 0); a write never waits. A 16-bit store writes its one
//   sample (by io_be), a 32-bit store two.
//
//   A bank is FULL when the program says so (READY); the sound plays it, from sample
//   0 to sample BLEN - 1, and then it is empty again: the program may fill it. The
//   sound goes on with the other bank if that one is FULL; if not, it plays 0 and
//   sets BUNDER, and starts the other bank as soon as it is FULL. So:
//
//       bank = 0
//       loop: wait until FULL<bank> is 0     (BSTATUS, or DONE<bank> and its irq)
//             write BLEN samples into the bank
//             write READY = 1 << bank
//             bank = 1 - bank
//
//   At 46,875 Hz a bank of 1024 lasts 21.8 ms: that long has the program to fill the
//   other one. A smaller BLEN plays shorter banks (less delay, less time).
//
// ---------------------------------------------------------------- the registers
//   At io_addr[12] = 0, ten 32-bit registers, picked by io_addr[5:2]:
//
//     +0   DATA    write: put the sample in bits 15..0 (signed, -32768 .. 32767) in
//                         the queue. While the queue is full the write waits (io_ready
//                         stays 0): a program can write samples in a row, at its own
//                         speed, and the queue paces it.
//                  read:  0
//
//     +4   STATUS  read:  bit  0     EMPTY  the queue is empty
//                         bit  1     FULL   the queue is full
//                         bit  2     HALF   at most half full: room for half of it
//                         bit  3     UNDER  a sample was due, the last one came from
//                                           the queue and the queue was empty: the
//                                           program was too slow (stays 1)
//                         bit  4     TONE   the tone sounds (LEN is not 0)
//                         bits 15..8        how many samples the queue holds
//                  write: a 1 in bit 3 clears UNDER
//
//     +8   CTRL    bit 0 ON:   the amplifier on (pa_en)
//                  bit 1 IE:   irq while the queue is at most half full
//                  bit 2 PLAY: play the banks. 0: they are silent, and the next
//                              PLAY starts again at bank 0, sample 0 (FULL stays)
//                  bit 3 BIE:  irq while DONE0 or DONE1 is 1: a bank has been played
//                  after reset 0: silent, no irq
//
//     +12  DIV     bits 7..0: ticks of half a BCLK, at least 2 (see above). Take a new
//                  DIV from one of the chip's rates; it applies from the next tick.
//
//     +16  TONE    a square wave, added to the samples:
//                  bits 15..0   half its period, in samples (46,875 / (2 * 440) = 53:
//                               442 Hz at 46,875 Hz); 0 = silent
//                  bits 30..16  its height: the wave goes between +height and -height
//
//     +20  LEN     bits 23..0: how many more samples the tone lasts; it counts down,
//                  one per sample, and the tone stops at 0. $FF_FFFF does not count
//                  down: the tone sounds until LEN is written again. A write starts
//                  the tone from the beginning of its period.
//
//     +24  BSTATUS read:  bit  0     FULL0   bank 0 is full: to be played, or playing
//                         bit  1     FULL1   bank 1 is full
//                         bit  2     BANK    the bank playing (or waited for)
//                         bit  3     BUNDER  a bank ended and the other was not full:
//                                            the program was too slow (stays 1)
//                         bit  4     BPLAYS  a bank is playing (PLAY, and BANK full)
//                         bit  5     DONE0   bank 0 has been played to its end: it is
//                                            empty, fill it (stays 1)
//                         bit  6     DONE1   the same for bank 1
//                         bits 25..16        the sample of BANK played next
//                  write: a 1 in bit 3 clears BUNDER, in bit 5 DONE0, in bit 6 DONE1
//                  (a bank that ends in the same tick sets its DONE again)
//
//                  An interrupt handler: read BSTATUS; for each DONE bit, fill that
//                  bank, write READY for it and a 1 to its DONE bit.
//
//     +28  BLEN    bits 10..0: samples played from each bank, 1 .. 1024; 0 or more
//                  than 1024 is taken as 1024. From reset 1024.
//
//     +32  READY   write: a 1 in bit 0 makes bank 0 FULL, in bit 1 bank 1. read: 0
//
// ---------------------------------------------------------------- handshake
//   The cache's handshake (see membus.v), as in uart.v: io_sel and the rest are held
//   until io_ready is 1; that tick ends the access, and io_rdata is valid in it.
//   io_ready is a register: an access takes at least two ticks.

module audio #(
    parameter [7:0] DIV_INIT = 8'd7,            // 46,875 Hz at 42 MHz
    parameter       BITS     = 6                // the queue: 64 samples
) (
    input  wire        clk,
    input  wire        reset,           // synchronous, active high

    // ---- the I/O bus
    input  wire        io_sel,
    input  wire        io_we,
    input  wire [3:0]  io_be,           // the sample memory: which samples a write takes
    input  wire [12:2] io_addr,         // bit 12: the sample memory, else the registers
    input  wire [31:0] io_wdata,
    output reg  [31:0] io_rdata,
    output reg         io_ready,

    // ---- to the processor's interrupt
    output wire        irq,

    // ---- the wires to the MAX98357A
    output reg         hp_bck,
    output reg         hp_ws,
    output reg         hp_din,
    output wire        pa_en
);
    localparam R_DATA = 4'd0, R_STATUS = 4'd1, R_CTRL = 4'd2, R_DIV = 4'd3,
               R_TONE = 4'd4, R_LEN = 4'd5, R_BSTATUS = 4'd6, R_BLEN = 4'd7,
               R_READY = 4'd8;
    localparam SIZE    = 1 << BITS;
    localparam FOREVER = 24'hFF_FFFF;

    wire       is_mem = io_addr[12];
    wire [3:0] reg_no = io_addr[5:2];

    // ================================================================ the registers
    reg        on, ie, play, bie, under, bunder;
    reg [7:0]  div;
    reg [15:0] tone_half;
    reg [14:0] tone_height;
    reg [23:0] len;
    reg [10:0] blen;
    reg [1:0]  full;                    // FULL1, FULL0
    reg [1:0]  done;                    // DONE1, DONE0: the bank has been played

    // ================================================================ the queue
    // As uart/fifo.v, 16 bits wide: LUT RAM, the first sample shown at once.
    reg  [15:0]     samples [0:SIZE-1];
    reg  [BITS-1:0] q_in, q_out;
    reg  [BITS:0]   used;

    wire        q_ready = (used != 0);
    wire        q_full  = (used == SIZE);
    wire        q_half  = (used <= SIZE / 2);
    wire [15:0] q_head  = samples[q_out];
    wire        q_put, q_take;

    always @(posedge clk) begin
        if (q_put)
            samples[q_in] <= io_wdata[15:0];
        if (reset) begin
            q_in  <= 0;
            q_out <= 0;
            used  <= 0;
        end else begin
            if (q_put)  q_in  <= q_in + 1'b1;
            if (q_take) q_out <= q_out + 1'b1;
            used <= used + q_put - q_take;
        end
    end

    // ================================================================ the sample memory
    // Two block RAMs of 1024 x 16: the samples in bits 15..0 of the words (the even
    // ones) and those in bits 31..16 (the odd ones). Address: {bank, word}. The
    // processor writes; the sound reads, every tick, the word of the next sample, so
    // it is there long before it is due.
    reg  [15:0] even_mem [0:1023];
    reg  [15:0] odd_mem  [0:1023];
    reg  [15:0] even_out, odd_out;

    reg         bank;                   // the bank playing, or waited for
    reg  [9:0]  pos;                    // its sample played next
    wire [9:0]  mem_rd   = {bank, pos[9:1]};
    wire [9:0]  mem_wr   = io_addr[11:2];
    wire        mem_put  = io_sel & io_ready & io_we & is_mem;

    always @(posedge clk) begin
        if (mem_put & (io_be[0] | io_be[1])) even_mem[mem_wr] <= io_wdata[15:0];
        if (mem_put & (io_be[2] | io_be[3])) odd_mem[mem_wr]  <= io_wdata[31:16];
        even_out <= even_mem[mem_rd];
        odd_out  <= odd_mem[mem_rd];
    end

    wire [15:0] b_sample = pos[0] ? odd_out : even_out;
    wire        b_plays  = play & full[bank];

    // ================================================================ the bit clock
    // half counts the ticks of half a BCLK. fall: the tick in which BCLK goes low,
    // and the next bit (slot) begins: LRCLK and DIN change with it, half a BCLK
    // before the chip takes them.
    reg  [7:0] half;
    wire       flip = (half >= div - 8'd1);     // >=: a smaller DIV takes at once
    wire       fall = flip & hp_bck;

    always @(posedge clk) begin
        if (reset) begin
            half   <= 0;
            hp_bck <= 0;
        end else if (flip) begin
            half   <= 0;
            hp_bck <= ~hp_bck;
        end else
            half   <= half + 8'd1;
    end

    // ================================================================ the frame
    // slot: the bit of the frame that begins at fall, 0 .. 63. LRCLK is low in
    // 0 .. 31 (left) and high in 32 .. 63 (right). The sample's 16 bits go in slots
    // 1 .. 16 and 33 .. 48. The next sample is made in the fall of slot 63 and
    // goes out from slot 1 on.
    reg  [5:0]  slot;
    reg  [15:0] now;                    // the sample going out
    wire [5:0]  next_slot = slot + 6'd1;
    wire [4:0]  in_half   = next_slot[4:0];
    wire        due       = fall & (slot == 6'd62);   // next_slot is 63

    always @(posedge clk) begin
        if (reset) begin
            slot   <= 6'd63;
            hp_ws  <= 1;
            hp_din <= 0;
        end else if (fall) begin
            slot   <= next_slot;
            hp_ws  <= next_slot[5];
            hp_din <= (in_half >= 5'd1 && in_half <= 5'd16) ? now[5'd16 - in_half] : 1'b0;
        end
    end

    // ================================================================ the next sample
    // In the tick of due: the queue's next sample, the bank's and the tone, added and
    // held to 16 bits, into now; the queue gives its sample; the bank, the tone and
    // LEN go on.
    reg  [15:0] phase;                  // samples into the tone's half period
    reg         high;                   // the tone's half: 1 = +height
    reg         from_queue;             // the last sample came from the queue

    wire        sounds = (len != 0) & (tone_half != 0);
    wire signed [17:0] q_value = q_ready ? {{2{q_head[15]}}, q_head} : 18'sd0;
    wire signed [17:0] b_value = b_plays ? {{2{b_sample[15]}}, b_sample} : 18'sd0;
    wire signed [17:0] t_value = !sounds ? 18'sd0 :
                                 high    ? {3'b000, tone_height} : -{3'b000, tone_height};
    wire signed [17:0] sum     = q_value + b_value + t_value;
    wire        [15:0] held    = (sum >  18'sd32767) ? 16'h7FFF :
                                 (sum < -18'sd32768) ? 16'h8000 : sum[15:0];

    assign q_take = due & q_ready;

    wire       b_last  = ({1'b0, pos} >= blen - 11'd1);   // the bank's last sample
    wire       b_ends  = due & b_plays & b_last;

    // ================================================================ the bus
    // Only a write of DATA with the queue full waits.
    wire waits  = io_we & !is_mem & (reg_no == R_DATA) & q_full & ~q_take;
    wire commit = io_sel & io_ready;
    wire wr_reg = commit & io_we & !is_mem;
    wire [7:0] count = used;            // widened (or cut) to 8 bits for STATUS

    assign q_put = wr_reg & (reg_no == R_DATA);

    always @(posedge clk) begin
        if (reset) begin
            io_ready <= 0;
            io_rdata <= 0;
        end else begin
            io_ready <= io_sel & ~io_ready & ~waits;
            if (is_mem) io_rdata <= 32'd0;
            else case (reg_no)
                R_STATUS:  io_rdata <= {16'd0, count,
                                        3'd0, sounds, under, q_half, q_full, ~q_ready};
                R_CTRL:    io_rdata <= {28'd0, bie, play, ie, on};
                R_DIV:     io_rdata <= {24'd0, div};
                R_TONE:    io_rdata <= {1'b0, tone_height, tone_half};
                R_LEN:     io_rdata <= {8'd0, len};
                R_BSTATUS: io_rdata <= {6'd0, pos, 9'd0, done, b_plays, bunder, bank, full};
                R_BLEN:    io_rdata <= {21'd0, blen};
                default:   io_rdata <= 32'd0;
            endcase
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            on          <= 0;
            ie          <= 0;
            play        <= 0;
            bie         <= 0;
            under       <= 0;
            bunder      <= 0;
            div         <= DIV_INIT;
            tone_half   <= 0;
            tone_height <= 0;
            len         <= 0;
            blen        <= 11'd1024;
            full        <= 2'b00;
            done        <= 2'b00;
            bank        <= 0;
            pos         <= 0;
            phase       <= 0;
            high        <= 1;
            from_queue  <= 0;
            now         <= 0;
        end else begin
            if (due) begin
                now        <= held;
                from_queue <= q_ready;
                if (!q_ready & from_queue)
                    under <= 1;
                if (sounds) begin
                    if (phase >= tone_half - 16'd1) begin
                        phase <= 0;
                        high  <= ~high;
                    end else
                        phase <= phase + 16'd1;
                    if (len != FOREVER)
                        len <= len - 24'd1;
                end
                // the banks: on to the next sample; at the end of a bank it is empty,
                // and the other one plays (or is waited for)
                if (b_plays) begin
                    if (b_last) begin
                        pos  <= 0;
                        bank <= ~bank;
                        if (!full[~bank] & !(wr_reg & (reg_no == R_READY) & io_wdata[~bank]))
                            bunder <= 1;
                    end else
                        pos <= pos + 10'd1;
                end
            end
            if (!play) begin
                bank <= 0;
                pos  <= 0;
            end
            // FULL: emptied when its bank ends, set by READY (which wins)
            full <= (full & ~({1'b0, b_ends} << bank)) |
                    ((wr_reg & (reg_no == R_READY)) ? io_wdata[1:0] : 2'b00);
            // DONE: set when its bank ends (which wins), cleared by a 1 in BSTATUS
            done <= (done & ~((wr_reg & (reg_no == R_BSTATUS)) ? io_wdata[6:5] : 2'b00)) |
                    ({1'b0, b_ends} << bank);
            // A write wins over the tick of due.
            if (wr_reg) case (reg_no)
                R_STATUS:  if (io_wdata[3]) under <= 0;
                R_CTRL:    begin
                               on   <= io_wdata[0];
                               ie   <= io_wdata[1];
                               play <= io_wdata[2];
                               bie  <= io_wdata[3];
                           end
                R_DIV:     div <= (io_wdata[7:0] < 8'd2) ? 8'd2 : io_wdata[7:0];
                R_TONE:    begin tone_half <= io_wdata[15:0]; tone_height <= io_wdata[30:16]; end
                R_LEN:     begin len <= io_wdata[23:0]; phase <= 0; high <= 1; end
                R_BSTATUS: if (io_wdata[3]) bunder <= 0;
                R_BLEN:    blen <= (io_wdata[10:0] == 11'd0 || io_wdata[10:0] > 11'd1024)
                                   ? 11'd1024 : io_wdata[10:0];
                default:   ;
            endcase
        end
    end

    assign pa_en = on;
    assign irq   = (ie & q_half) | (bie & (done != 2'b00));
endmodule
