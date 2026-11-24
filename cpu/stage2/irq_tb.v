// irq_tb.v: a test of interrupts and exceptions through the whole processor (cpu.v),
// on a real program (irq.s, assembled into irq.hex).
//
//   make test-irq
//
// Two processors run the same program, each with its own memory (code: irq.hex,
// answering line reads after 1 to 8 ticks; data: 8 KB, answering after 1 to 4 ticks):
//
//   quiet   no interrupts
//   busy    two devices that ask for an interrupt at random, on lines 0 and 1 of the
//           interrupt controller (../irqc.v, at DEV + 16: vectors 16 and 17, line 0
//           of the higher priority). A device asks again only after its handler has
//           told it it is done (a store to DEV + 0 / DEV + 4); it may ask again while
//           its handler still runs.
//
// Both have device 2 (line 2, vector 18): a timer the program starts with a store of a
// number of ticks to DEV + 32; when they have passed it asks, until its handler stores
// to DEV + 36. The program waits for it with WAIT, with I = 1 and with I = 0.
//
// The program also does a system call (INTR 48), runs an undefined opcode (exception
// 1) and EXC 3, traps from CONS (exception 4), has a critical section (PUSHF, CLI ..
// POPF, with one nested in it), raises the stack exceptions 8 .. 11 on purpose, and
// moves VEC to a second table halfway (see irq.s). Checked at the end:
//   - both processors end with the same registers (r0 .. r15, T, S, R, L, PSP, RSP, FP,
//     the flags, VEC) and the same memory (but for the free parts of the stacks, where
//     the handlers push): an interrupt changes nothing the program can see;
//   - the results irq.s lists (r10, r11, r12, r13; r16, r17, r30, r31, the stack
//     exceptions; r18, device 2) in both;
//   - busy: every interrupt asked for was handled once (r20, r24 and the stores to
//     DEV + 0 / + 4 equal what the devices asked for), none in the critical section
//     and no vector that should not be used (no store to DEV + 12);
//   - nesting: the handlers set I again while they wait; device 0 interrupted device
//     1's handler often (r23), never the other way round, and no handler was
//     interrupted by its own device (the handlers check: a store to DEV + 12); the
//     controller ends with nothing in service;
//   - enough interrupts were taken, and some INTR were turned down in execute (I = 0
//     by then, or the device already served), to show those cases were tried.

