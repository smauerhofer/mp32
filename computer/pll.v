// pll.v: the clocks of the mp32 computer, from the board's 27 MHz. The book's pll
// (chapter 5 of 6502-gate-by-gate) with one more output, the processor's clock:
//
//   fast_clk   126 MHz   27 / 3 * 14: the HDMI serializers (five ticks a pixel)
//   pixel_clk  25.2 MHz  126 / 5 (CLKDIV): one tick, one pixel
//   cpu_clk    42 MHz    126 / 3: the processor, its memory and the I/O
//
// cpu_clk comes from the rPLL's CLKOUTD3, its divide-by-3 output. If the tools do
// not take CLKOUTD3, set CPU_PLL = 1: a second rPLL makes 42 MHz from 27 MHz on its
// own (27 / 9 * 14), not in step with the other two; the video unit hands over
// between its two clocks either way (see ../display2/video.v).
module pll #(
    parameter CPU_PLL = 0               // 0: CLKOUTD3 of the first rPLL, 1: a second rPLL
) (
    input  wire clk,                    // the board's 27 MHz clock
    output wire pixel_clk,              // 25.2 MHz
    output wire fast_clk,               // 126 MHz
    output wire cpu_clk,                // 42 MHz
    output wire locked                  // 1 once the PLLs have settled
);
    wire d3, lock1, lock2;

    rPLL #(
        .FCLKIN       ("27"),
        .IDIV_SEL     (2),              // divide by 3
        .FBDIV_SEL    (13),             // multiply by 14: 126 MHz
        .ODIV_SEL     (4),              // the oscillator at 504 MHz
        .CLKOUTD3_SRC ("CLKOUT")        // CLKOUTD3 = CLKOUT / 3 = 42 MHz
    ) multiply (
        .CLKIN    (clk),
        .CLKOUT   (fast_clk),
        .LOCK     (lock1),
        .RESET    (1'b0),
        .RESET_P  (1'b0),
        .CLKFB    (1'b0),
        .FBDSEL   (6'b000000),
        .IDSEL    (6'b000000),
        .ODSEL    (6'b000000),
        .PSDA     (4'b0000),
        .DUTYDA   (4'b0000),
        .FDLY     (4'b0000),
        .CLKOUTP  (),
        .CLKOUTD  (),
        .CLKOUTD3 (d3)
    );

    CLKDIV #(
        .DIV_MODE ("5")
    ) divide (
        .HCLKIN (fast_clk),
        .RESETN (lock1),
        .CALIB  (1'b0),
        .CLKOUT (pixel_clk)
    );

    generate
        if (CPU_PLL) begin : second
            wire c42;
            rPLL #(
                .FCLKIN    ("27"),
                .IDIV_SEL  (8),         // divide by 9
                .FBDIV_SEL (13),        // multiply by 14: 42 MHz
                .ODIV_SEL  (16)         // the oscillator at 672 MHz
            ) cpu_pll (
                .CLKIN    (clk),
                .CLKOUT   (c42),
                .LOCK     (lock2),
                .RESET    (1'b0),
                .RESET_P  (1'b0),
                .CLKFB    (1'b0),
                .FBDSEL   (6'b000000),
                .IDSEL    (6'b000000),
                .ODSEL    (6'b000000),
                .PSDA     (4'b0000),
                .DUTYDA   (4'b0000),
                .FDLY     (4'b0000),
                .CLKOUTP  (),
                .CLKOUTD  (),
                .CLKOUTD3 ()
            );
            assign cpu_clk = c42;
        end else begin : one
            assign cpu_clk = d3;
            assign lock2   = 1'b1;
        end
    endgenerate

    assign locked = lock1 & lock2;
endmodule
