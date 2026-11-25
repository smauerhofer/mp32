// ch9350.v: the keyboard's module, for the test bench. It plays the CH9350L in
// working state 2 on the keyboard's side (the "lower computer"), as in chapter 21 of
// the book, but with both wires:
//
//   tx   to our kbd_rx: the frames of the chip (57 AB 01 + 8 bytes for the keyboard,
//        57 AB 02 + 4 for the mouse, 57 AB 80 + 1, 57 AB 86, 57 AB 89), or any byte
//        the test bench wants, even without its stop bit
//   rx   from our kbd_tx: it takes every byte, cuts them into frames 57 AB 12 + 8
//        bytes, checks each against what an upper computer sends
//          57 AB 12 00 00 00 00 LED 07 AC 20      (LED: bits 2..0, the rest 0)
//        and answers, as the chip does, 57 AB 80 3N with N the LEDs (after ANSWER ns)
//
// The test bench sends with the tasks below. Every task that puts bytes on tx takes
// the wire for the whole frame (lock), so that an answer never cuts into a frame.
// bit_ns is the length of a bit the chip sends, which the test bench may change
// (3 % fast, 3 % slow); rx_bit_ns the one it expects from us.

`timescale 1ns/1ps

module ch9350 (
    output reg  tx = 1,
    input  wire rx
);
    real    bit_ns    = 1.0e9 / 115200.0;
    real    rx_bit_ns = 1.0e9 / 115200.0;
    integer ANSWER    = 300_000;        // 0.3 ms before the answer to a keep-alive
    reg     answers   = 1;              // 0: it never answers

    // ================================================================ sending
    reg lock = 0;

    task automatic take_wire;
        begin
            while (lock) #1000;
            lock = 1;
        end
    endtask

    task automatic give_wire;
        lock = 0;
    endtask

    task automatic raw_byte(input [7:0] value, input stop);
        integer b;
        begin
            tx = 0;
            #(bit_ns);
            for (b = 0; b < 8; b = b + 1) begin
                tx = value[b];
                #(bit_ns);
            end
            tx = stop;
            #(bit_ns);
            tx = 1;
            if (!stop) #(2 * bit_ns);   // back at 1 for a while: the receiver starts over
        end
    endtask

    task automatic send_byte(input [7:0] value);
        raw_byte(value, 1'b1);
    endtask

    // Bytes that begin no frame, or a byte without its stop bit.
    task automatic junk(input [7:0] value);
        begin take_wire; send_byte(value); give_wire; end
    endtask

    task automatic no_stop(input [7:0] value);
        begin take_wire; raw_byte(value, 1'b0); give_wire; end
    endtask

    // 57 AB and its kind, nothing after.
    task automatic short_frame(input [7:0] kind);
        begin
            take_wire;
            send_byte(8'h57); send_byte(8'hAB); send_byte(kind);
            give_wire;
        end
    endtask

    // 57 AB 80 and its byte.
    task automatic status(input [7:0] value);
        begin
            take_wire;
            send_byte(8'h57); send_byte(8'hAB); send_byte(8'h80); send_byte(value);
            give_wire;
        end
    endtask

    // A report of the keyboard, the modifiers first (bits 63..56), sent times times.
    task automatic keyboard(input [63:0] report, input integer times);
        integer t, k;
        begin
            for (t = 0; t < times; t = t + 1) begin
                take_wire;
                send_byte(8'h57); send_byte(8'hAB); send_byte(8'h01);
                for (k = 7; k >= 0; k = k - 1) send_byte(report[8 * k +: 8]);
                give_wire;
            end
        end
    endtask

    // The first n bytes of a keyboard frame, and nothing more: a frame cut short.
    task automatic cut_frame(input integer n);
        integer k;
        begin
            take_wire;
            send_byte(8'h57); send_byte(8'hAB); send_byte(8'h01);
            for (k = 0; k < n; k = k + 1) send_byte(8'h00);
            give_wire;
        end
    endtask

    // A report of the mouse: buttons, dx, dy, wheel.
    task automatic mouse(input [7:0] buttons, input [7:0] dx, input [7:0] dy,
                         input [7:0] wheel);
        begin
            take_wire;
            send_byte(8'h57); send_byte(8'hAB); send_byte(8'h02);
            send_byte(buttons); send_byte(dx); send_byte(dy); send_byte(wheel);
            give_wire;
        end
    endtask

    // ================================================================ receiving
    reg  [7:0] got [0:10];              // the frame coming in
    integer    nbytes  = 0;             // bytes taken in the frame
    integer    frames  = 0;             // good keep-alives received
    integer    bad     = 0;             // bytes or frames that were wrong
    integer    all     = 0;             // every byte received
    reg  [2:0] leds    = 0;             // the LEDs of the last good keep-alive
    reg  [7:0] b;
    integer    i;
    reg        to_answer = 0;

    // What byte k of a keep-alive must be, with its LEDs l.
    function [7:0] want(input integer k, input [7:0] l);
        case (k)
            0: want = 8'h57;  1: want = 8'hAB;  2: want = 8'h12;
            7: want = l;      8: want = 8'h07;  9: want = 8'hAC;  10: want = 8'h20;
            default: want = 8'h00;
        endcase
    endfunction

    always begin
        @(negedge rx);
        #(rx_bit_ns / 2);
        if (rx !== 1'b0) begin
            bad = bad + 1;
            $display("%t module: a start bit shorter than half a bit", $realtime);
        end else begin
            for (i = 0; i < 8; i = i + 1) begin
                #(rx_bit_ns);
                b[i] = rx;
            end
            #(rx_bit_ns);
            if (rx !== 1'b1) begin
                bad = bad + 1;
                $display("%t module: no stop bit", $realtime);
            end
            all = all + 1;
            got[nbytes] = b;
            // The frame, byte by byte: the LED byte may hold 0..7, the rest is fixed.
            if (nbytes == 7 ? (b[7:3] != 0) : (b != want(nbytes, 0))) begin
                bad = bad + 1;
                $display("%t module: byte %0d of a keep-alive is %h", $realtime, nbytes, b);
                nbytes = 0;
            end else if (nbytes == 10) begin
                nbytes = 0;
                frames = frames + 1;
                leds   = got[7][2:0];
                if (answers) to_answer = 1;
            end else
                nbytes = nbytes + 1;
        end
    end

    // The answer, ANSWER ns after the keep-alive: 57 AB 80 3N, with the LEDs of the
    // last keep-alive when the wire is free. A keep-alive that comes while an answer
    // waits for the wire is answered after it.
    always begin
        wait (to_answer);
        #(ANSWER);
        while (lock) #1000;
        to_answer = 0;
        status({5'b00110, leds});
    end
endmodule
