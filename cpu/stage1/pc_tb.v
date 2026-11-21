// pc_tb.v: tests pc.v.
//
//   make test-pc
// or by hand:
//   iverilog -g2005 -o pc_tb.vvp pc_tb.v pc.v
//   vvp pc_tb.vvp
//
// It checks reset, steps of 1 to 4 bytes, holding, load, load winning over step, a
// pending interrupt stopping the step (but not a load), and the wrap from FFFFFFFF to 0. Then it runs thousands of random ticks against a model.

`timescale 1ns/1ps

module pc_tb;
    reg clk = 0;
    always #18.5 clk = ~clk;              // 27 MHz

    reg         reset = 1;
    reg         load = 0, step = 0, irq_pending = 0;
    reg  [31:0] load_value = 0;
    reg  [2:0]  len = 1;
    wire [31:0] value;

    pc #(.RESET_PC(32'h0000_1000)) dut (
        .clk(clk), .reset(reset),
        .load(load), .load_value(load_value),
        .irq_pending(irq_pending),
        .step(step), .len(len),
        .value(value)
    );

    integer errors = 0;

    task expect(input [31:0] want, input [8*24-1:0] what);
        begin
            if (value !== want) begin
                errors = errors + 1;
                $display("%t %0s: PC %h, expected %h", $realtime, what, value, want);
            end
        end
    endtask

    // one tick with these inputs; returns right after the edge
    task tick(input r, input l, input [31:0] lv, input i, input s, input [2:0] n);
        begin
            reset <= r; load <= l; load_value <= lv; irq_pending <= i; step <= s; len <= n;
            @(posedge clk); #1;
        end
    endtask

    integer i;
    reg [31:0] model;
    integer seed = 3;

    initial begin
        tick(1, 0, 0, 0, 0, 1);           expect(32'h0000_1000, "reset");
        tick(0, 0, 0, 0, 1, 1);           expect(32'h0000_1001, "step 1");
        tick(0, 0, 0, 0, 1, 2);           expect(32'h0000_1003, "step 2");
        tick(0, 0, 0, 0, 1, 3);           expect(32'h0000_1006, "step 3");
        tick(0, 0, 0, 0, 1, 4);           expect(32'h0000_100A, "step 4");
        tick(0, 0, 0, 0, 0, 4);           expect(32'h0000_100A, "hold");
        tick(0, 1, 32'h0040_0020, 0, 0, 1); expect(32'h0040_0020, "load");
        tick(0, 1, 32'h0000_0300, 0, 1, 4); expect(32'h0000_0300, "load wins over step");
        tick(0, 0, 0, 1, 1, 2);           expect(32'h0000_0300, "interrupt: no step");
        tick(0, 0, 0, 1, 1, 4);           expect(32'h0000_0300, "interrupt: still none");
        tick(0, 1, 32'h0000_FF00, 1, 1, 4); expect(32'h0000_FF00, "interrupt: load works");
        tick(0, 0, 0, 0, 1, 2);           expect(32'h0000_FF02, "interrupt over: step");
        tick(0, 1, 32'hFFFF_FFFE, 0, 0, 1); expect(32'hFFFF_FFFE, "load near the top");
        tick(0, 0, 0, 0, 1, 3);           expect(32'h0000_0001, "wrap");
        tick(1, 1, 32'h1234_5678, 0, 1, 2); expect(32'h0000_1000, "reset wins");

        // random ticks against a model
        model = 32'h0000_1000;
        for (i = 0; i < 10000; i = i + 1) begin
            reset      <= ($random(seed) & 255) == 0;
            load       <= ($random(seed) & 15) == 0;
            load_value <= $random(seed);
            irq_pending <= ($random(seed) & 7) == 0;
            step       <= $random(seed);
            len        <= 1 + ($random(seed) & 3);
            #1;
            if (reset)     model = 32'h0000_1000;
            else if (load) model = load_value;
            else if (step & !irq_pending) model = model + len;
            @(posedge clk); #1;
            expect(model, "random");
        end

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
