// memaccess_tb.v: tests memaccess.v.
//
//   make test-memaccess
// or by hand:
//   iverilog -g2005 -o memaccess_tb.vvp memaccess_tb.v memaccess.v
//   vvp memaccess_tb.vvp
//
// The memory bus is played by a model: a memory of 64 KB that answers each access after
// 1 to 8 ticks with the bus's handshake (and checks that the inputs are held
// until d_ready). Stage 3 is played by the test bench: it sends instructions and
// holds them while stall is 1. Stage 5 is a list of what should come out, in order.
//
// First a few fixed cases: word, halfword and byte stores at every alignment, loads
// back signed and unsigned, an instruction that is not a load passing through. Then
// thousands of random instructions against a model of the memory.

`timescale 1ns/1ps

module memaccess_tb;
    reg clk = 0;
    always #18.5 clk = ~clk;              // 27 MHz

    localparam [1:0] BYTE = 2'b00, HALF = 2'b01, WORD = 2'b10;

    reg         reset = 1;
    reg         x_valid = 0, x_load = 0, x_store = 0, x_signed = 0, x_wen = 0;
    reg  [1:0]  x_size = 0;
    reg  [31:0] x_addr = 0, x_wdata = 0, x_result = 0;
    reg  [5:0]  x_rd = 0;
    reg         x2_wen = 0;
    reg  [1:0]  x2_sel = 0;
    reg  [31:0] x2_data = 0;
    wire        stall;

    wire        d_sel, d_we;
    wire [3:0]  d_be;
    wire [31:0] d_addr;
    wire [31:0] d_wdata;
    reg  [31:0] d_rdata = 0;
    reg         d_ready = 0;

    wire        m_valid, m_wen;
    wire [5:0]  m_rd;
    wire [31:0] m_data;
    wire        m2_wen;
    wire [1:0]  m2_sel;
    wire [31:0] m2_data;

    memaccess dut (
        .clk(clk), .reset(reset),
        .x_valid(x_valid), .x_load(x_load), .x_store(x_store), .x_size(x_size),
        .x_signed(x_signed), .x_addr(x_addr), .x_wdata(x_wdata), .x_wen(x_wen),
        .x_rd(x_rd), .x_result(x_result),
        .x2_wen(x2_wen), .x2_sel(x2_sel), .x2_data(x2_data), .stall(stall),
        .d_sel(d_sel), .d_we(d_we), .d_be(d_be), .d_addr(d_addr),
        .d_wdata(d_wdata), .d_rdata(d_rdata), .d_ready(d_ready),
        .m_valid(m_valid), .m_wen(m_wen), .m_rd(m_rd), .m_data(m_data),
        .m2_wen(m2_wen), .m2_sel(m2_sel), .m2_data(m2_data)
    );

    integer errors = 0, k, seed = 5;

    task expect(input [31:0] got, input [31:0] want, input [8*32-1:0] what);
        begin
            if (got !== want) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("%t %0s: got %h, expected %h", $realtime, what, got, want);
            end
        end
    endtask

    // ================================================================ the memory bus model
    reg [31:0] mem [0:16383];             // 64 KB: d_addr[15:2]
    integer wait_ticks = 0;
    reg        busy = 0;
    reg        h_we;
    reg [3:0]  h_be;
    reg [31:0] h_addr;
    reg [31:0] h_wdata;

    always @(posedge clk) begin
        d_ready <= 0;
        if (d_sel && !d_ready) begin
            if (!busy) begin              // a new access: remember it, pick a latency
                busy    <= 1;
                h_we    <= d_we;   h_be <= d_be;
                h_addr  <= d_addr; h_wdata <= d_wdata;
                wait_ticks = 1 + ($random(seed) & 7);
                if (wait_ticks == 1) answer;
                else wait_ticks = wait_ticks - 1;
            end else begin                // the inputs must be held
                if (d_we !== h_we || d_be !== h_be || d_addr !== h_addr ||
                    (d_we && d_wdata !== h_wdata)) begin
                    errors = errors + 1;
                    $display("%t bus inputs not held", $realtime);
                end
                if (wait_ticks == 1) answer;
                else wait_ticks = wait_ticks - 1;
            end
        end
        if (d_ready) busy <= 0;
    end

    task answer;                          // d_ready in the next tick
        begin
            d_ready <= 1;
            if (d_we) begin
                if (d_be[0]) mem[d_addr[15:2]][7:0]   <= d_wdata[7:0];
                if (d_be[1]) mem[d_addr[15:2]][15:8]  <= d_wdata[15:8];
                if (d_be[2]) mem[d_addr[15:2]][23:16] <= d_wdata[23:16];
                if (d_be[3]) mem[d_addr[15:2]][31:24] <= d_wdata[31:24];
                d_rdata <= 32'hxxxxxxxx;
            end else
                d_rdata <= mem[d_addr[15:2]];
        end
    endtask

    // ================================================================ stage 5: what should come out
    reg [31:0] want_data [0:65535];
    reg [5:0]  want_rd   [0:65535];
    reg        want_wen  [0:65535];
    reg        want_w2   [0:65535];
    reg [1:0]  want_s2   [0:65535];
    reg [31:0] want_d2   [0:65535];
    integer    n_sent = 0, n_got = 0;

    always @(posedge clk) begin
        #1;
        if (m_valid) begin
            if (n_got >= n_sent) begin
                errors = errors + 1;
                $display("%t an instruction came out that was never sent", $realtime);
            end else begin
                expect(m_wen, want_wen[n_got], "m_wen");
                expect(m_rd,  want_rd[n_got],  "m_rd");
                if (want_wen[n_got]) expect(m_data, want_data[n_got], "m_data");
                expect(m2_wen, want_w2[n_got], "m2_wen");
                if (want_w2[n_got]) begin
                    expect(m2_sel,  want_s2[n_got], "m2_sel");
                    expect(m2_data, want_d2[n_got], "m2_data");
                end
            end
            n_got = n_got + 1;
        end
    end

    // ================================================================ the reference memory
    reg [7:0] ref [0:65535];

    function [31:0] ref_load(input [31:0] a, input [1:0] size, input sgn);
        reg [15:0] h;
        begin
            case (size)
            BYTE:    ref_load = {{24{sgn & ref[a[15:0]][7]}}, ref[a[15:0]]};
            HALF:    begin
                         h = {ref[{a[15:1], 1'b1}], ref[{a[15:1], 1'b0}]};
                         ref_load = {{16{sgn & h[15]}}, h};
                     end
            default: ref_load = {ref[{a[15:2], 2'd3}], ref[{a[15:2], 2'd2}],
                                 ref[{a[15:2], 2'd1}], ref[{a[15:2], 2'd0}]};
            endcase
        end
    endfunction

    task ref_store(input [31:0] a, input [1:0] size, input [31:0] d);
        begin
            case (size)
            BYTE: ref[a[15:0]] = d[7:0];
            HALF: begin
                      ref[{a[15:1], 1'b0}] = d[7:0];
                      ref[{a[15:1], 1'b1}] = d[15:8];
                  end
            default: begin
                      ref[{a[15:2], 2'd0}] = d[7:0];
                      ref[{a[15:2], 2'd1}] = d[15:8];
                      ref[{a[15:2], 2'd2}] = d[23:16];
                      ref[{a[15:2], 2'd3}] = d[31:24];
                  end
            endcase
        end
    endtask

    // ================================================================ stage 3: send one instruction
    // kind: 0 = other (passes x_result), 1 = load, 2 = store
    task send(input integer kind, input [1:0] size, input sgn, input [31:0] a,
              input [31:0] d, input [5:0] rd, input wen);
        begin
            x_valid = 1; x_load = (kind == 1); x_store = (kind == 2);
            x_size = size; x_signed = sgn; x_addr = a; x_wdata = d;
            x_rd = rd; x_wen = wen; x_result = d;
            x2_wen = $random(seed); x2_sel = $random(seed); x2_data = $random(seed);
            want_w2[n_sent] = x2_wen; want_s2[n_sent] = x2_sel; want_d2[n_sent] = x2_data;
            // what stage 5 should get
            want_rd[n_sent]  = rd;
            want_wen[n_sent] = wen;
            want_data[n_sent] = (kind == 1) ? ref_load(a, size, sgn) : d;
            if (kind == 2) ref_store(a, size, d);
            n_sent = n_sent + 1;
            // stage 4 takes it at the first edge with stall = 0
            #1;
            while (stall) begin @(posedge clk); #1; end
            @(posedge clk); #1;
            x_valid = 0; x_load = 0; x_store = 0;
        end
    endtask

    task bubble;
        begin x_valid = 0; @(posedge clk); #1; end
    endtask

    integer i, kind;
    reg [1:0]  sz;
    reg [31:0] a;

    initial begin
        for (i = 0; i < 16384; i = i + 1) mem[i] = 0;
        for (i = 0; i < 65536; i = i + 1) ref[i] = 0;

        @(posedge clk); #1; reset = 0;

        // ---- a word, read back
        send(2, WORD, 0, 32'h100, 32'h8899AABB, 6'd0, 0);
        send(1, WORD, 0, 32'h100, 0, 6'd5, 1);
        // ---- halfwords at both places, loaded signed and unsigned
        send(2, HALF, 0, 32'h104, 32'h00008001, 6'd0, 0);
        send(2, HALF, 0, 32'h106, 32'h00007FFE, 6'd0, 0);
        send(1, HALF, 1, 32'h104, 0, 6'd6, 1);
        send(1, HALF, 0, 32'h104, 0, 6'd7, 1);
        send(1, HALF, 1, 32'h106, 0, 6'd8, 1);
        send(1, WORD, 0, 32'h104, 0, 6'd9, 1);
        // ---- bytes at all 4 places, loaded signed and unsigned
        for (i = 0; i < 4; i = i + 1)
            send(2, BYTE, 0, 32'h108 + i, 32'h7F + i, 6'd0, 0);
        for (i = 0; i < 4; i = i + 1) begin
            send(1, BYTE, 1, 32'h108 + i, 0, 6'd10 + i, 1);
            send(1, BYTE, 0, 32'h108 + i, 0, 6'd20 + i, 1);
        end
        send(1, WORD, 0, 32'h108, 0, 6'd30, 1);
        // ---- an instruction that is not a load or store passes x_result
        send(0, WORD, 0, 32'h0, 32'h12345678, 6'd31, 1);
        send(0, WORD, 0, 32'h0, 32'h0, 6'd1, 0);
        // ---- a special register as destination
        send(1, WORD, 0, 32'h100, 0, 6'b100001, 1);
        bubble; bubble;

        // ---- random instructions, now and then a bubble
        for (k = 0; k < 20000; k = k + 1) begin
            kind = $random(seed) % 3; if (kind < 0) kind = -kind;
            sz   = $random(seed) % 3; if (sz == 3) sz = WORD;
            a    = $random(seed) & 32'hFF;        // a small area: lots of overlap
            if (sz == HALF) a[0] = 0;
            if (sz == WORD) a[1:0] = 0;
            send(kind, sz, $random(seed), a, $random(seed), $random(seed),
                 kind != 2);
            if (($random(seed) & 7) == 0) bubble;
        end
        repeat (4) bubble;

        expect(n_got, n_sent, "instructions out");
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
