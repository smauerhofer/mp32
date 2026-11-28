// sd_model.v: a model of a microSD card in SPI mode, for the test benches. A version 2
// card, SDHC (block addresses) or, with sdhc = 0, SDSC (byte addresses), with what a
// boot loader needs:
//
//   CMD0   go idle                    R1 = $01
//   CMD8   interface condition        R1 = $01, then R7: the argument's low 12 bits back
//   CMD55  an application command     R1 = $01 while starting, then $00
//   ACMD41 start                      R1 = $01 the first BUSY_TRIES times, then $00
//   CMD58  the OCR                    R1, then $C0FF8000 (powered up, CCS: SDHC), or
//                                     $80FF8000 for SDSC (CCS = 0)
//   CMD16  block length               R1
//   CMD17  read a block               R1 = $00, a few $FF, the token $FE, 512 bytes,
//                                     two CRC bytes (not real ones); the argument is
//                                     the block (SDHC) or its first byte (SDSC: a
//                                     multiple of 512, else R1 = $40, address error)
//   CMD24  write a block              R1 = $00 (the address as CMD17); then it waits
//                                     for the token $FE, takes 512 bytes and two CRC
//                                     bytes, answers the data response $E5 and is
//                                     busy (MISO 0) for a few bytes
//   (a block of CMD17 that is not read to its end goes on after CS was off and on
//   again, and the card takes no command until it is out: as a real card)
//   CMD9   the CSD                    R1 = $00, $FF, the token $FE, 16 bytes, two CRC
//                                     bytes: version 2 (SDHC: C_SIZE) or version 1
//                                     (SDSC: C_SIZE, C_SIZE_MULT 7, READ_BL_LEN 9),
//                                     for a capacity of SIZE (rounded up)
//   CMD10  the CID                    the same with the CID: maker $03, OEM "SD",
//                                     product "MP32C", revision 1.0, serial
//                                     $12345678, made 2026-11
//   others                            R1 = $04 (illegal command), or $05 while idle
//
// SPI mode 0: MOSI taken at the rising edge of SCLK, MISO changed at the falling edge.
// A command is six bytes, the first one $40 + its number; its answer comes a byte
// after the last of them (the loader polls for it). The card answers from a queue of
// bytes; when the queue is empty it sends $FF.
//
// The card holds SIZE bytes from block 0 on; the rest reads 0. A test bench fills
// mem[] (load from a file) and may set present = 0 for no card in the slot (MISO
// stays high, as the pull-up makes it).