`timescale 1ns/1ps

module irq_tb;
    reg clk = 0;
    always #18.5 clk = ~clk;              // 27 MHz
    reg reset = 1;

    parameter MAX_TICKS = 1500000;

    wire quiet_done, busy_done, quiet_error, busy_error;
    wire [31:0] busy_raised0, busy_raised1, busy_acked0, busy_acked1;
    wire [31:0] busy_taken, busy_refused;

    irq_tb_system #(.SEED(3), .INTERRUPTS(0)) quiet (
        .clk(clk), .reset(reset), .done(quiet_done), .error(quiet_error),
        .raised0(), .raised1(), .acked0(), .acked1(), .taken(), .refused()
    );
    irq_tb_system #(.SEED(7), .INTERRUPTS(1)) busy (
        .clk(clk), .reset(reset), .done(busy_done), .error(busy_error),
        .raised0(busy_raised0), .raised1(busy_raised1),
        .acked0(busy_acked0), .acked1(busy_acked1),
        .taken(busy_taken), .refused(busy_refused)
    );

    integer errors = 0, ticks = 0, k;
    task expect(input [8*40-1:0] what, input [31:0] got, input [31:0] want);
        if (got !== want) begin
            errors = errors + 1;
            $display("%0s: got %h, expected %h", what, got, want);
        end
    endtask

    always @(posedge clk) ticks = ticks + 1;

    initial begin
        repeat (3) @(posedge clk);
        #1 reset = 0;
        while (!(quiet_done && busy_done) && ticks < MAX_TICKS) @(posedge clk);
        if (!(quiet_done && busy_done)) begin
            errors = errors + 1;
            $display("the program did not end: quiet %b, busy %b (pc %h, %h)",
                     quiet_done, busy_done, quiet.pc, busy.pc);
        end
        repeat (300) @(posedge clk);      // the last interrupts are handled

        // ---- the same in both
        for (k = 0; k < 16; k = k + 1)
            if (quiet.processor.dec.regs.regs[k] !== busy.processor.dec.regs.regs[k]) begin
                errors = errors + 1;
                $display("r%0d: quiet %h, busy %h", k, quiet.processor.dec.regs.regs[k],
                         busy.processor.dec.regs.regs[k]);
            end
        expect("T",     busy.t,     quiet.t);
        expect("S",     busy.s,     quiet.s);
        expect("R",     busy.r,     quiet.r);
        expect("L",     busy.l,     quiet.l);
        expect("PSP",   busy.psp,   quiet.psp);
        expect("RSP",   busy.rsp,   quiet.rsp);
        expect("FP",    busy.fp,    quiet.fp);
        expect("flags", busy.flags, quiet.flags);
        expect("VEC",   busy.processor.ex.vec, quiet.processor.ex.vec);
        expect("I",     busy.ie,    quiet.ie);
        // (not the free parts of the stacks, below PSP and RSP: the handlers push there)
        for (k = 0; k < 2048; k = k + 1)
            if (!(k * 4 >= 32'h400 && k * 4 <= quiet.psp) && !(k * 4 >= 32'h600 && k * 4 <= quiet.rsp) &&
                quiet.dmem[k] !== busy.dmem[k]) begin
                errors = errors + 1;
                if (errors < 20) $display("memory %h: quiet %h, busy %h", k * 4, quiet.dmem[k], busy.dmem[k]);
            end

        for (k = 16; k < 32; k = k + 1)                                     // the main program's
            if ((k < 20 || k >= 30) &&                                       // (not the handlers')
                quiet.processor.dec.regs.regs[k] !== busy.processor.dec.regs.regs[k]) begin
                errors = errors + 1;
                $display("r%0d: quiet %h, busy %h", k, quiet.processor.dec.regs.regs[k],
                         busy.processor.dec.regs.regs[k]);
            end

        // ---- the results of the program
        expect("r16: PSP overflow",      quiet.processor.dec.regs.regs[16], 32'd1);
        expect("r17: PSP underflow",     quiet.processor.dec.regs.regs[17], 32'd1);
        expect("r30: RSP overflow",      quiet.processor.dec.regs.regs[30], 32'd2);
        expect("r31: RSP underflow",     quiet.processor.dec.regs.regs[31], 32'd1);
        expect("r18: device 2 (WAIT)",   quiet.processor.dec.regs.regs[18], 32'd2);
        expect("limits off at the end",  quiet.processor.ex.pspl | quiet.processor.ex.psph |
                                         quiet.processor.ex.rspl | quiet.processor.ex.rsph, 32'h0);
        expect("r10: undefined opcodes", quiet.processor.dec.regs.regs[10], 32'd19);
        expect("r11: EXC 3",             quiet.processor.dec.regs.regs[11], 32'd19);
        expect("r12: VEC read back",     quiet.processor.dec.regs.regs[12], 32'h400);
        expect("r13: system calls",      quiet.processor.dec.regs.regs[13], 32'd4510);
        expect("I at the end",           quiet.ie, 1'b1);

        // ---- the interrupts
        expect("quiet: error store",     quiet_error, 1'b0);
        expect("busy: error store",      busy_error, 1'b0);
        expect("quiet: r20",             quiet.processor.dec.regs.regs[20], 32'd0);
        expect("busy: device 0 done",    busy_acked0, busy_raised0);
        expect("busy: device 1 done",    busy_acked1, busy_raised1);
        expect("busy: r20 (device 0)",   busy.processor.dec.regs.regs[20], busy_raised0);
        expect("busy: r24 (device 1)",   busy.processor.dec.regs.regs[24], busy_raised1);
        expect("busy: INTR taken",       busy_taken, busy_raised0 + busy_raised1 + 2);   // + device 2
        expect("busy: in service at the end", busy.irq_ctrl.isr, 8'h00);
        expect("busy: MASK",             busy.irq_ctrl.mask, 8'h07);
        expect("quiet: device 2 done",   quiet.acked2, 32'd2);
        expect("busy: device 2 done",    busy.acked2, 32'd2);
        if (busy.processor.dec.regs.regs[23] < 20) begin
            errors = errors + 1;
            $display("busy: device 0 interrupted device 1's handler only %0d times",
                     busy.processor.dec.regs.regs[23]);
        end

        $display("busy: %0d + %0d interrupts, %0d INTR taken, %0d turned down, %0d nested; %0d ticks",
                 busy_raised0, busy_raised1, busy_taken, busy_refused,
                 busy.processor.dec.regs.regs[23], ticks);
        if (busy_raised0 + busy_raised1 < 200 || busy_refused < 2) begin
            errors = errors + 1;
            $display("too few interrupts, or none turned down");
        end

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule

// One processor with its memory and the two devices.
module irq_tb_system #(
    parameter SEED       = 1,
    parameter INTERRUPTS = 1
) (
    input  wire        clk,
    input  wire        reset,
    output reg         done,               // the program stored to DEV + 8
    output reg         error,              // the program stored to DEV + 12
    output reg  [31:0] raised0, raised1,   // interrupts the devices asked for
    output reg  [31:0] acked0, acked1,     // handlers that told their device they are done
    output reg  [31:0] taken, refused      // INTR from a device: taken, turned down in execute
);
    localparam [31:0] DEV = 32'h800;
    integer seed = SEED;

    // ---- the devices (2: the timer the program starts)
    reg  [2:0] pend;
    reg  [31:0] timer;
    reg  [31:0] acked2;

    // ---- the processor
    wire         line_sel, data_sel, data_we;
    wire [31:4]  line_addr;
    reg  [127:0] line_data = 0;
    reg          line_ready = 0;
    wire [3:0]   data_be;
    wire [31:0]  data_addr, data_wdata;
    reg  [31:0]  data_rdata = 0;
    reg          data_ready = 0;
    wire [31:0]  pc, t, s, r, l, psp, rsp, fp;
    wire [3:0]   flags;
    wire         ie;
    wire         irq, irq_ack;
    wire [7:0]   irq_num, irq_ack_num;

    cpu #(.RESET_PC(32'h0), .VEC_RESET(32'h0)) processor (
        .clk(clk), .reset(reset), .irq(irq), .irq_num(irq_num),
        .irq_ack(irq_ack), .irq_ack_num(irq_ack_num),
        .line_sel(line_sel), .line_addr(line_addr), .line_data(line_data),
        .line_ready(line_ready),
        .data_sel(data_sel), .data_we(data_we), .data_be(data_be), .data_addr(data_addr),
        .data_wdata(data_wdata), .data_rdata(data_rdata), .data_ready(data_ready),
        .pc(pc), .t(t), .s(s), .r(r), .l(l), .psp(psp), .rsp(rsp), .fp(fp),
        .flags(flags), .ie(ie)
    );

    // ---- the code: 2 KB
    reg [7:0] cmem [0:2047];
    initial $readmemh("../irq.hex", cmem);

    integer cwait = -1, i;
    always @(posedge clk) begin
        line_ready <= 0;
        if (line_sel && !line_ready) begin
            if (cwait < 0) cwait = $random(seed) & 7;
            if (cwait == 0) begin
                for (i = 0; i < 16; i = i + 1)
                    line_data[8*i +: 8] <= cmem[{line_addr[10:4], 4'h0} + i];
                line_ready <= 1; cwait = -1;
            end else cwait = cwait - 1;
        end
    end

    // ---- the data: 8 KB, and the devices at DEV
    reg [31:0] dmem [0:2047];
    integer    dwait = -1;
    initial for (i = 0; i < 2048; i = i + 1) dmem[i] = 0;

    wire is_dev  = (data_addr[31:4] == DEV[31:4]);
    wire is_irqc = (data_addr[31:4] == DEV[31:4] + 28'd1);     // DEV + 16
    wire is_dev2 = (data_addr[31:4] == DEV[31:4] + 28'd2);     // DEV + 32

    // ---- the interrupt controller: its registers at DEV + 16. A write goes to it once,
    // in the tick after the access ends (irqc_wr); a read takes its io_rdata.
    reg         irqc_wr = 0;
    reg  [1:0]  irqc_wa = 0;
    reg  [3:0]  irqc_wbe = 0;
    reg  [31:0] irqc_wd = 0;
    wire [31:0] irqc_rdata;
    irqc irq_ctrl (
        .clk(clk), .reset(reset), .lines({5'b00000, pend}),
        .irq(irq), .irq_num(irq_num), .ack(irq_ack), .ack_num(irq_ack_num),
        .io_sel(irqc_wr), .io_we(1'b1), .io_be(irqc_wbe),
        .io_addr(irqc_wr ? irqc_wa : data_addr[3:2]), .io_wdata(irqc_wd),
        .io_rdata(irqc_rdata)
    );

    always @(posedge clk) begin
        data_ready <= 0;
        irqc_wr    <= 0;
        if (reset) begin
            pend <= 0; done <= 0; error <= 0;
            raised0 <= 0; raised1 <= 0; acked0 <= 0; acked1 <= 0;
            timer <= 0; acked2 <= 0;
        end else begin
            // device 2: asks when its timer runs out
            if (timer != 0) begin
                timer <= timer - 1;
                if (timer == 1) pend[2] <= 1;
            end
            // the devices ask now and then (not after the end)
            if (INTERRUPTS && !done) begin
                if (!pend[0] && ($random(seed) & 127) == 0) begin pend[0] <= 1; raised0 <= raised0 + 1; end
                if (!pend[1] && ($random(seed) & 127) == 0) begin pend[1] <= 1; raised1 <= raised1 + 1; end
            end
            if (data_sel && !data_ready) begin
                if (dwait < 0) dwait = $random(seed) & 3;
                if (dwait == 0) begin
                    data_ready <= 1;
                    if (data_we && is_dev) begin
                        case (data_addr[3:2])
                            2'd0: begin
                                      if (!pend[0]) begin error <= 1; $display("device 0 done, but it did not ask"); end
                                      pend[0] <= 0; acked0 <= acked0 + 1;
                                  end
                            2'd1: begin
                                      if (!pend[1]) begin error <= 1; $display("device 1 done, but it did not ask"); end
                                      pend[1] <= 0; acked1 <= acked1 + 1;
                                  end
                            2'd2: done <= 1;
                            default: begin error <= 1; $display("%m: a store to DEV + 12 (pc %h)", pc); end
                        endcase
                    end else if (data_we && is_dev2) begin
                        if (!data_addr[2]) timer <= data_wdata;                 // + 32: ask in n ticks
                        else begin                                               // + 36: done
                            if (!pend[2]) begin error <= 1; $display("device 2 done, but it did not ask"); end
                            pend[2] <= 0; acked2 <= acked2 + 1;
                        end
                    end else if (is_irqc) begin
                        if (data_we) begin
                            irqc_wr <= 1; irqc_wa <= data_addr[3:2];
                            irqc_wbe <= data_be; irqc_wd <= data_wdata;
                        end else
                            data_rdata <= irqc_rdata;
                    end else if (data_we) begin
                        if (data_be[0]) dmem[data_addr[12:2]][7:0]   <= data_wdata[7:0];
                        if (data_be[1]) dmem[data_addr[12:2]][15:8]  <= data_wdata[15:8];
                        if (data_be[2]) dmem[data_addr[12:2]][23:16] <= data_wdata[23:16];
                        if (data_be[3]) dmem[data_addr[12:2]][31:24] <= data_wdata[31:24];
                    end else
                        data_rdata <= dmem[data_addr[12:2]];
                    dwait = -1;
                end else dwait = dwait - 1;
            end
        end
    end

    // ---- INTR from a device in execute: taken or turned down
    always @(posedge clk)
        if (reset) begin
            taken <= 0; refused <= 0;
        end else if (processor.ex.go && processor.ex.e_hw) begin
            if (processor.ex.refuse) refused <= refused + 1;
            else                     taken   <= taken + 1;
        end
endmodule
