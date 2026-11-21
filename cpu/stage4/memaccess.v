// memaccess.v: stage 4 of the mp32 pipeline, memory access.
//
//   Loads and stores go to the memory bus (membus.v): the SDRAM through the cache,
//   the mapped block RAM and the I/O range, picked by the address. Stage 3
//   (execute) supplies the address and, for a store, the data. The data a load reads
//   goes on to stage 5 (writeback). Every other instruction passes straight through.
//
// ---------------------------------------------------------------- from stage 3
// x_valid .. x_result are stage 3's output registers. Stage 4 takes them at the edge
// when stall is 0. While stall is 1, stage 3 must hold them: the cache wants its
// inputs held until d_ready.
//
//   x_load, x_store   the instruction is a load / a store (never both)
//   x_size            00 = byte, 01 = halfword (2 bytes), 10 = word (4 bytes)
//   x_signed          a load of a byte or halfword: 1 = sign-extend, 0 = zero-extend
//   x_addr            the byte address, worked out by stage 3
//   x_wdata           the data to store, in the low bits (bits 7..0 for a byte)
//   x_wen, x_rd       the instruction writes register x_rd (the 6-bit selector)
//   x_result          its result, for an instruction that is not a load
//   x2_wen, x2_sel,   a second register write, to a special register only (00 = T,
//   x2_data           01 = S, 10 = R, 11 = L), passed straight on to stage 5: e.g.
//                     DROP loads S (x_rd) and writes T = old S (x2_*)
//
// Alignment: a halfword ignores address bit 0, a word bits 1..0: they are set to 0 on
// d_addr, so the bus, the cache and the I/O always see an aligned address.
//
// ---------------------------------------------------------------- the memory bus
// d_sel is 1 while a load or store is in x_*. The handshake is the cache's: the inputs
// are held until d_ready is 1; that tick ends the access and, for a load, d_rdata is
// valid in it. Stage 4 holds stage 3 with stall = d_sel & ~d_ready, so x_* (and so
// the bus's inputs) stay put. d_addr is the whole 32-bit address: the bus decodes it.
// Stage 4 has priority over stage 1 on the bus.
//
// A store puts the byte or halfword in every lane of d_wdata and picks the lanes
// with d_be. A load takes the lane at the address out of the 32-bit word.
//
// ---------------------------------------------------------------- to stage 5
// m_valid, m_wen, m_rd and m_data are registers; stage 5 (writeback) writes m_data
// into register m_rd when m_valid and m_wen are 1. m_data is the data loaded, or
// x_result. m2_wen, m2_sel and m2_data are x2_* one stage on, for the second write. While stage 4 waits for the cache, m_valid is 0 (a bubble).
//
// Nothing after execute throws instructions away, so stage 4 has no redirect input:
// a load or store that reaches it always finishes.
//
// ---------------------------------------------------------------- timing
// A cache hit or a block RAM access takes 2 ticks (d_ready 1 tick after d_sel), so
// each load or store stalls the pipeline for at least 1 tick; a cache miss for the
// burst(s) as well, the I/O for as long as it takes, a fetch going on for its line.

module memaccess (
    input  wire        clk,
    input  wire        reset,          // synchronous, active high

    // from stage 3, execute
    input  wire        x_valid,
    input  wire        x_load,
    input  wire        x_store,
    input  wire [1:0]  x_size,         // 00 = byte, 01 = halfword, 10 = word
    input  wire        x_signed,
    input  wire [31:0] x_addr,
    input  wire [31:0] x_wdata,
    input  wire        x_wen,
    input  wire [5:0]  x_rd,
    input  wire [31:0] x_result,
    input  wire        x2_wen,
    input  wire [1:0]  x2_sel,
    input  wire [31:0] x2_data,
    output wire        stall,          // stage 3 must hold x_*

    // the memory bus
    output wire        d_sel,
    output wire        d_we,
    output reg  [3:0]  d_be,
    output wire [31:0] d_addr,
    output reg  [31:0] d_wdata,
    input  wire [31:0] d_rdata,
    input  wire        d_ready,

    // to stage 5, writeback
    output reg         m_valid,
    output reg         m_wen,
    output reg  [5:0]  m_rd,
    output reg  [31:0] m_data,
    output reg         m2_wen,
    output reg  [1:0]  m2_sel,
    output reg  [31:0] m2_data
);
    localparam [1:0] BYTE = 2'b00, HALF = 2'b01;

    assign d_sel  = x_valid & (x_load | x_store);
    assign d_we   = x_store;
    assign d_addr = (x_size == BYTE) ? x_addr :
                    (x_size == HALF) ? {x_addr[31:1], 1'b0} : {x_addr[31:2], 2'b00};
    assign stall    = d_sel & ~d_ready;

    // ================================================================ the store lanes
    always @* begin
        case (x_size)
        BYTE: begin
            d_wdata = {4{x_wdata[7:0]}};
            d_be    = 4'b0001 << x_addr[1:0];
        end
        HALF: begin
            d_wdata = {2{x_wdata[15:0]}};
            d_be    = x_addr[1] ? 4'b1100 : 4'b0011;
        end
        default: begin
            d_wdata = x_wdata;
            d_be    = 4'b1111;
        end
        endcase
    end

    // ================================================================ the load lane
    wire [7:0]  lbyte = d_rdata >> {x_addr[1:0], 3'b000};
    wire [15:0] lhalf = x_addr[1] ? d_rdata[31:16] : d_rdata[15:0];

    reg [31:0] loaded;
    always @* begin
        case (x_size)
        BYTE:    loaded = {{24{x_signed & lbyte[7]}},  lbyte};
        HALF:    loaded = {{16{x_signed & lhalf[15]}}, lhalf};
        default: loaded = d_rdata;
        endcase
    end

    // ================================================================ to stage 5
    always @(posedge clk) begin
        if (reset)
            m_valid <= 1'b0;
        else
            m_valid <= x_valid & ~stall;
        m_wen  <= x_wen;
        m_rd   <= x_rd;
        m_data <= x_load ? loaded : x_result;
        m2_wen  <= x2_wen;
        m2_sel  <= x2_sel;
        m2_data <= x2_data;
    end
endmodule
