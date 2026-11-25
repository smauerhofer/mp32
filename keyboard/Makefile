# The keyboard and the mouse of the mp32 computer: test it.
#   make test          run the test bench (keyboard.v at 42 MHz, with a model of the
#                      CH9350L module on both wires)
#   make size          synthesize the device alone and count what it takes
#   make clean         throw away what the build made
#
# In the computer, keyboard.v goes behind the I/O decoder (at $FFFF_0600, irq line 4),
# with the pins kbd_rx (42) and kbd_tx (41) in ../computer/top.cst.

BUILD  ?= build

BLOCKS = keyboard.v ../uart/uart_rx.v ../uart/uart_tx.v

test: $(BUILD)/keyboard_tb.vvp
	cd $(BUILD) && vvp keyboard_tb.vvp

# Simulation: iverilog compiles the test bench, vvp runs it.
$(BUILD)/keyboard_tb.vvp: keyboard_tb.v ch9350.v $(BLOCKS)
	mkdir -p $(BUILD)
	iverilog -g2005 -s keyboard_tb -o $@ $^

# What the chip makes of it, as if its ports were pins.
size: $(BLOCKS)
	yosys -p "read_verilog $^; synth_gowin -top keyboard; stat"

clean:
	rm -rf $(BUILD)

.PHONY: test size clean
.PRECIOUS: $(BUILD)/keyboard_tb.vvp
