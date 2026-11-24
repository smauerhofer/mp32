// flash_model.v: a model of the board's SPI flash (W25Q64 / XT25F64 class), for the
// test benches. Only what the boot loader uses:
//
//   $AB          release from deep power-down (taken, nothing more)
//   $03 a2 a1 a0 READ: from the 24-bit address on, one byte after the other while CS
//                stays low
//
// SPI mode 0: MOSI taken at the rising edge of SCLK, MISO changed at the falling edge
// (and when CS goes low: the first bit is out before the first rising edge).
//
// The flash holds SIZE bytes from BASE on; everything else reads $FF, as an erased
// flash. A test bench fills mem[] (load from a file, or erase) and may set present = 0
// for no flash at all (MISO stays high).

`timescale 1ns/1ps

module flash_model #(
    parameter [23:0] BASE = 24'h400000,
    parameter        SIZE = 65536
) (
    input  wire sclk,
    input  wire cs_n,
    input  wire mosi,
    output wire miso
);
    reg [7:0] mem [0:SIZE-1];
    reg       present = 1;

    integer i;
    task erase;
        for (i = 0; i < SIZE; i = i + 1) mem[i] = 8'hFF;
    endtask

    // the bytes of a file from BASE on (the rest erased); the number read
    integer fd, n;
    task load(input [8*256-1:0] name);
        begin
            erase;
            fd = $fopen(name, "rb");
            if (fd == 0) begin $display("flash_model: cannot open %0s", name); $finish; end
            n = $fread(mem, fd);
            $fclose(fd);
        end
    endtask

    initial erase;

    reg  [7:0]  in, out;
    reg  [2:0]  nbit;            // bits of the current byte taken so far
    reg  [2:0]  nbyte;           // bytes of the command so far (up to 4)
    reg  [7:0]  cmd;
    reg  [23:0] addr;
    reg         reading;

    assign miso = (!present || cs_n) ? 1'b1 : out[7];

    function [7:0] at(input [23:0] a);
        at = (a >= BASE && a < BASE + SIZE) ? mem[a - BASE] : 8'hFF;
    endfunction

    always @(negedge cs_n) begin
        nbit = 0; nbyte = 0; reading = 0; out = 8'hFF;
    end

    always @(posedge sclk) if (!cs_n) begin
        in = {in[6:0], mosi};
        nbit = nbit + 1;
        if (nbit == 0) begin                        // a whole byte
            if (nbyte == 0) cmd = in;
            else if (nbyte <= 3) addr = {addr[15:0], in};
            if (nbyte < 4) nbyte = nbyte + 1;
            if (cmd == 8'h03 && nbyte == 4 && !reading) reading = 1;
        end
    end

    // after the last falling edge of a byte: the next byte out
    always @(negedge sclk) if (!cs_n) begin
        if (nbit == 0) begin
            if (reading) begin out = at(addr); addr = addr + 1; end
            else out = 8'hFF;
        end else
            out = {out[6:0], 1'b1};
    end
endmodule
