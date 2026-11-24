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
        begin
            for (i = 0; i < SIZE; i = i + 1) mem[i] = 8'h00;
            fd = $fopen(name, "rb");
            if (fd == 0) begin $display("sd_model: cannot open %0s", name); $finish; end
            n = $fread(mem, fd);
            $fclose(fd);
        end
    endtask

    // what it was asked, for the test bench
    integer commands = 0, blocks_read = 0;

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
                           blocks_read = blocks_read + 1;
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
    always @(posedge cs_n) qhead = qtail;              // deselected: what was left goes

    always @(posedge sclk) if (present && !cs_n) begin
        in = {in[6:0], mosi};
        nbit = nbit + 1;
        if (nbit == 0) begin                            // a whole byte
            if (nframe == 0 && in[7:6] != 2'b01) ;      // not a command: $FF and such
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
        end else
            out = {out[6:0], 1'b1};
    end
endmodule