`timescale 1ns/1ps

module sd_model #(
    parameter SIZE       = 65536,
    parameter BUSY_TRIES = 2
) (
    input  wire sclk,
    input  wire cs_n,
    input  wire mosi,
    output wire miso
);
    reg [7:0] mem [0:SIZE-1];
    reg       present = 1;
    reg       sdhc = 1;

    integer i;
    integer fd, n;
    task load(input [8*256-1:0] name);
        load_at(name, 0);
    endtask
    // the file at byte a of the card (the rest of the card 0)
    task load_at(input [8*256-1:0] name, input integer a);
        begin
            for (i = 0; i < SIZE; i = i + 1) mem[i] = 8'h00;
            fd = $fopen(name, "rb");
            if (fd == 0) begin $display("sd_model: cannot open %0s", name); $finish; end
            n = $fread(mem, fd, a);
            $fclose(fd);
        end
    endtask

    // what it was asked, for the test bench
    integer commands = 0, blocks_read = 0, blocks_written = 0;
    // a block being sent (CMD17): it goes on when the card is deselected and selected
    // again, as a real card does, and no command is taken until it is out. data_end:
    // the queue's index after its CRC, -1 none.
    integer data_end = -1;

    // ---------------------------------------------------------------- the answers
    reg [7:0] q [0:1023];
    integer   qhead = 0, qtail = 0;
    task put(input [7:0] b);
        begin q[qtail] = b; qtail = (qtail + 1) % 1024; end
    endtask

    reg        idle = 1, app = 0;
    integer    tries = 0;
    reg [7:0]  frame [0:5];
    integer    nframe = 0;
    reg [31:0] arg;
    integer    k, base;
    // stale_block: as if block 0 had been read up to byte n and the card deselected
    // (the boot loader reads only the header of block 0): the rest of it comes first
    // when the card is selected again
    task stale_block(input integer n);
        integer j;
        begin
            for (j = n; j < 512; j = j + 1) put(mem[j]);
            put(8'h12); put(8'h34);
            data_end = qtail;
        end
    endtask

    // CMD9, CMD10: the registers
    localparam integer BLOCKS = (SIZE + 511) / 512;
    localparam integer CS_HC  = (BLOCKS + 1023) / 1024 - 1;       // SDHC: (C_SIZE + 1) * 1024
    localparam integer CS_SC  = (BLOCKS + 511) / 512 - 1;         // SDSC: (C_SIZE + 1) * 512
    reg [7:0] reg16 [0:15];
    task registers(input csd);
        integer j;
        begin
            for (j = 0; j < 16; j = j + 1) reg16[j] = 8'h00;
            if (!csd) begin
                reg16[0] = 8'h03; reg16[1] = "S"; reg16[2] = "D";
                reg16[3] = "M"; reg16[4] = "P"; reg16[5] = "3"; reg16[6] = "2"; reg16[7] = "C";
                reg16[8] = 8'h10;
                reg16[9] = 8'h12; reg16[10] = 8'h34; reg16[11] = 8'h56; reg16[12] = 8'h78;
                reg16[13] = 8'h01; reg16[14] = 8'hAB;          // 2000 + $1A, month 11
                reg16[15] = 8'h01;
            end else if (sdhc) begin
                reg16[0] = 8'h40; reg16[1] = 8'h0E; reg16[3] = 8'h32; reg16[4] = 8'h5B;
                reg16[5] = 8'h59;
                reg16[7] = (CS_HC >> 16) & 8'h3F; reg16[8] = (CS_HC >> 8) & 8'hFF;
                reg16[9] = CS_HC & 8'hFF;
                reg16[10] = 8'h7F; reg16[11] = 8'h80; reg16[12] = 8'h0A; reg16[13] = 8'h40;
                reg16[15] = 8'h01;
            end else begin
                reg16[0] = 8'h00; reg16[1] = 8'h26; reg16[3] = 8'h32; reg16[4] = 8'h5F;
                reg16[5] = 8'h59;                                   // READ_BL_LEN 9
                reg16[6] = 8'h80 | ((CS_SC >> 10) & 3);
                reg16[7] = (CS_SC >> 2) & 8'hFF;
                reg16[8] = ((CS_SC & 3) << 6) | 8'h3F;
                reg16[9] = 8'hFC | 8'h03;                           // C_SIZE_MULT 7
                reg16[10] = 8'hFF;
                reg16[15] = 8'h01;
            end
        end
    endtask

    // CMD24: 0 no write, 1 waiting for the token, 2 taking the data
    integer    wstate = 0, wcount = 0, wbase = 0;

    task answer(input [5:0] c);
        begin
            commands = commands + 1;
            arg = {frame[1], frame[2], frame[3], frame[4]};
            put(8'hFF);                                     // a byte of delay
            if (app && c == 6'd41) begin
                tries = tries + 1;
                if (tries > BUSY_TRIES) idle = 0;
                put(idle ? 8'h01 : 8'h00);
            end else case (c)
                6'd0:  begin idle = 1; tries = 0; put(8'h01); end
                6'd8:  begin put(8'h01); put(8'h00); put(8'h00);
                             put({4'h0, arg[11:8]}); put(arg[7:0]); end
                6'd55: put(idle ? 8'h01 : 8'h00);
                6'd58: begin put(idle ? 8'h01 : 8'h00);
                             put({1'b1, sdhc, 6'd0}); put(8'hFF); put(8'h80); put(8'h00); end
                6'd16: put(idle ? 8'h01 : 8'h00);
                6'd17: if (idle) put(8'h05);
                       else if (!sdhc && arg[8:0] != 0) put(8'h40);
                       else begin
                           put(8'h00);
                           put(8'hFF); put(8'hFF); put(8'hFF);
                           put(8'hFE);
                           base = sdhc ? arg * 512 : arg;
                           for (k = 0; k < 512; k = k + 1)
                               put((base + k < SIZE) ? mem[base + k] : 8'h00);
                           put(8'h12); put(8'h34);
                           data_end = qtail;
                           blocks_read = blocks_read + 1;
                       end
                6'd9, 6'd10:
                       if (idle) put(8'h05);
                       else begin
                           registers(c == 6'd9);
                           put(8'h00); put(8'hFF); put(8'hFE);
                           for (k = 0; k < 16; k = k + 1) put(reg16[k]);
                           put(8'h12); put(8'h34);
                       end
                6'd24: if (idle) put(8'h05);
                       else if (!sdhc && arg[8:0] != 0) put(8'h40);
                       else begin
                           put(8'h00);
                           wbase = sdhc ? arg * 512 : arg;
                           wstate = 1;
                       end
                default: put(idle ? 8'h05 : 8'h04);
            endcase
            app = (c == 6'd55);
        end
    endtask

    // ---------------------------------------------------------------- the wires
    reg [7:0] in, out = 8'hFF;
    reg [2:0] nbit = 0;

    assign miso = (!present || cs_n) ? 1'b1 : out[7];

    always @(negedge cs_n) begin
        nbit = 0; out = 8'hFF; nframe = 0;
    end
    always @(posedge cs_n) begin                        // deselected: what was left goes,
        if (data_end < 0) qhead = qtail;                // but not a block being sent
        wstate = 0;
    end

    always @(posedge sclk) if (present && !cs_n) begin
        in = {in[6:0], mosi};
        nbit = nbit + 1;
        if (nbit == 0) begin                            // a whole byte
            if (data_end >= 0) ;                        // sending a block: deaf
            else if (wstate == 1) begin                 // CMD24: the token?
                if (in == 8'hFE) begin wstate = 2; wcount = 0; end
            end else if (wstate == 2) begin             // CMD24: the data, the CRC
                if (wcount < 512 && wbase + wcount < SIZE) mem[wbase + wcount] = in;
                wcount = wcount + 1;
                if (wcount == 514) begin
                    wstate = 0;
                    blocks_written = blocks_written + 1;
                    put(8'hE5);                         // accepted
                    for (k = 0; k < 4; k = k + 1) put(8'h00);   // busy
                end
            end else if (nframe == 0 && in[7:6] != 2'b01) ;      // not a command: $FF and such
            else begin
                frame[nframe] = in;
                nframe = nframe + 1;
                if (nframe == 6) begin
                    nframe = 0;
                    answer(frame[0][5:0]);
                end
            end
        end
    end

    always @(negedge sclk) if (present && !cs_n) begin
        if (nbit == 0) begin
            if (qhead != qtail) begin out = q[qhead]; qhead = (qhead + 1) % 1024; end
            else out = 8'hFF;
            if (qhead == data_end) data_end = -1;       // the block is out
        end else
            out = {out[6:0], 1'b1};
    end
endmodule
