// decoder.v: the decoder of stage 2 (decode.v) in the mp32 pipeline: from the
// instruction (f_instr, its PC and length) and the step of the sequencer (d_step), the
// two operands' registers or constants and the control word of execute. It has no
// clock: a function of its inputs.
//
// decode.v uses it twice: on the instruction in f_* for the control word, and on the
// instruction and step that will be there after the next edge, for the registers the
// operands read (the pre-decode: decode.v keeps those in registers, so the register
// file reads from a register, not from the end of this logic).
//
// Everything about the opcodes is described in decode.v and ../isa.md.

module decoder (
    input  wire [31:0] f_pc,
    input  wire [31:0] f_instr,
    input  wire [2:0]  f_len,
    input  wire [1:0]  d_step,

    output reg  [31:0] a_const,        // operand A's constant (when d_a_use = 0)
    output reg  [31:0] b_const,        // operand B's constant (when d_b_use = 0)
    output reg         call,           // a call: decode redirects fetch
    output wire [31:0] target,         // the target of CBR, CBRL, the calls
    output reg         d_a_use,
    output reg  [5:0]  d_a_sel,
    output reg         d_b_use,
    output reg  [5:0]  d_b_sel,
    output reg  [4:0]  d_alu_op,
    output reg  [1:0]  d_cin,
    output reg  [3:0]  d_fmask,
    output reg         d_a_tmpl,
    output reg         d_b_s3,
    output reg         d_b_imm,
    output reg  [31:0] d_imm,
    output reg  [2:0]  d_s3,
    output reg  [2:0]  d_res,
    output reg         d_wen,
    output reg  [5:0]  d_rd,
    output reg         d_x2_wen,
    output reg  [1:0]  d_x2_sel,
    output reg  [1:0]  d_x2,
    output reg         d_load,
    output reg         d_store,
    output reg  [1:0]  d_size,
    output reg         d_signed,
    output reg         d_wdata,
    output reg         d_addr,
    output reg  [1:0]  d_sp_sel,
    output reg  [2:0]  d_sp_op,
    output reg         d_tmp_we,
    output reg         d_tmp_src,
    output reg         d_tl_we,
    output reg         d_th_we,
    output reg         d_th_y2,
    output reg         d_tl_shl,
    output reg         d_tl_shr,
    output reg         d_st_we,
    output reg         d_jump,
    output reg  [3:0]  d_cond,
    output reg         d_tgt,
    output reg         d_trap,         // CONS step 0: trap unless L <= HLIM
    output reg         d_hl_we,       // HLIM = r
    output reg         d_loop         // UNEXT, NEXT2, NEXT3: branch to d_imm if operand B != 0
);
    // ================================================================ names
    localparam [4:0] A_ADD = 0, A_ADC = 1, A_SUB = 2, A_SBC = 3, A_AND = 4, A_OR = 5,
                     A_XOR = 6, A_NOT = 7, A_LSL = 8, A_LSR = 9, A_ASR = 10, A_ROR = 11,
                     A_CSUB = 17, A_DIVS = 18, A_MUL = 19, A_SMUL = 20, A_ASL = 21,
                     A_ROL = 22, A_ROLC = 23, A_RORC = 24, A_MULS = 25,
                     A_RSB = 26, A_RSC = 27, A_TADD = 28, A_TSUB = 29, A_TTAG = 30;
    localparam [2:0] SP_BASE = 0, SP_PUSH = 1, SP_POP = 2, SP_SET = 3, SP_ENTER = 5, SP_LEAVE = 6;
    localparam [1:0] PSP = 0, RSP = 1, FP = 2;
    localparam [5:0] T_ = 6'b100000, S_ = 6'b100001, R_ = 6'b100010, L_ = 6'b100011;
    localparam [1:0] X2_T = 0, X2_S = 1, X2_L = 3;
    // d_res
    localparam [2:0] RES_Y = 0, RES_A = 1, RES_B = 2, RES_S3 = 3, RES_TMP = 4, RES_DIVS = 5,
                     RES_FLAGS = 6, RES_IMM = 7;
    // d_x2
    localparam [1:0] X2_Y = 0, X2_Y2 = 1, X2_A = 2, X2_B = 3;
    // d_cin
    localparam [1:0] CIN_0 = 0, CIN_1 = 1, CIN_C = 2, CIN_TMPL0 = 3;
    localparam [3:0] ALWAYS = 4'hE;

    // ================================================================ the bytes
    wire [7:0] op = f_instr[7:0];
    wire [7:0] b1 = f_instr[15:8];
    wire [7:0] b2 = f_instr[23:16];
    wire [7:0] b3 = f_instr[31:24];

    // MOVR / ADDR .. CMPR: byte 1 = 0, direction, the register (6-bit selector)
    wire       to_t = b1[6];                      // 1: the register into T
    wire [5:0] reg6 = b1[5:0];
    wire       in_file = !reg6[5] | (reg6[4:2] == 3'b000);   // r0 .. r31, T, S, R, L
    // the registers of stage 3 and PC: 0 PSP, 1 RSP, 2 FP, 3 PC, 4 TMPL, 5 TMPH, 6 ST,
    // 7 HLIM, 15 none
    localparam [3:0] NONE = 4'd15;
    function [3:0] s3w_of(input [5:0] g);
        case (g)
            6'b100100: s3w_of = 0;   6'b100101: s3w_of = 1;   6'b100110: s3w_of = 2;
            6'b100111: s3w_of = 3;   6'b101000: s3w_of = 4;   6'b101001: s3w_of = 5;
            6'b101010: s3w_of = 6;                                // ST
            6'b101011: s3w_of = 7;                                // HLIM
            default:   s3w_of = NONE;
        endcase
    endfunction
    function file_of(input [5:0] g);                // r0 .. r31, T, S, R, L
        file_of = !g[5] | (g[4:2] == 3'b000);
    endfunction
    wire [3:0] s3w = s3w_of(reg6);

    // ADD2 .. CMP2 (0x90 .. 0x97): byte 1 = opx (7..6) and the destination, also source 1 (5..0);
    // byte 2 = source 2 (5..0). Each is a register file register, PC, or a register of
    // stage 3; at most one of them may be in stage 3, as it can only come in on ALU
    // input b.
    wire [5:0] dst2 = b1[5:0];
    wire [5:0] src2 = b2[5:0];
    wire       df = file_of(dst2),  sf = file_of(src2);
    wire [3:0] dw = s3w_of(dst2),   sw = s3w_of(src2);
    wire       dpc = !df & (dw == 3), spc = !sf & (sw == 3);
    wire       ds3 = !df & (dw != 3) & (dw != NONE), ss3 = !sf & (sw != 3) & (sw != NONE);
    wire       add2_ok = (b1[7:6] == 2'b00) & (df | dw != NONE) & (sf | sw != NONE) & !(ds3 & ss3);

    // ADD3 .. CMP3 (0xD0 .. 0xD7): byte 1 = opx (7..6) and the destination; byte 2 =
    // source 1, byte 3 = source 2 (5..0). As ADD2: at most one source in stage 3.
    wire [5:0] d3 = b1[5:0], s13 = b2[5:0], s23 = b3[5:0];
    wire       d3f = file_of(d3), s13f = file_of(s13), s23f = file_of(s23);
    wire [3:0] d3w = s3w_of(d3),  s13w = s3w_of(s13),  s23w = s3w_of(s23);
    wire       d3pc = !d3f & (d3w == 3);
    wire       s13s3 = !s13f & (s13w != 3) & (s13w != NONE), s23s3 = !s23f & (s23w != 3) & (s23w != NONE);
    wire       add3_ok = (b1[7:6] == 2'b00) & (d3f | d3w != NONE) & (s13f | s13w != NONE) & (s23f | s23w != NONE)
                       & !(s13s3 & s23s3)
                       & !((op[2:0] == 3'd7) & d3pc);              // CMP3 PC, ..: no
    wire [2:0] res3 = (op[2:0] == 3'd7) ? RES_FLAGS : RES_Y;        // CMP3: the flags

    // MOV2 / MOVI2 (0x83): byte 1 = mode (7: 0 MOV2, 1 MOVI2), 0 (6), the destination
    // (5..0); byte 2 = the source register (5..0; bits 7..6 ignored), or for MOVI2 a
    // signed 8-bit constant. The value goes through the ALU as 0 + operand B (no flags).
    // Only the source is read, so both may be in stage 3.
    wire       movi = b1[7];
    wire [5:0] dm = b1[5:0], sm = b2[5:0];
    wire       dmf = file_of(dm), smf = file_of(sm);
    wire [3:0] dmw = s3w_of(dm),  smw = s3w_of(sm);
    wire       mov_ok = !b1[6] & (dmf | dmw != NONE) & (movi | smf | smw != NONE);

    // LDR / STR (0x84 / 0x85): byte 1 = the size (7..6: 00 byte, 01 halfword, 10 word;
    // 11 does nothing) and the data register (5..0); byte 2 = signed (7, LDR; STR: 0),
    // 0 (6) and the address register (5..0). The data register must be in the register
    // file (a load's data comes in stages 4, 5; a store's data is an operand). The
    // address goes through `stackregs`' addr output (d_addr = 0): a register file
    // register or PC as its offset with sel = none (0 + offset), or PSP, RSP, FP itself
    // with offset 0. TMPL, TMPH, ST cannot be the address.
    wire [5:0] ml = b1[5:0], al = b2[5:0];
    wire       alf = file_of(al);
    wire [3:0] alw = s3w_of(al);
    wire       al_ok = alf | (alw == 3) | (alw < 3);
    wire       ldr_ok = (b1[7:6] != 2'b11) & !b2[6] & file_of(ml) & al_ok;
    wire       str_ok = (b1[7:6] != 2'b11) & (b2[7:6] == 2'b00) & file_of(ml) & al_ok;

    // LDR3 / STR3 (0xC4 / 0xC5): as LDR / STR, the address = base + offset. Byte 1 = the
    // size and the data register; byte 2 = signed (7, LDR3; STR3: 0), mode (6: 1 = byte 3
    // is a signed 8-bit offset, 0 = byte 3 bits 5..0 the offset register) and the base
    // register; byte 3 = the offset. The base can be any register; the offset register
    // any but PC. At most one of base and offset in stage 3 (ALU input b). STR3 reads
    // the data too: not three register file registers (two read ports).
    // The address is ALU y = a + b (d_addr = 1): the one in stage 3 on b (d_b_s3), or
    // for STR3 with none in stage 3 the constant part on b through d_imm.
    wire [5:0] bs = b2[5:0], os = b3[5:0];
    wire       ofsi = b2[6];                                    // 1: imm8 offset
    wire [31:0] imm8 = {{24{b3[7]}}, b3};
    wire       bsf = file_of(bs), osf = file_of(os);
    wire [3:0] bsw = s3w_of(bs),  osw = s3w_of(os);
    wire       bspc = !bsf & (bsw == 3);
    wire       bss3 = !bsf & (bsw != 3) & (bsw != NONE), oss3 = !ofsi & !osf & (osw != 3) & (osw != NONE);
    wire       os_ok = ofsi | osf | oss3;                         // not PC
    wire       m3_ok = (b1[7:6] != 2'b11) & file_of(ml) & (bsf | bsw != NONE) & os_ok & !(bss3 & oss3);
    wire       ldr3_ok = m3_ok;
    wire       str3_ok = m3_ok & !b2[7] & !(bsf & !ofsi & osf);

    // ADDR .. CMPR (0x50 .. 0x57), ADD2 .. CMP2 (0x90 .. 0x97), ADD3 .. CMP3 (0xD0 .. 0xD7):
    // the ALU op and carry in, from opcode bits 2..0. A subtraction is the first operand
    // (the destination, for ADD3 .. CMP3 source 1) minus the other. It goes the other
    // way round (RSB / RSC: b - a) when that first operand is on operand B: for ADDR ..
    // CMPR when the register is the destination (operand A is always T), for ADD2 ..
    // CMP2 when the destination is the register of stage 3, for ADD3 .. CMP3 when
    // source 1 is. CMPR and CMP2 write nothing; CMP3 writes the flags into the destination.
    wire       rev  = !op[7] ? !to_t : !op[6] ? (ds3 & !ss3) : s13s3;
    wire       cmpr = (op[2:0] == 3'd7);
    reg  [4:0] rop;
    reg  [1:0] rcin;
    always @*
        case (op[2:0])
            3'd0:    begin rop = A_ADD;                rcin = CIN_0; end   // ADD
            3'd1:    begin rop = A_ADC;                rcin = CIN_C; end   // ADC
            3'd2:    begin rop = rev ? A_RSB : A_SUB;  rcin = CIN_1; end   // SUB
            3'd3:    begin rop = rev ? A_RSC : A_SBC;  rcin = CIN_C; end   // SBC
            3'd4:    begin rop = A_AND;                rcin = CIN_C; end   // AND (C kept)
            3'd5:    begin rop = A_OR;                 rcin = CIN_C; end   // OR
            3'd6:    begin rop = A_XOR;                rcin = CIN_C; end   // XOR
            default: begin rop = rev ? A_RSB : A_SUB;  rcin = CIN_1; end   // CMP
        endcase

    // ================================================================ addresses and constants
    wire [31:0] next = f_pc + {29'h0, f_len};

    reg  [31:0] offset;                           // for the adder: target = next + offset
    always @*
        case (op)
            8'h81:   offset = {{20{b2[7]}}, b2, b1[3:0]};          // CBR,  12 bits
            8'hC1:   offset = {{12{b3[7]}}, b3, b2, b1[3:0]};      // CBRL, 20 bits
            8'hC4, 8'hC5: offset = {{24{b3[7]}}, b3};              // LDR3 / STR3 imm8 (PC base)
            8'h42:   offset = {{24{b1[7]}}, b1};                   // JSRS,  8 bits
            8'h82:   offset = {{16{b2[7]}}, b2, b1};               // JSR,  16 bits
            8'h88:   offset = {{24{b2[7]}}, b2};                   // NEXT2,  8 bits
            8'hC8:   offset = {{16{b3[7]}}, b3, b2};               // NEXT3, 16 bits
            default: offset = {{ 8{b3[7]}}, b3, b2, b1};           // JSRL, 24 bits
        endcase
    assign target = next + offset;

    wire [31:0] lit8  = {{24{b1[7]}}, b1};
    wire [31:0] lit16 = {{16{b2[7]}}, b2, b1};
    wire [31:0] lit24 = {{ 8{b3[7]}}, b3, b2, b1};
    wire [31:0] local_ = {f_pc[31:4], b1[3:0]};   // CJMPL

    // ================================================================ the control word

    task pop_(input [1:0] st);
        begin d_sp_sel = st; d_sp_op = SP_POP;  d_load = 1; end
    endtask
    task push_(input [1:0] st, input src);         // src: 0 operand A, 1 operand B
        begin d_sp_sel = st; d_sp_op = SP_PUSH; d_store = 1; d_wdata = src; end
    endtask
    task rd_(input [5:0] sel, input [2:0] res);
        begin d_wen = 1; d_rd = sel; d_res = res; end
    endtask
    task x2_(input [1:0] sel, input [1:0] src);
        begin d_x2_wen = 1; d_x2_sel = sel; d_x2 = src; end
    endtask
    task ra(input [5:0] sel); begin d_a_use = 1; d_a_sel = sel; end endtask
    task rb(input [5:0] sel); begin d_b_use = 1; d_b_sel = sel; end endtask
    task jump_(input [3:0] c, input tgt); begin d_jump = 1; d_cond = c; d_tgt = tgt; end endtask
    // a binary op on S and T: T = S op T, S = pop
    task binop(input [4:0] aop, input [1:0] cin);
        begin
            ra(S_); rb(T_); d_alu_op = aop; d_cin = cin; d_fmask = 4'b1111;
            pop_(PSP); rd_(S_, RES_Y); x2_(X2_T, X2_Y);
        end
    endtask
    // a shift / rotate of T by one
    task shift1(input [4:0] aop);
        begin
            ra(T_); b_const = 1; d_alu_op = aop; d_cin = CIN_C; d_fmask = 4'b1111;
            rd_(T_, RES_Y);
        end
    endtask
    // read / write a register of stage 3 (s3w 0 PSP 1 RSP 2 FP 4 TMPL 5 TMPH 6 ST 7 HLIM)
    task s3_read(input [3:0] w);
        begin
            // PSP, RSP, FP from their own outputs (d_s3 4 .. 6), not through
            // `stackregs`' sel: sel stays free for a write of another one
            if (w < 3) d_s3 = 3'd4 + w[2:0];
            else       d_s3 = (w == 4) ? 3'd1 : (w == 5) ? 3'd2 : (w == 6) ? 3'd3 : 3'd7;
        end
    endtask
    task s3_write(input [3:0] w);                  // the value: the result r
        begin
            if (w < 3)       begin d_sp_sel = w[1:0]; d_sp_op = SP_SET; end
            else if (w == 4) d_tl_we = 1;
            else if (w == 5) d_th_we = 1;
            else if (w == 6) d_st_we = 1;
            else             d_hl_we = 1;
        end
    endtask

    always @* begin
        // nothing, by default (a NOP)
        d_a_use = 0; d_a_sel = 0; a_const = 0; d_b_use = 0; d_b_sel = 0; b_const = 0;
        d_alu_op = A_ADD; d_cin = CIN_0; d_fmask = 0; d_a_tmpl = 0; d_b_s3 = 0; d_s3 = 0;
        d_b_imm = 0; d_imm = 0;
        d_res = RES_Y; d_wen = 0; d_rd = 0; d_x2_wen = 0; d_x2_sel = 0; d_x2 = 0;
        d_load = 0; d_store = 0; d_size = 2'b10; d_signed = 0; d_wdata = 0; d_addr = 0;
        d_sp_sel = PSP; d_sp_op = SP_BASE; d_tmp_we = 0; d_tmp_src = 0;
        d_tl_we = 0; d_th_we = 0; d_th_y2 = 0; d_tl_shl = 0; d_tl_shr = 0; d_st_we = 0;
        d_jump = 0; d_cond = 0; d_tgt = 0; call = 0; d_trap = 0; d_hl_we = 0; d_loop = 0;

        case (op)
        // ---------------------------------------------------- stack
        8'h01: begin ra(R_); jump_(ALWAYS, 0); pop_(RSP); rd_(R_, RES_Y); end      // RET
        8'h02: begin ra(S_); rb(T_); push_(PSP, 0); rd_(S_, RES_B); end            // DUP
        8'h03: begin ra(S_); pop_(PSP); rd_(S_, RES_Y); x2_(X2_T, X2_A); end       // DROP
        8'h04: begin ra(S_); rb(T_); rd_(T_, RES_A); x2_(X2_S, X2_B); end          // SWAP
        8'h05: begin ra(S_); rb(T_); push_(PSP, 0); rd_(T_, RES_A); x2_(X2_S, X2_B); end // OVER
        8'h06: begin ra(S_); push_(PSP, 0); end                                    // DIP
        8'h07: begin pop_(PSP); rd_(S_, RES_Y); end                                // NIP
        8'h08: begin rb(T_); push_(PSP, 1); end                                    // TUCK
        8'h09: begin pop_(PSP); rd_(T_, RES_Y); end                                // DRIP
        8'h0A: begin ra(R_); rb(T_); push_(RSP, 0); rd_(R_, RES_B); end            // PUSH
        8'h0B: begin ra(R_); pop_(RSP); rd_(R_, RES_Y); x2_(X2_T, X2_A); end       // POP
        8'h0C: begin ra(R_); rb(S_); push_(RSP, 0); rd_(R_, RES_B); end            // PUSHS
        8'h0D: begin ra(R_); pop_(RSP); rd_(R_, RES_Y); x2_(X2_S, X2_A); end       // POPS
        8'h0E: if (!d_step) begin                                                  // ROT
                   rb(T_); d_tmp_we = 1; d_tmp_src = 1; pop_(PSP); rd_(T_, RES_Y);
               end else begin
                   ra(S_); push_(PSP, 0); rd_(S_, RES_TMP);
               end
        8'h0F: if (!d_step) begin                                                  // DROT
                   ra(S_); d_tmp_we = 1; d_tmp_src = 0; pop_(PSP); rd_(S_, RES_Y);
               end else begin
                   rb(T_); push_(PSP, 1); rd_(T_, RES_TMP);
               end
        // ---------------------------------------------------- arithmetic and logic
        8'h10: binop(A_ADD, CIN_0);                                                // ADD
        8'h11: binop(A_ADC, CIN_C);                                                // ADC
        8'h12: binop(A_SUB, CIN_1);                                                // SUB
        8'h13: binop(A_SBC, CIN_C);                                                // SBC
        8'h14: begin ra(T_); rb(S_); d_alu_op = A_CSUB; d_cin = CIN_1;             // CSUB
                     d_fmask = 4'b1111; rd_(T_, RES_Y); end
        8'h15: begin ra(T_); rb(S_); d_alu_op = A_DIVS; d_cin = CIN_C;             // DIVS
                     d_fmask = 4'b0001; d_tl_shl = 1; rd_(T_, RES_DIVS); end
        8'h16, 8'h17:                                                              // MUL, SMUL
               begin ra(S_); rb(T_); d_alu_op = (op == 8'h16) ? A_MUL : A_SMUL;
                     d_fmask = 4'b0110; rd_(T_, RES_Y); x2_(X2_S, X2_Y2); end
        8'h18: binop(A_AND, CIN_C);                                                // AND
        8'h19: binop(A_OR,  CIN_C);                                                // OR
        8'h1A: binop(A_XOR, CIN_C);                                                // XOR
        8'h1B: begin ra(T_); d_alu_op = A_NOT; d_cin = CIN_C; d_fmask = 4'b1110;   // INV
                     rd_(T_, RES_Y); end
        8'h1C: begin a_const = 0; rb(T_); d_alu_op = A_SUB; d_cin = CIN_1;         // NEG
                     d_fmask = 4'b1111; rd_(T_, RES_Y); end
        8'h1D: begin ra(T_); rb(S_); d_alu_op = A_MULS; d_cin = CIN_TMPL0;         // MULS
                     d_tl_shr = 1; rd_(T_, RES_Y); end
        8'h1E: begin ra(S_); rb(T_); d_alu_op = A_SUB; d_cin = CIN_1;              // CMP
                     d_fmask = 4'b1111; end
        8'h1F: begin ra(R_); b_const = next; jump_(ALWAYS, 0);                    // EXC (next = PC + 1)
                     rd_(R_, RES_B); end
        // ---------------------------------------------------- shifts, rotates
        8'h20: shift1(A_ASL);   8'h21: shift1(A_ASR);   8'h22: shift1(A_LSL);
        8'h23: shift1(A_LSR);   8'h24: shift1(A_ROL);   8'h25: shift1(A_ROR);
        8'h26: shift1(A_ROLC);  8'h27: shift1(A_RORC);
        // ---------------------------------------------------- LISP
        // the cons tag is 01: the car is at the pointer - 1, the cdr at + 3
        8'h2C, 8'h2D: begin                                                        // CAR, CDR
                   ra(T_); b_const = op[0] ? 32'd3 : 32'hFFFF_FFFF;                // T = the word at T - 1 / T + 3
                   d_alu_op = A_ADD; d_cin = CIN_0; d_addr = 1;
                   d_load = 1; rd_(T_, RES_Y);
               end
        8'h2E, 8'h2F: begin                                                        // RPLACA, RPLACD
                   ra(T_); d_b_imm = 1; d_imm = op[0] ? 32'd3 : 32'hFFFF_FFFF;     // the word at T - 1 / T + 3 = S
                   d_alu_op = A_ADD; d_cin = CIN_0; d_addr = 1;
                   d_store = 1; rb(S_); d_wdata = 1;
               end
        8'h31: case (d_step)                                                       // CONS
               2'd0: begin                                                         // the check: HLIM - L, C = (L <= HLIM)
                   ra(L_); d_b_s3 = 1; d_s3 = 3'd7; d_alu_op = A_RSB; d_cin = CIN_1;
                   // if it traps (C = 0): a call to the GC vector that comes back to
                   // this CONS: push R, R = the CONS's own address. Execute does these
                   // only when it traps.
                   d_trap = 1; rb(R_); push_(RSP, 1); d_imm = f_pc; rd_(R_, RES_IMM);
               end
               2'd1: begin                                                         // the word at L - 1 = S (the car)
                   ra(L_); d_b_imm = 1; d_imm = 32'hFFFF_FFFF;
                   d_alu_op = A_ADD; d_cin = CIN_0; d_addr = 1;
                   d_store = 1; rb(S_); d_wdata = 1;
               end
               2'd2: begin                                                         // the word at L + 3 = T (the cdr), T = L
                   ra(L_); d_b_imm = 1; d_imm = 32'd3;
                   d_alu_op = A_ADD; d_cin = CIN_0; d_addr = 1;
                   d_store = 1; rb(T_); d_wdata = 1; rd_(T_, RES_A);
               end
               default: begin                                                      // S = pop, L = L + 8
                   ra(L_); d_b_imm = 1; d_imm = 32'd8; d_alu_op = A_ADD; d_cin = CIN_0;
                   pop_(PSP); rd_(S_, RES_Y); x2_(X2_L, X2_Y);
               end
               endcase
        8'h32: binop(A_TADD, CIN_0);                                               // TADD
        8'h33: binop(A_TSUB, CIN_1);                                               // TSUB
        // ---------------------------------------------------- SHI, TTAG
        8'h47: if (b1[7:5] <= 3'd4) begin                                          // SHI: T shifted by b1[4:0]
                   ra(T_); b_const = {27'h0, b1[4:0]}; d_cin = CIN_C; d_fmask = 4'b1111;
                   case (b1[7:5])
                       3'd0: d_alu_op = A_LSL;  3'd1: d_alu_op = A_LSR;  3'd2: d_alu_op = A_ASR;
                       3'd3: d_alu_op = A_ROL;  default: d_alu_op = A_ROR;
                   endcase
                   rd_(T_, RES_Y);
               end
        8'h87: begin                                                               // TTAG: Z = ((T & mask) == value)
                   ra(T_); b_const = {16'h0, b1, b2}; d_alu_op = A_TTAG; d_cin = CIN_C;
                   d_fmask = 4'b0010;
               end
        // ---------------------------------------------------- LEAVE, ENTER
        // the return stack's top is R: a push of FP is "push R, R = FP", a pop "FP = R,
        // pop R". `stackregs` writes RSP and FP in the same tick (ENTER, LEAVE ops).
        8'h30: begin                                                               // LEAVE
                   d_sp_sel = RSP; d_sp_op = SP_LEAVE;                             // RSP = FP + 4, FP = R
                   ra(R_); d_load = 1; rd_(R_, RES_A);                             // r = R (FP's new value); R = the word at FP + 4
               end
        8'h46, 8'h86, 8'hC6: begin                                                 // ENTER, ENTER2, ENTER3
                   d_sp_sel = RSP; d_sp_op = SP_ENTER;                             // RSP = RSP - 4 - 4n, FP = RSP - 4
                   b_const = (op == 8'h46) ? {22'h0, b1, 2'b00} :                  // n words, unsigned:
                             (op == 8'h86) ? {14'h0, b2, b1, 2'b00} :              // 4 * n bytes
                                             {6'h0, b3, b2, b1, 2'b00};
                   ra(R_); d_store = 1; d_wdata = 0;                               // the word at RSP = R
                   d_s3 = 3'd6; rd_(R_, RES_S3);                                   // R = the old FP
               end
        // ---------------------------------------------------- INC, DEC, INCW, DECW
        8'h28, 8'h29, 8'h2A, 8'h2B:                                                // T = T +- 1 / 4
               begin ra(T_); b_const = op[1] ? 32'd4 : 32'd1;
                     d_alu_op = op[0] ? A_SUB : A_ADD; d_cin = op[0] ? CIN_1 : CIN_0;
                     d_fmask = 4'b1111; rd_(T_, RES_Y); end
        // ---------------------------------------------------- constants
        8'h40: begin a_const = lit8;  rd_(T_, RES_A); end                          // LIT8
        8'h80: begin a_const = lit16; rd_(T_, RES_A); end                          // LIT16
        8'hC0: begin a_const = lit24; rd_(T_, RES_A); end                          // LIT24
        // ---------------------------------------------------- jumps and calls
        8'h41: begin a_const = local_; rb(T_); jump_(b1[7:4], 0); end              // CJMPL
        8'h81, 8'hC1:                                                              // CBR, CBRL
               begin a_const = target; rb(T_); jump_(b1[7:4], 0); end
        8'h42, 8'h82, 8'hC2:                                                       // JSRS, JSR, JSRL
               begin a_const = next; rb(R_); push_(RSP, 1); rd_(R_, RES_A); call = 1; end
        // ---------------------------------------------------- counted loops
        // The counter on operand B, 1 on A: y = B - 1 (RSB). Execute branches to d_imm
        // when the counter is not 0 (tz: operand B == 0, before the decrement), and then
        // writes the counter - 1. When it is 0, the loop ends: no branch and no write,
        // but for R the return stack is popped into R (the load and the stack op
        // happen only then). No flags.
        8'h48: if (b1[7:4] == 4'h0) begin                                          // UNEXT: R, in the line
                   a_const = 1; rb(R_); d_alu_op = A_RSB; d_cin = CIN_1;
                   d_imm = local_; d_loop = 1;
                   pop_(RSP); rd_(R_, RES_Y);                                      // R = R - 1, or the pop
               end
        8'h88, 8'hC8: if (b1[7:6] == 2'b00 && in_file) begin                       // NEXT2, NEXT3
                   a_const = 1; rb(reg6); d_alu_op = A_RSB; d_cin = CIN_1;
                   d_imm = target; d_loop = 1;
                   rd_(reg6, RES_Y);                                               // reg = reg - 1
                   if (reg6 == R_) pop_(RSP);                                      // R: dropped at the end
               end
        // ---------------------------------------------------- MOVR
        8'h43: if (b1[7]) ;                                                        // bit 7 must be 0
               else if (in_file) begin
                   if (to_t) begin ra(reg6); rd_(T_,  RES_A); end                  // MOVR T, <reg>
                   else      begin ra(T_);   rd_(reg6, RES_A); end                 // MOVR <reg>, T
               end else if (s3w == 3) begin                                        // PC
                   if (to_t) begin a_const = next; rd_(T_, RES_A); end             // MOVR T, PC
                   else      begin ra(T_); jump_(ALWAYS, 0); end                   // MOVR PC, T
               end else if (s3w != NONE) begin                                        // PSP .. TMPH, ST
                   if (to_t) begin s3_read(s3w); rd_(T_, RES_S3); end              // MOVR T, <s3>
                   else      begin ra(T_); d_res = RES_A; s3_write(s3w); end       // MOVR <s3>, T
               end
        // ---------------------------------------------------- INCR, DECR, INCWR, DECWR
        // byte 1: bit 7 = 0 inc / 1 dec, bit 6 = 0 by 1 / 1 by 4, bits 5..0 the register.
        // The register on operand B (where a register of stage 3 can come in), the
        // constant on A: inc = A + B, dec = B - A (RSB).
        8'h44: if (in_file | s3w != NONE) begin                                       // reg = reg +- 1 / 4
                   a_const = b1[6] ? 32'd4 : 32'd1;
                   d_alu_op = b1[7] ? A_RSB : A_ADD; d_cin = b1[7] ? CIN_1 : CIN_0;
                   d_fmask = 4'b1111;
                   if (in_file)          begin rb(reg6); rd_(reg6, RES_Y); end
                   else if (s3w == 3)    begin b_const = next; jump_(ALWAYS, 1); end   // PC: a jump
                   else                  begin d_b_s3 = 1; s3_read(s3w); d_res = RES_Y; s3_write(s3w); end
               end
        // ---------------------------------------------------- ADDR .. CMPR
        8'h50, 8'h51, 8'h52, 8'h53, 8'h54, 8'h55, 8'h56, 8'h57:
               if (b1[7]) ;
               else if (in_file) begin
                   ra(T_); rb(reg6); d_fmask = 4'b1111; d_alu_op = rop; d_cin = rcin;
                   if (cmpr) ;                                                     // flags only
                   else if (to_t) rd_(T_, RES_Y); else rd_(reg6, RES_Y);          // xR T, <reg> / <reg>, T
               end else if (s3w == 3) begin                                        // PC
                   ra(T_); b_const = next; d_fmask = 4'b1111; d_alu_op = rop; d_cin = rcin;
                   if (cmpr) ;
                   else if (to_t) rd_(T_, RES_Y);                                  // xR T, PC
                   else           jump_(ALWAYS, 1);                                // xR PC, T (a jump)
               end else if (s3w != NONE) begin                                        // PSP .. TMPH
                   ra(T_); d_b_s3 = 1; s3_read(s3w); d_fmask = 4'b1111;
                   d_alu_op = rop; d_cin = rcin;
                   if (cmpr) ;
                   else if (to_t) rd_(T_, RES_Y);                                  // xR T, <s3>
                   else           begin d_res = RES_Y; s3_write(s3w); end          // xR <s3>, T
               end
        // ---------------------------------------------------- ADD2 .. CMP2
        8'h90, 8'h91, 8'h92, 8'h93, 8'h94, 8'h95, 8'h96, 8'h97:
               if (add2_ok) begin                                                  // dst = dst op src
                   d_alu_op = rop; d_cin = rcin; d_fmask = 4'b1111;
                   // operand B: the register of stage 3, if there is one, else the source;
                   // operand A: the other (rev turns a subtraction round when the
                   // destination is on B)
                   if (ss3) begin
                       d_b_s3 = 1; s3_read(sw);
                       if (df) ra(dst2); else a_const = next;                      // dst: file or PC
                   end else if (ds3) begin
                       d_b_s3 = 1; s3_read(dw);
                       if (sf) ra(src2); else a_const = next;
                   end else begin
                       if (df) ra(dst2); else a_const = next;
                       if (sf) rb(src2); else b_const = next;
                   end
                   // the destination
                   if (cmpr)     ;                                                 // CMP2: flags only
                   else if (df)  rd_(dst2, RES_Y);
                   else if (dpc) jump_(ALWAYS, 1);                                 // ADD2 PC, <src>: a jump
                   else          begin d_res = RES_Y; s3_write(dw); end
               end
        // ---------------------------------------------------- LDR, STR
        8'h84, 8'h85:
               if (op[0] ? str_ok : ldr_ok) begin
                   d_size = b1[7:6];
                   d_addr = 0; d_sp_op = SP_BASE;                                  // stackregs addr
                   if (!alf && alw < 3) begin d_sp_sel = alw[1:0]; b_const = 0; end  // PSP, RSP, FP
                   else begin
                       d_sp_sel = 2'b11;                                           // none: 0 + offset
                       if (alf) rb(al); else b_const = next;                       // register, PC
                   end
                   if (!op[0]) begin d_load = 1; d_signed = b2[7]; rd_(ml, RES_Y); end   // LDR
                   else        begin d_store = 1; ra(ml); d_wdata = 0; end              // STR
               end
        // ---------------------------------------------------- LDR3, STR3
        8'hC4, 8'hC5:
               if (op[0] ? str3_ok : ldr3_ok) begin
                   d_size = b1[7:6]; d_addr = 1;                                   // the address: ALU y
                   d_alu_op = A_ADD; d_cin = CIN_0;                                // no flags
                   if (oss3) begin                                                 // offset in stage 3
                       d_b_s3 = 1; s3_read(osw);
                       if (bsf) ra(bs); else a_const = next;                       // base: register, PC
                   end else if (bss3) begin                                        // base in stage 3
                       d_b_s3 = 1; s3_read(bsw);
                       if (ofsi) a_const = imm8; else ra(os);
                   end else if (!op[0]) begin                                      // LDR3: both operands
                       if (bsf) ra(bs); else a_const = next;
                       if (ofsi) b_const = imm8; else rb(os);
                   end else begin                                                  // STR3: the constant part on d_imm
                       d_b_imm = 1;
                       d_imm = bspc ? (ofsi ? target : next) : (ofsi ? imm8 : 32'h0);
                       if (bsf) ra(bs); else if (!ofsi) ra(os);                    // the register part (one)
                   end
                   if (!op[0]) begin d_load = 1; d_signed = b2[7]; rd_(ml, RES_Y); end   // LDR3
                   else        begin d_store = 1; rb(ml); d_wdata = 1; end              // STR3: data on B
               end
        // ---------------------------------------------------- MOV2, MOVI2
        8'h83: if (mov_ok) begin                                                   // dst = src / imm8
                   d_alu_op = A_ADD; d_cin = CIN_0;                                // y = 0 + B; no flags
                   if (movi)             b_const = {{24{b2[7]}}, b2};                 // imm8, sign-extended
                   else if (smf)         rb(sm);
                   else if (smw == 3)    b_const = next;                           // PC
                   else begin d_b_s3 = 1; s3_read(smw); end                        // PSP .. ST
                   if (dmf)              rd_(dm, RES_Y);
                   else if (dmw == 3)    jump_(ALWAYS, 1);                         // MOV2 PC, ..: a jump
                   else begin d_res = RES_Y; s3_write(dmw); end
               end
        // ---------------------------------------------------- ADD3 .. CMP3
        8'hD0, 8'hD1, 8'hD2, 8'hD3, 8'hD4, 8'hD5, 8'hD6, 8'hD7:
               if (add3_ok) begin                                                  // dst = src1 op src2
                   d_alu_op = rop; d_cin = rcin; d_fmask = 4'b1111;
                   // operand B: the source in stage 3, if there is one, else source 2;
                   // operand A: the other source
                   if (s23s3) begin
                       d_b_s3 = 1; s3_read(s23w);
                       if (s13f) ra(s13); else a_const = next;
                   end else if (s13s3) begin                                       // rev
                       d_b_s3 = 1; s3_read(s13w);
                       if (s23f) ra(s23); else a_const = next;
                   end else begin
                       if (s13f) ra(s13); else a_const = next;
                       if (s23f) rb(s23); else b_const = next;
                   end
                   // the destination (CMP3: the new flags, {V, N, Z, C})
                   if (d3f)       rd_(d3, res3);
                   else if (d3pc) jump_(ALWAYS, 1);                                // a jump (not CMP3)
                   else           begin d_res = res3; s3_write(d3w); end
               end
        default: ;                                                                 // NOP, unknown
        endcase
    end
endmodule
