// fetch.v: stage 1 of the mp32 pipeline, the fetch stage.
//
//   It reads whole 16-byte lines into a 16-byte instruction buffer (IB) and hands
//   the decode stage one instruction per tick, as long as the instructions come from
//   the line in the buffer.
//
// ---------------------------------------------------------------- instructions
// An instruction is 1 to 4 bytes long, little-endian like the memory: the byte at the
// PC is the first byte, in bits 7..0 of f_instr. The top 2 bits of the first byte
// give the length:
//
//   first byte bits 7..6   00 = 1 byte, 01 = 2 bytes, 10 = 3 bytes, 11 = 4 bytes
//
// so the fetch stage knows the PC of the next instruction in the same tick, with no
// decoding at all.
//
// ---------------------------------------------------------------- the line boundary
// The IB holds one line, PC[31:4]. f_instr is the 4 bytes from PC[3:0] on; a byte
// that would come from beyond the end of the line (offset 16 and up) is 0, whatever
// the memory holds there. The next PC is still PC + length, so an instruction that
// runs over the end of a line is executed with its last bytes taken as 0, and the
// next instruction starts after them, in the next line.
//
// The assembler must make that harmless: an instruction may only cross the end of a
// line if the bytes it puts into the next line are 0 (else pad with NOPs first).
//
// ---------------------------------------------------------------- the decode stage
// f_valid, f_pc, f_instr and f_len are registers. When stall is 0 the decode stage
// takes them at the next rising edge (if f_valid). When stall is 1 they are held.
// f_instr always holds 4 bytes: those after f_len belong to the next instruction
// (or are 0 past the end of the line); the decode stage must ignore them.
//
// redirect (a taken branch, a jump, an interrupt, ...) comes from a later stage. At
// the next edge the PC becomes redirect_pc and f_valid becomes 0: the instruction in
// f_* is thrown away, even if stall is 1.
//
// f_next_instr and f_load tell decode what f_instr will be after the next edge, so it
// can work out the registers its operands read a tick early (decode.v, the pre-decode).
//
// ---------------------------------------------------------------- the line port
// The same handshake as the cache: fetch sets line_sel and line_addr and holds them
// until line_ready is 1. That tick ends the access, and line_data is valid during it.
// line_data is the line little-endian: the byte at offset k in bits 8k+7..8k (the
// same layout as the cache's data_ram).
//
// A fill that has started is always finished, even after a redirect (the handshake
// does not allow giving up halfway); then, if the PC has moved on, the next fill starts.
//
// ---------------------------------------------------------------- interrupts
// When irq_pending is 1, stage 1 takes the interrupt: instead of instructions from
// memory it hands stage 2 the interrupt sequence (irq_sequence.v), one instruction per
// tick, with f_inject = 1 and f_pc = the PC. The PC does not change: it is the address
// of the first instruction not fetched, where the program goes on afterwards.
//
// After the last instruction of the sequence stage 1 fetches nothing more and waits
// for a redirect: the sequence ends with a jump to the handler. Any redirect ends the
// interrupt in stage 1:
//   - the jump of the sequence: fetching goes on at the handler;
//   - a redirect from an instruction older than the sequence (a branch taken while
//     the sequence was coming): it throws the sequence away, and if the interrupt is
//     still pending the sequence starts again, from its first instruction, at the
//     new PC.
// So stage 1 never acknowledges an interrupt: the sequence must do that (or turn
// interrupts off) before its jump, or the interrupt would be taken again.
// An instruction waiting in f_* (stall) is not affected; it goes first.
//
// ---------------------------------------------------------------- the PC
// The PC (pc.v) is the address of the next instruction to fetch. reset sets it to
// RESET_PC, 0xF000_0000 by default: the mapped block RAM, which holds the boot code
// when the FPGA is loaded (the SDRAM is empty at power-up). It is an output
// too, so the rest of the processor (and a test bench) can see it.
//
// Timing: a hit gives one instruction per tick. A miss costs 1 tick to start the fill,
// the memory's latency, and 1 tick to use the line.

