// echo.v: a first test of the serial port on the board, without the processor.
//
//   A small state machine takes the processor's place on the I/O bus of uart.v. It
//   writes a greeting, then reads DATA again and again; every byte that comes is
//   written back, so whatever you type in the terminal on the PC comes back to it.
//   Enter (CR) comes back as CR LF. The six LEDs show the low six bits of the last
//   byte (an LED is lit for a 1).
//
//   It runs on the board's 27 MHz clock, without a PLL: DIV = 234 ticks a bit,
//   115,385 baud, 0.16 % fast, which the PC takes for 115,200.
//
//   make flash-echo, then on the PC a terminal on the board's COM port at 115200 8N1
//   (PuTTY, Tera Term, or python -m serial.tools.miniterm COM5 115200).
//
// The access: hold sel and the rest until io_ready, which ends it (see uart.v). The
// state only changes in a tick with io_ready, so the outputs stay put in between.

module top (
    input  wire       clk,              // 27 MHz
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [5:0] led               // lit at 0
);
    // ================================================================ reset at power-on
    reg [3:0] boot  = 0;
    wire      reset = (boot != 4'hF);
    always @(posedge clk)
        if (reset) boot <= boot + 1'b1;

    // ================================================================ the serial port
    reg         io_we;
    reg  [3:2]  io_addr;
    reg  [31:0] io_wdata;
    wire [31:0] io_rdata;
    wire        io_ready;
    wire        io_sel = ~reset;

    uart #(.DIV_INIT(16'd234)) port (
        .clk(clk), .reset(reset),
        .io_sel(io_sel), .io_we(io_we), .io_be(4'hF), .io_addr(io_addr),
        .io_wdata(io_wdata), .io_rdata(io_rdata), .io_ready(io_ready),
        .irq(), .uart_rx(uart_rx), .uart_tx(uart_tx)
    );

    // ================================================================ the greeting
    localparam LEN = 18;
    function [7:0] greeting(input [4:0] i);
        case (i)
            0: greeting = "m";  1: greeting = "p";  2: greeting = "3";  3: greeting = "2";
            4: greeting = " ";  5: greeting = "s";  6: greeting = "e";  7: greeting = "r";
            8: greeting = "i";  9: greeting = "a"; 10: greeting = "l"; 11: greeting = " ";
           12: greeting = "p"; 13: greeting = "o"; 14: greeting = "r"; 15: greeting = "t";
           16: greeting = 8'h0D;
           default: greeting = 8'h0A;
        endcase
    endfunction

    // ================================================================ the state machine
    localparam GREET = 2'd0, POLL = 2'd1, ECHO = 2'd2, LF = 2'd3;
    localparam R_DATA = 2'd0;

    reg [1:0] state = GREET;
    reg [4:0] i     = 0;
    reg [7:0] ch    = 0;

    always @(*) begin
        io_addr = R_DATA;
        case (state)
            GREET:   begin io_we = 1; io_wdata = {24'd0, greeting(i)}; end
            POLL:    begin io_we = 0; io_wdata = 0;                    end
            ECHO:    begin io_we = 1; io_wdata = {24'd0, ch};          end
            default: begin io_we = 1; io_wdata = 32'h0A;               end
        endcase
    end

    always @(posedge clk) begin
        if (reset) begin
            state <= GREET;
            i     <= 0;
        end else if (io_ready) begin
            case (state)
                GREET: begin
                    i <= i + 1'b1;
                    if (i == LEN - 1) state <= POLL;
                end
                POLL:
                    if (io_rdata[8]) begin           // VALID: a byte came
                        ch    <= io_rdata[7:0];
                        state <= ECHO;
                    end
                ECHO:
                    state <= (ch == 8'h0D) ? LF : POLL;
                LF:
                    state <= POLL;
            endcase
        end
    end

    assign led = ~ch[5:0];
endmodule
