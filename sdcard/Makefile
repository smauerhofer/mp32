# The microSD card of the mp32 computer, in SPI mode: test it, and see what the chip
# makes of it.
#   make test          run the test bench (against a model of a card, at 42 MHz)
#   make size          synthesize it alone and count what it takes
#   make clean         throw away what the build made
#
# There is no circuit for the board here: the card goes there inside the computer,
# behind the I/O decoder, with the pins from sdcard.cst.

BUILD ?= build

# The building blocks. Test benches pick what they need.
BLOCKS = sdcard.v

test: test-sdcard

# Simulation: iverilog compiles a test bench, vvp runs it.
$(BUILD)/%_tb.vvp: %_tb.v $(BLOCKS)
	mkdir -p $(BUILD)
	iverilog -g2005 -s $*_tb -o $@ $^

test-%: $(BUILD)/%_tb.vvp
	cd $(BUILD) && vvp $*_tb.vvp

# What the chip makes of it, as if its ports were pins.
size: $(BLOCKS)
	yosys -p "read_verilog $^; synth_gowin -top sdcard; stat"

clean:
	rm -rf $(BUILD)

.PHONY: test size clean
.PRECIOUS: $(BUILD)/%_tb.vvp
