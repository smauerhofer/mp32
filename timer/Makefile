# The two timers of the mp32 computer, as an I/O device: test it, and see what the
# chip makes of it.
#   make test          run the test bench (at 42 MHz)
#   make size          synthesize it alone and count what it takes
#   make clean         throw away what the build made
#
# There is no circuit for the board here: the timers go there inside the computer,
# behind the I/O decoder (0xFFFF_0700), on lines 6 and 7 of the interrupt controller.

BUILD ?= build

# The building blocks. Test benches pick what they need.
BLOCKS = timer.v

test: test-timer

# Simulation: iverilog compiles a test bench, vvp runs it.
$(BUILD)/%_tb.vvp: %_tb.v $(BLOCKS)
	mkdir -p $(BUILD)
	iverilog -g2005 -s $*_tb -o $@ $^

test-%: $(BUILD)/%_tb.vvp
	cd $(BUILD) && vvp $*_tb.vvp

# What the chip makes of it, as if its ports were pins.
size: $(BLOCKS)
	yosys -p "read_verilog $^; synth_gowin -top timer; stat"

clean:
	rm -rf $(BUILD)

.PHONY: test size clean
.PRECIOUS: $(BUILD)/%_tb.vvp