module fetch #(
    parameter [31:0] RESET_PC = 32'hF000_0000     // the mapped block RAM: boot from it
) (
    input  wire         clk,
    input  wire         reset,          // synchronous, active high

    // from a later stage
    input  wire         redirect,
    input  wire [31:0]  redirect_pc,
    input  wire         irq_pending,    // an interrupt is pending: take it

    // to stage 2, decode
    input  wire         stall,          // decode cannot take f_* at the next edge
    output reg          f_valid,
    output reg  [31:0]  f_pc,
    output reg  [31:0]  f_instr,
    output reg  [2:0]   f_len,          // 1..4
    output reg          f_inject,       // from the interrupt sequence, not from memory
    output wire [31:0]  f_next_instr,   // what f_instr becomes at the next edge ...
    output wire         f_load,         // ... if f_load (for decode's pre-decode)

    // the line port: to the cache
    output reg          line_sel,
    output reg  [31:4]  line_addr,
    input  wire [127:0] line_data,
    input  wire         line_ready,

    // the program counter
    output wire [31:0]  pc
);
    // ================================================================ the IB
    reg [127:0] ib_data;
    reg [31:4]  ib_tag;
    reg         ib_valid;

    wire        hit    = ib_valid & (ib_tag == pc[31:4]);

    // the 4 bytes from the PC on, 0 past the end of the line
    wire [159:0] padded = {32'h0, ib_data};
    wire [31:0]  window = padded[{pc[3:0], 3'b000} +: 32];
    wire [2:0]   len    = {1'b0, window[7:6]} + 3'd1;

    // f_* can be loaded when decode takes what is there, or when it is empty
    wire        take   = !stall | !f_valid;

    // ================================================================ the fill
    always @(posedge clk) begin
        if (reset) begin
            ib_valid <= 1'b0;
            line_sel <= 1'b0;
        end else if (line_sel) begin
            if (line_ready) begin
                ib_data  <= line_data;
                ib_tag   <= line_addr;
                ib_valid <= 1'b1;
                line_sel <= 1'b0;
            end
        end else if (!hit & !redirect) begin
            line_sel  <= 1'b1;
            line_addr <= pc[31:4];
        end
    end

    // ================================================================ interrupts
    // irq_busy: an interrupt has been taken; until the next redirect no other is
    // taken and nothing comes from memory. in_seq: the sequence is still coming out;
    // seq_index is its next instruction.
    reg         irq_busy;
    reg         in_seq;
    reg  [3:0]  seq_index;

    wire        start   = irq_pending & !irq_busy;   // take an interrupt now
    wire        inject  = start | in_seq;             // f_* gets an instruction of the sequence

    wire [31:0] seq_instr;
    wire        seq_last;
    irq_sequence irq_seq (
        .index(start ? 4'd0 : seq_index),
        .instr(seq_instr), .last(seq_last)
    );

    // an instruction from memory goes into f_*
    wire        from_mem = hit & !inject & !irq_busy;

    // ================================================================ the PC
    // It moves on when an instruction from memory goes into f_*; a redirect wins, and
    // it stays while an interrupt is pending or being taken.
    pc #(.RESET_PC(RESET_PC)) program_counter (
        .clk(clk), .reset(reset),
        .load(redirect), .load_value(redirect_pc),
        .irq_pending(irq_pending | irq_busy),
        .step(take & from_mem), .len(len),
        .value(pc)
    );

    // ================================================================ f_*
    // for decode's pre-decode: the instruction that goes into f_* at the next edge
    assign f_next_instr = inject ? seq_instr : window;
    assign f_load       = !reset & !redirect & take & (inject | from_mem);

    always @(posedge clk) begin
        if (reset | redirect) begin
            f_valid  <= 1'b0;
            irq_busy <= 1'b0;
            in_seq   <= 1'b0;
        end else if (take) begin
            if (inject) begin
                f_valid   <= 1'b1;
                f_pc      <= pc;
                f_instr   <= seq_instr;
                f_len     <= {1'b0, seq_instr[7:6]} + 3'd1;
                f_inject  <= 1'b1;
                irq_busy  <= 1'b1;
                in_seq    <= !seq_last;
                seq_index <= (start ? 4'd0 : seq_index) + 4'd1;
            end else begin
                f_valid <= from_mem;
                if (from_mem) begin
                    f_pc     <= pc;
                    f_instr  <= window;
                    f_len    <= len;
                    f_inject <= 1'b0;
                end
            end
        end
    end
endmodule
