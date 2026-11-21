// core_tb.v: checks core.v (the top for the timing) before it goes to the chip: it
// runs ../stage2/lisp.s (as lisp_lines.hex in the code RAM) and checks the results,
// as stage2/lisp_tb.v does. So the wiring of the stages and the two block RAMs is right.
//
//   make test

`timescale 1ns/1ps

module core_tb;
    reg clk = 0;
    always #7.9 clk = ~clk;              // 63 MHz

    wire [5:0] led;
    top #(.CODE("../lisp_lines.hex")) dut (.clk(clk), .led(led));

    integer errors = 0;
    task expect(input [8*24-1:0] what, input [31:0] got, input [31:0] want);
        if (got !== want) begin
            errors = errors + 1;
            $display("%0s: got %h, expected %h", what, got, want);
        end
    endtask

    initial begin
        repeat (3000) @(posedge clk);
        #1;
        expect("r2: the sum, fixnum",    dut.dec.regs.regs[2], 32'd24);
        expect("r5: the sum untagged",   dut.dec.regs.regs[5], 32'd6);
        expect("r7: GC handler runs",    dut.dec.regs.regs[7], 32'd1);
        expect("r4 bit 3: TADD's V",     {31'h0, dut.dec.regs.regs[4][3]}, 32'd1);
        expect("r6: car after RPLACA",   dut.dec.regs.regs[6], 32'd40);
        expect("r8: the car of the cdr", dut.dec.regs.regs[8], 32'd8);
        expect("r9: HLIM was raised",    dut.dec.regs.regs[9], 32'd1);
        expect("cell $110 car",          dut.data.ram[9'h11][31:0], 32'd40);
        expect("cell $110 cdr",          dut.data.ram[9'h11][63:32], 32'h109);
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
