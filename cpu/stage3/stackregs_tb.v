// stackregs_tb.v: tests stackregs.v.
//
//   make test-stackregs
// or by hand:
//   iverilog -g2005 -o stackregs_tb.vvp stackregs_tb.v stackregs.v
//   vvp stackregs_tb.vvp
//
// First a few fixed cases: SET of each register, pushes and pops (post-decrement,
// pre-increment), FP as a base with positive and negative offsets, ADD, en = 0 and
// sel = 11 changing nothing, ENTER and LEAVE. Then thousands of random ticks against
// a model.

`timescale 1ns/1ps

module stackregs_tb;
    reg clk = 0;
    always #18.5 clk = ~clk;              // 27 MHz

    localparam [1:0] PSP = 2'd0, RSP = 2'd1, FP = 2'd2, NONE = 2'd3;
    localparam [2:0] BASE = 3'd0, PUSH = 3'd1, POP = 3'd2, SET = 3'd3, ADD = 3'd4,
                     ENTER = 3'd5, LEAVE = 3'd6;

    reg         en = 0;
    reg  [1:0]  sel = 0;
    reg  [2:0]  op = 0;
    reg  [31:0] offset = 0, w_data = 0;
    wire [31:0] value, addr, psp, rsp, fp;

    stackregs dut (
        .clk(clk), .en(en), .sel(sel), .op(op), .offset(offset), .w_data(w_data),
        .value(value), .addr(addr), .psp(psp), .rsp(rsp), .fp(fp)
    );

    // ---- the model
    reg [31:0] m [0:2];
    integer errors = 0, k;
    integer seed = 23;

    function [31:0] m_value(input [1:0] s);
        m_value = (s == NONE) ? 0 : m[s];
    endfunction

    function [31:0] m_addr(input [1:0] s, input [2:0] o);
        case (o)
            PUSH:    m_addr = m_value(s);
            POP:     m_addr = m_value(s) + 4;
            ENTER:   m_addr = m[1];
            LEAVE:   m_addr = m[2] + 4;
            default: m_addr = m_value(s) + offset;
        endcase
    endfunction

    function [31:0] m_next(input [1:0] s, input [2:0] o);
        case (o)
            PUSH:    m_next = m_value(s) - 4;
            POP:     m_next = m_value(s) + 4;
            SET:     m_next = w_data;
            ADD:     m_next = m_value(s) + offset;
            default: m_next = m_value(s);
        endcase
    endfunction

    task expect(input [31:0] got, input [31:0] want, input [8*32-1:0] what);
        begin
            if (got !== want) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("%t %0s: got %h, expected %h", $realtime, what, got, want);
            end
        end
    endtask

    task check_outputs;
        begin
            expect(value, m_value(sel), "value");
            if (op != SET) expect(addr, m_addr(sel, op), "addr");
            expect(psp, m[0], "PSP");
            expect(rsp, m[1], "RSP");
            expect(fp,  m[2], "FP");
        end
    endtask

    task edge_;
        begin
            @(posedge clk);
            if (en && op == ENTER)      begin m[2] = m[1] - 4; m[1] = m[1] - 4 - offset; end
            else if (en && op == LEAVE) begin m[1] = m[2] + 4; m[2] = w_data; end
            else if (en && sel != NONE) m[sel] = m_next(sel, op);
            #1;
        end
    endtask

    // one instruction: set the inputs, check, take the edge
    task do_op(input [1:0] s, input [2:0] o, input [31:0] off, input [31:0] wd);
        begin
            en = 1; sel = s; op = o; offset = off; w_data = wd; #1;
            check_outputs;
            edge_;
            en = 0;
        end
    endtask

    initial begin
        m[0] = 0; m[1] = 0; m[2] = 0;

        // ---- after loading, all 0
        #1; expect(psp | rsp | fp, 0, "after loading");

        // ---- SET each one
        do_op(PSP, SET, 0, 32'h0010_0000);
        do_op(RSP, SET, 0, 32'h0020_0000);
        do_op(FP,  SET, 0, 32'h0030_0000);
        expect(psp, 32'h0010_0000, "PSP set");
        expect(rsp, 32'h0020_0000, "RSP set");
        expect(fp,  32'h0030_0000, "FP set");

        // ---- push: store at the pointer, then pointer - 4
        en = 1; sel = PSP; op = PUSH; #1;
        expect(addr, 32'h0010_0000, "push address");
        edge_; en = 0;
        expect(psp, 32'h000F_FFFC, "PSP after push");
        do_op(PSP, PUSH, 0, 0);
        expect(psp, 32'h000F_FFF8, "PSP after 2 pushes");

        // ---- pop: pointer + 4, then load from it: gets the last word pushed
        en = 1; sel = PSP; op = POP; #1;
        expect(addr, 32'h000F_FFFC, "pop address");
        edge_; en = 0;
        expect(psp, 32'h000F_FFFC, "PSP after pop");
        en = 1; sel = PSP; op = POP; #1;
        expect(addr, 32'h0010_0000, "second pop address");
        edge_; en = 0;
        expect(psp, 32'h0010_0000, "PSP back where it started");

        // RSP and FP untouched
        expect(rsp, 32'h0020_0000, "RSP untouched");
        expect(fp,  32'h0030_0000, "FP untouched");

        // ---- FP as a base with offsets, FP unchanged
        en = 0; sel = FP; op = BASE; offset = 32'd8; #1;
        expect(addr, 32'h0030_0008, "FP + 8");
        offset = -32'd12; #1;
        expect(addr, 32'h002F_FFF4, "FP - 12");
        do_op(FP, BASE, -32'd12, 0);
        expect(fp, 32'h0030_0000, "FP unchanged by BASE");

        // ---- ADD: reserve 16 bytes on the return stack, free them again
        do_op(RSP, ADD, -32'd16, 0);
        expect(rsp, 32'h001F_FFF0, "RSP - 16");
        do_op(RSP, ADD, 32'd16, 0);
        expect(rsp, 32'h0020_0000, "RSP + 16");

        // ---- en = 0 changes nothing
        en = 0; sel = PSP; op = PUSH; edge_;
        expect(psp, 32'h0010_0000, "no change without en");

        // ---- sel = 11 changes nothing
        do_op(NONE, SET, 0, 32'hFFFF_FFFF);
        expect(psp, 32'h0010_0000, "PSP after sel 11");
        expect(rsp, 32'h0020_0000, "RSP after sel 11");
        expect(fp,  32'h0030_0000, "FP after sel 11");

        // ---- ENTER 16, LEAVE: back to where it was
        do_op(PSP, ENTER, 32'd16, 0);
        expect(rsp, 32'h0020_0000 - 4 - 16, "RSP after ENTER 16");
        expect(fp,  32'h0020_0000 - 4,      "FP after ENTER 16");
        do_op(NONE, LEAVE, 0, 32'h0030_0000);
        expect(rsp, 32'h0020_0000, "RSP after LEAVE");
        expect(fp,  32'h0030_0000, "FP after LEAVE");

        // ---- random ticks against the model
        for (k = 0; k < 20000; k = k + 1) begin
            en     = ($random(seed) & 3) != 0;
            sel    = $random(seed);
            op     = $random(seed);
            offset = $random(seed) % 256;
            w_data = $random(seed);
            #1;
            check_outputs;
            edge_;
        end

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
